import 'dart:convert';
import 'dart:io';
import '../models/pipeline_step.dart';
import '../models/config_model.dart';
import '../services/spotify_scraper.dart';
import '../services/metadata_enricher.dart';
import '../services/snapshot_manager.dart';
import '../services/file_renamer.dart';
import '../services/playlist_parser.dart';
import '../services/lufs_service.dart';
import '../services/rag_service.dart';
import '../services/youtube_service.dart';

class PipelineOrchestrator {
  final AppConfig config;
  final void Function(String) onLog;
  final void Function(int current, int total, int stepIndex) onProgress;
  final PipelineState state;

  PipelineOrchestrator({
    required this.config,
    required this.onLog,
    required this.onProgress,
    PipelineState? state,
  }) : state = state ?? PipelineState();

  Future<void> run({int fromStep = 0, int? toStep}) async {
    final steps = <(String, double, Future<void> Function(void Function(double)))>[
      ('Scrape Spotify playlists', 20.0, _stepScrape),
      ('Download missing tracks', 30.0, _stepDownload),
      ('Build playlist M3U8 files', 10.0, _stepBuildM3u8),
      ('Organize unsorted songs', 10.0, _stepUnsorted),
      ('Enrich metadata', 10.0, _stepMetadata),
      ('Measure LUFS', 10.0, _stepMeasureLufs),
    ];
    if (config.podcastRagInMusic) {
      steps.add(('Podcast RAG index', 10.0, _stepRag));
    }

    final end = toStep ?? steps.length;
    int doneWeight = 0;
    for (int i = 0; i < fromStep && i < steps.length; i++) {
      doneWeight += steps[i].$2.toInt();
    }

    for (int i = fromStep; i < end; i++) {
      if (state.isCancelled) break;
      await state.waitIfPaused();
      if (state.isCancelled) break;

      onLog('--- Step ${i + 1}/${steps.length}: ${steps[i].$1} ---');
      onProgress(0, 100, i);

      try {
        await steps[i].$3((pct) {
          final global = doneWeight + (pct / 100.0 * steps[i].$2);
          onProgress(global.toInt(), 100, i);
        });
      } catch (e) {
        onLog('  ❌ ${steps[i].$1} 失敗: $e');
        if (!state.isCancelled) {
          state.cancel();
        }
      }
      doneWeight += steps[i].$2.toInt();
    }

    if (state.isCancelled) {
      onLog('Pipeline 已取消');
    } else {
      onLog('Pipeline 完成');
    }
  }

  /// Standalone RAG index rebuild (index position varies when the RAG step is
  /// toggled in the music pipeline, so run it directly).
  Future<void> runRagOnly() async {
    onLog('--- Podcast RAG index ---');
    _stepRag((_) {});
  }

  Future<void> _stepDownload(void Function(double) progress) async {
    final musicDir = Directory(config.musicPath);
    await musicDir.create(recursive: true);

    // Load snapshot_cache.json (built by Step 1 via SnapshotManager).
    final snapFile = File('${config.basePath}\\snapshot_cache.json');
    if (!await snapFile.exists()) {
      onLog('找不到 snapshot_cache.json，跳過下載');
      progress(100); return;
    }
    final snap = jsonDecode(await snapFile.readAsString()) as Map<String, dynamic>;
    final playlists = snap['playlists'] as Map<String, dynamic>? ?? {};

    // Collect all unique songs from playlists.
    final allSongs = <String>{};
    for (final pl in playlists.values) {
      final tracks = (pl as Map<String, dynamic>)['tracks'] as List<dynamic>? ?? [];
      for (final t in tracks) {
        allSongs.add(t as String);
      }
    }
    if (allSongs.isEmpty) {
      onLog('無歌曲需下載');
      progress(100); return;
    }
    onLog('播放清單共 ${allSongs.length} 首歌曲');

    // Check which already exist in musicPath.
    final existing = <String>{};
    if (await musicDir.exists()) {
      await for (final f in musicDir.list()) {
        if (f is File) {
          final stem = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
          existing.add(stem.toLowerCase());
        }
      }
    }
    final missing = allSongs.where((s) => !existing.contains(s.toLowerCase())).toList();
    onLog('已有 ${existing.length} 首，需下載 ${missing.length} 首');

    if (missing.isEmpty) {
      onLog('所有歌曲已下載');
      progress(100); return;
    }

    // Download missing songs using yt-dlp — serial with retry.
    int done = 0;
    int ok = 0;
    int fail = 0;
    int consecutiveFails = 0;
    final total = missing.length;
    final yt = YoutubeService.instance;

    for (final song in missing) {
      if (state.isCancelled) return;
      await state.waitIfPaused();
      if (state.isCancelled) return;

      // 如果連續失敗太多次，等待較久（YouTube rate limit）
      if (consecutiveFails >= 3) {
        final waitSec = (consecutiveFails - 2) * 15;
        onLog('  ⏳ 連續失敗 $consecutiveFails 次，等待 ${waitSec}s 後重試…');
        await Future<void>.delayed(Duration(seconds: waitSec));
      }

      final safeName = song.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final outPath = '${musicDir.path}\\$safeName.mp3';

      onLog('  [$done/$total] $song');

      try {
        onLog('    ⬇️ 搜尋+下載中…');
        final tmpPath = '${musicDir.path}\\dl_${safeName.hashCode.toRadixString(16)}.mp3';
        final savedPath = await yt.searchAndDownload(
          song,
          outputPath: tmpPath,
          onTitle: (title) { if (title != null) onLog('    ⬇️ $title'); },
        );
        if (savedPath != null && File(tmpPath).existsSync()) {
          if (File(outPath).existsSync()) await File(outPath).delete();
          await File(tmpPath).rename(outPath);
          onLog('    ✅ 完成');
          ok++;
          consecutiveFails = 0;
        } else {
          onLog('    ❌ 下載失敗');
          fail++;
          consecutiveFails++;
        }
      } catch (e) {
        onLog('  ❌ 異常: $song → $e');
        fail++;
        consecutiveFails++;
      }
      done++;
      progress((done / total * 100).toDouble());
    }

    onLog('下載完成: $ok 成功, $fail 失敗 (共 $total 首)');
    progress(100);
  }

  Future<void> _stepScrape(void Function(double) progress) async {
    final urls = config.urlNames.keys.toList();
    if (urls.isEmpty) {
      onLog('沒有 Spotify URL');
      progress(100); return;
    }
    await Directory(config.playlistsPath).create(recursive: true);

    final scraper = SpotifyScraper(log: onLog, playlistsPath: config.playlistsPath, libraryPath: config.libraryPath);
    final plResults = await scraper.scrapeAll(urls, writeM3u8: false);

    // Snapshot: save ALL track names from scraper (not just resolved ones from m3u8).
    int totalRemoved = 0;
    for (final entry in plResults.entries) {
      final plName = entry.key;
      final allTracks = entry.value;
      final removed = SnapshotManager.processPlaylist(plName, allTracks);
      if (removed > 0) {
        onLog('  📋 $plName: 偵測到 $removed 首已移除歌曲');
        totalRemoved += removed;
      }
    }
    if (totalRemoved > 0) {
      onLog('  📋 共 $totalRemoved 首已移除歌曲被記錄');
    }
    progress(100);
  }

  Future<void> _stepBuildM3u8(void Function(double) progress) async {
    final plDir = Directory(config.playlistsPath);
    if (!await plDir.exists()) {
      onLog('播放清單資料夾不存在');
      progress(100); return;
    }

    // Load snapshot (built by Step 1).
    final snapFile = File('${config.basePath}\\snapshot_cache.json');
    if (!await snapFile.exists()) {
      onLog('找不到 snapshot_cache.json，跳過 M3U8 產生');
      progress(100); return;
    }
    final snap = jsonDecode(await snapFile.readAsString()) as Map<String, dynamic>;
    final playlists = snap['playlists'] as Map<String, dynamic>? ?? {};

    if (playlists.isEmpty) {
      onLog('無歌單資料');
      progress(100); return;
    }

    // Build audio index: scan musicPath for existing files.
    final musicDir = Directory(config.musicPath);
    final audioIndex = <String, String>{}; // lowerCase_stem -> full path
    if (await musicDir.exists()) {
      await for (final f in musicDir.list()) {
        if (f is File) {
          final low = f.path.toLowerCase();
          if (low.endsWith('.mp3') || low.endsWith('.m4a') || low.endsWith('.flac') || low.endsWith('.wav')) {
            final stem = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
            audioIndex[stem.toLowerCase()] = f.path;
          }
        }
      }
    }

    await Directory(config.playlistsPath).create(recursive: true);
    int totalPl = playlists.length;
    int idx = 0;
    int totalResolved = 0;
    int totalTracks = 0;

    for (final entry in playlists.entries) {
      idx++;
      if (state.isCancelled) break;
      await state.waitIfPaused();
      if (state.isCancelled) break;

      final plName = entry.key;
      final plData = entry.value as Map<String, dynamic>;
      final tracks = (plData['tracks'] as List<dynamic>?)?.cast<String>() ?? [];
      if (tracks.isEmpty) continue;

      final buffer = StringBuffer('#EXTM3U\n');
      int resolved = 0;

      for (final t in tracks) {
        final match = audioIndex[t.toLowerCase()];
        if (match != null) {
          final localName = File(match).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
          buffer.writeln('#EXTINF:-1,$localName');
          final absPath = File(match).absolute.path;
          final absPl = Directory('${config.playlistsPath}\\$plName.m3u8').parent.absolute.path;
          String relPath;
          try { relPath = _relativePath(absPath, absPl); } catch (_) { relPath = match; }
          buffer.writeln(relPath);
          resolved++;
        }
        // Skip tracks not on disk (prune effect)
      }

      final m3uPath = '${config.playlistsPath}\\$plName.m3u8';
      await File(m3uPath).writeAsString(buffer.toString(), flush: true);

      totalResolved += resolved;
      totalTracks += tracks.length;
      onLog('  $plName.m3u8 ($resolved/${tracks.length})');
      progress((idx / totalPl * 100).toDouble());
    }

    onLog('M3U8 產生完成: $totalResolved/$totalTracks 首已解析路徑');
    progress(100);
  }

  Future<void> _stepUnsorted(void Function(double) progress) async {
    final plDir = Directory(config.playlistsPath);
    if (!await plDir.exists()) { progress(100); return; }

    final allPlaylistSongs = <String>{};
    await for (final e in plDir.list()) {
      if (e is File) {
        final low = e.path.toLowerCase();
        if (!(low.endsWith('.m3u8') || low.endsWith('.m3u'))) continue;
        if (PlaylistParser.isInternalPlaylist(File(e.path).uri.pathSegments.last)) continue;
        try {
          final names = PlaylistParser.parseTrackNames(e.path);
          for (final n in names) {
            allPlaylistSongs.add(n.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
          }
        } catch (_) {}
      }
    }

    final unsortedFiles = <String>[];
    final libDir = Directory(config.libraryPath);
    if (await libDir.exists()) {
      await for (final e in libDir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final low = e.path.toLowerCase();
          if (!(low.endsWith('.mp3') || low.endsWith('.m4a') || low.endsWith('.flac'))) continue;
          final stem = e.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
          if (!allPlaylistSongs.contains(stem)) unsortedFiles.add(e.path);
        }
      }
    }

    final unsortedPath = '${config.playlistsPath}\\_Unsorted.m3u8';
    final existingStems = <String>{};
    if (await File(unsortedPath).exists()) {
      try {
        final existing = PlaylistParser.parseTrackEntries(unsortedPath);
        for (final e in existing) {
          existingStems.add(File(e).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
        }
      } catch (_) {}
    }

    final newUnsorted = unsortedFiles.where((f) {
      final stem = File(f).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      return !existingStems.contains(stem.toLowerCase());
    }).toList();

    if (newUnsorted.isEmpty) {
      onLog('未分類歌曲共 ${unsortedFiles.length} 首，無新增');
      progress(100); return;
    }

    final sb = StringBuffer();
    if (existingStems.isEmpty) sb.write('#EXTM3U\n');
    for (final filePath in newUnsorted) {
      final absFilePath = File(filePath).absolute.path;
      final absPlPath = Directory(unsortedPath).parent.absolute.path;
      String relPath;
      try {
        relPath = _relativePath(absFilePath, absPlPath);
      } catch (_) {
        relPath = absFilePath;
      }
      // Raw relative path only — Echo Nightly does NOT decode %XX escapes.
      final nameNoExt = File(filePath).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      sb.writeln('#EXTINF:-1,$nameNoExt');
      sb.writeln(relPath);
    }

    await File(unsortedPath).writeAsString(sb.toString(),
        mode: existingStems.isEmpty ? FileMode.write : FileMode.append);
    onLog('已為 ${newUnsorted.length} 首新未分類歌曲更新清單 (共 ${unsortedFiles.length} 首)');
    progress(100);
  }

  String _relativePath(String absPath, String relativeTo) {
    final absParts = absPath.replaceAll('\\', '/').split('/');
    final relParts = relativeTo.replaceAll('\\', '/').split('/');
    if (absParts.first.toLowerCase() != relParts.first.toLowerCase()) {
      // 跨磁碟：回傳絕對路徑，避免產生 ../../D:/ 這種無效相對路徑
      return absPath.replaceAll('\\', '/');
    }
    int common = 0;
    while (common < absParts.length && common < relParts.length &&
        absParts[common].toLowerCase() == relParts[common].toLowerCase()) {
      common++;
    }
    final up = List.filled(relParts.length - common, '..');
    final down = absParts.sublist(common);
    return [...up, ...down].join('/');
  }

  Future<void> _stepMetadata(void Function(double) progress) async {
    if (!config.enableMetadataEnrichment) {
      onLog('Metadata enrichment 未啟用，跳過');
      progress(100);
      return;
    }
    onLog('Metadata enrichment 已啟用，開始掃描…');
    final enricher = MetadataEnricher(
      log: onLog,
      libraryPath: config.libraryPath,
    );
    await enricher.enrichAll(onProgress: (current, total) {
      progress(total > 0 ? current / total * 100 : 0);
    });

    onLog('根據 metadata 重新命名檔案…');
    final renamer = FileRenamer(
      log: onLog,
      libraryPath: config.libraryPath,
    );
    final result = await renamer.batchRename();
    final renamed = result['renamed'] as int;
    if (renamed > 0) {
      onLog('重新命名完成: $renamed 個檔案');
    } else {
      onLog('無需重新命名');
    }
    progress(100);
  }

  Future<void> _stepMeasureLufs(void Function(double) progress) async {
    try {
      final svc = LufsService.instance;
      await svc.measureAndNormalizePlaylistMp3s(
        onLog: onLog,
        onProgress: (done, total) {
          progress(total > 0 ? done / total * 100 : 0);
        },
        // 8 個全檔 ffmpeg 重編碼會吃滿 CPU；兩條 pipeline 一起跑時
        // UI thread 會被餓死，降到 4 留一點喘息空間。
        concurrency: 4,
        tolerance: 2.0,
        isCancelled: () => state.isCancelled,
      );
    } catch (e) {
      onLog('LUFS 異常: $e');
    }
    progress(100);
  }

  /// Update the podcast RAG vector index (incremental, non-fatal).
  Future<void> _stepRag(void Function(double) progress) async {
    if (state.isCancelled) return;
    onLog('檢查 Podcast 逐字稿並更新 RAG 向量庫…');
    try {
      await RagService.instance.build((line) {
        if (state.isCancelled) return;
        onLog('  $line');
        // build_db.py 進度行格式: [12/219] 42.5% | ...
        final m = RegExp(r'\[(\d+)/(\d+)\]\s+[\d.]+%').firstMatch(line);
        if (m != null) {
          final done = int.tryParse(m.group(1)!) ?? 0;
          final total = int.tryParse(m.group(2)!) ?? 0;
          if (total > 0) progress(done / total * 100);
        }
      });
      onLog('✅ RAG 索引已更新');
    } catch (e) {
      onLog('  ⚠️ RAG 索引更新失敗（需要 Ollama + chromadb）: $e');
    }
    progress(100);
  }
}
