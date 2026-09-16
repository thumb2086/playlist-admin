import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:media_kit/media_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/playlist_item.dart';
import '../services/config_service.dart';
import '../services/stream_server.dart';
import '../services/smtc_service.dart';
import '../services/playback_history.dart';
import '../services/metadata_reader.dart';
import '../services/jam_service.dart';

/// Central playback controller: owns the MediaKit Player, queue, and all state.
/// Used by both PlayerBar (bottom bar) and the queue drawer / PlayerPage.
class PlayerController {
  static PlayerController? _instance;
  static PlayerController get instance => _instance ??= PlayerController._();
  PlayerController._();

  final Player _player = Player();
  final List<String> _queue = [];           // local file paths
  final List<String> _queueTitles = [];     // display names
  int _index = -1;
  bool _isPlaying = false;
  bool _shuffle = false;
  bool _loop = true;
  List<int> _shuffleOrder = [];
  double _volume = 0.7;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String _title = '';
  String _artist = '';
  String? _coverPath;
  String _statusText = '';
  Timer? _smtcTimer;
  Timer? _sleepTimer;
  DateTime? _sleepEndsAt;
  bool _prefetching = false;
  // 在「一起聽」房間內以成員身份連線時為 true：控制動作改送給房主。
  bool jamFollowMode = false;
  // PlaylistItem data for prefetch (query + isrc per queue slot).
  final List<PlaylistItem> _queueItems = [];
  // Playback history scrobble state.
  String _recordedSongKey = '';
  // Cover art memory cache (path → bytes). LRU capped: unbounded growth
  // eats RAM the longer the app plays.
  final Map<String, Uint8List?> _artworkCache = {};
  static const int _artworkCacheMax = 50;
  void _artworkPut(String path, Uint8List? bytes) {
    _artworkCache.remove(path);
    _artworkCache[path] = bytes;
    while (_artworkCache.length > _artworkCacheMax) {
      _artworkCache.remove(_artworkCache.keys.first);
    }
  }

  // media_kit stream subscriptions: must cancel in dispose.
  final List<StreamSubscription> _playerSubs = [];
  DateTime _lastPositionNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // Getters
  Player get player => _player;
  bool get isPlaying => _isPlaying;
  bool get shuffle => _shuffle;
  bool get loop => _loop;
  double get volume => _volume;
  Duration get position => _position;
  Duration get duration => _duration;
  String get title => _title;
  String get artist => _artist;
  String? get coverPath => _coverPath;
  int get index => _index;
  List<String> get queue => List.unmodifiable(_queue);
  List<String> get queueTitles => List.unmodifiable(_queueTitles);
  bool get hasTrack => _index >= 0 && _index < _queue.length;
  String get statusText => _statusText;
  DateTime? get sleepEndsAt => _sleepEndsAt;
  String get sleepRemainingText {
    final end = _sleepEndsAt;
    if (end == null) return '';
    final left = end.difference(DateTime.now());
    if (left.isNegative) return '';
    final m = left.inMinutes.remainder(60);
    final h = left.inHours;
    return h > 0 ? '$h時$m分' : '$m分';
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEndsAt = null;
    if (duration == null) { _notify(); return; }
    _sleepTimer = Timer(duration, () {
      if (_isPlaying) { _player.pause(); _isPlaying = false; }
      _sleepEndsAt = null;
      _notify();
    });
    _sleepEndsAt = DateTime.now().add(duration);
    _notify();
  }

  final _listeners = <VoidCallback>[];
  void addListener(VoidCallback fn) => _listeners.add(fn);
  void removeListener(VoidCallback fn) => _listeners.remove(fn);
  void _notify() {
    for (final fn in _listeners) {
      try { fn(); } catch (_) {}
    }
  }

  void init() {
    _volume = ConfigService.instance.config.volume.clamp(0.0, 1.0);
    _player.setVolume(_volume);
    _playerSubs.add(_player.stream.completed.listen((_) {
      if (jamFollowMode) return;
      if (_loop || _shuffle) {
        next();
      } else {
        _isPlaying = false;
        _notify();
      }
    }));
    _playerSubs.add(_player.stream.position.listen((p) {
      _position = p;
      _checkPlaybackRecord(p);
      // position 每秒更新數十次：節流 notify，否則整頁高頻 rebuild。
      final now = DateTime.now();
      if (now.difference(_lastPositionNotify).inMilliseconds < 500) return;
      _lastPositionNotify = now;
      _notify();
    }));
    _playerSubs.add(_player.stream.duration.listen((d) {
      _duration = d;
      _notify();
    }));
    // Attach SMTC: media buttons → PlayerController.
    SmtcService.instance.attach(
      onPlayPause: togglePlay,
      onNext: next,
      onPrevious: previous,
      onStop: () { if (_isPlaying) { _player.pause(); _isPlaying = false; _notify(); } },
      onSeek: (pos) { seek(pos); },
    );
    // Periodic SMTC push.
    _smtcTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isPlaying) return;
      _pushSmtc();
    });
  }

  /// Play a local file.
  Future<void> playFile(String path, {String? title, String? artist, String? coverUrl}) async {
    StreamServer.instance.stopActive();
    await _player.stop();
    _title = title ?? _titleFromPath(path);
    _artist = artist ?? _artistFromPath(path);
    _coverPath = coverUrl;
    _recordedSongKey = '';
    _isPlaying = true;
    _notify();
    // Load embedded artwork if no cover URL provided.
    if (_coverPath == null) {
      _loadEmbeddedArtwork(path);
    }
    final uri = Uri.file(path).toString();
    await _player.open(Media(uri));
    _pushSmtc();
  }

  /// Play via download-then-play: resolve → ffmpeg download → play local mp3.
  Future<void> playStream(String query, {String? title, String? artist, String? isrc, String? coverUrl}) async {
    await _player.stop();
    _title = title ?? query;
    _artist = artist ?? '';
    _coverPath = coverUrl;
    _recordedSongKey = '';
    _statusText = '下載中: $_title';
    _isPlaying = false;
    _notify();
    try {
      await StreamServer.instance.start();
      final localPath = await StreamServer.instance.resolveToFile(query, isrc: isrc)
          .timeout(const Duration(seconds: 60), onTimeout: () {
        _statusText = '下載逾時: $query';
        _notify();
        return '';
      });
      if (localPath.isEmpty || !File(localPath).existsSync()) {
        _statusText = '找不到: $query';
        _notify();
        return;
      }
      _statusText = '';
      _isPlaying = true;
      await _player.open(Media(Uri.file(localPath).toString()));
      _pushSmtc();
      _prefetchNext();
    } catch (e) {
      _statusText = '錯誤: $e';
      _notify();
    }
    _notify();
  }

  /// Smart play: local file if path exists, otherwise search music library, then stream.
  Future<void> play(String pathOrQuery, {String? title, String? artist, String? isrc, String? coverUrl}) async {
    if (File(pathOrQuery).existsSync()) {
      await playFile(pathOrQuery, title: title, artist: artist, coverUrl: coverUrl);
      return;
    }
    // Check music library for matching file.
    final local = await _findLocalTrack(pathOrQuery);
    if (local != null) {
      await playFile(local, title: title, artist: artist, coverUrl: coverUrl);
      return;
    }
    await playStream(pathOrQuery, title: title, artist: artist, isrc: isrc, coverUrl: coverUrl);
  }

  /// Play podcast show: look up RSS feed, get episodes, play latest.
  Future<void> playPodcastShow(String showName) async {
    StreamServer.instance.stopActive();
    await _player.stop();
    _title = showName;
    _statusText = '載入 Podcast: $showName';
    _isPlaying = false;
    _notify();
    try {
      final cfg = ConfigService.instance.config;
      final rssUrl = cfg.podcastSubscriptions[showName];
      if (rssUrl == null || rssUrl.isEmpty) {
        _statusText = '找不到 RSS: $showName';
        _notify();
        return;
      }
      // Fetch RSS feed.
      final resp = await http.get(Uri.parse(rssUrl),
          headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        _statusText = 'RSS 載入失敗: ${resp.statusCode}';
        _notify();
        return;
      }
      // Parse XML for episodes with audio URLs.
      final episodes = _parseRssEpisodes(resp.body);
      if (episodes.isEmpty) {
        _statusText = '找不到集數: $showName';
        _notify();
        return;
      }
      // Play first episode (latest).
      final ep = episodes.first;
      _title = ep['title'] ?? showName;
      _artist = showName;
      _statusText = '播放: $_title';
      _notify();
      await _player.open(Media(ep['url']!));
      _isPlaying = true;
      _pushSmtc();
    } catch (e) {
      _statusText = '錯誤: $e';
    }
    _notify();
  }

  /// Parse RSS XML to extract episodes with title + audio URL.
  List<Map<String, String>> _parseRssEpisodes(String xml) {
    final episodes = <Map<String, String>>[];
    final itemPattern = RegExp(r'<item>(.*?)</item>', dotAll: true);
    final titlePattern = RegExp(r'<title><!\[CDATA\[(.*?)\]\]></title>|<title>(.*?)</title>');
    final urlPattern = RegExp(r'<enclosure[^>]+url="([^"]+)"');
    for (final match in itemPattern.allMatches(xml)) {
      final item = match.group(1)!;
      final titleMatch = titlePattern.firstMatch(item);
      final title = (titleMatch?.group(1) ?? titleMatch?.group(2) ?? '').trim();
      final urlMatch = urlPattern.firstMatch(item);
      final url = urlMatch?.group(1) ?? '';
      if (url.isNotEmpty && (url.endsWith('.mp3') || url.endsWith('.m4a') || url.contains('audio'))) {
        episodes.add({'title': title, 'url': url});
      }
    }
    return episodes;
  }

  /// Play a PlaylistItem: direct RSS URL if available, else cache-first, else stream.
  Future<void> playItem(PlaylistItem item) async {
    StreamServer.instance.stopActive();
    await _player.stop();
    _title = item.name;
    _artist = item.artist;
    _coverPath = item.coverUrl;
    _recordedSongKey = '';
    _notify();

    // 1. Direct RSS URL (podcast).
    if (item.audioUrl != null && item.audioUrl!.isNotEmpty) {
      _statusText = '播放: ${item.name}';
      _isPlaying = true;
      _notify();
      // Cache RSS audio: play URL, cache in background.
      _cacheRssAudio(item);
      await _player.open(Media(item.audioUrl!));
      _pushSmtc();
      _notify();
      return;
    }

    // 2. Check cache\stream\ first.
    final cached = StreamServer.instance.findCached(item.audioQuery);
    if (cached != null && File(cached).existsSync()) {
      await playFile(cached, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
      return;
    }

    // 3. Check local music library.
    final local = await _findLocalTrack(item.audioQuery);
    if (local != null) {
      await playFile(local, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
      return;
    }

    // 4. Stream via YouTube.
    await playStream(item.audioQuery, title: item.name, artist: item.artist, isrc: item.isrc, coverUrl: item.coverUrl);
  }

  // 播放路徑 stem 索引：30 秒 TTL。原本每次點播都 listSync 全目錄凍 UI。
  Map<String, String> _localStemIndex = {};
  DateTime _localStemAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String?> _findLocalTrack(String query) async {
    final now = DateTime.now();
    if (now.difference(_localStemAt).inSeconds > 30 || _localStemIndex.isEmpty) {
      final idx = <String, String>{};
      try {
        final musicDir = Directory(ConfigService.instance.config.musicPath);
        if (await musicDir.exists()) {
          await for (final f in musicDir.list()) {
            if (f is File && f.path.endsWith('.mp3')) {
              idx[File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase()] = f.path;
            }
          }
        }
      } catch (_) {}
      _localStemIndex = idx;
      _localStemAt = now;
    }
    final lower = query.toLowerCase();
    final hit = _localStemIndex[lower];
    if (hit != null) return hit;
    for (final e in _localStemIndex.entries) {
      if (e.key.contains(lower) || lower.contains(e.key)) return e.value;
    }
    return null;
  }

  void _cacheRssAudio(PlaylistItem item) async {
    try {
      final cacheDir = Directory(ConfigService.instance.config.streamCachePath);
      await cacheDir.create(recursive: true);
      final safeName = item.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final outPath = '${cacheDir.path}\\$safeName.mp3';
      if (await File(outPath).exists()) return;
      // 串流寫檔：整集 bodyBytes 進 RAM，大檔直接爆記憶體。
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(item.audioUrl!));
        final resp = await client.send(req).timeout(const Duration(seconds: 60));
        if (resp.statusCode != 200) return;
        final total = resp.contentLength ?? -1;
        final sink = File(outPath).openWrite();
        int got = 0;
        try {
          await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
            got += chunk.length;
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          try { await sink.close(); } catch (_) {}
          try { await File(outPath).delete(); } catch (_) {}
          return;
        }
        // 提早斷流的截斷檔不可入庫（舊 http.get 會直接拋錯不寫檔）。
        if (total > 0 && got < total) {
          try { await File(outPath).delete(); } catch (_) {}
        }
      } finally {
        client.close();
      }
    } catch (_) {}
  }


  /// Prefetch next track in background (download ahead of time).
  void _prefetchNext() {
    if (_prefetching || _queue.isEmpty || _index < 0) return;
    final nextIdx = _index + 1;
    if (nextIdx >= _queue.length) return;
    final nextQuery = _queue[nextIdx];
    // Only prefetch if not already cached locally.
    if (StreamServer.instance.findCached(nextQuery) != null) return;
    _prefetching = true;
    // timeout + 外層 catch 重置 flag：舊寫法失敗就卡死，預取永久停用。
    StreamServer.instance.start()
        .timeout(const Duration(seconds: 30))
        .then((_) => StreamServer.instance
            .resolveToFile(nextQuery)
            .timeout(const Duration(minutes: 5)))
        .then((_) { _prefetching = false; })
        .catchError((_) { _prefetching = false; });
  }

  void setQueue(List<String> paths, {List<String>? titles, int startIndex = 0, List<PlaylistItem>? items}) {
    _queue
      ..clear()
      ..addAll(paths);
    _queueTitles
      ..clear()
      ..addAll(titles ?? paths.map(_titleFromPath));
    _queueItems
      ..clear()
      ..addAll(items ?? []);
    _index = startIndex;
    if (_shuffle) _buildShuffleOrder();
    _notify();
  }

  void addToQueue(String path, {String? title, PlaylistItem? item}) {
    _queue.add(path);
    _queueTitles.add(title ?? _titleFromPath(path));
    if (item != null) _queueItems.add(item);
    _notify();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    _queueTitles.removeAt(index);
    if (index < _queueItems.length) _queueItems.removeAt(index);
    if (_index >= _queue.length) _index = _queue.length - 1;
    if (index < _index) _index--;
    _notify();
  }

  void clearQueue() {
    _queue.clear();
    _queueTitles.clear();
    _queueItems.clear();
    _index = -1;
    if (_isPlaying) { _player.stop(); _isPlaying = false; }
    _title = '';
    _artist = '';
    _position = Duration.zero;
    _duration = Duration.zero;
    _statusText = '';
    _notify();
  }

  /// newIndex 語意：移除 oldIndex 之後的位置（配合 onReorderItem，
  /// 舊 onReorder 往下拖會差一格）。
  void moveInQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex > _queue.length) return;
    final path = _queue.removeAt(oldIndex);
    final title = oldIndex < _queueTitles.length ? _queueTitles.removeAt(oldIndex) : '';
    _queue.insert(newIndex.clamp(0, _queue.length), path);
    _queueTitles.insert(newIndex.clamp(0, _queueTitles.length), title);
    if (oldIndex < _queueItems.length) {
      final item = _queueItems.removeAt(oldIndex);
      _queueItems.insert(newIndex.clamp(0, _queueItems.length), item);
    }
    if (_index == oldIndex) {
      _index = newIndex;
    } else if (oldIndex < _index && newIndex >= _index) {
      _index--;
    } else if (oldIndex > _index && newIndex <= _index) {
      _index++;
    }
    _notify();
  }

  void jumpTo(int index) {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    if (index < _queueItems.length) {
      playItem(_queueItems[index]);
    } else {
      play(_queue[index], title: _queueTitles[index]);
    }
  }

  void next() {
    if (jamFollowMode) {
      JamService.instance.next();
      return;
    }
    if (_queue.isEmpty) return;
    if (_shuffle) {
      if (_shuffleOrder.isEmpty) _buildShuffleOrder();
      final pos = _shuffleOrder.indexOf(_index);
      final nextPos = (pos + 1) % _shuffleOrder.length;
      _index = _shuffleOrder[nextPos];
      if (nextPos == 0) _buildShuffleOrder(); // 重新洗牌
    } else {
      _index = (_index + 1) % _queue.length;
    }
    if (_index < _queueItems.length) {
      playItem(_queueItems[_index]);
    } else {
      play(_queue[_index], title: _queueTitles[_index]);
    }
  }

  void previous() {
    if (jamFollowMode) {
      JamService.instance.previous();
      return;
    }
    if (_queue.isEmpty) return;
    if (_shuffle) {
      if (_shuffleOrder.isEmpty) _buildShuffleOrder();
      final pos = _shuffleOrder.indexOf(_index);
      final prevPos = (pos - 1 + _shuffleOrder.length) % _shuffleOrder.length;
      _index = _shuffleOrder[prevPos];
    } else {
      _index = (_index - 1 + _queue.length) % _queue.length;
    }
    if (_index < _queueItems.length) {
      playItem(_queueItems[_index]);
    } else {
      play(_queue[_index], title: _queueTitles[_index]);
    }
  }

  void togglePlay() {
    if (jamFollowMode) {
      JamService.instance.togglePlay();
      return;
    }
    if (_isPlaying) {
      _player.pause();
      _isPlaying = false;
    } else {
      _player.play();
      _isPlaying = true;
    }
    _notify();
    _pushSmtc();
  }

  /// 播放（resume）— jam 房間房主/成員共用。
  Future<void> resume() async {
    if (jamFollowMode) {
      JamService.instance.togglePlay();
      return;
    }
    await _player.play();
    _isPlaying = true;
    _notify();
    _pushSmtc();
  }

  /// 暫停 — jam 房間房主/成員共用。
  Future<void> pause() async {
    if (jamFollowMode) {
      JamService.instance.togglePlay();
      return;
    }
    await _player.pause();
    _isPlaying = false;
    _notify();
    _pushSmtc();
  }

  /// 停止並清掉目前播放狀態（不碰佇列）。
  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
    _notify();
  }

  /// 播放一個遠端 URL（jam 成員收到房主提供的串流 URL 時用）。
  Future<void> playJamUrl(String url,
      {String? title, String? artist, String? coverUrl}) async {
    StreamServer.instance.stopActive();
    await _player.stop();
    _title = title ?? '';
    _artist = artist ?? '';
    _coverPath = coverUrl;
    _recordedSongKey = '';
    _statusText = '';
    _isPlaying = true;
    _notify();
    await _player.open(Media(url));
    _pushSmtc();
  }

  /// 本機 seek（jam 成員做 drift 校正用，不會送指令給房主）。
  Future<void> jamSeekLocal(Duration pos) async {
    if (pos.inMilliseconds < 0) return;
    await _player.seek(pos);
    _position = pos;
    _notify();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_shuffle) _buildShuffleOrder();
    _notify();
  }

  /// Fisher-Yates shuffle: 產生完整的隨機播放順序，確保每首歌只播一次才重洗。
  void _buildShuffleOrder() {
    _shuffleOrder = List<int>.generate(_queue.length, (i) => i);
    final rng = Random();
    for (int i = _shuffleOrder.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final temp = _shuffleOrder[i];
      _shuffleOrder[i] = _shuffleOrder[j];
      _shuffleOrder[j] = temp;
    }
    // 確保不在開頭就重複目前曲目。
    if (_shuffleOrder.isNotEmpty && _index >= 0 && _shuffleOrder.first == _index && _shuffleOrder.length > 1) {
      final swap = _shuffleOrder[1];
      _shuffleOrder[1] = _shuffleOrder.first;
      _shuffleOrder.first = swap;
    }
  }
  void toggleLoop() { _loop = !_loop; _notify(); }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    ConfigService.instance.config.volume = _volume;
    ConfigService.instance.save();
    _notify();
  }

  Future<void> seek(Duration pos) async {
    if (jamFollowMode) {
      JamService.instance.seek(pos);
      return;
    }
    await _player.seek(pos);
    _position = pos;
    _notify();
    _pushSmtc();
  }

  void _pushSmtc() {
    if (_title.isEmpty) {
      SmtcService.instance.update(title: 'playlist-admin', playing: false);
      return;
    }
    SmtcService.instance.update(
      title: _title, artist: _artist, artworkUrl: _coverPath,
      playing: _isPlaying, position: _position, duration: _duration,
    );
  }

  /// Scrobble: record track when listened to >=50% (capped at 4 min).
  void _checkPlaybackRecord(Duration position) {
    if (_title.isEmpty || _duration.inMilliseconds == 0) return;
    final stem = _title.toLowerCase();
    if (stem == _recordedSongKey) return;
    final thresholdMs = (_duration.inMilliseconds ~/ 2)
        .clamp(0, const Duration(minutes: 4).inMilliseconds);
    if (position.inMilliseconds < thresholdMs) return;
    _recordedSongKey = stem;
    PlaybackHistory.instance.record(_title, _artist, _duration);
  }

  /// Load embedded artwork from a local audio file in background.
  /// 世代 guard：快速切歌時慢查詢回來不可覆蓋新歌封面。
  int _artworkGen = 0;
  void _loadEmbeddedArtwork(String path) async {
    final gen = ++_artworkGen;
    if (_artworkCache.containsKey(path)) {
      final cached = _artworkCache[path];
      if (cached != null && gen == _artworkGen) {
        _coverPath = 'mem:${path.hashCode}';
        _notify();
      }
      return;
    }
    try {
      final meta = await MetadataReader.read(path);
      _artworkPut(path, meta.artwork);
      if (gen != _artworkGen) return; // 已切歌：丟棄過期結果
      if (meta.artwork != null && meta.artwork!.isNotEmpty) {
        _coverPath = 'mem:${path.hashCode}';
        _notify();
        _pushSmtc();
      }
    } catch (_) {}
  }

  /// Get cached artwork bytes (for PlayerBar to display).
  Uint8List? getArtworkBytes([String? forPath]) {
    final cp = _coverPath;
    if (cp == null || !cp.startsWith('mem:')) return null;
    // 直查 path（呼叫方傳入當前曲目路徑可完全避開 hash 掃描）；
    // 不傳則 fallback 掃 hash（舊行為，相容）。
    if (forPath != null) return _artworkCache[forPath];
    for (final entry in _artworkCache.entries) {
      if ('mem:${entry.key.hashCode}' == cp) return entry.value;
    }
    return null;
  }

  String _titleFromPath(String path) {
    final stem = File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
    if (stem.contains(' - ')) return stem.split(' - ').first.trim();
    return stem;
  }

  String _artistFromPath(String path) {
    final stem = File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
    if (stem.contains(' - ')) return stem.split(' - ').sublist(1).join(' - ').trim();
    return '';
  }

  void dispose() {
    for (final s in _playerSubs) {
      try { s.cancel(); } catch (_) {}
    }
    _playerSubs.clear();
    _smtcTimer?.cancel();
    _sleepTimer?.cancel();
    _player.dispose();
  }
}
