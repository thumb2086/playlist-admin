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
import '../services/log_manager.dart';
import '../services/podcast_service.dart';
import '../models/podcast_episode.dart';

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
  // ── 詳細面板（點縮圖彈出）的資料：來源 + 即時音訊參數 + 專輯 ──
  String _sourceKind = '';
  String _sourceDetail = '';
  double? _bitrateRaw; // mpv audio-bitrate：可能 bps 或 kbps，顯示端自適應
  int? _sampleRate;
  int? _channelCount;
  String? _audioFormat;
  String _album = '';

  /// 每次換歌重置音訊參數（舊值屬上一首）。
  void _resetAudioInfo() {
    _bitrateRaw = null;
    _sampleRate = null;
    _channelCount = null;
    _audioFormat = null;
    _album = '';
  }

  String get sourceKind => _sourceKind;
  String get sourceDetail => _sourceDetail;
  String get album => _album;
  int? get sampleRate => _sampleRate;
  int? get channelCount => _channelCount;
  String? get audioFormat => _audioFormat;

  /// 位元率 kbps：mpv 有時回 bps(>10000) 有時 kbps，自適應。
  double? get bitrateKbps {
    final b = _bitrateRaw;
    if (b == null || b <= 0) return null;
    return b > 10000 ? b / 1000.0 : b;
  }

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
  // mpv 開檔失敗旗標：誤導 completed → 自動跳歌的防護（見 completed listener）。
  bool _loadFailed = false;

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
      if (_isPlaying) { _player.pause(); _isPlaying = false; _pushSmtc(); }
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
    // media_kit 音量刻度是 0~100（mpv），app 內部是 0~1（audioplayers 遷移遺跡）。
    // 不 ×100 的話 UI 顯示100%實際只有1%，再乘系統主音量 = 人耳聽不見的無聲播放。
    _player.setVolume(_volume * 100);
    _playerSubs.add(_player.stream.completed.listen((_) {
      if (jamFollowMode) return;
      if (_loadFailed) {
        // 開檔失敗 ≠ 播完：不自動跳，否則 50 首的失敗佇列會連環空轉。
        _loadFailed = false;
        _isPlaying = false;
        _notify();
        _pushSmtc();
        return;
      }
      if (_loop || _shuffle) {
        next();
      } else {
        _isPlaying = false;
        _notify();
        _pushSmtc(); // 播完停住：卡片若不更新會停在 Playing，按了像沒反應
      }
    }));
    _playerSubs.add(_player.stream.position.listen((p) {
      _position = p;
      if (p > Duration.zero && _statusText.startsWith('播放錯誤')) {
        _statusText = ''; // 已在動：剛才的 error 是雜訊，清掉
      }
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
    // 詳細面板：即時解碼參數（取樣率/聲道/格式）+ 位元率。
    _playerSubs.add(_player.stream.audioParams.listen((p) {
      _sampleRate = p.sampleRate;
      _channelCount = p.channelCount;
      _audioFormat = p.format;
    }));
    _playerSubs.add(_player.stream.audioBitrate.listen((b) {
      _bitrateRaw = b;
    }));
    // mpv 開不起來（404 等）→ 顯示錯誤並停；已在播時的 error 多半是串流
    // 雜訊，只記 log 不動播放狀態（否則「按鈕狀態怪=播著卻顯示▶」）。
    _playerSubs.add(_player.stream.error.listen((msg) {
      if (msg.isEmpty) return;
      LogManager.instance.info('[player] mpv error: $msg');
      // 字幕自動載入失敗（相鄰 .srt 缺失/長檔名）＝無害雜訊，絕不可殺播放。
      final low = msg.toLowerCase();
      if (low.contains('.srt') || low.contains('external file') ||
          low.contains('sub') || low.contains('subtitle')) {
        return;
      }
      if (_position > Duration.zero) return; // 有進度 = 正在播 → 雜訊
      _loadFailed = true; // completed 不可把失敗當播完去自動跳下一首
      _statusText = '播放錯誤: $msg';
      _isPlaying = false;
      _notify();
      _pushSmtc();
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
    // 啟動即推一次：沒播過歌時也要讓 flyout 顯示 app 名而非系統預設值。
    _pushSmtc();
  }

  /// Play a local file.
  Future<void> playFile(String path,
      {String? title, String? artist, String? coverUrl, String? album}) async {
    StreamServer.instance.stopActive();
    await _player.stop();
    _position = Duration.zero; // 開新檔歸零：error 判斷(見 listener)依賴它
    _statusText = ''; // 入口清殘留錯誤（playFile 不設 statusText，不清會帶到下一首）
    _resetAudioInfo();
    _sourceKind = '本機檔案';
    _sourceDetail = path.split(Platform.pathSeparator).last;
    _album = album ?? ''; // Spotify album 先佔位，ID3 讀到再覆蓋
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

  /// True streaming: 開 local HTTP 端點讓 mpv 邊下邊播，不再等整首下載完
  /// （舊 resolveToFile = download-then-play，一首歌要卡 10~30 秒才出聲）。
  /// 下一首仍由 _prefetchNext 後台完整下載入快取，換歌不卡。
  Future<void> playStream(String query,
      {String? title, String? artist, String? isrc, String? coverUrl, String? album}) async {
    await _player.stop();
    _position = Duration.zero; // 開新檔歸零（見 error listener）
    _resetAudioInfo();
    _album = album ?? '';
    _sourceKind = '線上串流（YouTube → 即時轉檔）';
    _title = title ?? query;
    _artist = artist ?? '';
    _coverPath = coverUrl;
    _recordedSongKey = '';
    _statusText = '';
    _isPlaying = true;
    _notify();
    try {
      await StreamServer.instance.start();
      // 來源細節要在 start() 之後記：之前取會拿到 port 0（server 未 bind）。
      _sourceDetail =
          StreamServer.instance.baseUrl.replaceFirst('http://', '');
      // 防御：清掉尾巴懸空分隔符（artsits 空時曾產生「title - 」→ 404）。
      final cleanQuery = query.trim().replaceAll(RegExp(r'\s*-\s*$'), '').trim();
      final url =
          '${StreamServer.instance.baseUrl}/stream/${Uri.encodeComponent(cleanQuery.isEmpty ? query : cleanQuery)}';
      await _player.open(Media(url));
      _pushSmtc();
      _prefetchNext();
    } catch (e) {
      _statusText = '串流錯誤: $e';
      _isPlaying = false;
      _notify();
      _pushSmtc();
    }
  }

  /// Smart play: local file if path exists, otherwise search music library, then stream.
  Future<void> play(String pathOrQuery,
      {String? title, String? artist, String? isrc, String? coverUrl, String? album}) async {
    if (File(pathOrQuery).existsSync()) {
      await playFile(pathOrQuery,
          title: title, artist: artist, coverUrl: coverUrl, album: album);
      return;
    }
    // Check music library for matching file.
    final local = await _findLocalTrack(pathOrQuery);
    if (local != null) {
      await playFile(local,
          title: title, artist: artist, coverUrl: coverUrl, album: album);
      return;
    }
    await playStream(pathOrQuery,
        title: title,
        artist: artist,
        isrc: isrc,
        coverUrl: coverUrl,
        album: album);
  }

  /// Play podcast show: look up RSS feed, get episodes, play latest.
  Future<void> playPodcastShow(String showName, {String? coverUrl}) async {
    StreamServer.instance.stopActive();
    await _player.stop();
    _position = Duration.zero; // 開新檔歸零（見 error listener）
    _title = showName;
    _artist = showName; // 舊版從不設 artist → 殘留上一首的歌手名
    _coverPath = coverUrl; // 呼叫端（Spotify 卡片）封面當保底
    _statusText = '載入 Podcast: $showName';
    _isPlaying = false;
    _notify();
    try {
      final cfg = ConfigService.instance.config;
      var rssUrl = cfg.podcastSubscriptions[showName];
      // 未訂閱的節目 → iTunes 搜同名節目拿 feed 兜底（訂閱清單外也能聽）。
      if (rssUrl == null || rssUrl.isEmpty) {
        try {
          final shows = await PodcastService.instance.searchPodcasts(showName);
          final hit = shows.where((s) => s.feedUrl.isNotEmpty).firstOrNull;
          if (hit != null) {
            rssUrl = hit.feedUrl;
            _statusText = '載入 Podcast: $showName（未訂閱，iTunes 解析）';
            _notify();
          }
        } catch (_) {}
      }
      if (rssUrl == null || rssUrl.isEmpty) {
        _statusText = '找不到 RSS: $showName（未訂閱且 iTunes 無結果）';
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
      // 封面 fallback 鏈：channel 層 itunes:image → 首個單集層 image →
      // 呼叫端卡片封面（coverUrl 參數已在入口設過，只在 RSS 有圖時覆蓋）。
      final chCover = RegExp(r'<itunes:image[^>]*href="([^"]+)"').firstMatch(resp.body)?.group(1) ??
          RegExp(r'<image>\s*<url>([^<]+)</url>\s*</image>', dotAll: true)
              .firstMatch(resp.body)?.group(1);
      if (chCover != null) _coverPath = chCover;
      final episodes = _parseRssEpisodes(resp.body);
      if (episodes.isEmpty) {
        _statusText = '找不到集數: $showName';
        _notify();
        return;
      }
      // Play first episode (latest).
      final ep = episodes.first;
      _resetAudioInfo();
      _sourceKind = 'RSS 直連（Podcast）';
      _sourceDetail = Uri.tryParse(ep['url'] ?? '')?.host ?? '';
      _title = ep['title'] ?? showName;
      _artist = showName;
      _statusText = ''; // 標題已足夠；舊的「播放: …」會永久佔著狀態列（橘字）
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
    _position = Duration.zero; // 開新檔歸零（見 error listener）
    _statusText = ''; // 入口清殘留錯誤（分支需要時會再設）
    _resetAudioInfo();
    _album = item.album ?? '';
    _title = item.name;
    _artist = item.artist;
    _coverPath = item.coverUrl;
    _recordedSongKey = '';
    _notify();

    // 1. Direct RSS URL (podcast).
    if (item.audioUrl != null && item.audioUrl!.isNotEmpty) {
      _statusText = ''; // 標題已足夠；舊的「播放: …」會永久蓋掉歌名顯示
      _sourceKind = 'RSS 直連（Podcast）';
      _sourceDetail = Uri.tryParse(item.audioUrl!)?.host ?? '';
      // 本機優先：podcasts\<節目>\ 已下載過 → 播檔案，不燒網路。
      final localEp = _findLocalEpisode(item.name, item.artist);
      if (localEp != null) {
        await playFile(localEp, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
        return;
      }
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

    // 3.5. 本機單集優先（podcasts\ 是天然索引，不需要 M3U8）；
    //      沒有本機檔才做 RSS 二段解析（已訂閱 → iTunes showHint）。
    final localEpDirect = _findLocalEpisode(item.name, item.artist);
    if (localEpDirect != null) {
      await playFile(localEpDirect, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
      return;
    }
    final ep = await findEpisodeByTitle(item.name, showHint: item.artist);
    if (ep != null) {
      _statusText = '';
      await playItem(ep);
      return;
    }

    // 4. Stream via YouTube.
    await playStream(item.audioQuery, title: item.name, artist: item.artist, isrc: item.isrc, coverUrl: item.coverUrl);
  }

  /// 單集標題解析（public：PlaylistDetailPage 下載也走同一套判別）。
  /// 1) 已訂閱節目的 RSS（平行、feed 快取 10 分鐘）
  /// 2) showHint（Spotify episode 的 artist 位常是節目名）→ iTunes 搜節目
  ///    → 取前 3 個 feed 找該集 — 覆蓋「沒訂閱但歌單裡有」的單集。
  final Map<String, ({DateTime at, List<PodcastEpisode> eps})> _epFeedCache = {};
  final Map<String, ({DateTime at, PlaylistItem? item})> _epResolveCache = {};

  Future<List<PodcastEpisode>> _episodesCached(String feedUrl) async {
    final hit = _epFeedCache[feedUrl];
    if (hit != null && DateTime.now().difference(hit.at) < const Duration(minutes: 10)) {
      return hit.eps;
    }
    final eps = (await PodcastService.instance.fetchEpisodes(feedUrl)).episodes;
    if (_epFeedCache.length > 64) _epFeedCache.clear();
    _epFeedCache[feedUrl] = (at: DateTime.now(), eps: eps);
    return eps;
  }

  Future<PlaylistItem?> findEpisodeByTitle(String title, {String? showHint}) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final mem = _epResolveCache[t];
    if (mem != null && DateTime.now().difference(mem.at) < const Duration(minutes: 10)) {
      return mem.item;
    }
    PlaylistItem? found;

    // Phase 1: subscribed feeds.
    final subs = ConfigService.instance.config.podcastSubscriptions;
    if (subs.isNotEmpty) {
      final results = await Future.wait(subs.entries.map((e) async {
        try {
          final eps = await _episodesCached(e.value);
          for (final ep in eps) {
            if (ep.title == t && ep.audioUrl.startsWith('http')) {
              return _epItem(ep.title, e.key, ep.audioUrl);
            }
          }
        } catch (_) {}
        return null;
      }));
      for (final r in results) {
        if (r != null) { found = r; break; }
      }
    }

    // Phase 2: iTunes search by show hint.
    final hint = (showHint ?? '').trim();
    if (found == null && hint.isNotEmpty) {
      try {
        final shows = await PodcastService.instance.searchPodcasts(hint);
        final feeds = shows.take(3).map((s) => s.feedUrl).where((u) => u.isNotEmpty);
        final results = await Future.wait(feeds.map((u) async {
          try {
            final eps = await _episodesCached(u);
            for (final ep in eps) {
              if (ep.title == t && ep.audioUrl.startsWith('http')) {
                return _epItem(ep.title, matchSubscribedShow(hint), ep.audioUrl);
              }
            }
          } catch (_) {}
          return null;
        }));
        for (final r in results) {
          if (r != null) { found = r; break; }
        }
      } catch (_) {}
    }

    if (_epResolveCache.length > 256) _epResolveCache.clear();
    _epResolveCache[t] = (at: DateTime.now(), item: found);
    return found;
  }

  /// show 提示對回訂閱 key（Spotify artist='科技浪' vs 訂閱 key='科技浪 Tech.wav'），
  /// 確保下載落在 pipeline 同一個 podcasts\<節目>\ 資料夾。Public：下載頁共用。
  String matchSubscribedShow(String hint) {
    final subs = ConfigService.instance.config.podcastSubscriptions;
    if (hint.isEmpty) return hint;
    for (final k in subs.keys) {
      if (k == hint || k.contains(hint) || hint.contains(k)) return k;
    }
    return hint;
  }

  PlaylistItem _epItem(String title, String show, String audioUrl) => PlaylistItem(
      name: title, artist: show, audioQuery: title, audioUrl: audioUrl);

  /// 找本機單集檔：podcasts\<節目>\（含對回的訂閱 key 資料夾）與根目錄。
  /// 找不到回 null；資料夾不存在時 podcastDir 會建（無害）。
  String? _findLocalEpisode(String title, String show) {
    try {
      final safe = PodcastService.normalizeFileName(title);
      if (safe.isEmpty) return null;
      final roots = <String>{};
      final key = matchSubscribedShow(show);
      if (key.isNotEmpty) roots.add(PodcastService.instance.podcastDir(key));
      final raw = show.trim();
      if (raw.isNotEmpty) roots.add(PodcastService.instance.podcastDir(raw));
      roots.add(PodcastService.instance.podcastDir(''));
      for (final dir in roots) {
        for (final ext in ['mp3', 'm4a', 'mp4', 'wav', 'aac']) {
          final f = File('$dir\\$safe.$ext');
          if (f.existsSync()) return f.path;
        }
      }
    } catch (_) {}
    return null;
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
    if (_queue.isEmpty) {
      // 空佇列也要同步 SMTC：否則卡片停在 Playing，看起來像壞了。
      _pushSmtc();
      return;
    }
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
    _pushSmtc();
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
    await _player.setVolume(_volume * 100); // media_kit 0~100，見 init()
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
      if (meta.album != null && meta.album!.isNotEmpty) _album = meta.album!;
      if (meta.artwork != null && meta.artwork!.isNotEmpty) {
        _coverPath = 'mem:${path.hashCode}'; // 內嵌封面（回歸防護：不可漏）
        _pushSmtc();
      }
      _notify(); // 專輯/封面任一有值都讓面板拿得到
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
