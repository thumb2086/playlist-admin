import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'models/config_model.dart';
import 'services/config_service.dart';
import 'services/favorites_service.dart';
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
  dart cli_main.dart status                     Show status
  dart cli_main.dart play <歌曲名>               播放（本機庫優先，找不到走串流）
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

    case 'favorite':
      await _favoriteCmd(args.sublist(1), cfg);
      break;

    default:
      stderr.writeln('未知命令: $cmd');
      print('可用命令: pipeline, podcast, status, favorite');
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
      for (final f in dir.listSync()) {
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
