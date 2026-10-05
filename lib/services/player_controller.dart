import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:media_kit/media_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/playlist_item.dart';
import '../services/config_service.dart';
import '../services/cover_cache.dart';
import '../services/stream_server.dart';
import '../services/smtc_service.dart';
import '../services/playback_history.dart';
import '../services/metadata_reader.dart';
import '../services/youtube_service.dart';
import '../services/lyrics_service.dart';
import '../services/audio_exts.dart';
import '../services/fs_paths.dart';
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

  /// 自動接歌（Spotube 式電台）：播到隊尾/單曲播完時，自動排相似歌曲繼續。
  /// 預設開（關掉 = 回到播完即停）。Podcast 單集播完不接歌。
  bool _autoplay = true;

  /// 目前播的是 Podcast 單集（playItem 單集分支設 true，音樂分支設 false）。
  bool _currentIsPodcast = false;
  bool _radioBusy = false;
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
  Timer? _volumeSaveTimer;
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

  // 房主身份且房間正在播 jam 歌 → 控制列/自動接歌也要走 jam（否則成員收不到）。
  bool get _jamHostActive =>
      JamService.instance.mode == 'host' &&
      JamService.instance.current != null;
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
    _playerSubs.add(_player.stream.completed.listen((_) async {
      if (jamFollowMode) return;
      if (_jamHostActive) {
        // jam 房主播完 → 接房間佇列（relay host_next → 解析 → 成員跟播）。
        JamService.instance.next();
        return;
      }
      if (_loadFailed) {
        // 開檔失敗 ≠ 播完：不自動跳，否則 50 首的失敗佇列會連環空轉。
        _loadFailed = false;
        _isPlaying = false;
        _notify();
        _pushSmtc();
        return;
      }
      // 隊列還有下一首 → 直接接（不管 loop 開關；播完停只發生在隊尾）。
      if (_queue.isNotEmpty && _hasMore()) {
        next();
        return;
      }
      // 隊尾 / 單曲：loop 開 → 循環整單（loop 優先於 autoplay，用戶決議）。
      // autoplay 只在 loop 關時接電台。
      if (_loop) {
        if (_queue.isEmpty) {
          // 單曲直撥（queue 空）→ 重播 = 無限自動播放（舊版在這裡空轉卡死）。
          _replayCurrent();
        } else {
          next(); // 有隊列 → 接下一首（% 取餘 = 播到尾回頭，無限循環）
        }
        return;
      }
      if (_shuffle && _queue.isNotEmpty) {
        next();
        return;
      }
      // 都沒開 → 自動接歌（電台）：播完播相似歌曲；Podcast 單集不接。
      // （loop 優先：上面 loop 開已 return，到這裡表示 loop 關。）
      if (_autoplay &&
          _title.isNotEmpty &&
          !_currentIsPodcast &&
          !jamFollowMode) {
        await _playRadio();
        return;
      }
      _isPlaying = false;
      _notify();
      _pushSmtc(); // 播完停住：卡片若不更新會停在 Playing，按了像沒反應
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
    _currentIsPodcast = false; // 本機檔一定是音樂（防 Podcast 後殘留旗標）
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
    _warmLyrics();
  }

  /// True streaming: 開 local HTTP 端點讓 mpv 邊下邊播，不再等整首下載完
  /// （舊 resolveToFile = download-then-play，一首歌要卡 10~30 秒才出聲）。
  /// 下一首仍由 _prefetchNext 後台完整下載入快取，換歌不卡。
  /// 手機版改走 _playStreamDirect（無 yt-dlp，直連 youtube_explode 直鏈）。
  Future<void> playStream(String query,
      {String? title, String? artist, String? isrc, String? coverUrl, String? album}) async {
    _currentIsPodcast = false;
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
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      // 手機沒有 yt-dlp 執行檔，StreamServer 管線播不了：
      // 改走 youtube_explode 直鏈（Spotube 同款，純 Dart）。
      await _playStreamDirect(query);
      return;
    }
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
      _warmLyrics();
    } catch (e) {
      // 桌面管線（yt-dlp + cookies）掛了 → 改試直連（手機同款路徑）。
      // 宿舍網這類直鏈 403 的環境兩邊都會失敗，才報錯。
      final ok = await _playStreamDirect(query, fromDesktopFallback: true);
      if (!ok && _statusText.isEmpty) {
        // _playStreamDirect 失敗時自己會設具體指引：有就不蓋掉。
        _statusText = '串流錯誤: $e';
        _isPlaying = false;
        _notify();
        _pushSmtc();
      }
    }
  }

  /// 手機直連播放：youtube_explode 拿直鏈 → mpv 直接播，不經本地轉碼管線。
  /// 回傳是否成功（桌面管線失敗時拿它當 fallback）。
  ///
  /// 二段式：① 直連（免電腦，同 Spotube）；② 直連被擋（宿舍網這類 403）
  /// → 經電腦轉播（電腦有 cookies，區網 pipe 保證能播；需曾連線同步過）。
  /// [fromDesktopFallback] 為 true 時錯誤文案不提轉播（桌面用戶用不上）。
  Future<bool> _playStreamDirect(String query,
      {bool fromDesktopFallback = false}) async {
    final cleanQuery = query.trim().replaceAll(RegExp(r'\s*-\s*$'), '').trim();
    final q = cleanQuery.isEmpty ? query : cleanQuery;
    // ① 直連。
    try {
      final r = await YoutubeService.instance.resolveStreamDirect(q);
      if (r != null && r.audioUrl.isNotEmpty) {
        _sourceKind = '線上串流（YouTube 直連）';
        _sourceDetail = Uri.tryParse(r.audioUrl)?.host ?? '';
        if ((_coverPath ?? '').isEmpty) _coverPath = r.thumbnailUrl;
        await _player.open(Media(r.audioUrl));
        _pushSmtc();
        _warmLyrics();
        return true;
      }
    } catch (_) {
      // 掉下去試轉播。
    }
    // ② 經電腦轉播（只在手機試；桌面 fallback 不需要繞自己）。
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        final host =
            ConfigService.instance.config.lastSyncHost.trim();
        if (host.isNotEmpty && await _pingRelay(host)) {
          _sourceKind = '線上串流（經電腦轉播）';
          _sourceDetail = host;
          final url =
              'http://$host/relay-stream?q=${Uri.encodeComponent(q)}';
          await _player.open(Media(url));
          _pushSmtc();
          _warmLyrics();
          return true;
        }
      } catch (_) {
        // 掉下去報錯。
      }
    }
    _statusText = fromDesktopFallback
        ? '串流錯誤: 管線與直連都失敗（換首歌或檢查網路/cookies）'
        : '串流錯誤: 直連被擋且電腦轉播連不上（電腦開了同步開關？同 Wi-Fi？曾連線同步過？）';
    _isPlaying = false;
    _notify();
    _pushSmtc();
    return false;
  }

  /// 轉播前先 ping：電腦不在線就不讓 mpv 對著黑洞空等。
  Future<bool> _pingRelay(String host) async {
    try {
      final resp = await http
          .get(Uri.parse('http://$host/api/ping'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 歌詞預熱（設定「播放時預取歌詞」開才做）：開歌同時背景抓歌詞進快取，
  /// 打開歌詞頁直接顯示，不用等。Podcast 單集不抓（LRCLib 沒有 podcast）。
  /// LRCLib 有內建記憶體快取（200 首 LRU），重複開歌不重打。
  void _warmLyrics() {
    if (_currentIsPodcast) return;
    try {
      if (!ConfigService.instance.config.enableRetroactiveLyrics) return;
    } catch (_) {
      return;
    }
    final artist = _artist.trim();
    final title = _title.trim();
    if (artist.isEmpty || title.isEmpty) return;
    LyricsService.instance.fetch(artist, title).catchError((_) => null);
  }

  /// Smart play: local file if path exists, otherwise search music library, then stream.
  Future<void> play(String pathOrQuery,
      {String? title, String? artist, String? isrc, String? coverUrl, String? album}) async {
    _currentIsPodcast = false;
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
    _currentIsPodcast = true; // 整個節目都是單集：播完不接音樂電台
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
    _currentIsPodcast = false; // 預設音樂；單集分支後面會改回 true
    _position = Duration.zero; // 開新檔歸零（見 error listener）
    _statusText = ''; // 入口清殘留錯誤（分支需要時會再設）
    _resetAudioInfo();
    _album = item.album ?? '';
    _title = item.name;
    _artist = item.artist;
    _coverPath = item.coverUrl;
    if (_coverPath == null || _coverPath!.isEmpty) {
      // 呼叫端沒帶圖 → 查封面快取（詳情頁 enrichment 寫入的）。
      // 播放列/SMTC 跟著有圖，不用每條播放路徑各自處理。
      try {
        final cache = await CoverCache.load();
        final e = cache[CoverCache.key(item.isrc, item.name, item.artist)];
        if (e is Map) {
          final c = e['c'] as String?;
          if (c != null && c.isNotEmpty) _coverPath = c;
          final a = e['a'] as String?;
          if (_album.isEmpty && a != null && a.isNotEmpty) _album = a;
        }
      } catch (_) {}
    }
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
        _currentIsPodcast = true; // 單集播完不接音樂電台
        await playFile(localEp, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
        return;
      }
      _isPlaying = true;
      _notify();
      // Cache RSS audio: play URL, cache in background.
      _cacheRssAudio(item);
      _currentIsPodcast = true;
      await _player.open(Media(item.audioUrl!));
      _pushSmtc();
      _notify();
      return;
    }

    // 2. Check cache\stream\ first.
    final cached = StreamServer.instance.findCached(item.audioQuery);
    if (cached != null && File(cached).existsSync()) {
      _currentIsPodcast = false;
      await playFile(cached, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
      return;
    }

    // 3. Check local music library.
    final local = await _findLocalTrack(item.audioQuery);
    if (local != null) {
      _currentIsPodcast = false;
      await playFile(local, title: item.name, artist: item.artist, coverUrl: item.coverUrl);
      return;
    }

    // 3.5. 本機單集優先（podcasts\ 是天然索引，不需要 M3U8）；
    //      沒有本機檔才做 RSS 二段解析（已訂閱 → iTunes showHint）。
    final localEpDirect = _findLocalEpisode(item.name, item.artist);
    if (localEpDirect != null) {
      _currentIsPodcast = true;
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
          final f = File(joinPath(dir, '$safe.$ext'));
          if (f.existsSync()) return f.path;
        }
      }
    } catch (_) {}
    return null;
  }

  // 播放路徑 stem 索引：30 秒 TTL。原本每次點播都 listSync 全目錄凍 UI。
  Map<String, String> _localStemIndex = {};
  DateTime _localStemAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 確保 stem 索引新鮮（_findLocalTrack 與電台共用）。
  Future<void> _ensureStemIndex() async {
    final now = DateTime.now();
    if (now.difference(_localStemAt).inSeconds <= 30 &&
        _localStemIndex.isNotEmpty) {
      return;
    }
    final idx = <String, String>{};
    try {
      final musicDir = Directory(ConfigService.instance.config.musicPath);
      if (await musicDir.exists()) {
        await for (final f in musicDir.list(recursive: true, followLinks: false)) {
          // 全站正規集合：m4a/webm 過渡檔也要認（播得到），同步會再換成 MP3。
          if (f is File && isAudioFile(f.path)) {
            idx[File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase()] = f.path;
          }
        }
      }
    } catch (_) {}
    _localStemIndex = idx;
    _localStemAt = now;
  }

  Future<String?> _findLocalTrack(String query) async {
    await _ensureStemIndex();
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
      final outPath = joinPath(cacheDir.path, '$safeName.mp3');
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

  /// 隊列是否還有下一首（shuffle 視為永遠有：播完重洗）。
  bool _hasMore() {
    if (_queue.isEmpty) return false;
    if (_shuffle) return true;
    return _index < _queue.length - 1;
  }

  /// 電台：以目前歌曲為種子排相似歌曲（同歌單 → 同歌手 → 隨機），
  /// 接進新隊列繼續播。失敗（無曲庫）→ 保持停止，不洗狀態。
  Future<void> _playRadio() async {
    if (_radioBusy) return;
    _radioBusy = true;
    try {
      final seedTitle = _title;
      final seedArtist = _artist;
      if (seedTitle.isEmpty) {
        _isPlaying = false;
        _notify();
        _pushSmtc();
        return;
      }
      final queries = <String>[];
      final titles = <String>[];
      final seen = <String>{_radioNorm('$_title - $_artist')};
      // 1. 同歌單其他歌（snapshot 快照，順序保留）。
      try {
        final snapFile = File(joinPath(
            ConfigService.instance.config.basePath, 'snapshot_cache.json'));
        if (await snapFile.exists()) {
          final snap =
              jsonDecode(await snapFile.readAsString()) as Map<String, dynamic>;
          final pls = (snap['playlists'] as Map?) ?? {};
          String? hitList;
          for (final e in pls.entries) {
            final tracks = ((e.value as Map?)?? {})['tracks'];
            if (tracks is! List) continue;
            var found = false;
            for (final t in tracks) {
              if (t is! String) continue;
              if (_radioSeedIn(t, seedTitle, seedArtist)) {
                found = true;
                break;
              }
            }
            if (found) {
              hitList = e.key as String?;
              for (final t in tracks) {
                if (t is! String) continue;
                final k = _radioNorm(t);
                if (seen.contains(k)) continue;
                if (_radioSeedIn(t, seedTitle, seedArtist)) continue;
                seen.add(k);
                queries.add(t);
                titles.add(t);
                if (queries.length >= 25) break;
              }
              break;
            }
          }
          if (hitList != null) {
            LogManager.instance
                .info('[radio] 同歌單接歌：$hitList（${queries.length} 首）');
          }
        }
      } catch (_) {}
      // 2. 同歌手本機檔案。
      if (queries.length < 25) {
        final artistNorm = _radioNorm(seedArtist);
        if (artistNorm.length >= 2) {
          await _ensureStemIndex();
          final same = <String>[];
          for (final e in _localStemIndex.entries) {
            if (seen.contains(e.key)) continue;
            if (e.key.contains(artistNorm)) {
              seen.add(e.key);
              same.add(e.value);
            }
          }
          same.shuffle(Random());
          for (final p in same) {
            if (queries.length >= 25) break;
            queries.add(p);
            titles.add(_titleFromPath(p));
          }
        }
      }
      // 3. 隨機本機補滿。
      if (queries.length < 25) {
        await _ensureStemIndex();
        final rest = _localStemIndex.entries
            .where((e) => !seen.contains(e.key))
            .map((e) => e.value)
            .toList();
        rest.shuffle(Random());
        for (final p in rest) {
          if (queries.length >= 25) break;
          queries.add(p);
          titles.add(_titleFromPath(p));
        }
      }
      if (queries.isEmpty) {
        _isPlaying = false;
        _notify();
        _pushSmtc();
        return;
      }
      if (!_isPlaying) return; // 組裝期間使用者已手動暫停/切歌 → 不劫持
      LogManager.instance.info(
          '[radio] 電台啟動：$seedTitle（${queries.length} 首）');
      setQueue(queries, titles: titles, startIndex: 0);
      jumpTo(0);
    } finally {
      _radioBusy = false;
    }
  }

  /// 電台種子比對：曲名與（有歌手時）首都出現在候選裡，不分順序。
  static bool _radioSeedIn(String candidate, String title, String artist) {
    final c = _radioNorm(candidate);
    final nt = _radioNorm(title);
    if (nt.length < 2 || !c.contains(nt)) return false;
    final na = _radioNorm(artist);
    if (na.isEmpty) return true;
    if (na.length < 2) return true;
    return c.contains(na);
  }

  static String _radioNorm(String s) => s.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fff\u3400-\u4dbf㐀-䶿豈-﫿]'), '');

  /// 單曲（無隊列）重播：completed/next/previous 共用，避免各處散落。
  /// ponytail: 未快取 pipe 串流回捲依賴 mpv 緩衝（串流快取預設開、可 seek）。
  void _replayCurrent() {
    _player.seek(Duration.zero);
    _player.play();
    _position = Duration.zero;
    _isPlaying = true;
    _notify();
    _pushSmtc();
  }

  void next() {
    if (jamFollowMode || _jamHostActive) {
      JamService.instance.next();
      return;
    }
    if (_queue.isEmpty) {
      // 空佇列（單曲直撥）→ 重播這首；沒標題才只同步 SMTC。
      if (_title.isNotEmpty) {
        _replayCurrent();
      } else {
        _pushSmtc();
      }
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
    if (jamFollowMode || _jamHostActive) {
      JamService.instance.previous();
      return;
    }
    if (_queue.isEmpty) {
      if (_title.isNotEmpty) _replayCurrent(); // 單曲 → 回到開頭
      return;
    }
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
    if (jamFollowMode || _jamHostActive) {
      // jam 中的本地 play/pause 都要廣播給房間，不能只動本機。
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
    _currentIsPodcast = false;
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

  bool get autoplay => _autoplay;
  void toggleAutoplay() { _autoplay = !_autoplay; _notify(); }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    await _player.setVolume(_volume * 100); // media_kit 0~100，見 init()
    ConfigService.instance.config.volume = _volume;
    // 拖拽中每個 tick 都寫 config.json 會把滑桿拖到卡：debounce 500ms。
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer =
        Timer(const Duration(milliseconds: 500), () => ConfigService.instance.save());
    _notify();
  }

  Future<void> seek(Duration pos) async {
    if (jamFollowMode || _jamHostActive) {
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
    _volumeSaveTimer?.cancel();
    if (_volumeSaveTimer != null) ConfigService.instance.save();
    _player.dispose();
  }
}
