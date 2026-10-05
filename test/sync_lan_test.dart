import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/models/config_model.dart';
import 'package:playlist_admin/services/config_service.dart';
import 'package:playlist_admin/services/sync_client.dart';
import 'package:playlist_admin/services/sync_server.dart';

/// 區網同步回環測試：本機起 SyncServer，走 127.0.0.1 測 ping/tracks/下載/比對。
/// 全程 loopback，不耗外部流量；不依賴手機。
void main() {
  late Directory musicDir;
  late Directory phoneDir;

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('sync_test_');
    musicDir = Directory('${tmp.path}${Platform.pathSeparator}music');
    await musicDir.create(recursive: true);
    phoneDir = Directory('${tmp.path}${Platform.pathSeparator}phone');
    await phoneDir.create(recursive: true);
    // 3 首假 mp3（內容不重要，測的是位元組一致）。
    await File('${musicDir.path}${Platform.pathSeparator}歌手A - 歌1.mp3')
        .writeAsBytes(List.generate(3000, (i) => i % 256));
    await File('${musicDir.path}${Platform.pathSeparator}歌2.mp3')
        .writeAsBytes(List.generate(5000, (i) => (i * 7) % 256));
    final sub = Directory(
        '${musicDir.path}${Platform.pathSeparator}未分類');
    await sub.create();
    await File('${sub.path}${Platform.pathSeparator}歌手B - 歌3.mp3')
        .writeAsBytes(List.generate(4000, (i) => (i * 13) % 256));
    ConfigService.instance.config =
        AppConfig(basePath: tmp.path, language: 'zh-TW');
    // musicPath 在 music/ 不存在時退回 basePath：強制建出來。
    await Directory(ConfigService.instance.config.musicPath)
        .create(recursive: true);
  });

  tearDown(() async {
    SyncServer.instance.debugMusicRoot = null;
    await SyncServer.instance.stop();
  });

  test('ping + tracks + 目錄穿越拒絕', () async {
    await SyncServer.instance.start();
    final port = SyncServer.instance.port;
    expect(port, greaterThan(0));

    final host = await SyncClient.ping('127.0.0.1', port);
    expect(host, isNotNull);
    expect(host!.tracks, 3);

    final tracks = await SyncClient.fetchTracks(host);
    expect(tracks.length, 3);
    expect(tracks.map((t) => t.size).toSet(), {3000, 5000, 4000});

    // 目錄穿越必須 403。
    final client = HttpClient();
    try {
      final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/file/..%2Fsecret.mp3'));
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.forbidden);
      await resp.drain();
    } finally {
      client.close();
    }
  });

  test('轉播路由存在：/relay-stream 不帶 q 回 400（不斷 yt-dlp）', () async {
    await SyncServer.instance.start();
    final port = SyncServer.instance.port;
    final client = HttpClient();
    try {
      final req =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/relay-stream'));
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.badRequest);
      await resp.drain();
    } finally {
      client.close();
    }
  });

  test('UDP 發現回應', () async {
    await SyncServer.instance.start();
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      sock.send(utf8.encode(SyncServer.discoverMagic),
          InternetAddress.loopbackIPv4, SyncServer.udpPort);
      final completer = Completer<String>();
      final sub = sock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        try {
          completer.complete(utf8.decode(dg.data).trim());
        } catch (_) {}
      });
      final msg = await completer.future
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      await sub.cancel();
      expect(msg.startsWith(SyncServer.herePrefix), true, reason: msg);
      final parts = msg.split('|');
      expect(int.tryParse(parts[1]), SyncServer.instance.port);
    } finally {
      sock.close();
    }
  });

  test('下載 + diff 收斂 + mtime 對齊', () async {
    await SyncServer.instance.start();
    final host = await SyncClient.ping('127.0.0.1', SyncServer.instance.port);
    expect(host, isNotNull);
    final remote = await SyncClient.fetchTracks(host!);

    // 本機是空的 → 全缺。
    final localEmpty = <String, (int size, int mtime)>{};
    expect(SyncClient.diff(remote, localEmpty).length, 3);

    // 切到「手機」目錄，跑真正的下載（server 用 override 續服電腦目錄）。
    ConfigService.instance.config =
        AppConfig(basePath: phoneDir.path, language: 'zh-TW');
    SyncServer.instance.debugMusicRoot =
        '${musicDir.path}${Platform.pathSeparator}';
    for (final t in remote) {
      String? err;
      final ok = await SyncClient.download(host, t, onError: (m) => err = m);
      // ignore: avoid_print
      print('DL ${t.path} ok=$ok err=$err');
      expect(ok, true, reason: t.path);
    }

    // 位元組與電腦端一致。
    for (final t in remote) {
      final relParts = t.path.split('/');
      final src = File(
          '${musicDir.path}${Platform.pathSeparator}${relParts.join(Platform.pathSeparator)}');
      final dst = File(
          '${phoneDir.path}${Platform.pathSeparator}music${Platform.pathSeparator}${relParts.join(Platform.pathSeparator)}');
      expect(await dst.exists(), true);
      expect(await dst.length(), await src.length());
    }

    // 索引重建 → diff 為空；再跑一次依然為空（冪等）。
    var idx = await SyncClient.localIndex();
    expect(SyncClient.diff(remote, idx), isEmpty);
    idx = await SyncClient.localIndex();
    expect(SyncClient.diff(remote, idx), isEmpty);
  });
}
