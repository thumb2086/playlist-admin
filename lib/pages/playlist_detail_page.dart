import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/playlist_item.dart';
import '../services/player_controller.dart';
import '../services/config_service.dart';
import '../services/favorites_service.dart';
import '../services/youtube_service.dart';
import '../services/spotify_gql_client.dart';
import '../services/spotify_session.dart';
import '../services/cover_cache.dart';
import '../widgets/dark_theme.dart';
import '../services/podcast_service.dart';
import '../services/artwork_embedder.dart';

/// Unified detail page for music playlists AND podcast shows.
/// Supports per-track download with checkmarks for already-downloaded items.
class PlaylistDetailPage extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? coverUrl;
  final List<PlaylistItem> items;
  final bool isPodcast;
  final String? spotifyUrl;
  /// Podcast 節目的 RSS feed — 提供時 header 顯示「訂閱」鈕（未訂閱可就地訂閱）。
  final String? subscribeUrl;

  const PlaylistDetailPage({
    super.key,
    required this.title,
    this.subtitle,
    this.coverUrl,
    required this.items,
    this.isPodcast = false,
    this.spotifyUrl,
    this.subscribeUrl,
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  /// Track indices currently being downloaded.
  final Set<int> _downloading = {};
  /// Track indices that have been downloaded in this session.
  final Set<int> _downloaded = {};
  /// Download progress per track (0.0 - 1.0).
  final Map<int, double> _progress = {};
  /// Which tracks are already on disk (filled async after first frame).
  Set<int> _localTracks = {};
  Set<String> _favorites = {};
  bool _subscribed = false;
  // 封面/時長補齊用的可變副本（widget.items 是 final，enrichment 只加
  // coverUrl/durationMs/album，name/artist/audioQuery 絕不動 → 播放匹配不受影響）。
  late List<PlaylistItem> _items;
  String? _headerCover;
  int _coverGen = 0;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
    _loadFavorites();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scanLocalTracks();
      _enrichCovers();
    });
  }

  /// 頁面封面：補齊後的 header 封面 > 呼叫端給的 > null（佔位圖）。
  String? get _pageCover => _headerCover ?? widget.coverUrl;

  /// 封面快取 key：ISRC 優先，否則正規化「曲名 - 歌手」（共用 CoverCache）。
  static String _coverKey(String? isrc, String name, String artist) =>
      CoverCache.key(isrc, name, artist);

  static String _normName(String name, String artist) =>
      CoverCache.norm('$name - $artist');

  static String? _playlistIdFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    return RegExp(r'playlist[/:]([A-Za-z0-9]+)').firstMatch(url)?.group(1);
  }

  Future<Map<String, dynamic>> _loadCoverCache() => CoverCache.load();

  Future<void> _saveCoverCache(Map<String, dynamic> cache) =>
      CoverCache.save(cache);

  /// 背景補封面+時長：先套磁碟快取（秒開、離線可看），再一次 playlist
  /// fetch 補缺的（單次呼叫覆蓋整單，非逐曲打 API）。未登入/無 URL/
  /// 斷網 → 靜默維持佔位圖，不報錯不洗畫面。
  Future<void> _enrichCovers() async {
    final gen = ++_coverGen;
    if (_items.isEmpty || _items.every((e) => (e.coverUrl ?? '').isNotEmpty)) {
      return;
    }
    var url = widget.spotifyUrl;
    if (url == null || url.isEmpty) {
      try {
        url = ConfigService.instance.config.urlNames.entries
            .firstWhere((e) => e.value == widget.title)
            .key;
      } catch (_) {
        url = null;
      }
    }
    final id = _playlistIdFromUrl(url);
    if (id == null || id.isEmpty) return;
    if (!SpotifySession.instance.isLoggedIn) return;
    final cache = await _loadCoverCache();
    if (gen != _coverGen || !mounted) return;
    var changed = _applyCoverCache(cache);
    if (changed && mounted && gen == _coverGen) setState(() {});
    final missing =
        _items.where((e) => (e.coverUrl ?? '').isEmpty).length;
    if (missing == 0) return;
    final gql = SpotifyGqlClient();
    try {
      final all = <SpotifyTrackItem>[];
      var offset = 0;
      const step = 50;
      while (true) {
        final data = await gql.fetchPlaylist(id, offset: offset, limit: step);
        if (gen != _coverGen || !mounted) return;
        if (offset == 0) {
          final pc = SpotifyTrackItem.parsePlaylistCover(data);
          if (pc != null) {
            setState(() => _headerCover = pc);
          }
        }
        final tracks = SpotifyTrackItem.parsePlaylistTracks(data);
        if (tracks.isEmpty) break;
        all.addAll(tracks);
        if (tracks.length < step || all.length >= _items.length) break;
        offset += step;
      }
      if (gen != _coverGen || !mounted) return;
      if (_matchAndApply(all, cache)) {
        if (_headerCover == null) {
          final first = _items
              .map((e) => e.coverUrl)
              .firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);
          if (first != null) _headerCover = first;
        }
        await _saveCoverCache(cache);
        if (mounted && gen == _coverGen) setState(() {});
      }
      // 輪替掉的曲目（playlist fetch 沒有）→ 逐曲搜尋兜底。
      // 3 並行、可取消、結果寫透快取（一次成本，之後秒開）。
      // playlist 整單失敗也不影響：search 照跑（內層各自 try）。
      try {
        await _enrichMissingBySearch(gql, cache, gen);
      } catch (_) {}
      if (mounted && gen == _coverGen) setState(() {});
    } catch (_) {}
  }

  /// 逐曲搜尋補封面（playlist 輪替後不在名單內的曲目用）。
  Future<void> _enrichMissingBySearch(
      SpotifyGqlClient gql, Map<String, dynamic> cache, int gen) async {
    final missing = <int>[];
    for (int i = 0; i < _items.length; i++) {
      if ((_items[i].coverUrl ?? '').isEmpty) missing.add(i);
    }
    var saved = false;
    for (int k = 0; k < missing.length; k += 3) {
      if (gen != _coverGen || !mounted) return;
      final chunk = missing.sublist(k, (k + 3).clamp(0, missing.length));
      final results = await Future.wait(chunk.map((i) async {
        final it = _items[i];
        final q = '${it.name} ${it.artist}'.trim();
        if (q.isEmpty) return <SpotifyTrackItem>[];
        try {
          final data = await gql.searchTracks(q, limit: 5);
          return SpotifyTrackItem.parseSearchTracks(data);
        } catch (_) {
          return <SpotifyTrackItem>[];
        }
      }));
      if (gen != _coverGen || !mounted) return;
      var changed = false;
      for (int j = 0; j < chunk.length; j++) {
        if (results[j].isEmpty) continue;
        // 驗收：首個「曲名相符」的結果才收（防搜尋第一名是別的歌）。
        SpotifyTrackItem? pick;
        final want = _norm(_items[chunk[j]].name);
        for (final t in results[j]) {
          final nt = _norm(t.name);
          if (want.length >= 2 &&
              nt.length >= 2 &&
              (nt.contains(want) || want.contains(nt))) {
            pick = t;
            break;
          }
        }
        pick ??= results[j].first;
        if (_matchOne(chunk[j], [pick], {}, {}, cache)) changed = true;
      }
      if (changed) {
        await _saveCoverCache(cache);
        saved = true;
        if (mounted && gen == _coverGen) setState(() {});
      }
    }
    if (!saved) await _saveCoverCache(cache);
  }

  /// 套用磁碟快取。回傳是否有變動。
  bool _applyCoverCache(Map<String, dynamic> cache) {
    var changed = false;
    for (int i = 0; i < _items.length; i++) {
      final it = _items[i];
      if ((it.coverUrl ?? '').isNotEmpty && it.durationMs > 0) continue;
      final e = cache[_coverKey(it.isrc, it.name, it.artist)];
      if (e is Map) {
        _items[i] = PlaylistItem(
          name: it.name,
          artist: it.artist,
          durationMs:
              (e['d'] as num?)?.toInt() ?? it.durationMs,
          coverUrl: (e['c'] as String?) ?? it.coverUrl,
          audioQuery: it.audioQuery,
          audioUrl: it.audioUrl,
          isrc: it.isrc,
          album: (e['a'] as String?) ?? it.album,
        );
        changed = true;
      }
    }
    return changed;
  }

  /// Spotify 曲目配對到本機條目（只補 cover/duration/album）。
  /// 檔名「曲名 - 歌手」順序與 Spotify displayName 一致時走精確比對；
  /// Daily Mix 每日輪替、m3u8 快照是舊的，另有不分順序的 both-parts 兜底。
  /// 回傳是否有變動（同時寫透磁碟快取 map，呼叫端負責存檔）。
  bool _matchAndApply(
      List<SpotifyTrackItem> tracks, Map<String, dynamic> cache,
      {Set<int>? only}) {
    final byIsrc = <String, SpotifyTrackItem>{};
    final full = <String, SpotifyTrackItem>{};
    for (final t in tracks) {
      if ((t.isrc ?? '').isNotEmpty) {
        byIsrc[t.isrc!.toLowerCase()] = t;
      }
      final disp = _normName(t.name, t.artists.join(', '));
      full.putIfAbsent(disp, () => t);
      full.putIfAbsent(_normName(t.artists.join(', '), t.name), () => t);
    }
    var changed = false;
    for (int i = 0; i < _items.length; i++) {
      if (only != null && !only.contains(i)) continue;
      if (_matchOne(i, tracks, byIsrc, full, cache)) changed = true;
    }
    return changed;
  }

  /// 單條目配對（供 playlist 整批與逐曲搜尋共用）。
  bool _matchOne(int i, List<SpotifyTrackItem> tracks,
      Map<String, SpotifyTrackItem> byIsrc, Map<String, SpotifyTrackItem> full,
      Map<String, dynamic> cache) {
    final it = _items[i];
    final needCover = (it.coverUrl ?? '').isEmpty;
    final needDur = it.durationMs <= 0;
    if (!needCover && !needDur) return false;
    SpotifyTrackItem? hit;
    if ((it.isrc ?? '').isNotEmpty) {
      hit = byIsrc[it.isrc!.toLowerCase()];
    }
    final stem = _normName(it.name, it.artist);
    hit ??= full[stem];
    // both-parts（不分順序）：曲名與首位歌手同時出現在 stem 裡。
    if (hit == null) {
      for (final t in tracks) {
        final nt = _norm(t.name);
        final na = _norm(t.artists.isNotEmpty ? t.artists.first : '');
        if (nt.length >= 2 &&
            na.length >= 2 &&
            stem.contains(nt) &&
            stem.contains(na)) {
          hit = t;
          break;
        }
      }
    }
    // 曲名單獨出現（len>=3，避開單字誤配）。
    if (hit == null) {
      for (final t in tracks) {
        final nt = _norm(t.name);
        if (nt.length >= 3 && stem.contains(nt)) {
          hit = t;
          break;
        }
      }
    }
    if (hit == null) return false;
    _items[i] = PlaylistItem(
      name: it.name,
      artist: it.artist,
      durationMs:
          needDur && hit.durationMs > 0 ? hit.durationMs : it.durationMs,
      coverUrl: needCover ? hit.coverUrl : it.coverUrl,
      audioQuery: it.audioQuery,
      audioUrl: it.audioUrl,
      isrc: it.isrc,
      album: (it.album ?? '').isEmpty ? hit.album : it.album,
    );
    cache[_coverKey(it.isrc, it.name, it.artist)] = {
      'c': hit.coverUrl,
      'd': hit.durationMs,
      'a': hit.album,
    };
    return true;
  }

  static String _norm(String s) => CoverCache.norm(s);

  Future<void> _scanLocalTracks() async {
    final found = await _findLocalTracksAsync();
    if (mounted) setState(() => _localTracks = found);
  }

  Future<void> _loadFavorites() async {
    final favs = await FavoritesService.load();
    if (mounted) setState(() => _favorites = favs);
  }

  static String _favKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  bool _isFav(PlaylistItem item) {
    final key = _favKey('${item.name} - ${item.artist}');
    return _favorites.any((f) => _favKey(f) == key);
  }

  Future<void> _toggleFav(PlaylistItem item) async {
    final key = '${item.name} - ${item.artist}';
    final favs = await FavoritesService.load();
    final match = favs.firstWhere(
      (f) => _favKey(f) == _favKey(key),
      orElse: () => '',
    );
    if (match.isNotEmpty) {
      await FavoritesService.toggle(match);
    } else {
      await FavoritesService.toggle(key);
    }
    await _loadFavorites();
  }

  /// Check which tracks already exist in the local music library.
  /// 全 async：本來在 initState 同步掃目錄，且快取目錄被每首歌重列一次 O(N×M)。
  /// 現在兩個目錄各只列一次，之後全是記憶體比對。
  Future<Set<int>> _findLocalTracksAsync() async {
    final result = <int>{};
    if (_items.isEmpty) return result;
    final cfg = ConfigService.instance.config;
    final musicDir = Directory(cfg.musicPath);
    final localFiles = <String>{};
    if (await musicDir.exists()) {
      await for (final f in musicDir.list(recursive: true, followLinks: false)) {
        // 手機下載是 m4a/webm（無 ffmpeg 轉 mp3）：副檔名都要認，
        // 否則手機下的歌會被誤判「沒下載」一直重下。
        final low = f.path.toLowerCase();
        if (f is File &&
            (low.endsWith('.mp3') ||
                low.endsWith('.m4a') ||
                low.endsWith('.webm'))) {
          localFiles.add(f.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
        }
      }
    }
    // Stream cache: scan ONCE (was re-listed per track).
    final cacheNames = <String>[];
    final cacheDir = Directory(cfg.streamCachePath);
    if (await cacheDir.exists()) {
      await for (final f in cacheDir.list()) {
        if (f is File && f.path.endsWith('.mp3')) {
          try {
            if (await f.length() > 65536) {
              cacheNames.add(f.path.split(Platform.pathSeparator).last.toLowerCase());
            }
          } catch (_) {}
        }
      }
    }
    for (int i = 0; i < _items.length; i++) {
      final query = _items[i].audioQuery.toLowerCase();
      var hit = false;
      for (final local in localFiles) {
        if (local == query || local.contains(query) || query.contains(local)) {
          hit = true;
          break;
        }
      }
      if (!hit && query.isNotEmpty) {
        // 空 query 的 prefix 是 ''，contains('') 恆真會誤標：直接跳過。
        final prefix = query.substring(0, query.length.clamp(0, 20));
        if (prefix.isNotEmpty) {
          for (final name in cacheNames) {
            if (name.contains(prefix)) { hit = true; break; }
          }
        }
      }
      // 單集候選（有 audioUrl 或無 ISRC）→ podcasts\ 資料夾也算已下載。
      if (!hit) {
        final it = _items[i];
        final isEp = (it.audioUrl != null && it.audioUrl!.isNotEmpty) ||
            (it.isrc ?? '').isEmpty;
        if (isEp) {
          final shows = <String>{
            it.artist,
            PlayerController.instance.matchSubscribedShow(it.artist),
          };
          for (final s in shows) {
            if (s.isEmpty) continue;
            if (PodcastService.instance
                .isEpisodeDownloaded(it.name, it.audioUrl ?? '',
                    podcastName: s)) { hit = true; break; }
          }
        }
      }
      if (hit) result.add(i);
    }
    return result;
  }

  bool _isLocal(int index) => _localTracks.contains(index) || _downloaded.contains(index);
  bool _isDownloading(int index) => _downloading.contains(index);

  /// Register the Spotify playlist URL in config so Pipeline can scrape it.
  void _registerSpotifyUrl() {
    if (widget.spotifyUrl == null || widget.isPodcast) return;
    final cfg = ConfigService.instance.config;
    if (cfg.urlNames.containsKey(widget.spotifyUrl)) return;
    cfg.urlNames[widget.spotifyUrl!] = widget.title;
    ConfigService.instance.save();
  }

  Future<void> _downloadTrack(int index) async {
    if (_isLocal(index) || _isDownloading(index)) return;
    final item = _items[index];
    if (mounted) setState(() { _downloading.add(index); _progress[index] = 0; });
    try {
      // ── 單集判別：有 audioUrl，或無 ISRC（Spotify episode 沒有 isrc）→
      //    RSS 解析 → 下載到 podcasts\<節目>\（跟 podcast pipeline 同資料夾），
      //    絕不混進音樂庫（否則會被 _Unsorted 收進歌單）。
      final isEpisodeCandidate = (item.audioUrl != null && item.audioUrl!.isNotEmpty) ||
          ((item.isrc ?? '').isEmpty && item.audioUrl == null);
      PlaylistItem? ep;
      if (item.audioUrl != null && item.audioUrl!.isNotEmpty) {
        ep = item;
      } else if (isEpisodeCandidate) {
        ep = await PlayerController.instance
            .findEpisodeByTitle(item.name, showHint: item.artist);
      }
      if (ep != null) {
        final show = PlayerController.instance.matchSubscribedShow(ep.artist);
        debugPrint('[DL] $index episode -> podcasts\\$show');
        await PodcastService.instance.downloadEpisode(
          '',
          0,
          (p) { if (mounted) setState(() => _progress[index] = p * 0.95); },
          podcastName: show,
          knownTitle: ep.name,
          knownAudioUrl: ep.audioUrl,
        );
        final ok = PodcastService.instance
            .isEpisodeDownloaded(ep.name, ep.audioUrl ?? '', podcastName: show);
        if (ok) {
          if (mounted) {
            setState(() { _downloaded.add(index); _progress[index] = 1.0; });
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('單集下載失敗: ${ep.name}'),
              duration: const Duration(seconds: 2)));
        }
        return;
      }
      // ── 非單集（真歌）→ 原音樂下載路徑（進音樂庫，歌單 m3u8 會收錄）。
      final cfg = ConfigService.instance.config;
      final musicDir = Directory(cfg.musicPath);
      await musicDir.create(recursive: true);
      final finalName = '${item.name} - ${item.artist}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      // 同 stem 任一副檔名（mp3/m4a/webm）都算已下載：手機下的 m4a
      // 同步回電腦後，桌面不該再重下一份 mp3。
      final stemLower = finalName.toLowerCase();
      var haveLocal = File('${musicDir.path}\\$finalName.mp3').existsSync();
      if (!haveLocal) {
        try {
          await for (final f in musicDir.list(followLinks: false)) {
            if (f is! File) continue;
            final n = f.uri.pathSegments.last.toLowerCase();
            if ((n.endsWith('.m4a') || n.endsWith('.webm')) &&
                n.replaceAll(RegExp(r'\.\w+$'), '') == stemLower) {
              haveLocal = true;
              break;
            }
          }
        } catch (_) {}
      }
      final finalPath = '${musicDir.path}\\$finalName.mp3';
      if (haveLocal) {
        if (mounted) { _localTracks.add(index); setState(() { _downloaded.add(index); _progress[index] = 1.0; }); }
        return;
      }
      // Prefer artist+title for better YouTube matching, not ISRC.
      final searchQuery = '${item.artist} ${item.name}'.trim();
      // 手機獨立下載（Spotube 式）：無 yt-dlp/ffmpeg，直鏈存檔（m4a/webm）。
      // 桌面走下面 ffmpeg 轉 mp3＋內嵌封面那條（副檔名不同，兩邊不互蓋）。
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        debugPrint('[DL] $index mobile direct: query="$searchQuery"');
        await _downloadTrackMobile(index, item, musicDir, finalName);
        return;
      }
      debugPrint('[DL] $index start: query="$searchQuery" isrc=${item.isrc}');
      final streamResult = await YoutubeService.instance.resolveStream(searchQuery)
          .timeout(const Duration(seconds: 30), onTimeout: () {
        debugPrint('[DL] $index TIMEOUT resolving: $searchQuery');
        return null;
      });
      if (streamResult == null) {
        debugPrint('[DL] $index NOT FOUND: ${item.name}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('找不到: ${item.name}'), duration: const Duration(seconds: 2)));
        }
        return;
      }
      debugPrint('[DL] $index resolved: ${streamResult.title}');
      if (mounted) setState(() { _progress[index] = 0.3; });
      final tmpPath = '${musicDir.path}\\dl_${finalName.hashCode.toRadixString(16)}.mp3';
      final ffmpeg = cfg.resolvedFfmpegPath;
      debugPrint('[DL] $index ffmpeg: $ffmpeg');
      final proc = await Process.start(
        ffmpeg,
        ['-y', '-i', streamResult.audioUrl, '-vn', '-acodec', 'libmp3lame', '-q:a', '0', '-ac', '2', tmpPath],
        runInShell: false, // URL 含 &：不可經 cmd（分隔符會腰斬 ffmpeg 參數）
        );
      // stderr 也要排空，否則輸出大時 pipe 塞住 deadlock；
      // 先掛 exitCode timeout 再收 stderr，避免 ffmpeg 僵住時 join 永遠等不到。
      unawaited(proc.stdout.drain());
      final codeFuture = proc.exitCode.timeout(
        const Duration(seconds: 90), onTimeout: () { proc.kill(); return -1; },
      );
      final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      final code = await codeFuture;
      // Capture stderr for debugging.
      final stderrOutput = await stderrFuture.timeout(
        const Duration(seconds: 10), onTimeout: () => '');
      if (mounted) setState(() { _progress[index] = 0.5; });
      if (code == 0 && File(tmpPath).existsSync()) {
        if (File(finalPath).existsSync()) await File(finalPath).delete();
        await File(tmpPath).rename(finalPath);
        debugPrint('[DL] $index OK: $finalPath');
        // 內嵌封面（下載鏈本來就沒圖：YouTube 音源無圖 + ffmpeg -vn）。
        final art = await ArtworkEmbedder.instance.embedForFile(
          finalPath, title: item.name, artist: item.artist);
        debugPrint('[DL] $index artwork: $art');
        if (mounted) { _localTracks.add(index); setState(() { _downloaded.add(index); _progress[index] = 1.0; }); }
      } else {
        debugPrint('[DL] $index ffmpeg FAILED exit=$code stderr=$stderrOutput');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('下載失敗: ${item.name} (exit=$code)'), duration: const Duration(seconds: 3)));
        }
      }
    } catch (e) {
      debugPrint('[DL] error: $e');
    } finally {
      if (mounted) setState(() { _downloading.remove(index); });
    }
  }

  /// 手機獨立下載：resolveStreamDirect（純 Dart）→ downloadDirect 存檔。
  /// 不經 ffmpeg（手機沒有），副檔名跟直鏈容器（m4a/webm）；
  /// 封面不內嵌（ArtworkEmbedder 只吃 mp3），播放時走 CoverCache/網路圖。
  Future<void> _downloadTrackMobile(
      int index, PlaylistItem item, Directory musicDir, String finalName) async {
    final searchQuery = '${item.artist} ${item.name}'.trim();
    try {
      final r = await YoutubeService.instance
          .resolveStreamDirect(searchQuery)
          .timeout(const Duration(seconds: 60), onTimeout: () => null);
      if (r == null) {
        debugPrint('[DL] $index mobile NOT FOUND: ${item.name}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('找不到: ${item.name}'), duration: const Duration(seconds: 2)));
        }
        return;
      }
      if (mounted) setState(() => _progress[index] = 0.3);
      final saved = await YoutubeService.instance.downloadDirect(
        videoId: r.videoId,
        dir: musicDir.path,
        stem: finalName,
        onProgress: (p) {
          if (mounted) setState(() => _progress[index] = 0.3 + p * 0.7);
        },
      );
      if (saved.isNotEmpty) {
        debugPrint('[DL] $index mobile OK: $saved');
        if (mounted) {
          _localTracks.add(index);
          setState(() => _downloaded.add(index));
          _progress[index] = 1.0;
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('下載失敗: ${item.name}'), duration: const Duration(seconds: 3)));
      }
    } catch (e) {
      debugPrint('[DL] $index mobile error: $e');
    }
  }

  /// 整單下載開關：true 跑 serial，false 停在當前這首後。
  bool _downloadingAll = false;

  /// 已訂閱狀態：進頁面即判 config（不只依賴點過訂閱鈕的 flag）。
  bool get _alreadySubscribed =>
      _subscribed ||
      ConfigService.instance.config.podcastSubscriptions.containsKey(widget.title);

  /// 就地訂閱：寫入 config（跟 Download 頁同一份 podcastSubscriptions）。
  void _subscribe() {
    final url = widget.subscribeUrl;
    if (url == null || url.isEmpty) return;
    final cfg = ConfigService.instance.config;
    cfg.podcastSubscriptions[widget.title] = url;
    ConfigService.instance.save();
    if (mounted) setState(() => _subscribed = true);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已訂閱「${widget.title}」— Pipeline 也會抓它的新集數')));
  }

  Future<void> _downloadAll() async {
    // 跑一半再按一次 = 取消。
    if (_downloadingAll) { _downloadingAll = false; return; }
    _registerSpotifyUrl();
    final toDownload = <int>[];
    for (int i = 0; i < _items.length; i++) {
      if (!_isLocal(i) && !_isDownloading(i)) {
        toDownload.add(i);
      }
    }
    if (toDownload.isEmpty) return;
    if (mounted) setState(() => _downloadingAll = true);
    try {
      // Serial：跟音樂鏈路一致（YouTube 限流只能 serial），百首單可中途取消。
      for (final i in toDownload) {
        if (!_downloadingAll) break;
        if (!_isLocal(i)) await _downloadTrack(i);
      }
    } finally {
      _downloadingAll = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final localCount = _localTracks.length + _downloaded.length;
    final totalCount = _items.length;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context, localCount, totalCount)),
          SliverToBoxAdapter(child: _buildColumnHeader()),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _buildTrackRow(ctx, i),
              childCount: _items.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int localCount, int totalCount) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 140, height: 140,
              color: AppColors.surfaceLight,
              child: _pageCover != null
                  ? CachedNetworkImage(imageUrl: _pageCover!, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.surfaceLight),
                      errorWidget: (_, __, ___) => Icon(
                          widget.isPodcast ? Icons.podcasts_rounded : Icons.music_note_rounded,
                          color: AppColors.textMuted, size: 48))
                  : Icon(
                      widget.isPodcast ? Icons.podcasts_rounded : Icons.music_note_rounded,
                      color: AppColors.textMuted, size: 48),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.isPodcast ? 'Podcast 節目' : '歌單',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted.withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 4),
                Text(widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(widget.subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted.withValues(alpha: 0.8))),
                ],
                const SizedBox(height: 8),
                Text('$totalCount 首', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                const SizedBox(height: 12),
                Row(children: [
                  ElevatedButton.icon(
                    onPressed: () => _playAll(context, 0),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('播放全部'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _playAll(context, -1),
                    icon: const Icon(Icons.shuffle_rounded, size: 16),
                    label: const Text('隨機'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                  // Podcast 節目：可就地訂閱（不用回 Download 頁）。
                  if (widget.isPodcast && (widget.subscribeUrl?.isNotEmpty ?? false)) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _alreadySubscribed ? null : _subscribe,
                      icon: Icon(_alreadySubscribed ? Icons.check_rounded : Icons.add_rounded, size: 16),
                      label: Text(_alreadySubscribed ? '已訂閱' : '訂閱'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _alreadySubscribed ? AppColors.textMuted : AppColors.accent,
                        side: const BorderSide(color: AppColors.border),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  // 下載鈕不再排除 podcast：單集走 _downloadTrack 的 RSS 分支
                  // 進 podcasts\<節目>\（跟 pipeline 同資料夾）。
                  OutlinedButton.icon(
                    onPressed: _downloadAll,
                    icon: Icon(_downloadingAll ? Icons.stop_rounded : Icons.download_rounded, size: 16),
                    label: Text(_downloadingAll ? '取消下載' : (localCount > 0 ? '下載 ($localCount/$totalCount)' : '下載全部')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColumnHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(children: [
        const SizedBox(width: 32, child: Text('#', style: TextStyle(fontSize: 11, color: AppColors.textMuted))),
        const SizedBox(width: 48),
        const Expanded(flex: 5, child: Text('標題', style: TextStyle(fontSize: 11, color: AppColors.textMuted))),
        if (!widget.isPodcast)
          const Expanded(flex: 3, child: Text('專輯', style: TextStyle(fontSize: 11, color: AppColors.textMuted))),
        const SizedBox(width: 50, child: Text('時長', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: AppColors.textMuted))),
        const SizedBox(width: 32),
        const SizedBox(width: 32),
      ]),
    );
  }

  Widget _buildTrackRow(BuildContext context, int index) {
    final item = _items[index];
    final isLocal = _isLocal(index);
    final isDownloading = _isDownloading(index);
    // Cover thumbnail：音樂列沒配對到就放佔位圖，不可拿歌單封面充數
    //（之前全列共用第一首的圖，看起來像一堆錯誤縮圖）。
    // Podcast 單集沒圖才退回節目封面。
    final rowCover =
        item.coverUrl ?? (widget.isPodcast ? _pageCover : null);

    return InkWell(
      onTap: isDownloading ? null : () => _playTrack(context, index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        child: Row(children: [
          // Number / play icon
          SizedBox(
            width: 32,
            child: isDownloading
                ? const Icon(Icons.downloading_rounded, size: 16, color: AppColors.accent)
                : Text('${index + 1}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ),
          // Cover thumbnail (rowCover computed above).
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              width: 40, height: 40,
              color: AppColors.surfaceLight,
              child: rowCover != null
                  ? CachedNetworkImage(imageUrl: rowCover, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.surfaceLight),
                      errorWidget: (_, __, ___) => const Icon(Icons.music_note_rounded, size: 16, color: AppColors.textMuted))
                  : const Icon(Icons.music_note_rounded, size: 16, color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 12),
          // Title + Artist
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                        color: isLocal ? AppColors.accent : AppColors.text)),
                if (item.artist.isNotEmpty)
                  Text(item.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
          // Album (music only)
          if (!widget.isPodcast)
            const Expanded(flex: 3, child: SizedBox()),
          // Duration
          SizedBox(
            width: 50,
            child: Text(item.durationText, textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted, fontFamily: 'Consolas')),
          ),
          // Favorite star
          SizedBox(
            width: 32,
            child: IconButton(
              icon: Icon(
                _isFav(item) ? Icons.star_rounded : Icons.star_border_rounded,
                size: 18,
                color: _isFav(item) ? AppColors.accent : AppColors.textMuted,
              ),
              onPressed: () => _toggleFav(item),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32),
            ),
          ),
          // Download / play button
          if (!widget.isPodcast)
            SizedBox(
              width: 32,
              child: isLocal
                  ? const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.accent)
                  : isDownloading
                      ? const SizedBox(width: 18, height: 18)
                      : IconButton(
                          icon: const Icon(Icons.download_rounded, size: 18, color: AppColors.textMuted),
                          onPressed: () => _downloadTrack(index),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32),
                        ),
            )
          else
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded, size: 18, color: AppColors.textMuted),
              onPressed: () => _playTrack(context, index),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32),
            ),
        ]),
      ),
    );
  }

  void _playAll(BuildContext context, int startIndex) {
    final ctrl = PlayerController.instance;
    final queries = _items.map((i) => i.audioQuery).toList();
    final titles = _items.map((i) => i.name).toList();
    ctrl.setQueue(queries, titles: titles, startIndex: startIndex < 0 ? 0 : startIndex, items: _items);
    final first = _items[startIndex < 0 ? 0 : startIndex];
    ctrl.playItem(first);
  }

  void _playTrack(BuildContext context, int index) {
    final ctrl = PlayerController.instance;
    final queries = _items.map((i) => i.audioQuery).toList();
    final titles = _items.map((i) => i.name).toList();
    ctrl.setQueue(queries, titles: titles, startIndex: index, items: _items);
    ctrl.playItem(_items[index]);
  }
}
