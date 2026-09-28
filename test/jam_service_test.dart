import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/config_service.dart';
import 'package:playlist_admin/services/jam_service.dart';

/// 一起聽（Cloudflare Relay 版）協議回歸測試：本地假 relay，不碰外網。
/// 覆蓋：建房、加入、錯碼、聊天、離開。
void main() {
  late HttpServer relay;
  late int relayPort;
  // code -> host name
  final rooms = <String, String>{};

  Map<String, dynamic> welcomeState(String code, String me, bool isHost, List<Map<String, dynamic>> members) {
    return {
      'type': 'welcome',
      'yourId': me,
      'state': {
        'code': code,
        'members': members,
        'queue': [],
        'current': null,
        'playing': false,
        'pos': 0,
        'ts': 0,
        'chat': [],
        'skipVotes': 0,
        'skipNeeded': 1,
      },
    };
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // test 環境無 libmpv：跳過播放器，只測 relay 協議。
    JamService.testMode = true;
    await ConfigService.instance.load();
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relayPort = relay.port;
    JamService.relayUrlOverride = 'ws://127.0.0.1:$relayPort/jam';
    relay.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        Map<String, dynamic> m;
        try {
          m = jsonDecode(raw as String) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        switch (m['type']) {
          case 'create':
            const code = 'ABC123';
            rooms[code] = (m['name'] ?? 'host').toString();
            ws.add(jsonEncode(welcomeState(code, 'host-1', true, [
              {'id': 'host-1', 'name': rooms[code], 'isHost': true},
            ])));
          case 'join':
            final code = (m['code'] ?? '').toString();
            final name = (m['name'] ?? 'guest').toString();
            if (!rooms.containsKey(code)) {
              ws.add(jsonEncode({'type': 'error', 'message': '房間代碼錯誤'}));
              return;
            }
            ws.add(jsonEncode(welcomeState(code, 'client-1', false, [
              {'id': 'host-1', 'name': rooms[code], 'isHost': true},
              {'id': 'client-1', 'name': name, 'isHost': false},
            ])));
          case 'chat':
            ws.add(jsonEncode({
              'type': 'chat_item',
              'item': {'text': m['text'], 'ts': 0},
            }));
          // 與真實 relay v2 對齊的規格化回應。
          case 'play':
          case 'pause':
            ws.add(jsonEncode({
              'type': 'playback',
              'playing': m['type'] == 'play',
              'pos': m['pos'] is int ? m['pos'] : 0,
              'ts': 1,
            }));
          case 'add':
            ws.add(jsonEncode({
              'type': 'queue_update',
              'queue': [m['track']],
            }));
          // 測試用：把任意訊息注入當成 relay 廣播（協議回歸用）。
          case 'x_push':
            ws.add(jsonEncode(m['msg']));
        }
      });
    });
  });

  tearDownAll(() async {
    JamService.relayUrlOverride = null;
    await relay.close(force: true);
  });

  tearDown(() async {
    await JamService.instance.leaveRoom();
  });

  /// 等 relay roundtrip：welcome 是非同步回來的，直接斷言會競態。
  Future<void> waitMode(String m) async {
    for (int i = 0; i < 50; i++) {
      if (JamService.instance.mode == m) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    fail('mode 卡在 ${JamService.instance.mode}，等不到 $m（lastError=${JamService.instance.lastError}）');
  }

  Future<void> waitTrue(bool Function() cond, String what) async {
    for (int i = 0; i < 50; i++) {
      if (cond()) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    fail('等不到：$what');
  }

  test('host: 建房、聊天、離開', () async {
    final jam = JamService.instance;
    await jam.startHost(name: '房主');
    await waitMode('host');
    expect(jam.roomCode, 'ABC123');
    expect(jam.members.length, 1);
    expect(jam.isHost, true);

    jam.sendChat('哈囉大家');
    await waitTrue(
        () => jam.chat.any((c) => (c['text'] as String).contains('哈囉大家')),
        '房主收到聊天廣播');

    await jam.leaveRoom();
    expect(jam.mode, 'idle');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('client: 正確代碼加入、錯碼被拒', () async {
    final jam = JamService.instance;
    await jam.startHost(name: '房主');

    await jam.connect(code: 'ABC123', name: '小明');
    await waitMode('client');
    expect(jam.isHost, false);
    expect(jam.members.length, 2, reason: '看到 2 個成員');
    expect(jam.members.any((m) => m['name'] == '小明'), true);

    await jam.leaveRoom();
    await jam.connect(code: 'ZZZZZZ', name: '壞人');
    await waitTrue(() => jam.lastError.contains('房間代碼錯誤'), '錯誤代碼被拒');
    await jam.leaveRoom();
    expect(jam.mode, 'idle');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('normalized: playback/queue_update/skip_count 更新狀態、host_next 非房主忽略', () async {
    final jam = JamService.instance;
    await jam.startHost(name: '房主');
    await waitMode('host');

    // 直接注入 relay 廣播（等同真實 relay v2 送出來的訊息）。
    void push(String type, Map<String, dynamic> extra) {
      JamService.instance.debugSendForTest(
          {'type': 'x_push', 'msg': {'type': type, ...extra}});
    }

    push('queue_update', {
      'queue': [
        {'id': 'q1', 'title': 'A', 'artist': 'B', 'votes': 3}
      ]
    });
    await waitTrue(() => jam.queue.length == 1, 'queue_update 進佇列');
    expect(jam.queue.first['votes'], 3);

    push('playback', {'playing': true, 'pos': 1200, 'ts': 99});
    await waitTrue(() => jam.playing, 'playback 開始播放');
    expect(jam.positionMs, 1200);

    push('skip_count', {'count': 2, 'needed': 3});
    await waitTrue(() => jam.skipVotes == 2, 'skip_count 計票');
    expect(jam.skipNeeded, 3);

    // 房主身份收到 host_next 也無法播（testMode 無播放器）——但不可拋錯、狀態不亂動。
    push('host_next', {
      'track': {'id': 'q1', 'title': 'A', 'artist': 'B'}
    });
    await Future.delayed(const Duration(milliseconds: 300));
    expect(jam.mode, 'host');

    await jam.leaveRoom();
    expect(jam.mode, 'idle');
  }, timeout: const Timeout(Duration(seconds: 20)));
}
