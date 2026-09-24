import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  // 播放/預取統一走 yt-dlp（簽章/UA/cookies 內部搞定）；不再持有 URL 快取
  //（googlevideo 直鏈給外部程式會 403，快取也沒意義）。
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
  /// stem 全等比對：前綴 contains 會讓 EP10 命中 EP100.mp3 播錯集。
  String? findCached(String query) {
    final dir = Directory(_cacheDir);
    if (!dir.existsSync()) return null;
    final stem = _stemOf(query);
    if (stem.isEmpty) return null;
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.endsWith('.mp3') && f.lengthSync() > 65536) {
        final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
        final nameStem = name.replaceAll(RegExp(r'\.\w+$'), '');
        if (nameStem == stem) return f.path;
      }
    }
    return null;
  }

  static String _stemOf(String query) => query
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.pathSegments;
    if (path.isNotEmpty && path[0] == 'stream' && path.length >= 2) {
      // 診斷：印出客戶端（mpv vs 探針）實際送出的請求。
      final hdrs = request.headers.toString().replaceAll('\r\n', ' ~ ');
      print('[stream] ${request.method} ${request.uri} :: ${hdrs.substring(0, hdrs.length.clamp(0, 360))}');
      // pathSegments 已解碼過一次；mpv 可能重編碼，二次 decodeComponent 會
      // 對殘留的裸 % 拋 ArgumentError — 必須包住（歷史炸點：未捕獲 →
      // 連線斷 → mpv "Failed to open" → 單集播不出來）。
      String query = path.sublist(1).join('/');
      try {
        final dec = Uri.decodeComponent(query);
        if (dec.isNotEmpty) query = dec;
      } catch (_) {}
      try {
        final cached = _cacheIndex[query];
        if (cached != null && File(cached).existsSync()) {
          await _serveFile(request, File(cached));
          return;
        }
        await _serveTranscoded(request, query);
      } catch (e) {
        print('[stream] handler error: $e');
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

  /// Resolve → download via yt-dlp one-shot → return local mp3 path.
  Future<String> resolveToFile(String query, {String? isrc}) async {
    final cacheDir = Directory(_cacheDir);
    await cacheDir.create(recursive: true);

    final safeName = query.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    // 全等比對（見 findCached）：前綴 contains 會播錯集。
    final wantStem = safeName.toLowerCase();
    if (wantStem.isNotEmpty) {
      for (final f in cacheDir.listSync().whereType<File>()) {
        final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
        if (name.replaceAll(RegExp(r'\.\w+$'), '') == wantStem &&
            f.path.endsWith('.mp3') && f.lengthSync() > 65536) {
          return f.path;
        }
      }
    }

    // 不跨請求 kill：每請求獨立 tmp，併發同 query 各下各的。
    // （stopActive 照樣能停掉「最新」那個。）

    try {
      // yt-dlp one-shot: search + sign + transcode to mp3, all internal.
      // (old path: _resolve -> ffmpeg -i URL: 403 no headers + & split by cmd)

      // 2. Download to mp3 via yt-dlp (one process: search+sign+transcode).
      // 先寫 .part、成功才改名：失敗殘檔不可被下次當命中。
      // tmp 每請求唯一（micros），併發同 query 不互蓋。
      final outBase = '${cacheDir.path}\\dl_${safeName.hashCode.toRadixString(16)}_${DateTime.now().microsecondsSinceEpoch}';
      final partPath = '$outBase.mp3';
      final cookies = YoutubeService.cookiesPathForDiag;
      final ytdlpArgs = <String>[
        '-x', '--audio-format', 'mp3',
        '-f', 'ba/b', '--no-playlist', '--no-overwrites',
        '--no-check-certificates',
        '--retries', '3', '--fragment-retries', '10', '--socket-timeout', '60',
        // android：實測3.0s下載完成（mweb 10.4s）；android_vr 會403。
        '--extractor-args', 'youtube:player_client=android',
        if (cookies != null) ...['--cookies', cookies],
        '-o', '$outBase.%(ext)s',
        'ytsearch1:$query',
      ];
      final proc = await Process.start('yt-dlp', ytdlpArgs, runInShell: false);
      _activeProc = proc;
      proc.stderr.transform(const SystemEncoding().decoder).listen((_) {}); // drain

      final code = await proc.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () { proc.kill(); return -1; },
      );
      _activeProc = null;

      if (code == 0 && File(partPath).existsSync()) {
        final finalPath = '${cacheDir.path}\\$safeName.mp3';
        // Windows rename 不覆蓋：legacy 截斷殘檔先刪，否則拋錯整筆失敗。
        try { if (await File(finalPath).exists()) await File(finalPath).delete(); } catch (_) {}
        if (partPath != finalPath) await File(partPath).rename(finalPath);
        _cacheIndex[query] = finalPath;
        _saveIndex();
        return finalPath;
      }
      try { if (await File(partPath).exists()) await File(partPath).delete(); } catch (_) {}
      print('[StreamServer] yt-dlp failed (exit $code) for: $query');
      return '';
    } catch (e) {
      _activeProc?.kill();
      _activeProc = null;
      print('[StreamServer] resolveToFile error: $e');
      return '';
    }
  }

  /// True streaming: yt-dlp 管線輸出（搜尋+簽章+位元組一氣呵成）→ HTTP response。
  Future<void> _serveTranscoded(HttpRequest request, String query) async {
    // 三層雷的終極解：yt-dlp 直接 `ytsearch1:query -o -`：
    // ① ffmpeg 直餵 googlevideo 403（缺 header/簽章配套）
    // ② googlevideo 直鏈交給外部 extractor（UA 不符）也失敗
    // ③ runInShell 經 cmd 把 URL 的 & 當分隔符
    // yt-dlp 內部全搞定，倒原始音訊位元組給 mpv 自行解碼。
    final cookies = YoutubeService.cookiesPathForDiag;
    final ytArgs = <String>[
      '--no-warnings',
      // 優先 webm/opus：EBML 標頭在檔頭、天生可管線播放；
      // m4a(mp4) 的 moov 在尾端，pipe 場景 mpv 拿不到 moov 無法開啟（Failed to open）。
      '-f', 'ba[ext=webm]/b[ext=webm]/ba/b',
      '-o', '-',
      '--retries', '3',
      // android client：實測完整下載9.7MB僅3.0s（冷啟動遠低於mpv~10s底線)；
      // mweb 要10.4s會讓mpv等不及；android_vr(另一個)拿資料會403。
      '--extractor-args', 'youtube:player_client=android',
      if (cookies != null) ...['--cookies', cookies],
      'ytsearch1:$query',
    ];
    final ff = await Process.start('yt-dlp', ytArgs, runInShell: false);
    _activeProc = ff;
    // stderr 必須排空 + 留樣本：沒人讀會塞滿 pipe 卡死 ffmpeg，失敗也無從得知。
    final ffErr = <String>[];
    ff.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((l) {
      // 留最後6行：錯誤訊息在橫幅之後。
      if (ffErr.length >= 6) ffErr.removeAt(0);
      ffErr.add(l);
    });

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

    // ── 手管 socket：Dart 的 header 必須等第一個 body 位元組才 flush
    //（flush() 實測無效：headers 延遲 = yt-dlp 冷啟動 ~10s > mpv stream-open
    // 耐心 → mpv 必死 "Failed to open"；python/ffprobe 能忍所以一直沒事）。
    // detachSocket → 立刻手寫 200 OK → yt-dlp 位元組 Connection: close 裸流。
    final socket = await request.response.detachSocket(writeHeaders: false);
    const headerStr = 'HTTP/1.1 200 OK\r\n'
        'Content-Type: application/octet-stream\r\n'
        'Cache-Control: no-store\r\n'
        'Connection: close\r\n'
        '\r\n';
    socket.add(headerStr.codeUnits);
    await socket.flush();
    print('[stream] raw headers sent instantly, query=$query port=$_port');
    final sw = Stopwatch()..start();
    bool firstLogged = false;

    final bodyDone = Completer<void>();
    bool stdoutDone = false;
    socket.done.then((_) {
      print('[stream] socket done at ${sw.elapsedMilliseconds}ms firstByte=$firstLogged');
      if (!bodyDone.isCompleted) bodyDone.complete();
      // 客戶端真的提前斷才 kill：正常播完(stdoutDone)不可殺，exit 0 才能入快取。
      if (!stdoutDone) {
        try { ff.kill(); } catch (_) {}
      }
    }).catchError((_) {
      if (!bodyDone.isCompleted) bodyDone.complete();
    });

    ff.stdout.listen(
      (data) {
        if (!firstLogged) {
          firstLogged = true;
          print('[stream] first byte after ${sw.elapsedMilliseconds}ms');
        }
        try { socket.add(data); } catch (_) {}
        cacheSink?.add(data);
      },
      onDone: () async {
        stdoutDone = true;
        try { await socket.flush(); } catch (_) {}
        try { await socket.close(); } catch (_) {}
        if (!bodyDone.isCompleted) bodyDone.complete();
      },
      onError: (e) {
        print('[stream] ytdlp stdout error: $e');
        if (!bodyDone.isCompleted) bodyDone.complete();
      },
      cancelOnError: true,
    );

    // 等 yt-dlp 結束（或 socket 斷被 kill）。
    final ffCode = await ff.exitCode.timeout(const Duration(seconds: 300),
        onTimeout: () { ff.kill(); return -1; });
    await bodyDone.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    _activeProc = null;
    await cacheSink?.close();
    final errTail = ffErr.isEmpty
        ? ''
        : (ffErr.last.length > 240 ? ffErr.last.substring(ffErr.last.length - 240) : ffErr.last);
    print('[stream] yt-dlp exit=$ffCode lastErr=$errTail');

    // 只有 exit 0 且 >65KB 才入庫；失敗殘檔刪（截斷檔不可命中）。
    if (cacheEnabled && cacheFile != null && ffCode == 0 &&
        cacheFile.existsSync() && cacheFile.lengthSync() > 65536) {
      _cacheIndex[query] = cacheFile.path;
      _saveIndex();
      _enforceCacheLimit();
    } else if (cacheFile != null) {
      try { if (await cacheFile.exists()) await cacheFile.delete(); } catch (_) {}
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
