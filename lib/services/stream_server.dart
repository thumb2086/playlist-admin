import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'config_service.dart';
import 'youtube_service.dart';

/// Local streaming server: resolves a song query via YoutubeService (native Dart)
/// and serves the audio bytes over http://127.0.0.1:PORT/stream.
class StreamServer {
  static StreamServer? _instance;
  static StreamServer get instance => _instance ??= StreamServer._();
  StreamServer._();

  HttpServer? _server;
  int _port = 0;
  bool _started = false;

  String publicBase = 'http://127.0.0.1:0';

  int get port => _port;

  // YouTube stream URL 約 6 小時失效：快取必須帶 TTL，否則隔天點播
  // 直接失敗直到重開 app。5 小時到期。
  final Map<String, ({String url, DateTime at})> _resolved = {};
  static const _resolveTtl = Duration(hours: 5);
  Process? _activeProc;
  final Map<String, String> _cacheIndex = {};

  bool get isRunning => _started;
  String get baseUrl => 'http://127.0.0.1:$_port';

  static String get _cacheDir => ConfigService.instance.config.streamCachePath;
  static String get _indexPath => '$_cacheDir\\stream_index.json';

  Future<void> start() async {
    if (_started) return;
    _loadIndex();
    try {
      final dir = Directory(_cacheDir);
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          if (f.uri.pathSegments.last.startsWith('stream_')) f.deleteSync();
        }
      }
    } catch (_) {}
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle);
    _started = true;
  }

  Future<void> stop() async {
    _started = false;
    await _server?.close(force: true);
    _server = null;
  }

  void _loadIndex() {
    try {
      final f = File(_indexPath);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      for (final e in data.entries) {
        final p = e.value as String;
        if (File(p).existsSync()) _cacheIndex[e.key] = p;
      }
    } catch (_) {}
  }

  void _saveIndex() {
    try {
      final f = File(_indexPath);
      f.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(_cacheIndex));
    } catch (_) {}
  }

  String? cachedPathFor(String query) => _cacheIndex[query];

  void stopActive() {
    _activeProc?.kill();
    _activeProc = null;
  }

  /// Search cache\stream\ for a file matching the query name.
  String? findCached(String query) {
    final dir = Directory(_cacheDir);
    if (!dir.existsSync()) return null;
    final lower = query.toLowerCase();
    final prefix = lower.substring(0, lower.length.clamp(0, 20));
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.endsWith('.mp3') && f.lengthSync() > 65536) {
        final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
        if (name.contains(prefix)) return f.path;
      }
    }
    return null;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.pathSegments;
    if (path.isNotEmpty && path[0] == 'stream' && path.length >= 2) {
      final query = Uri.decodeComponent(path.sublist(1).join('/'));
      try {
        final cached = _cacheIndex[query];
        if (cached != null && File(cached).existsSync()) {
          await _serveFile(request, File(cached));
          return;
        }
        await _serveTranscoded(request, query);
      } catch (e) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  /// Resolve URL via YoutubeService (native).
  Future<String> _resolve(String query) async {
    final hit = _resolved[query];
    if (hit != null) {
      if (DateTime.now().difference(hit.at) < _resolveTtl) return hit.url;
      _resolved.remove(query); // 過期：重解
    }
    try {
      final result = await YoutubeService.instance.resolveStream(query);
      if (result == null) {
        print('[StreamServer] resolve failed for: $query');
        return '';
      }
      _resolved[query] = (url: result.audioUrl, at: DateTime.now());
      return result.audioUrl;
    } catch (e) {
      print('[StreamServer] resolve exception: $e');
    }
    return '';
  }

  Future<String> resolveForTest(String query) => _resolve(query);

  /// Resolve → download via ffmpeg → return local mp3 path.
  Future<String> resolveToFile(String query, {String? isrc}) async {
    final cacheDir = Directory(_cacheDir);
    await cacheDir.create(recursive: true);

    final safeName = query.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    // Check cache first.
    final prefix = safeName.substring(0, safeName.length.clamp(0, 20)).toLowerCase();
    for (final f in cacheDir.listSync().whereType<File>()) {
      final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
      if (name.contains(prefix) && f.path.endsWith('.mp3') && f.lengthSync() > 65536) {
        return f.path;
      }
    }

    _activeProc?.kill();
    _activeProc = null;

    try {
      // 1. Resolve audio URL via YoutubeService (native).
      final url = await _resolve(query);
      if (url.isEmpty) {
        print('[StreamServer] resolveToFile: no URL for: $query');
        return '';
      }

      // 2. Download + convert to mp3 via ffmpeg.
      final outBase = '${cacheDir.path}\\dl_${safeName.hashCode.toRadixString(16)}';
      final mp3Path = '$outBase.mp3';
      final ffmpeg = ConfigService.instance.config.resolvedFfmpegPath;

      final proc = await Process.start(
        ffmpeg,
        ['-y', '-i', url, '-vn', '-acodec', 'libmp3lame', '-q:a', '0', '-ac', '2', mp3Path],
        runInShell: true,
      );
      _activeProc = proc;

      final code = await proc.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () { proc.kill(); return -1; },
      );
      _activeProc = null;

      if (code == 0 && File(mp3Path).existsSync()) {
        final finalPath = '${cacheDir.path}\\$safeName.mp3';
        if (mp3Path != finalPath) await File(mp3Path).rename(finalPath);
        _cacheIndex[query] = finalPath;
        _saveIndex();
        return finalPath;
      }
      print('[StreamServer] ffmpeg failed (exit $code) for: $query');
      return '';
    } catch (e) {
      _activeProc?.kill();
      _activeProc = null;
      print('[StreamServer] resolveToFile error: $e');
      return '';
    }
  }

  /// True streaming: resolve URL → ffmpeg pipe → HTTP response.
  Future<void> _serveTranscoded(HttpRequest request, String query) async {
    final url = await _resolve(query);
    if (url.isEmpty) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final ffmpeg = ConfigService.instance.config.resolvedFfmpegPath;

    final args = [
      '-user_agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      '-i', url,
      '-vn', '-c:a', 'libmp3lame', '-q:a', '0', '-f', 'mp3', 'pipe:1',
    ];
    final ff = await Process.start(ffmpeg, args, runInShell: true);

    final cacheEnabled = ConfigService.instance.config.streamCacheEnabled;
    IOSink? cacheSink;
    File? cacheFile;
    if (cacheEnabled) {
      try {
        final dir = Directory(_cacheDir);
        await dir.create(recursive: true);
        final safeName = query.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
        cacheFile = File('$_cacheDir\\$safeName.mp3');
        cacheSink = cacheFile.openWrite();
      } catch (_) {}
    }

    request.response.headers.contentType = ContentType('audio', 'mpeg');
    request.response.headers.set('Cache-Control', 'no-store');

    await request.response.addStream(ff.stdout.transform(
        StreamTransformer.fromHandlers(
            handleData: (data, sink) { cacheSink?.add(data); sink.add(data); },
            handleError: (e, st, sink) {},
            handleDone: (sink) => sink.close())));
    await request.response.close();
    await cacheSink?.close();

    if (cacheEnabled && cacheFile != null && cacheFile.existsSync() && cacheFile.lengthSync() > 65536) {
      _cacheIndex[query] = cacheFile.path;
      _saveIndex();
      _enforceCacheLimit();
    }
  }

  Future<void> _serveFile(HttpRequest request, File file) async {
    request.response.headers.contentType = ContentType('audio', 'mpeg');
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  Future<void> _enforceCacheLimit() async {
    final maxBytes = ConfigService.instance.config.streamCacheMaxMb * 1024 * 1024;
    final files = <File>[];
    var total = 0;
    for (final e in _cacheIndex.entries) {
      final f = File(e.value);
      if (!f.existsSync()) continue;
      total += await f.length();
      files.add(f);
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    for (final f in files) {
      if (total <= maxBytes) break;
      final len = await f.length();
      try { await f.delete(); } catch (_) {}
      total -= len;
      _cacheIndex.removeWhere((k, v) => v == f.path);
    }
    _saveIndex();
  }
}
