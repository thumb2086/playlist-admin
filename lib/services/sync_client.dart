import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'config_service.dart';
import 'sync_server.dart';

/// 區網同步客戶端（手機端）：從電腦把 mp3 拉下來，全程區網、不耗行動數據。
///
/// 流程：discover（UDP）或手輸 IP → ping → tracks → diff（缺檔/大小變/新版）
/// → download（串流寫檔 + .part→改名 + 對齊 mtime）。
class SyncHost {
  final String ip;
  final int port;
  final int tracks;
  SyncHost({required this.ip, required this.port, required this.tracks});
  String get baseUrl => 'http://$ip:$port';
  @override
  String toString() => '$ip:$port（$tracks 首）';
}

class SyncTrack {
  final String path; // 相對 music/，`/` 分隔
  final int size;
  final int mtime;
  SyncTrack({required this.path, required this.size, required this.mtime});
  factory SyncTrack.fromJson(Map<String, dynamic> j) => SyncTrack(
        path: (j['p'] ?? '') as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
      );
}

class SyncClient {
  static final _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  /// UDP 廣播找區網電腦（3 秒）。回傳找到的主機（可能多台）。
  static Future<List<SyncHost>> discover(
      {Duration timeout = const Duration(seconds: 3)}) async {
    final found = <String, SyncHost>{};
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      sock.send(utf8.encode(SyncServer.discoverMagic),
          InternetAddress('255.255.255.255'), SyncServer.udpPort);
      final doneAt = DateTime.now().add(timeout);
      await for (final e in sock.timeout(timeout + const Duration(seconds: 1))) {
        if (e != RawSocketEvent.read) continue;
        final dg = sock.receive();
        if (dg == null) continue;
        String msg = '';
        try {
          msg = utf8.decode(dg.data).trim();
        } catch (_) {
          continue;
        }
        if (!msg.startsWith(SyncServer.herePrefix)) continue;
        final parts = msg.split('|');
        if (parts.length < 3) continue;
        final port = int.tryParse(parts[1]) ?? 0;
        if (port <= 0) continue;
        final key = '${dg.address.address}:$port';
        found[key] = SyncHost(
          ip: dg.address.address,
          port: port,
          tracks: int.tryParse(parts[2]) ?? 0,
        );
        if (DateTime.now().isAfter(doneAt)) break;
      }
    } catch (_) {
    } finally {
      try {
        sock?.close();
      } catch (_) {}
    }
    return found.values.toList();
  }

  static Future<SyncHost?> ping(String ip, int port) async {
    try {
      final req = await _http
          .getUrl(Uri.parse('http://$ip:$port/api/ping'))
          .timeout(const Duration(seconds: 5));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['app'] != 'playlist-admin') return null;
      return SyncHost(
          ip: ip, port: port, tracks: (j['tracks'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  static Future<List<SyncTrack>> fetchTracks(SyncHost host) async {
    final req = await _http
        .getUrl(Uri.parse('${host.baseUrl}/api/tracks'))
        .timeout(const Duration(seconds: 30));
    final resp = await req.close().timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw Exception('電腦回了 ${resp.statusCode}');
    }
    final body = await resp.transform(utf8.decoder).join();
    final list = jsonDecode(body) as List<dynamic>;
    return list
        .map((e) => SyncTrack.fromJson(e as Map<String, dynamic>))
        .where((t) => t.path.isNotEmpty)
        .toList();
  }

  /// 保證本機音樂庫目錄存在（手機首次 basePath 是空的 → 指到 app 文件夾）。
  /// 一律回傳 `<base>/music`（musicPath 在目錄不存在時會退回 basePath，
  /// 不能直接拿來用）。
  static Future<Directory> ensureLocalLibrary() async {
    final cfg = ConfigService.instance.config;
    if (cfg.basePath.isEmpty) {
      final docs = await getApplicationDocumentsDirectory();
      cfg.basePath =
          '${docs.path}${Platform.pathSeparator}playlist-admin';
      await ConfigService.instance.save();
    }
    final music = Directory(
        '${cfg.basePath}${Platform.pathSeparator}music');
    await music.create(recursive: true);
    return music;
  }

  /// 本機索引：檔名（小寫 stem）→ (size, mtime)。
  static Future<Map<String, (int size, int mtime)>> localIndex() async {
    final out = <String, (int size, int mtime)>{};
    final dir = await ensureLocalLibrary();
    if (!await dir.exists()) return out;
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      final low = f.path.toLowerCase();
      if (!low.endsWith('.mp3') && !low.endsWith('.flac')) continue;
      try {
        final st = await f.stat();
        final stem = f.uri.pathSegments.last
            .replaceAll(RegExp(r'\.\w+$'), '')
            .toLowerCase();
        out[stem] =
            (st.size, st.modified.millisecondsSinceEpoch);
      } catch (_) {}
    }
    return out;
  }

  /// 比對：回傳需要下載的（本機沒有 / 大小不同 / 電腦版新 2 秒以上）。
  /// 用檔名 stem 比（手機可能只有子集；路徑結構不要求一致）。
  static List<SyncTrack> diff(
      List<SyncTrack> remote, Map<String, (int size, int mtime)> local) {
    final out = <SyncTrack>[];
    for (final t in remote) {
      final stem = t.path
          .split('/')
          .last
          .replaceAll(RegExp(r'\.\w+$'), '')
          .toLowerCase();
      final l = local[stem];
      if (l == null) {
        out.add(t);
        continue;
      }
      if (l.$1 != t.size) {
        out.add(t);
        continue;
      }
      if ((t.mtime - l.$2).abs() > 2000 && t.mtime > l.$2) out.add(t);
    }
    return out;
  }

  /// 下載單檔（串流寫 .part → 改名 → 對齊 mtime）。回傳 true=成功。
  /// onError 帶回最後一次失敗原因（UI 可顯示，不再無聲失敗）。
  static Future<bool> download(
    SyncHost host,
    SyncTrack track, {
    void Function(int done, int total)? onProgress,
    void Function(String msg)? onError,
    int retries = 2,
  }) async {
    final dir = await ensureLocalLibrary();
    final target = File(
        '${dir.path}${Platform.pathSeparator}${track.path.replaceAll('/', Platform.pathSeparator)}');
    String lastErr = '';
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        await target.parent.create(recursive: true);
        final part = File('${target.path}.part');
        final req = await _http
            .getUrl(Uri.parse(
                '${host.baseUrl}/file/${track.path.split('/').map(Uri.encodeComponent).join('/')}'))
            .timeout(const Duration(seconds: 15));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          lastErr = 'HTTP ${resp.statusCode}';
          throw Exception(lastErr);
        }
        final total = resp.contentLength;
        var done = 0;
        final sink = part.openWrite();
        try {
          await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
            done += chunk.length;
            if (onProgress != null) onProgress(done, total);
          }
        } finally {
          await sink.close();
        }
        if (total > 0 && done != total) {
          lastErr = '傳到一半斷線';
          throw Exception(lastErr);
        }
        if (track.size > 0 && done != track.size) {
          lastErr = '大小不符（要 ${track.size}，實 $done）';
          throw Exception(lastErr);
        }
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
        await part.rename(target.path);
        try {
          if (track.mtime > 0) {
            await target.setLastModified(
                DateTime.fromMillisecondsSinceEpoch(track.mtime));
          }
        } catch (_) {}
        return true;
      } catch (e) {
        lastErr = '$e';
        if (attempt == retries) {
          onError?.call(lastErr);
          return false;
        }
        await Future.delayed(Duration(seconds: 1 + attempt));
      }
    }
    onError?.call(lastErr.isEmpty ? '未知錯誤' : lastErr);
    return false;
  }
}
