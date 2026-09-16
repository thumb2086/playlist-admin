import 'dart:convert';
import 'dart:io';
import 'config_service.dart';

class LufsService {
  static final LufsService _instance = LufsService._();
  static LufsService get instance => _instance;
  LufsService._();

  String get _cacheDir => ConfigService.instance.config.basePath;
  String _cacheFile(String fmt) => '$_cacheDir\\${fmt}_lufs_cache.json';

  Map<String, double> _load(String fmt) {
    try {
      final f = File(_cacheFile(fmt));
      if (!f.existsSync()) return {};
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final result = <String, double>{};
      for (final e in json.entries) {
        // Normalize cache keys: resolve ../ or ..\\ in paths.
        final key = e.key.replaceAll('\\', '/').contains('..')
            ? _normalizeCacheKey(e.key) : e.key;
        result[key] = (e.value as num).toDouble();
      }
      return result;
    } catch (_) { return {}; }
  }

  static String _normalizeCacheKey(String path) {
    try {
      final f = File(path);
      return f.absolute.path;
    } catch (_) { return path; }
  }

  void _save(String fmt, Map<String, double> cache) {
    try {
      File(_cacheFile(fmt)).writeAsStringSync(
        jsonEncode(cache), flush: true);
    } catch (_) {}
  }

  int cachedCount(String fmt) => _load(fmt).length;

  String? _ffmpegPath;

  Future<String> _resolveFfmpeg() async {
    if (_ffmpegPath != null) return _ffmpegPath!;
    _ffmpegPath = ConfigService.instance.config.resolvedFfmpegPath;
    return _ffmpegPath!;
  }

  /// Resolve a playlist entry path to an absolute file path.
  String? _resolvePlaylistPath(String entry, String playlistsPath, String basePath, String libraryPath) {
    String decodePath(String s) {
      try { return Uri.decodeComponent(s); } catch (_) { return s; }
    }
    entry = decodePath(entry);
    if (entry.isEmpty) return null;
    if (!entry.contains('.') && !entry.contains('\\') && !entry.contains('/')) return null;

    // Try resolving against playlists directory (handles ../music/ relative paths).
    final resolved = '$playlistsPath\\$entry';
    if (File(resolved).existsSync()) {
      // Normalize to absolute path (remove ..) so ffmpeg works correctly.
      try {
        return File(resolved).resolveSymbolicLinksSync();
      } catch (_) {
        return File(resolved).absolute.path;
      }
    }

    if (File(entry).existsSync()) {
      try { return File(entry).resolveSymbolicLinksSync(); } catch (_) { return File(entry).absolute.path; }
    }

    final fname = File(entry).uri.pathSegments.last;
    for (final base in [basePath, libraryPath, playlistsPath]) {
      final candidate = '$base\\$fname';
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Collect all MP3 file paths referenced in non-internal playlist m3u8 files.
  Future<Set<String>> getPlaylistMp3Files(String playlistsPath, String basePath, String libraryPath) async {
    final plDir = Directory(playlistsPath);
    if (!await plDir.exists()) return {};

    final mp3Files = <String>{};
    await for (final e in plDir.list()) {
      if (e is! File) continue;
      final low = e.path.toLowerCase();
      if (!low.endsWith('.m3u8') && !low.endsWith('.m3u')) continue;
      if (_isInternalPlaylist(e.path)) continue;

      try {
        final content = await e.readAsString(encoding: utf8);
        for (final line in content.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          if (!trimmed.contains('.mp3') && !trimmed.contains('.m4a') && !trimmed.contains('.flac')) continue;
          final resolved = _resolvePlaylistPath(trimmed, playlistsPath, basePath, libraryPath);
          if (resolved != null && resolved.toLowerCase().endsWith('.mp3')) {
            mp3Files.add(resolved);
          }
        }
      } catch (_) {}
    }
    return mp3Files;
  }

  static bool _isInternalPlaylist(String path) {
    final name = File(path).uri.pathSegments.last.toLowerCase();
    if (name.contains('_removed songs') || name.contains('_unsorted') || name.contains('single tracks') || name.contains('_favorites')) return true;
    return false;
  }

  /// Normalize all playlisted MP3s to -14 LUFS in a single pass.
  /// Captures the measured input LUFS from ffmpeg stderr to update cache.
  /// This gives complete (whole-file) LUFS measurement + normalization together,
  /// which is faster than measuring first then normalizing separately.
  Future<void> measureAndNormalizePlaylistMp3s({
    required void Function(String log) onLog,
    void Function(int done, int total)? onProgress,
    int concurrency = 8,
    double tolerance = 2.0,
    bool Function()? isCancelled,
  }) async {
    final config = ConfigService.instance.config;
    final lib = config.libraryPath;
    final plPath = config.playlistsPath;
    final base = config.basePath;

    if (lib.isEmpty || plPath.isEmpty) {
      onLog('Library or Playlists path not configured');
      return;
    }

    onLog('掃描歌單中的 MP3 檔案…');
    final playlistFiles = await getPlaylistMp3Files(plPath, base, lib);
    if (playlistFiles.isEmpty) {
      onLog('歌單中沒有 MP3 檔案');
      return;
    }
    onLog('歌單內共 ${playlistFiles.length} 個 MP3');

    final cache = _load('mp3');
    const target = -14.0;

    // Determine which files actually need normalization (uncached or deviating)
    final needsNormalize = <String>[];
    int skipCount = 0;
    for (final path in playlistFiles) {
      final cached = cache[path];
      if (cached != null && (cached - target).abs() <= tolerance) {
        skipCount++;
      } else {
        needsNormalize.add(path);
      }
    }

    if (needsNormalize.isEmpty) {
      onLog('所有歌單 MP3 已在 $target±${tolerance}LUFS 範圍內 (已快取 $skipCount 檔)');
      return;
    }

    onLog('需 Normalize/測量: ${needsNormalize.length} 檔 ($skipCount 檔已合格)');
    final ffmpeg = await _resolveFfmpeg();
    int done = 0;
    int total = needsNormalize.length;
    int lastSave = 0;

    // Process with concurrency
    for (int i = 0; i < total; i += concurrency) {
      if (isCancelled?.call() ?? false) break;
      final batch = needsNormalize.skip(i).take(concurrency).toList();
      final futures = <Future<void>>[];
      for (final path in batch) {
        futures.add(_normalizeOne(path, ffmpeg, target, cache, onLog, isCancelled: isCancelled));
      }
      await Future.wait(futures);
      if (isCancelled?.call() ?? false) break;
      done += batch.length;
      onProgress?.call(done, total);

      if (done - lastSave >= 10) {
        _save('mp3', cache);
        lastSave = done;
        onLog('  進度: $done/$total');
      }
    }

    _save('mp3', cache);
    if (isCancelled?.call() ?? false) {
      onLog('LUFS 已取消（已處理 $done 檔）');
    } else {
      onLog('完成: $done 個檔案已統一至 $target LUFS');
    }
  }

  /// Run loudnorm normalization in one pass and capture input LUFS from stderr.
  Future<void> _normalizeOne(String absPath, String ffmpeg, double target,
      Map<String, double> cache, void Function(String) onLog,
      {bool Function()? isCancelled}) async {
    final file = File(absPath);
    if (!await file.exists()) return;

    // Skip 0-byte files (corrupt/failed output) instead of failing every run.
    try {
      if (await file.length() == 0) {
        onLog('  ⚠️ 跳過 0-byte 空檔（未計入快取，需重新轉檔）: $absPath');
        return;
      }
    } catch (_) {}

    final base = absPath.substring(0, absPath.lastIndexOf('.'));
    final tmp = '${base}_tmp.mp3';
    final name = absPath.split(Platform.pathSeparator).last;

    try {
      final proc = await Process.start(ffmpeg, [
        '-y', '-i', absPath,
        '-vn',
        '-af', 'loudnorm=I=$target:TP=-1:LRA=7',
        '-c:a', 'libmp3lame', '-q:a', '2', tmp,
      ]);

      final result = await _runWithCancel(proc, isCancelled);
      if (result == null) return; // cancelled

      if (result.exitCode != 0 || !await File(tmp).exists()) {
        onLog('  ❌ $name normalize 失敗');
        return;
      }

      // Parse input LUFS from stderr: "Input Integrated:    -15.2 LUFS"
      double inputLufs = target;
      final stderr = result.stderr as String? ?? '';
      final inputMatch = RegExp(r'Input Integrated:\s+([-\d.]+)').firstMatch(stderr);
      if (inputMatch != null) {
        inputLufs = double.tryParse(inputMatch.group(1)!) ?? target;
      }

      await File(tmp).rename(absPath);
      cache[absPath] = target;

      if ((inputLufs - target).abs() > 0.1) {
        onLog('  ✅ $name  (${inputLufs.toStringAsFixed(1)} → $target)');
      }
    } catch (ex) {
      onLog('  ⚠️ $name: $ex');
    }
  }

  /// Run a process while polling for cancellation; returns null if cancelled.
  Future<ProcessResult?> _runWithCancel(Process proc, bool Function()? isCancelled) async {
    final stderrBuf = <int>[];
    final outBuf = <int>[];
    proc.stderr.listen(stderrBuf.addAll);
    proc.stdout.listen(outBuf.addAll);
    while (true) {
      if (isCancelled?.call() ?? false) {
        proc.kill(ProcessSignal.sigkill);
        return null;
      }
      final exited = await proc.exitCode.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () => -1,
      );
      if (exited != -1) {
        return ProcessResult(proc.pid, exited,
            String.fromCharCodes(outBuf), String.fromCharCodes(stderrBuf));
      }
    }
  }

  /// Measure and cache an M4A file's LUFS.
  /// MP3 cache is intentionally NOT written here: conversion already applies
  /// loudnorm to -14, and Step 6 (Measure LUFS) records real values when it
  /// normalizes playlist MP3s.
  Future<void> cacheConversionLufs(String m4aPath, String mp3Path,
      {bool Function()? isCancelled}) async {
    final m4aCache = _load('m4a');
    if (!m4aCache.containsKey(m4aPath)) {
      await _measureOne(m4aPath, m4aCache, (v) { m4aCache[m4aPath] = v; },
          isCancelled: isCancelled);
      _save('m4a', m4aCache);
    }
  }

  /// Cache the M4A LUFS value already measured by loudnorm during conversion.
  /// No extra ffmpeg scan. Falls back to a full measurement if null.
  void cacheConversionLufsFast(String m4aPath, String mp3Path, double? lufs) {
    final m4aCache = _load('m4a');
    if (!m4aCache.containsKey(m4aPath) && lufs != null) {
      m4aCache[m4aPath] = lufs;
      _save('m4a', m4aCache);
    }
  }

  /// Delete the mp3 LUFS cache to force a fresh measurement.
  void clearMp3Cache() {
    try { File(_cacheFile('mp3')).deleteSync(); } catch (_) {}
  }

  /// Legacy: measure all files of given format (for completeness).
  Future<void> measureFormat(String fmt, {
    required void Function(String log) onLog,
    void Function(int done, int total)? onProgress,
    int concurrency = 8,
  }) async {
    final lib = ConfigService.instance.config.libraryPath;
    if (lib.isEmpty) { onLog('Library path not configured'); return; }

    final cache = _load(fmt);
    final allFiles = <String>[];
    final libDir = Directory(lib);
    if (!await libDir.exists()) { onLog('Library not found: $lib'); return; }

    await for (final e in libDir.list(recursive: true, followLinks: false)) {
      if (e is File && e.path.toLowerCase().endsWith('.$fmt')) {
        allFiles.add(e.path);
      }
    }

    final toMeasure = allFiles.where((f) => !cache.containsKey(f)).toList();
    if (toMeasure.isEmpty) {
      onLog('[$fmt] 所有 ${allFiles.length} 個檔案已快取');
      return;
    }
    onLog('[$fmt] ${allFiles.length} 個檔案，${cache.length} 已快取，需測量 ${toMeasure.length}');

    int done = 0;
    int total = toMeasure.length;
    int lastSave = 0;

    for (int i = 0; i < total; i += concurrency) {
      final batch = toMeasure.skip(i).take(concurrency).toList();
      final futures = <Future<void>>[];
      for (final path in batch) {
        futures.add(_measureOne(path, cache, (v) { cache[path] = v; }));
      }
      await Future.wait(futures);
      done += batch.length;
      onProgress?.call(done, total);

      if (done - lastSave >= 25) {
        _save(fmt, cache);
        lastSave = done;
      }
    }

    _save(fmt, cache);
    onLog('[$fmt] 測量完成，共 ${cache.length} 個檔案');
  }

  Future<void> _measureOne(String path, Map<String, double> cache,
      void Function(double) onResult, {bool Function()? isCancelled}) async {
    final ffmpeg = await _resolveFfmpeg();
    try {
      final proc = await Process.start(ffmpeg, [
        '-i', path,
        '-af', 'loudnorm=print_format=json',
        '-f', 'null', '-', '-hide_banner', '-y',
      ]);
      final result = await _runWithCancel(proc, isCancelled);
      if (result == null) { onResult(-14.0); return; }
      if (result.exitCode != 0) { onResult(-14.0); return; }

      final stderr = result.stderr as String? ?? '';
      final jsonStart = stderr.lastIndexOf('{');
      if (jsonStart >= 0) {
        try {
          final data = jsonDecode(stderr.substring(jsonStart)) as Map<String, dynamic>;
          final inputI = data['input_i'];
          if (inputI != null) {
            onResult((inputI as num).toDouble());
            return;
          }
        } catch (_) {}
      }
      onResult(-14.0);
    } catch (_) {
      onResult(-14.0);
    }
  }

  /// Legacy: normalize all MP3s (for completeness).
  Future<void> normalizeMp3({
    required void Function(String log) onLog,
    void Function(int done, int total)? onProgress,
    double tolerance = 2.0,
  }) async {
    final lib = ConfigService.instance.config.libraryPath;
    if (lib.isEmpty) { onLog('Library path not configured'); return; }

    final cache = _load('mp3');
    if (cache.isEmpty) { onLog('MP3 LUFS 快取為空，跳過 normalize'); return; }

    const target = -14.0;
    final toNormalize = <String, double>{};
    for (final e in cache.entries) {
      if ((e.value - target).abs() > tolerance) {
        toNormalize[e.key] = e.value;
      }
    }

    if (toNormalize.isEmpty) {
      onLog('所有 MP3 已在 $target±$tolerance LUFS 範圍內');
      return;
    }

    onLog('Normalize ${toNormalize.length} 個偏離 $target 的 MP3...');
    final ffmpeg = await _resolveFfmpeg();
    int done = 0;
    int total = toNormalize.length;

    for (final e in toNormalize.entries) {
      final absPath = e.key;
      if (!await File(absPath).exists()) continue;

      final base = absPath.substring(0, absPath.lastIndexOf('.'));
      final tmp = '${base}_tmp.mp3';

      try {
        final result = await Process.run(ffmpeg, [
          '-y', '-i', absPath,
          '-af', 'loudnorm=I=$target:TP=-1:LRA=7',
          '-c:a', 'libmp3lame', '-q:a', '2', tmp,
        ]);
        if (result.exitCode == 0 && await File(tmp).exists()) {
          await File(tmp).rename(absPath);
          cache[absPath] = target;
          onLog('  ✅ ${absPath.split('\\').last}  (${e.value.toStringAsFixed(1)} → $target)');
        } else {
          onLog('  ❌ ${absPath.split('\\').last} normalize 失敗');
        }
      } catch (ex) {
        onLog('  ⚠️ ${absPath.split('\\').last}: $ex');
      }

      done++;
      onProgress?.call(done, total);
      if (done % 10 == 0) _save('mp3', cache);
    }

    _save('mp3', cache);
    onLog('Normalize 完成，已處理 $done 個檔案');
  }
}
