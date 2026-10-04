import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'config_service.dart';

/// 區網同步伺服器（電腦端）：手機一鍵把電腦的 mp3 拉過去，全程走區網、不耗網路流量。
///
/// 協定（v1，全部明文 JSON，僅區網可見）：
/// - UDP 15486：手機廣播 `playlist-admin-discover` → 本機回
///   `playlist-admin-here|<httpPort>|<trackCount>`
/// - HTTP 15487（被佔用自動 +1）：`GET /api/ping` → `{ok,app,version,tracks}`
/// - `GET /api/tracks` → `[{p,size,mtime}]`（p = 相對 music/ 的路徑，`/` 分隔）
/// - `GET /file/<rel...>` → 檔案位元組（附 content-length 供進度條）
///
/// 只讀 music/ 內的 .mp3/.flac；路徑含 `..` 一律拒絕（防目錄穿越）。
class SyncServer {
  static SyncServer? _instance;
  static SyncServer get instance => _instance ??= SyncServer._();
  SyncServer._();

  static const int udpPort = 15486;
  static const int httpPortBase = 15487;
  static const String discoverMagic = 'playlist-admin-discover';
  static const String herePrefix = 'playlist-admin-here';

  HttpServer? _http;
  RawDatagramSocket? _udp;
  StreamSubscription<RawSocketEvent>? _udpSub;
  int _port = 0;
  bool _running = false;

  bool get isRunning => _running;
  int get port => _port;

  /// 測試/特殊用途覆寫：不讀全域 config，直接指定要服的音樂目錄。
  String? debugMusicRoot;

  Directory _musicDir() {
    final o = debugMusicRoot;
    if (o != null && o.isNotEmpty) {
      // 尾部分隔符先清掉，否則拼接路徑會出現雙分隔符（Windows 會找不到檔）。
      var p = o;
      while (p.length > 1 && p.endsWith(Platform.pathSeparator)) {
        p = p.substring(0, p.length - 1);
      }
      return Directory(p);
    }
    return Directory(ConfigService.instance.config.musicPath);
  }

  /// 本機區網 IPv4（沒有就回 127.0.0.1，僅本機可測）。
  static Future<String> lanIp() async {
    try {
      final ifs = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      for (final i in ifs) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
            return ip;
          }
        }
      }
      for (final i in ifs) {
        if (i.addresses.isNotEmpty) return i.addresses.first.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> start() async {
    if (_running) return;
    // HTTP：固定 port 優先（QR 才不會失效），被佔用往上找。
    HttpServer? http;
    int port = httpPortBase;
    for (int i = 0; i < 8; i++) {
      try {
        http = await HttpServer.bind(InternetAddress.anyIPv4, port);
        break;
      } catch (_) {
        port++;
      }
    }
    if (http == null) throw Exception('區網同步埠都被佔用（$httpPortBase 起）');
    _http = http;
    _port = port;
    _http!.listen(_handle);
    // UDP 發現回應。
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
      _udp!.broadcastEnabled = true;
      _udpSub = _udp!.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = _udp!.receive();
        if (dg == null) return;
        String msg = '';
        try {
          msg = utf8.decode(dg.data).trim();
        } catch (_) {
          return;
        }
        if (msg != discoverMagic) return;
        _trackCount().then((n) {
          final reply = '$herePrefix|$_port|$n';
          try {
            _udp!.send(utf8.encode(reply), dg.address, dg.port);
          } catch (_) {}
        });
      });
    } catch (_) {
      // UDP 起不來不致命：手機仍可用手輸 IP。
      _udp = null;
    }
    _running = true;
  }

  Future<void> stop() async {
    _running = false;
    try {
      await _udpSub?.cancel();
    } catch (_) {}
    _udpSub = null;
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
  }

  Future<int> _trackCount() async {
    var n = 0;
    try {
      final dir = _musicDir();
      if (await dir.exists()) {
        await for (final f in dir.list(recursive: true, followLinks: false)) {
          if (f is File) {
            final low = f.path.toLowerCase();
            if (low.endsWith('.mp3') || low.endsWith('.flac')) n++;
          }
        }
      }
    } catch (_) {}
    return n;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final segs = req.uri.pathSegments;
      if (segs.isEmpty) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      if (segs[0] == 'api' && segs.length >= 2 && segs[1] == 'ping') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'ok': true,
          'app': 'playlist-admin',
          'tracks': await _trackCount(),
        }));
        await req.response.close();
        return;
      }
      if (segs[0] == 'api' && segs.length >= 2 && segs[1] == 'tracks') {
        final out = <Map<String, dynamic>>[];
        try {
          final dir = _musicDir();
          if (await dir.exists()) {
            await for (final f
                in dir.list(recursive: true, followLinks: false)) {
              if (f is! File) continue;
              final low = f.path.toLowerCase();
              if (!low.endsWith('.mp3') && !low.endsWith('.flac')) continue;
              final st = await f.stat();
              var rel = f.path;
              final base = dir.path;
              if (rel.startsWith(base)) {
                rel = rel.substring(base.length);
              }
              rel = rel
                  .replaceAll('\\', '/')
                  .replaceAll(RegExp(r'^/+'), '');
              if (rel.contains('..')) continue;
              out.add({
                'p': rel,
                'size': st.size,
                'mtime': st.modified.millisecondsSinceEpoch,
              });
            }
          }
        } catch (_) {}
        out.sort((a, b) => (a['p'] as String).compareTo(b['p'] as String));
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(out));
        await req.response.close();
        return;
      }
      if (segs[0] == 'file' && segs.length >= 2) {
        final rel = segs
            .sublist(1)
            .map((s) {
              try {
                return Uri.decodeComponent(s);
              } catch (_) {
                return s;
              }
            })
            .join('/');
        // 防目錄穿越：拒 ..、絕對路徑、非音訊副檔名。
        final low = rel.toLowerCase();
        if (rel.contains('..') ||
            rel.startsWith('/') ||
            (!low.endsWith('.mp3') && !low.endsWith('.flac'))) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        final base = _musicDir();
        final file = File(
            '${base.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
        if (!await file.exists()) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final len = await file.length();
        req.response.headers.contentType = ContentType('audio', 'mpeg');
        req.response.headers.set('Content-Length', len);
        await req.response.addStream(file.openRead());
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }
}
