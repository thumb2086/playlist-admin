import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'models/config_model.dart';
import 'services/config_service.dart';
import 'services/favorites_service.dart';
import 'services/library_organizer.dart';
import 'services/library_doctor.dart';
import 'services/artwork_embedder.dart';
import 'services/metadata_enricher.dart';
import 'services/upload_budget.dart';
import 'services/spotify_session.dart';
import 'services/stream_server.dart';
import 'pipeline/pipeline_orchestrator.dart';
import 'pipeline/podcast_pipeline.dart';
import 'models/pipeline_step.dart';

// Shared CLI engine — used by the Flutter app binary itself (main.dart
// dispatches CLI args here) and by `playlist-admin` (npm wrapper spawning
// the built exe). One engine, two surfaces.
Future<void> runCli(List<String> args) async {
  await ConfigService.instance.load();
  final cfg = ConfigService.instance.config;

  if (args.isEmpty) {
    print('''playlist-admin CLI
Usage:
  dart cli_main.dart pipeline                   Run full pipeline
  dart cli_main.dart pipeline --step N          Run single step
  dart cli_main.dart podcast                    Run podcast pipeline
  dart cli_main.dart status                     Show status
  dart cli_main.dart play <歌曲名>               播放（本機庫優先，找不到走串流）
  dart cli_main.dart organize                    歌單外歌曲移入「未分類」資料夾（歌單原位）
  dart cli_main.dart artwork backfill           全庫 mp3 內嵌封面（有圖跳過，可重跑）
  dart cli_main.dart doctor                     音訊庫健康檢查（覆蓋率/損毀/品質/語言/STT額度）
  dart cli_main.dart favorite list              List favorite songs
  dart cli_main.dart favorite toggle <song>     Toggle favorite (我的最愛) by filename or path
''');
    return;
  }

  final cmd = args[0];

  switch (cmd) {
    case 'pipeline':
      final fromStep = _getFlag(args, '--step');
      final state = PipelineState();
      final orch = PipelineOrchestrator(
        config: cfg,
        onLog: (msg) => print(msg),
        onProgress: (c, t, s) {},
        state: state,
      );
      await orch.run(fromStep: fromStep);
      break;

    case 'podcast':
      final state = PipelineState();
      final pipeline = PodcastPipeline(
        onLog: (msg) => print(msg),
        onProgress: (c, t, s) {},
        state: state,
      );
      await pipeline.run();
      break;

    case 'status':
      print('''Library: ${cfg.libraryPath}
Playlists: ${cfg.urlNames.length}
Downloaded: ${cfg.lastUpdated.length}''');
      break;

    case 'play':
      if (args.length < 2) {
        print('Usage: playlist-admin play <歌曲名或關鍵字>');
        return;
      }
      await _playCmd(args.sublist(1).join(' ').trim());
      break;

    case 'organize':
      print('整理中：歌單外歌曲 → ${LibraryOrganizer.unsortedDirName}\\（歌單內原位）...');
      await LibraryOrganizer.organize(log: print);
      break;

    case 'artwork':
      if (args.length < 2 || args[1] != 'backfill') {
        print('Usage: dart cli_main.dart artwork backfill');
        return;
      }
      print('全庫內嵌封面（有圖跳過，Ctrl+C 中止，可重跑）...');
      try {
        await SpotifySession.instance.load();
      } catch (_) {}
      print(SpotifySession.instance.isLoggedIn
          ? 'Spotify 已登入：可搜尋缺漏封面'
          : '⚠️ Spotify 未登入：只嵌快取已有封面（先在 app 登入再重跑）');
      final stats = await ArtworkEmbedder.instance.backfill(
        onProgress: (done, total, file) {
          if (done % 50 == 0 || done == total) print('  [$done/$total] $file');
        },
      );
      print('完成：共 ${stats['total']} 首，'
          '已嵌 ${stats['embedded']}，已有圖跳過 ${stats['skipped']}，'
          '無封面 ${stats['noCover']}，失敗 ${stats['failed']}，'
          '補 album/date ${stats['tagged'] ?? 0}');
      break;

    case 'doctor':
      // 全庫健康檢查：覆蓋率 / 音訊完整性 / 逐字稿品質 / 語言一致性 / STT 額度。
      // 這五項都是「pipeline 回報成功但資料其實是壞的」案例的獨立驗證標準。
      final verbose = args.contains('--verbose') || args.contains('-v');
      final fast = args.contains('--fast');
      print('檢查音訊庫（${fast ? "快速模式，只看大小不看可解碼長度" : "完整模式"}）...');
      final t0 = DateTime.now();
      final report = await LibraryDoctor.run(
        podcastsDir: '${cfg.basePath}${Platform.pathSeparator}podcasts',
        skipAudioProbe: fast,
        onProgress: (d, t) => print('  [$d/$t]'),
      );
      print('');
      print(LibraryDoctor.format(report, verbose: verbose));
      print('耗時 ${(DateTime.now().difference(t0).inSeconds)} 秒');
      if (!args.contains('--no-stt')) {
        print('');
        print('STT 中轉額度：${await LibraryDoctor.probeStt()}');
      }
      break;

    case 'budget':
      if (args.length >= 2 && args[1] == 'reset') {
        // 每天（或重開機後）設一次「今日基準」，之後的判定都以此為準
        UploadBudget.markTodayBaseline();
        print('今日流量基準已設定（從現在起算）');
        print('  ${UploadBudget.todayText()}');
      } else if (args.length >= 2 && args[1] == 'today') {
        print(UploadBudget.todayText());
      } else {
        print(UploadBudget.describe());
        print('  ${UploadBudget.todayText()}');
        if (!UploadBudget.hasLimit) {
          print('  （未設 PA_UPLOAD_BUDGET_MB → 不限）');
        }
      }
      break;

    case 'metadata':
      if (args.length < 2) {
        print('Usage: dart cli_main.dart metadata '
            '<enrich|artists|years|spotify>');
        print('  enrich    從 spotify_cache + cover_cache 補 album/date/'
            'title/artist 到 ID3');
        print('            （album/date 的來源是 artwork backfill 寫的快取，'
            '所以正常流程是 backfill → enrich，不要同時跑）');
        print('  artists   ID3 英文歌手名轉中文（ArtistNames 對照表內）');
        print('  years     用 Spotify getTrack 補年份（需登入，每首一次請求，'
            '慢；--limit N 可先試跑）');
        print('  spotify   全庫以 Spotify 為準重寫 title/artist/album/year');
        print('            （--all 全庫重寫、預設只修有問題的：'
            'album 空/等於曲名/無年份；--limit N 試跑）');
        return;
      }
      if (args[1] == 'spotify') {
        final all = args.contains('--all');
        var lim = 0;
        final li = args.indexOf('--limit');
        if (li > 0 && li + 1 < args.length) {
          lim = int.tryParse(args[li + 1]) ?? 0;
        }
        await MetadataEnricher(
          log: print,
          libraryPath: cfg.musicPath,
        ).correctFromSpotify(
          onlyProblems: !all,
          limit: lim,
          onProgress: (done, total, file) {
            if (done % 50 == 0 || done == total) {
              print('  [$done/$total] $file');
            }
          },
        );
        break;
      }
      if (args[1] == 'artists') {
        print('artist 英文名 → 中文（只轉對照表有的，日韓歐美不動）...');
        await MetadataEnricher(
          log: print,
          libraryPath: cfg.musicPath,
        ).localizeArtists(
          onProgress: (done, total) {
            if (done % 100 == 0 || done == total) {
              print('  [$done/$total]');
            }
          },
        );
        break;
      }
      if (args[1] == 'years') {
        // Spotify 只有 getTrack 查詢會回 albumOfTrack.date；searchTracks 不回。
        var lim = 0;
        final li = args.indexOf('--limit');
        if (li > 0 && li + 1 < args.length) {
          lim = int.tryParse(args[li + 1]) ?? 0;
        }
        await MetadataEnricher(
          log: print,
          libraryPath: cfg.musicPath,
        ).fillYearsFromSpotify(
          limit: lim,
          onProgress: (done, total, file) {
            if (done % 50 == 0 || done == total) {
              print('  [$done/$total] $file');
            }
          },
        );
        break;
      }
      if (args[1] != 'enrich' && args[1] != 'tags') {
        print('Usage: dart cli_main.dart metadata <enrich|artists|years>');
        return;
      }
      print('補 metadata（只讀本地 spotify_cache + cover_cache）...');
      await MetadataEnricher(
        log: print,
        libraryPath: cfg.musicPath,
      ).enrichAll(
        onProgress: (done, total) {
          if (done % 50 == 0 || done == total) print('  [$done/$total]');
        },
      );
      break;

    case 'favorite':
      await _favoriteCmd(args.sublist(1), cfg);
      break;

    default:
      stderr.writeln('未知命令: $cmd');
      print('可用命令: pipeline, podcast, status, favorite, play, organize, artwork, metadata');
      exit(1);
  }
}

/// CLI 播放：本機庫優先，找不到走本地串流端點（邊下邊播）。
/// 無 GUI／不碰 SmtcService（那需要 Flutter engine）；Ctrl+C 即停。
Future<void> _playCmd(String query) async {
  if (query.isEmpty) {
    print('Usage: playlist-admin play <歌曲名或關鍵字>');
    return;
  }
  final cfg = ConfigService.instance.config;

  // 本機音樂庫比對（stem 全等或互含）。
  String? local;
  try {
    final dir = Directory(cfg.musicPath);
    if (dir.existsSync()) {
      final lower = query.toLowerCase();
      for (final f in dir.listSync(recursive: true)) {
        if (f is! File || !f.path.toLowerCase().endsWith('.mp3')) continue;
        final stem = f.uri.pathSegments.last
            .replaceAll(RegExp(r'\.\w+$'), '')
            .toLowerCase();
        if (stem == lower || stem.contains(lower) || lower.contains(stem)) {
          local = f.path;
          break;
        }
      }
    }
  } catch (_) {}

  MediaKit.ensureInitialized();
  final player = Player();
  player.setVolume(70); // media_kit 0~100
  // mpv 內部 log 直通 CLI：定位「Failed to open」的真正理由。
  player.stream.log.listen((l) {
    if (l.prefix == 'cplayer' && l.text.contains('Exiting')) return;
    print('[mpvlog] ${l.prefix}: ${l.text}');
  });
  try {
    if (local != null) {
      print('播放（本機）: ${local.split(Platform.pathSeparator).last}');
      await player.open(Media(Uri.file(local).toString()));
    } else {
      await StreamServer.instance.start();
      final url =
          '${StreamServer.instance.baseUrl}/stream/${Uri.encodeComponent(query)}';
      print('播放（串流）: $query');
      await player.open(Media(url));
    }
    player.stream.error.listen((e) => print('[mpv] $e'));
    final dur = await player.stream.duration.first
        .timeout(const Duration(seconds: 20))
        .catchError((_) => Duration.zero);
    if (dur > Duration.zero) {
      print('時長: ${dur.inMinutes}:${(dur.inSeconds % 60).toString().padLeft(2, '0')}');
    }
    print('（播完自動結束 / Ctrl+C 隨時中止）');
    // 等單曲播完；開檔失敗(mpv error)→ 有回報地結束，不吊著等 completed。
    await Future.any([
      player.stream.completed.first,
      player.stream.error.first.then((e) => throw Exception('播放失敗: $e')),
    ]).timeout(const Duration(hours: 2));
    print('播放結束');
  } finally {
    try { await player.dispose(); } catch (_) {}
    try { await StreamServer.instance.stop(); } catch (_) {}
  }
}

Future<void> _favoriteCmd(List<String> args, AppConfig cfg) async {
  if (args.isEmpty || args[0] == 'list') {
    final favs = await FavoritesService.load();
    if (favs.isEmpty) {
      print('我的最愛 (Favorites): (空)');
      return;
    }
    print('我的最愛 (Favorites): ${favs.length} 首');
    final sorted = favs.toList()..sort();
    for (final f in sorted) {
      final name = File(f).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      print('  ★ $name');
    }
    return;
  }

  final action = args[0];
  if (args.length < 2) {
    print('Usage: dart cli_main.dart favorite toggle <song>');
    return;
  }
  final song = await _resolveSong(cfg, args[1]);
  if (song == null) {
    print('找不到歌曲: ${args[1]}');
    return;
  }
  if (action == 'toggle') {
    final nowFav = await FavoritesService.toggle(song);
    print('${nowFav ? '★ 已加入' : '☆ 已移除'}我的最愛: ${File(song).uri.pathSegments.last}');
  } else if (action == 'add') {
    final favs = await FavoritesService.load();
    final key = FavoritesService.normalize(File(song).absolute.path);
    if (!favs.contains(key)) await FavoritesService.toggle(song);
    print('★ 已加入我的最愛: ${File(song).uri.pathSegments.last}');
  } else if (action == 'remove') {
    final favs = await FavoritesService.load();
    final key = FavoritesService.normalize(File(song).absolute.path);
    if (favs.contains(key)) await FavoritesService.toggle(song);
    print('☆ 已移除我的最愛: ${File(song).uri.pathSegments.last}');
  } else {
    print('未知操作: $action');
  }
}

Future<String?> _resolveSong(AppConfig cfg, String query) async {
  final q = query.trim();
  final direct = File(q);
  if (direct.existsSync()) return direct.absolute.path;
  if (File('$q.mp3').existsSync()) return File('$q.mp3').absolute.path;
  final lib = cfg.libraryPath;
  // 庫路徑不存在時 list() 直接拋 FileSystemException：先檢查。
  if (lib.isEmpty || !await Directory(lib).exists()) return null;
  final lower = q.toLowerCase();
  await for (final e in Directory(lib).list(recursive: true, followLinks: false)) {
    if (e is File) {
      final low = e.path.toLowerCase();
      if (!(low.endsWith('.mp3') || low.endsWith('.m4a') || low.endsWith('.flac'))) continue;
      final stem = File(e.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      if (stem.toLowerCase() == lower || File(e.path).uri.pathSegments.last.toLowerCase() == lower) {
        return e.path;
      }
    }
  }
  return null;
}

void main(List<String> args) async {
  try {
    await runCli(args);
    exit(0);
  } catch (e) {
    print('CLI fail: $e');
    exit(1);
  }
}

int _getFlag(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx >= 0 && idx + 1 < args.length) {
    return int.tryParse(args[idx + 1]) ?? 0;
  }
  return 0;
}
