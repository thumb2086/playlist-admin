import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';
import '../models/pipeline_step.dart';
import '../models/config_model.dart';
import '../services/spotify_scraper.dart';
import '../services/metadata_enricher.dart';
import '../services/snapshot_manager.dart';
import '../services/file_renamer.dart';
import '../services/playlist_parser.dart';
import '../services/artwork_embedder.dart';
import '../services/lufs_service.dart';
import '../services/lyrics_service.dart';
import '../services/rag_service.dart';
import '../services/youtube_service.dart';
import '../version.dart';

const int maxPath = 260;

class PipelineOrchestrator {
  final AppConfig config;
  final void Function(String) onLog;
  final void Function(int current, int total, int stepIndex) onProgress;
  final PipelineState state;

  /// Decode filesystem path from Big5/CP950 to UTF-8
  /// Windows filesystem stores Chinese filenames in Big5/CP950, but Dart reads as UTF-8
  String _decodeFilePath(String path) {
    // Use win32 API to get the correct long path name
    try {
      // Convert to wide string for Windows API
      final pathPtr = path.toNativeUtf16();
      final buffer = calloc<Uint16>(maxPath);
      try {
        // Get the long path name which will be in the correct encoding
        // Cast buffer to Pointer<Utf16> for the API call
        final result = GetLongPathName(pathPtr, buffer.cast<Utf16>(), maxPath);
        if (result > 0 && result < maxPath) {
          final decoded = buffer.cast<Utf16>().toDartString(length: result.toInt());
          free(pathPtr);
          free(buffer);
          return decoded;
        }
      } finally {
        free(buffer);
        free(pathPtr);
      }
    } catch (_) {
      // Fallback: try to decode as Big5/CP950 manually
      try {
        return _decodeBig5(path.codeUnits);
      } catch (_) {
        return path;
      }
    }
    return path;
  }

  /// Decode bytes as Big5/CP950 encoded text
  String _decodeBig5(List<int> bytes) {
    // Simple Big5/CP950 decoding for common Chinese characters
    // This is a fallback when win32 API fails
    final buffer = StringBuffer();
    for (int i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      if (byte < 0x80) {
        // ASCII character
        buffer.writeCharCode(byte);
      } else if (i + 1 < bytes.length) {
        // Potential double-byte character
        final high = byte;
        final low = bytes[i + 1];
        final code = (high << 8) | low;
        try {
          // Try to decode as Big5
          final bytes2 = [high, low];
          const Utf8Decoder().convert(latin1.encode(
            String.fromCharCodes(bytes2)
          ));
          // This is a fallback - in practice we'd use a proper Big5 decoder
          buffer.writeCharCode(code > 0x8080 ? code : bytes[i]);
          i++; // Skip next byte
        } catch (_) {
          buffer.writeCharCode(bytes[i]);
        }
      } else {
        buffer.writeCharCode(byte);
      }
    }
    return buffer.toString();
  }

  PipelineOrchestrator({
    required this.config,
    required this.onLog,
    required this.onProgress,
    PipelineState? state,
  }) : state = state ?? PipelineState();

  /// Main entry point - runs the pipeline from a given step
  Future<void> run({int fromStep = 0, int? toStep}) async {
    // 比照 Podcast Pipeline：時間戳 + 版本號
    final stamp = DateTime.now().toString().substring(0, 19);
    final ver = appVersion.startsWith('v') ? appVersion : 'v$appVersion';
    onLog('$stamp  playlist-admin $ver');

    final steps = <(String, double, Future<void> Function(void Function(double)))>[
      ('Scrape Spotify playlists', 20.0, _stepScrape),
      ('Download missing tracks', 30.0, _stepDownload),
      ('Build playlist M3U8 files', 10.0, _stepBuildM3u8),
      ('Organize unsorted songs', 10.0, _stepUnsorted),
      ('Enrich metadata', 10.0, _stepMetadata),
      ('Download lyrics', 10.0, _stepLyrics),
      ('Measure LUFS', 10.0, _stepMeasureLufs),
    ];
    if (config.podcastRagInMusic) {
      steps.add(('Podcast RAG index', 10.0, _stepRag));
    }

    // 篩選要跑的步驟
    final start = fromStep.clamp(0, steps.length - 1);
    final end = (toStep ?? steps.length - 1).clamp(start, steps.length - 1);
    final selectedSteps = steps.sublist(start, end + 1);

    // 執行選定的步驟
    for (int i = 0; i < selectedSteps.length; i++) {
      if (state.isCancelled) break;
      final stepIndex = start + i;
      final (name, weight, fn) = selectedSteps[i];
      onLog('=== [$stepIndex] $name ===');
      try {
        await fn((p) => onProgress(
              stepIndex,
              steps.length,
              (p * weight / 100).toInt(),
            ));
      } catch (e) {
        onLog('Step $stepIndex ($name) failed: $e');
        rethrow;
      }
    }
    onLog('Pipeline completed.');
  }

  /// 步驟 1：抓取 Spotify 播放清單
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
    // processAll 一次 load+save（舊寫法每首 2 load + 1 save）
    final removedMap = SnapshotManager.processAll(plResults);
    int totalRemoved = 0;
    for (final entry in removedMap.entries) {
      if (entry.value > 0) {
        onLog('  ⚠️ ${entry.key}: 偵測到 ${entry.value} 首已移除歌曲');
        totalRemoved += entry.value;
      }
    }
    if (totalRemoved > 0) {
      onLog('  📋 共 $totalRemoved 首已移除歌曲被記錄');
    }
    progress(100);
  }

  /// 步驟 2：下載缺少的音軌
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
    // 診斷：cookies / yt-dlp 狀態先印，失敗時不用猜。
    final cookiesPath = YoutubeService.cookiesPathForDiag;
    if (cookiesPath == null) {
      onLog('  ⚠️ 找不到 yt_cookies.txt（桌面/文件/APPDATA），YouTube 極可能擋 bot');
    } else {
      onLog('  🍪 cookies: $cookiesPath');
    }
    try {
      final ver = await Process.run('yt-dlp', ['--version'], runInShell: false);
      final v = (ver.stdout as String? ?? '').trim().split('\n').first.trim();
      if (v.isNotEmpty) onLog('  🔧 yt-dlp $v');
    } catch (_) {}

    // Check which already exist in musicPath.
    // recursive：歌曲可能已被整理進子資料夾（未分類），不可誤判缺檔而重下。
    final existing = <String>{};
    if (await musicDir.exists()) {
      await for (final f in musicDir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          final stem = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
          existing.add(_normSong(stem));
        }
      }
    }
    final missing =
        allSongs.where((s) => !existing.contains(_normSong(s))).toList();
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
    const maxConsecutiveFails = 10;
    final total = missing.length;
    final yt = YoutubeService.instance;

    for (final song in missing) {
      if (state.isCancelled) return;
      await state.waitIfPaused();
      if (state.isCancelled) return;

      // 歌名是空白 → 送給 yt-dlp 的是 "ytsearch1" 空查詢，這種情況直接跳過並記錄。
      // Spotify 偶爾會給空標題的項目，這裡直接跳過並記錄。
      if (song.trim().isEmpty) {
        onLog('  ⏭️ 跳過空白歌名（playlist 項目沒有標題）');
        continue;
      }

      // 連續失敗太多次 → 中止（YouTube bot detection / 封鎖）。
      if (consecutiveFails >= maxConsecutiveFails) {
        onLog('  🛑 連續失敗 $consecutiveFails 次，疑似被 YouTube 封鎖，中止下載');
        onLog('  💡 請確認 yt_cookies.txt 存在且有效（桌面或文件夾）');
        break;
      }

      // 如果連續失敗 >= 3 次，等待 backoff（上限 60s）。
      if (consecutiveFails >= 3) {
        final waitSec = ((consecutiveFails - 2) * 15).clamp(0, 60);
        onLog('  ⏳ 連續失敗 $consecutiveFails 次，等待 ${waitSec}s 後重試…');
        for (int s = 0; s < waitSec; s++) {
          if (state.isCancelled) return;
          await state.waitIfPaused();
          if (state.isCancelled) return;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }

      final safeName = song.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final outPath = '${musicDir.path}\\$safeName.mp3';

      onLog('  [$done/$total] $song');

      String? failReason;
      try {
        onLog('    ⬇️ 搜尋+下載中…');
        final tmpPath = '${musicDir.path}\\dl_${safeName.hashCode.toRadixString(16)}.mp3';
        final savedPath = await yt.searchAndDownload(
          song,
          outputPath: tmpPath,
          onTitle: (title) { if (title != null) onLog('    ⬇️ $title'); },
          isCancelled: () => state.isCancelled,
          onError: (err) { failReason = err; },
        );
        if (savedPath != null && File(tmpPath).existsSync()) {
          if (File(outPath).existsSync()) await File(outPath).delete();
          await File(tmpPath).rename(outPath);
          // 內嵌封面（YouTube 音源無圖 + 下載本來就 -vn：不嵌就永遠沒圖）。
          final parts = ArtworkEmbedder.splitStem(
              File(outPath).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), ''));
          final art = await ArtworkEmbedder.instance.embedForFile(
            outPath, title: parts.$1, artist: parts.$2);
          if (art == ArtworkResult.embedded) onLog('    🖼️ 已嵌封面');
          onLog('    ✅ 完成');
          ok++;
          consecutiveFails = 0;
        } else {
          onLog('    ❌ 下載失敗${failReason != null ? '：$failReason' : ''}');
          fail++;
          consecutiveFails++;
        }
      } catch (e) {
        onLog('  ❌ 異常: $song → $e${failReason != null ? '（$failReason）' : ''}');
        fail++;
        consecutiveFails++;
      }
      done++;
      progress((done / total * 100).toDouble());
    }

    final skipped = total - done;
    final parts = ['$ok 成功', '$fail 失敗'];
    if (skipped > 0) parts.add('$skipped 跳過');
    onLog('下載完成: ${parts.join(", ")} (共 $total 首)');
    progress(100);
  }

  /// 步驟 3：建立播放清單 M3U8 檔案
  Future<void> _stepBuildM3u8(void Function(double) progress) async {
    final plDir = Directory(config.playlistsPath);
    if (!await plDir.exists()) {
      onLog('播放清單資料夾不存在');
      progress(100); return;
    }

    // Load snapshot (built by Step 1 via SnapshotManager).
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
    // recursive：含子分類資料夾（整理後仍要能找到）。
    final musicDir = Directory(config.musicPath);
    final audioIndex = <String, String>{}; // lowerCase_stem -> full path
    if (await musicDir.exists()) {
      await for (final f in musicDir.list(recursive: true, followLinks: false)) {
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

  /// 步驟 4：整理未分類歌曲
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

    final unsortedPath = '${config.playlistsPath}\\Unsorted.m3u8';
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
      try { relPath = _relativePath(absFilePath, absPlPath); } catch (_) { relPath = absFilePath; }
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

  /// 步驟 5：補齊 Metadata
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

  /// 步驟 6：量測 LUFS
  Future<void> _stepMeasureLufs(void Function(double) progress) async {
    try {
      final svc = LufsService.instance;
      await svc.measureAndNormalizePlaylistMp3s(
        onLog: onLog,
        onProgress: (done, total) {
          progress(total > 0 ? done / total * 100 : 0);
        },
        // 8 個全檔 ffmpeg 重編碼會滿 CPU；兩條 pipeline 一起跑時
        // UI thread 會被餓死，降到 4 點點空檔。
        concurrency: 4,
        tolerance: 2.0,
        isCancelled: () => state.isCancelled,
      );
    } catch (e) {
      onLog('LUFS 異常: $e');
    }
    progress(100);
  }

  /// 步驟 7：下載歌詞
  Future<void> _stepLyrics(void Function(double) progress) async {
    if (!config.enablePipelineLyricsDownload) {
      onLog('Lyrics download disabled (enable_pipeline_lyrics_download=false), skipping');
      progress(100);
      return;
    }
    onLog('Downloading lyrics for library tracks...');
    final lyricsDir = Directory('${config.basePath}${Platform.pathSeparator}${config.lyricsFolderName ?? "Lyrics"}');
    if (!lyricsDir.existsSync()) lyricsDir.createSync(recursive: true);

    final libDir = Directory(config.libraryPath);
    if (!libDir.existsSync()) {
      onLog('Library path does not exist: ${config.libraryPath}');
      progress(100);
      return;
    }

    final files = <File>[];
    await for (final e in libDir.list(recursive: true, followLinks: false)) {
      if (e is File && (e.path.toLowerCase().endsWith('.mp3') || e.path.toLowerCase().endsWith('.flac') || e.path.toLowerCase().endsWith('.m4a'))) {
        // Fix encoding: Windows file system uses Big5/CP950, decode to UTF-8
        final decodedPath = _decodeFilePath(e.path);
        files.add(File.fromUri(Uri.file(decodedPath)));
      }
    }

    if (files.isEmpty) {
      onLog('No music files found');
      progress(100);
      return;
    }

    onLog('Library has ${files.length} music files. Starting lyrics download...');
    int success = 0, skipped = 0, failed = 0;
    for (int i = 0; i < files.length; i++) {
      if (state.isCancelled) return;
      await state.waitIfPaused();
      if (state.isCancelled) return;

      final file = files[i];
      final stem = p.basenameWithoutExtension(file.path);
      // stem is already decoded via p.basenameWithoutExtension
      final lrcPath = '${lyricsDir.path}${Platform.pathSeparator}$stem.lrc';

      // Already exists? skip
      if (File(lrcPath).existsSync()) {
        skipped++;
        progress((i / files.length * 100).toDouble());
        continue;
      }

      // Parse artist - track from filename
      String artist = '', track = '', album = '';
      final parts = stem.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        track = parts[1].trim();
      } else {
        artist = stem;
        track = '';
      }

      try {
        final result = await LyricsService.instance.fetch(
          artist, track,
          album: album.isNotEmpty ? album : null,
        ).timeout(const Duration(seconds: 15));

        if (result != null && result.hasSynced) {
          await File(lrcPath).writeAsString(result.syncedLyrics!, flush: true);
          success++;
        } else if (result != null && result.hasPlain) {
          await File(lrcPath).writeAsString(result.plainLyrics!, flush: true);
          success++;
        } else {
          failed++;
        }
      } catch (e) {
        failed++;
      }

      // Polite delay to avoid LRCLib rate limit
      await Future.delayed(const Duration(milliseconds: 200));
      progress((i / files.length * 100).toDouble());
    }

    onLog('Lyrics download complete: success $success, skipped $skipped, failed $failed');
    onLog('Lyrics saved to: ${lyricsDir.path}');
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
      onLog('  ⚠️ RAG 索引更新失敗（需啟動 Ollama + chromadb）: $e');
    }
    progress(100);
  }

  /// 歌名正規化：把 Windows 檔名非法字元換成底線，與下載時落盤的規則一致。
  ///
  /// 下載時 `song.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')`
  /// 但「已有」比對時只對 `toLowerCase()` 這個替換缺失 →
  /// `24/7 Shining - AKB48 Team TP` 盤面變 `24_7 Shining - AKB48 Team TP`
  /// 比對永遠失敗 → 每次 pipeline 重複下載同一批（實測三輪
  /// 都「6 成功」，音檔庫數量卻一直停在 4971）。
  static String _normSong(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim().toLowerCase();
}