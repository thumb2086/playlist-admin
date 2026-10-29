import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/player_controller.dart';
import '../services/spotify_session.dart';
import '../services/spotify_gql_client.dart';
import '../services/youtube_service.dart';
import '../services/config_service.dart';

/// 「一起聽」— Cloudflare Worker 中繼版。
/// 房主和成員都連到 Relay，不需輸入 IP，任何網路都能加入。
class JamService extends ChangeNotifier {
  JamService._();
  static final JamService instance = JamService._();

  // ---------- Relay ----------
  static const _defaultRelayUrl = 'wss://jam-relay.cpxru83.workers.dev/jam';

  /// 測試用 relay 覆寫（flutter_test 指向本地假 relay，平時 null）。
  static String? relayUrlOverride;
  
  /// 從 ConfigService 讀取使用者設定的 relay URL，支援在設定頁修改
  static String get _relay {
    if (relayUrlOverride != null) return relayUrlOverride!;
    try {
      final cfg = ConfigService.instance.config;
      final url = cfg.jamRelayUrl;
      if (url.isNotEmpty) return url;
    } catch (_) {}
    return _defaultRelayUrl;
  }

  /// flutter_test 用：test 環境無 libmpv，PlayerController 建不起來。
  /// 開啟後播放器呼叫全變 no-op，協議邏輯照常測試。正式環境恆 false。
  static bool testMode = false;
  static PlayerController? get _pc => testMode ? null : PlayerController.instance;

  // ---------- 公開狀態 ----------
  String mode = 'idle'; // 'idle' | 'host' | 'client'
  String roomCode = '';
  String myId = '';
  String myName = '';
  bool get isHost => mode == 'host';

  final List<Map<String, dynamic>> members = [];
  final List<Map<String, dynamic>> queue = [];
  Map<String, dynamic>? current;
  bool playing = false;
  int positionMs = 0;
  int ts = 0;
  final List<Map<String, dynamic>> chat = [];
  int skipVotes = 0;
  int skipNeeded = 0;

  String lastError = '';
  String statusText = '';

  final Map<String, int> _myVotes = {};
  List<Map<String, dynamic>> searchResults = [];
  bool searching = false;
  String searchError = '';
  final Map<int, Completer<List<Map<String, dynamic>>>> _searchCompleters = {};

  // ---------- 併發控制 ----------
  final _resolveQueue = _AsyncQueue<_ResolveTask>();
  final _playLock = _AsyncLock();

  // ---------- WebSocket ----------
  WebSocket? _ws;
  Timer? _driftTimer;
  String _lastUrl = '';

  // ===================================================================
  //  連線（房主和成員都走這個）
  // ===================================================================

  Future<void> startHost({String name = '我'}) async {
    await leaveRoom();
    myName = name;
    lastError = '';
    statusText = '建立房間…';
    try {
      _ws = await WebSocket.connect(_relay)
          .timeout(const Duration(seconds: 10));
      _ws!.listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed());
      _ws!.add(jsonEncode({'type': 'create', 'name': name}));
    } catch (e) {
      mode = 'idle';
      lastError = '連線失敗: $e';
      statusText = lastError;
      notifyListeners();
    }
  }

  Future<void> connect({required String code, String name = '我'}) async {
    await leaveRoom();
    myName = name;
    lastError = '';
    statusText = '加入房間…';
    try {
      _ws = await WebSocket.connect(_relay)
          .timeout(const Duration(seconds: 10));
      _ws!.listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed());
      _ws!.add(jsonEncode({
        'type': 'join',
        'code': code.toUpperCase().trim(),
        'name': name,
      }));
    } catch (e) {
      mode = 'idle';
      lastError = '連線失敗: $e';
      statusText = lastError;
      notifyListeners();
    }
  }

  Future<void> leaveRoom() async {
    _driftTimer?.cancel();
    _driftTimer = null;
    await _resolveQueue.clear();
    _ws?.close();
    _ws = null;
    _resetState();
    mode = 'idle';
    _myVotes.clear();
    searchResults = [];
    searching = false;
    _pc?.jamFollowMode = false;
    _lastUrl = '';
    notifyListeners();
  }

  void _resetState() {
    members.clear();
    queue.clear();
    current = null;
    playing = false;
    positionMs = 0;
    ts = 0;
    chat.clear();
    skipVotes = 0;
    skipNeeded = 0;
  }

  void _onClosed() {
    if (mode == 'idle') return;
    mode = 'idle';
    _ws = null;
    _pc?.jamFollowMode = false;
    lastError = '與 Relay 的連線中斷';
    notifyListeners();
  }

  // ===================================================================
  //  訊息處理（房主和成員共用）
  // ===================================================================

  void _onMessage(dynamic raw) {
    late final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = msg['type'] as String?;

    switch (type) {
      case 'welcome':
        myId = msg['yourId'] as String;
        final state = msg['state'] as Map<String, dynamic>;
        mode = (state['members'] as List).any(
                (m) => m['id'] == myId && m['isHost'] == true)
            ? 'host'
            : 'client';
        roomCode = state['code'] as String? ?? '';
        _pc?.jamFollowMode = mode == 'client';
        _applyState(state);
        _startDriftSync();
        statusText = '';
        lastError = '';
        notifyListeners();
        break;

      case 'member_joined':
        members.add(msg['member']);
        notifyListeners();
        break;

      case 'member_left':
        final leftId = msg['memberId'];
        members.removeWhere((m) => m['id'] == leftId);
        notifyListeners();
        break;

      case 'track_change':
        _applyTrackChange(msg);
        break;

      case 'playback':
        playing = msg['playing'] as bool? ?? false;
        positionMs = msg['pos'] as int? ?? 0;
        ts = msg['ts'] as int? ?? 0;
        _mirrorPlayPause();
        notifyListeners();
        break;

      case 'progress':
        positionMs = msg['pos'] as int? ?? 0;
        ts = msg['ts'] as int? ?? 0;
        _driftCorrect();
        notifyListeners();
        break;

      case 'queue_update':
        queue
          ..clear()
          ..addAll((msg['queue'] as List? ?? []).cast<Map<String, dynamic>>());
        notifyListeners();
        break;

      case 'skip_count':
        skipVotes = msg['count'] as int? ?? 0;
        skipNeeded = msg['needed'] as int? ?? 0;
        notifyListeners();
        break;

      case 'chat_item':
        chat.add(msg['item']);
        if (chat.length > 100) chat.removeAt(0);
        notifyListeners();
        break;

      case 'host_next':
        if (isHost && msg['track'] is Map<String, dynamic>) {
          _playAsHost((msg['track'] as Map).cast<String, dynamic>());
        }
        break;

      case 'promoted':
        if (msg['memberId'] == myId) {
          mode = 'host';
          _pc?.jamFollowMode = false;
          notifyListeners();
        }
        break;

      case 'search_results':
        searching = false;
        final c = _searchCompleters.remove(msg['reqId'] as int?);
        final items = (msg['items'] as List? ?? []).cast<Map<String, dynamic>>();
        if (c != null && !c.isCompleted) c.complete(items);
        searchResults = items;
        notifyListeners();
        break;

      case 'search_error':
        searching = false;
        searchError = msg['message'] as String? ?? '搜尋失敗';
        notifyListeners();
        break;

      case 'error':
        lastError = msg['message'] as String? ?? '錯誤';
        notifyListeners();
        break;
    }
  }

  void _applyState(Map<String, dynamic> state) {
    members
      ..clear()
      ..addAll((state['members'] as List? ?? []).cast<Map<String, dynamic>>());
    queue
      ..clear()
      ..addAll((state['queue'] as List? ?? []).cast<Map<String, dynamic>>());
    chat
      ..clear()
      ..addAll((state['chat'] as List? ?? []).cast<Map<String, dynamic>>());
    skipVotes = state['skipVotes'] as int? ?? 0;
    skipNeeded = state['skipNeeded'] as int? ?? 0;
    _applyTrackChange({
      'current': state['current'],
      'playing': state['playing'],
      'pos': state['time'],
      'ts': state['ts'],
    });
    notifyListeners();
  }

  void _applyTrackChange(Map<String, dynamic> msg) {
    current = msg['current'] as Map<String, dynamic>?;
    playing = msg['playing'] as bool? ?? false;
    positionMs = msg['pos'] as int? ?? 0;
    ts = msg['ts'] as int? ?? 0;

    if (current == null) {
      _pc?.stop();
      notifyListeners();
      return;
    }

    final url = current!['audioUrl'] as String? ?? '';
    if (url.isNotEmpty && url != _lastUrl) {
      _lastUrl = url;
      _pc?.playJamUrl(url,
          title: current!['title'] as String? ?? '',
          artist: current!['artist'] as String? ?? '',
          coverUrl: current!['coverUrl'] as String?);
    } else if (url.isNotEmpty) {
      _mirrorPlayPause();
      _driftCorrect();
    }
    notifyListeners();
  }

  void _mirrorPlayPause() {
    final pc = _pc;
    if (pc == null) return;
    if (playing) {
      if (!pc.isPlaying) pc.resume();
    } else {
      if (pc.isPlaying) pc.pause();
    }
  }

  void _startDriftSync() {
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mode == 'idle') return;
      if (isHost && playing && current != null) {
        final p = _pc?.position.inMilliseconds ?? 0;
        if (p > 0) {
          _send({
            'type': 'progress',
            'pos': p,
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
        }
      }
      if (!playing || current == null) return;
      _driftCorrect();
    });
  }

  void _driftCorrect() {
    final pc = _pc;
    if (pc == null) return;
    if (pc.title.isEmpty) return;
    final elapsed = DateTime.now().millisecondsSinceEpoch - ts;
    final expected = positionMs + elapsed;
    final actual = pc.position.inMilliseconds;
    if ((expected - actual).abs() > 1500) {
      pc.jamSeekLocal(Duration(milliseconds: expected));
    }
  }

  // ===================================================================
  //  指令（房主和成員共用，全部走 relay）
  // ===================================================================

  void _send(Map<String, dynamic> msg) {
    try { _ws?.add(jsonEncode(msg)); } catch (_) {}
  }

  @visibleForTesting
  void debugSendForTest(Map<String, dynamic> msg) => _send(msg);

  /// 非阻塞播放/暫停切換
  void togglePlay() {
    if (mode == 'idle') return;
    // 先送 relay（非阻塞）
    _send({
      'type': playing ? 'pause' : 'play',
      if (isHost) 'pos': _pc?.position.inMilliseconds ?? 0,
    });
    // 本地立即反應（非阻塞）
    unawaited(_localTogglePlay());
  }

  Future<void> _localTogglePlay() async {
    final pc = _pc;
    if (pc == null) return;
    if (playing) {
      await pc.pause();
      playing = false;
    } else {
      await pc.resume();
      playing = true;
    }
    notifyListeners();
  }

  void seek(Duration pos) {
    _send({'type': 'seek', 'pos': pos.inMilliseconds});
    _pc?.jamSeekLocal(pos);
  }

  void next() {
    _send({'type': 'next'});
  }

  void previous() {
    _send({'type': 'prev'});
  }

  void skipVote() {
    _send({'type': 'skip_vote'});
  }

  bool mySkip = false;
  void toggleSkip() {
    mySkip = !mySkip;
    skipVote();
    notifyListeners();
  }

  void sendChat(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final item = {'text': '$myName：$t', 'ts': DateTime.now().millisecondsSinceEpoch};
    chat.add(item);
    _send({'type': 'chat', 'text': t});
    notifyListeners();
  }

  void addTrackFromSearch(Map<String, dynamic> item) {
    final normalized = <String, dynamic>{
      'title': item['name'],
      'artist': (item['artists'] as List? ?? []).join(', '),
      'coverUrl': item['coverUrl'],
      'isrc': item['isrc'],
    };
    _send({'type': 'add', 'track': normalized});
  }

  void vote(String? trackId, int delta) {
    if (trackId == null || trackId.isEmpty) return;
    final cur = _myVotes[trackId] ?? 0;
    final newDelta = cur == delta ? 0 : delta;
    _myVotes[trackId] = newDelta;
    _send({'type': 'vote', 'trackId': trackId, 'delta': newDelta});
    notifyListeners();
  }

  int myVote(String trackId) => _myVotes[trackId] ?? 0;

  void removeTrack(String trackId) {
    _send({'type': 'remove', 'trackId': trackId});
  }

  // ===================================================================
  //  房主端：加歌、解析、播放（併發控制）
  // ===================================================================

  /// 房主加歌：先入佇列回應 UI，背景解析 YouTube
  Future<void> hostAddTrack(Map<String, dynamic> raw) async {
    final title = (raw['name'] ?? '').toString().trim();
    final artist = (raw['artists'] as List? ?? []).join(', ');
    if (title.isEmpty) return;

    final track = <String, dynamic>{
      'id': 't-${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}',
      'title': title,
      'artist': artist,
      'coverUrl': raw['coverUrl'],
      'audioUrl': '',  // 先給空
      'addedBy': myName,
      'votes': 0,
      '_resolving': true,  // 標記正在解析
    };

    // 1. 先加入佇列、即時回應 UI
    _send({'type': 'add', 'track': track});
    final wasEmpty = queue.isEmpty && current == null;

    // 2. 丟進解析佇列（背景處理）
    await _resolveQueue.enqueue(_ResolveTask(
      track: track,
      priority: wasEmpty ? 0 : 1,  // 佇列原本空 → 最高優先級
    ));
  }

  /// 房主播放：解析 audioUrl（若空則 YouTube）→ 播放 + 廣播
  Future<void> _playAsHost(Map<String, dynamic> track) async {
    await _playLock.acquire();
    try {
      var url = (track['audioUrl'] as String?) ?? '';
      if (url.isEmpty) {
        final title = (track['title'] ?? '').toString();
        final artist = (track['artist'] ?? '').toString();
        if (title.isEmpty) return;
        try {
          final r = await YoutubeService.instance
              .resolveStream('$title $artist')
              .timeout(const Duration(seconds: 30));
          url = r?.audioUrl ?? '';
        } catch (_) {}
        if (url.isEmpty) {
          statusText = '無法解析音訊串流：$title';
          notifyListeners();
          return;
        }
        track['audioUrl'] = url;
      }
      _lastUrl = url;
      _send({
        'type': 'track_change',
        'current': track,
        'playing': true,
        'pos': 0,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      await _pc?.playJamUrl(url,
          title: (track['title'] ?? '').toString(),
          artist: (track['artist'] ?? '').toString(),
          coverUrl: track['coverUrl'] as String?);
    } finally {
      _playLock.release();
    }
  }

  /// 房主：點佇列播放
  Future<void> hostPlayTrack(Map<String, dynamic> track) => _playAsHost(track);

  // ===================================================================
  //  搜尋
  // ===================================================================

  Future<List<Map<String, dynamic>>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    searching = true;
    searchError = '';
    searchResults = [];
    notifyListeners();
    try {
      if (!SpotifySession.instance.isLoggedIn) {
        final ytResults = await YoutubeService.instance.search(query, limit: 20);
        searchResults = ytResults
            .map((r) => <String, dynamic>{
                  'name': r.title,
                  'artists': <String>[r.author],
                  'coverUrl': r.thumbnailUrl,
                })
            .toList();
        searching = false;
        searchError = ytResults.isEmpty ? '搜尋失敗' : '';
        notifyListeners();
        return searchResults;
      }
      final data = await SpotifyGqlClient().searchTracks(q, limit: 20);
      searchResults = _parseSearchItems(data);
      searching = false;
      notifyListeners();
      return searchResults;
    } catch (_) {
      searching = false;
      searchError = '搜尋失敗';
      notifyListeners();
      return [];
    }
  }

  List<Map<String, dynamic>> _parseSearchItems(Map<String, dynamic> data) {
    final out = <Map<String, dynamic>>[];
    try {
      final search = (data['data'] as Map?)?['searchV2'] as Map<String, dynamic>?;
      final tracks = search?['tracksV2'] as Map<String, dynamic>?;
      final items = tracks?['items'] as List<dynamic>? ?? [];
      for (final it in items) {
        final raw = (it as Map<String, dynamic>)['item'] as Map<String, dynamic>?;
        if (raw == null) continue;
        final track = SpotifyTrackItem.trackData(raw);
        final album = track['albumOfTrack'] as Map<String, dynamic>?;
        final name = (track['name'] ?? '') as String? ?? '';
        if (name.isEmpty) continue;
        final uri = (track['uri'] ?? '') as String? ?? '';
        final artists = SpotifyTrackItem.parseArtists(track['artists']);
        final cover = album != null
            ? SpotifyTrackItem.coverFromSources(album['coverArt']?['sources'])
            : null;
        out.add({
          'uri': uri, 'name': name, 'artists': artists,
          'album': (album?['name'] as String?) ?? '',
          'coverUrl': cover,
        });
      }
    } catch (_) {}
    return out;
  }
}

/// 解析任務
class _ResolveTask {
  final Map<String, dynamic> track;
  final int priority; // 0 = 最高（佇列空需立即播放）
  _ResolveTask({required this.track, required this.priority});
}

/// 非同步佇列（支援優先級、清空）
class _AsyncQueue<T> {
  final _queue = <T>[];
  final _waiters = <Completer<T>? >[];
  bool _closed = false;

  Future<void> enqueue(T item) async {
    if (_closed) throw StateError('Queue closed');
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0)!.complete(item);
    } else {
      _queue.add(item);
      _queue.sort((a, b) => 
          (a as _ResolveTask).priority.compareTo((b as _ResolveTask).priority));
    }
  }

  Future<T?> dequeue() async {
    if (_queue.isNotEmpty) return _queue.removeAt(0);
    if (_closed) return null;
    final completer = Completer<T>();
    _waiters.add(completer);
    return completer.future;
  }

  Future<void> clear() async {
    _closed = true;
    for (final w in _waiters) {
      if (w != null && !w.isCompleted) w.complete(null as T);
    }
    _waiters.clear();
    _queue.clear();
  }
}

/// 簡易非同步鎖
class _AsyncLock {
  final _queue = <Completer<void>>[];
  bool _locked = false;

  Future<void> acquire() async {
    if (!_locked) {
      _locked = true;
      return;
    }
    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _locked = false;
    }
  }
}