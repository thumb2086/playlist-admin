import 'dart:convert';
import 'package:http/http.dart' as http;
import 'i18n.dart';
import 'spotify_session.dart';

/// Spotify internal GraphQL client (APQ persisted queries against
/// api-partner.spotify.com/pathfinder/v2/query), mirroring the
/// spotube-plugin-spotify implementation. Metadata + library only —
/// audio streaming is handled separately via yt-dlp.
class SpotifyGqlClient {
  static const _endpoint = 'https://api-partner.spotify.com/pathfinder/v2/query';

/// 依 app 語言設定決定 Spotify 回傳的 artist/專輯名語言。
  /// 不帶這個的話 Spotify 永遠回英文（搜「晴天 周杰倫」得到 artist=Jay Chou），
  /// 導致全庫 artist 名要靠映射表兜，且顯示與設定頁語言不一致。
  /// 語言來源：設定頁「語言」（I18N.currentLang，預設 zh-TW）。
  static String _locale() {
    var lang = 'zh-TW';
    try {
      lang = I18N.instance.currentLang;
    } catch (_) {}
    switch (lang) {
      case 'en':
        return 'en';
      case 'zh-CN':
        return 'zh-CN';
      case 'ja':
        return 'ja';
      case 'ko':
        return 'ko';
      default:
        return 'zh-TW';
    }
  }

  /// 語言請求標頭（兩個都要帶：Accept-Language 給通用、Spotify 專用頭給 GQL）。
  static Map<String, String> _langHeaders() {
    final l = _locale();
    return {
      'Accept-Language': '$l,${l.split('-').first};q=0.9,en;q=0.5',
      'X-Spotify-Language': l,
    };
  }

  static const _searchDesktop = 'd9f785900f0710b31c07818d617f4f7600c1e21217e80f5b043d1e78d74e6026';
  static const _fetchPlaylist = 'cd2275433b29f7316176e7b5b5e098ae7744724e1a52d63549c76636b3257749';
  static const _home = '3357ffed7961629ba92b4e0a41514e4d5004a14355c964c23ce442205c9e44a1';
  static const _whatsNew = '3b53dede3c6054e8b7c962dd280eb6761c5d1c82b06b039f4110d76a62b4966b';
  static const _browseAll = 'dbd8b55e09a58afc52eab438bc228ba28fd72ac2f2148c6c26354980e4579001';
  static const _libraryV3 = '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455';
  static const _getTrack = '612585ae06ba435ad26369870deaae23b5c8800a256cd8a57e08eddc25a37294';

  static const _userAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:147.0) Gecko/20100101 Firefox/147.0',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0',
  ];

  String _ua() => _userAgents[DateTime.now().millisecondsSinceEpoch % _userAgents.length];

  /// Search all content types in one call (tracks/albums/artists/playlists/users).
  Future<Map<String, dynamic>> search(String query, {int limit = 10}) async {
    return _query(_searchDesktop, 'searchDesktop', {
      'searchTerm': query,
      'offset': 0,
      'limit': limit,
      'numberOfTopResults': 5,
      'includeAudiobooks': true,
      'includeArtistHasConcertsField': false,
      'includePreReleases': true,
      'includeLocalConcertsField': false,
      'includeAuthors': false,
    });
  }

  /// Search tracks only (more results).
  /// 注意：persisted doc 裡的操作名只有 searchDesktop（曾用錯名 searchTracks，
  /// 伺服器回 GRAPHQL_UNKNOWN_OPERATION_NAME 400，整個站內搜尋是死的）。
  Future<Map<String, dynamic>> searchTracks(String query, {int limit = 20}) async {
    return _query(_searchDesktop, 'searchDesktop', {
      'searchTerm': query,
      'offset': 0,
      'limit': limit,
      'includePreReleases': false,
      'numberOfTopResults': 20,
      'includeAudiobooks': true,
      'includeAuthors': false,
    });
  }

  Future<Map<String, dynamic>> fetchPlaylist(String id, {int offset = 0, int limit = 50}) async {
    return _query(_fetchPlaylist, 'fetchPlaylist', {
      'uri': 'spotify:playlist:$id',
      'offset': offset,
      'limit': limit,
      'enableWatchFeedEntrypoint': true,
    });
  }

  /// Personalized home feed. Requires the sp_t cookie.
  Future<Map<String, dynamic>> home({int sectionItemsLimit = 30}) async {
    return _query(_home, 'home', {
      'timeZone': DateTime.now().timeZoneName,
      'sp_t': SpotifySession.instance.spT ?? '',
      'facet': '',
      'sectionItemsLimit': sectionItemsLimit,
    });
  }

  /// New releases feed.
  Future<Map<String, dynamic>> whatsNew({int limit = 20}) async {
    return _query(_whatsNew, 'queryWhatsNewFeed', {
      'offset': 0,
      'limit': limit,
      'onlyUnPlayedItems': false,
      'includedContentTypes': ['ALBUM', 'SINGLE', 'EP'],
    });
  }

  /// Browse hub / categories start page.
  Future<Map<String, dynamic>> browseAll() async {
    return _query(_browseAll, 'browseAll', {
      'pagePagination': {'offset': 0, 'limit': 50},
      'sectionPagination': {'offset': 0, 'limit': 50},
      'browseEndUserIntegration': 'INTEGRATION_WEB_PLAYER',
    });
  }

  /// Current user's playlists / saved library.
  /// 注意：不可傳 order — 'AUDIO_ITEM_CREATED_AT_DESC' 已被 Spotify 宣判非法
  /// （LibraryInvalidSortOrderIdError，2026-09 實測），省略 order 即用預設序。
  Future<Map<String, dynamic>> libraryPlaylists({int offset = 0, int limit = 50}) async {
    return _query(_libraryV3, 'libraryV3', {
      'filters': ['Playlists'],
      'textFilter': '',
      'features': [],
      'limit': limit,
      'offset': offset,
      'flatten': true,
      'expandedFolders': [],
      'includeFoldersWhenFlattening': true,
    });
  }

  Future<Map<String, dynamic>> libraryAlbums({int offset = 0, int limit = 50}) async {
    return _query(_libraryV3, 'libraryV3', {
      'filters': ['Albums'],
      'textFilter': '',
      'features': [],
      'limit': limit,
      'offset': offset,
      'flatten': true,
      'expandedFolders': [],
      'includeFoldersWhenFlattening': true,
    });
  }

  /// Liked songs (Spotify's "Liked Songs" playlist).
  Future<Map<String, dynamic>> likedSongs({int offset = 0, int limit = 50}) async {
    return _query(_fetchPlaylist, 'fetchPlaylist', {
      'uri': 'spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ',
      'offset': offset,
      'limit': limit,
      'enableWatchFeedEntrypoint': true,
    });
  }

  Future<Map<String, dynamic>> getTrack(String id) async {
    return _query(_getTrack, 'getTrack', {'uri': 'spotify:track:$id'});
  }

  Future<Map<String, dynamic>> _query(
      String hash, String operationName, Map<String, dynamic> variables) async {
    final session = SpotifySession.instance;
    final token = session.accessToken;
    if (token == null || token.isEmpty) {
      throw Exception('Spotify 尚未登入或 token 已過期');
    }
    final resp = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'Cookie': 'sp_dc=${session.spDc ?? ''}; sp_t=${session.spT ?? ''}',
        'User-Agent': _ua(),
        ..._langHeaders(),
      },
      body: jsonEncode({
        'variables': variables,
        'operationName': operationName,
        'extensions': {
          'persistedQuery': {'version': 1, 'sha256Hash': hash},
        },
      }),
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode == 401) {
      await session.refreshToken();
      final retry = session.accessToken;
      if (retry != null) {
        return _queryWithToken(hash, operationName, variables, retry);
      }
    }
    if (resp.statusCode >= 400) {
      final body = resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body;
      print('[GQL] ERR ${resp.statusCode} op=$operationName body=$body');
      throw Exception('Spotify GQL ${resp.statusCode}: $body');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _queryWithToken(
      String hash, String operationName, Map<String, dynamic> variables, String token) async {
    final session = SpotifySession.instance;
    final resp = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'Cookie': 'sp_dc=${session.spDc ?? ''}; sp_t=${session.spT ?? ''}',
        'User-Agent': _ua(),
        ..._langHeaders(),
      },
      body: jsonEncode({
        'variables': variables,
        'operationName': operationName,
        'extensions': {
          'persistedQuery': {'version': 1, 'sha256Hash': hash},
        },
      }),
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode >= 400) {
      throw Exception('Spotify GQL retry ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}

/// Helpers to extract track-like items from GQL responses.
class SpotifyTrackItem {
  final String uri;
  final String name;
  final List<String> artists;
  final String album;
  final int durationMs;
  final String? coverUrl;
  final String? isrc;
  /// 專輯發行年份（4 位數字）：albumOfTrack.date 的前 4 碼。
  /// 以前 parser 沒讀這個欄位 → 全庫 album/date 幾乎是空（enricher 拿不到就
  /// 寫空 date，ffprobe 讀回 1970）。Spotify 每張專輯都有 date，不是資料源缺。
  final String? year;

  SpotifyTrackItem({
    required this.uri,
    required this.name,
    required this.artists,
    required this.album,
    required this.durationMs,
    this.coverUrl,
    this.isrc,
    this.year,
  });

  String get id => uri.split(':').last;
  String get title => name;

  /// Display "Title - Artist" (matches library file naming).
  /// artists 空時不可輸出尾巴「 - 」：會污染串流 query → YouTube 搜尋失敗 404。
  String get displayName {
    final a = artists.where((s) => s.trim().isNotEmpty).join(', ');
    return a.isEmpty ? name : '$name - $a';
  }

  static String? coverFromSources(dynamic sources) {
    if (sources is! List || sources.isEmpty) return null;
    final s = sources.cast<Map<String, dynamic>>().last;
    return s['url'] as String?;
  }

  /// 三種 artists 形狀都要吃：裸 List（舊搜尋）、{items:[...]}（新搜尋/
  /// 歌單）、{profile:{name}} 單體。回傳歌手名清單。
  static List<String> parseArtists(dynamic artistsRaw) {
    if (artistsRaw is List) {
      return artistsRaw
          .map((a) => (a is Map ? ((a['profile'] as Map?)?['name'] ?? '') : '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (artistsRaw is Map) {
      final nested = artistsRaw['items'];
      if (nested is List) return parseArtists(nested);
      final single = (artistsRaw['profile'] as Map?)?['name'];
      if (single is String && single.isNotEmpty) return [single];
    }
    return [];
  }

  /// 曲目本體：新回應包在 item.data 下，舊（若有）直接是 item。
  static Map<String, dynamic> trackData(Map<String, dynamic> item) {
    final inner = item['data'];
    if (inner is Map<String, dynamic>) return inner;
    return item;
  }

  /// 時長毫秒：新 key 是 duration，舊是 trackDuration，兩邊都讀。
  static int trackDurationMs(Map<String, dynamic> track) {
    for (final key in const ['trackDuration', 'duration']) {
      final m = track[key];
      if (m is Map) {
        final v = (m['totalMilliseconds'] as num?)?.toInt();
        if (v != null && v > 0) return v;
      }
    }
    return 0;
  }

  /// 專輯年份。實測 Spotify 回應有三種形狀，全要吃：
  /// ① {date: {isoString: "2003-07-29T00:00:00Z", precision: DAY, year: 2003}}
  ///    —— getTrack 查詢才有（searchTracks/fetchPlaylist 不回）
  /// ② {date: "2011-07-08"} 或 {releaseDate: "1999-12-31"}
  /// ③ {date: 1433116800000}（毫秒時間戳；秒級太小不是年份，不可誤判）
  /// 只認 1000~2999 的 4 位數。
  static String? albumYear(Map<String, dynamic>? album) {
    if (album == null) return null;

    String? valid(Object? y) {
      final n = y is num ? y.toInt() : int.tryParse('${y ?? ''}');
      if (n == null || n < 1000 || n > 2999) return null;
      return '$n';
    }

    for (final key in const ['date', 'releaseDate', 'release_date']) {
      final v = album[key];
      if (v == null) continue;
      // ① 巢狀 {year, isoString, precision}
      if (v is Map) {
        final hit = valid(v['year']);
        if (hit != null) return hit;
        final iso = v['isoString'] ?? v['fullDate'];
        if (iso is String) {
          final m = RegExp(r'(1\d{3}|2\d{3})').firstMatch(iso);
          if (m != null) return m.group(1);
        }
        continue;
      }
      // ② 字串 / ③ 數字
      if (v is String) {
        final m = RegExp(r'(1\d{3}|2\d{3})').firstMatch(v);
        if (m != null) return m.group(1);
      } else if (v is num) {
        final ms = v.toInt();
        if (ms >= 946684800000 && ms < 4102444800000) {
          final hit = valid(DateTime.fromMillisecondsSinceEpoch(ms).year);
          if (hit != null) return hit;
        }
      }
    }
    return null;
  }

  /// 從 getTrack 回應取「主曲目所屬專輯」的年份。
  ///
  /// 為什麼不能用深層 DFS：getTrack 回應有 60KB+，內含推薦/「更多來自」等
  /// 其他專輯物件，深層掃描會抓到別張專輯的日期（實測把 BTS 的歌標成
  /// ARIRANG/2026）。改成 BFS（逐層掃、先到者為主曲目）＋專輯名比對。
  static String? yearFromResponse(Map<String, dynamic> resp,
      {String? expectAlbumName}) {
    // BFS：層級由淺到深，第一個帶年份的 albumOfTrack 就是主曲目。
    var queue = <dynamic>[resp];
    Map<String, dynamic>? found;
    var depth = 0;
    while (queue.isNotEmpty && found == null && depth < 8) {
      final next = <dynamic>[];
      for (final node in queue) {
        if (node is Map) {
          final a = node['albumOfTrack'];
          if (a is Map) {
            final am = a.cast<String, dynamic>();
            if (albumYear(am) != null) {
              found = am;
              break;
            }
          }
          next.addAll(node.values);
        } else if (node is List) {
          next.addAll(node);
        }
      }
      queue = next;
      depth++;
    }
    if (found == null) return null;
    // 專輯名對不上 → 多半抓到別的專輯，寧可不要。
    if (expectAlbumName != null && expectAlbumName.trim().isNotEmpty) {
      final got = (found['name'] ?? '').toString();
      if (got.trim() != expectAlbumName.trim()) return null;
    }
    return albumYear(found);
  }

  /// 從 fetchPlaylist 回應解析曲目（含封面/時長/ISRC）。
  /// 原本散在 home_page._extractPlaylistTracks，收攏至此避免分叉。
  static List<SpotifyTrackItem> parsePlaylistTracks(Map<String, dynamic> data) {
    final out = <SpotifyTrackItem>[];
    try {
      final playlist =
          (data['data'] as Map?)?['playlistV2'] as Map<String, dynamic>?;
      final content = playlist?['content'] as Map<String, dynamic>?;
      final items = content?['items'] as List<dynamic>? ?? [];
      for (final it in items) {
        final wrapper = (it as Map<String, dynamic>)['itemV2'] as Map<String, dynamic>?;
        if (wrapper == null) continue;
        // Track data is nested inside itemV2.data (not itemV2 directly).
        final item = wrapper['data'] as Map<String, dynamic>? ?? wrapper;
        final name = (item['name'] ?? '') as String? ?? '';
        final uri = (item['uri'] ?? '') as String? ?? '';
        if (name.isEmpty && uri.isEmpty) continue;
        // Track has albumOfTrack; episode has coverArt directly.
        final album = item['albumOfTrack'] as Map<String, dynamic>?;
        final coverArt = item['coverArt'] as Map<String, dynamic>?;
        String? cover;
        if (album != null) {
          cover = SpotifyTrackItem.coverFromSources(album['coverArt']?['sources']);
        } else if (coverArt != null) {
          cover = SpotifyTrackItem.coverFromSources(coverArt['sources']);
        }
        final artists = SpotifyTrackItem.parseArtists(item['artists']);
        final duration = SpotifyTrackItem.trackDurationMs(item);
        final albumName = (album?['name'] as String?) ?? '';
        // ISRC：persisted doc 若有回傳就吃，沒有則 null（呼叫端照舊用 t: key）。
        final isrc = (item['isrc'] as String?)?.trim();
        if (name.isNotEmpty) {
          out.add(SpotifyTrackItem(
            uri: uri, name: name, artists: artists,
            album: albumName, durationMs: duration, coverUrl: cover,
            isrc: (isrc != null && isrc.isNotEmpty) ? isrc : null,
            year: SpotifyTrackItem.albumYear(album),
          ));
        }
      }
    } catch (_) {}
    return out;
  }

  /// 從 searchTracks 回應解析曲目（欄位形狀與 fetchPlaylist 不同：
  /// artists 是裸 List，item 包在 item key 下）。與 search_page._parseTracks 同規則。
  static List<SpotifyTrackItem> parseSearchTracks(Map<String, dynamic> data) {
    final out = <SpotifyTrackItem>[];
    try {
      final search =
          (data['data'] as Map?)?['searchV2'] as Map<String, dynamic>?;
      final tracks = search?['tracksV2'] as Map<String, dynamic>?;
      final items = tracks?['items'] as List<dynamic>? ?? [];
      for (final it in items) {
        final raw =
            (it as Map<String, dynamic>)['item'] as Map<String, dynamic>?;
        if (raw == null) continue;
        final track = SpotifyTrackItem.trackData(raw);
        final album = track['albumOfTrack'] as Map<String, dynamic>?;
        final name = (track['name'] ?? '') as String? ?? '';
        if (name.isEmpty) continue;
        final uri = (track['uri'] ?? '') as String? ?? '';
        final artists = SpotifyTrackItem.parseArtists(track['artists']);
        final duration = SpotifyTrackItem.trackDurationMs(track);
        final cover = album != null
            ? SpotifyTrackItem.coverFromSources(album['coverArt']?['sources'])
            : null;
        final isrc = (track['isrc'] as String?)?.trim();
        out.add(SpotifyTrackItem(
          uri: uri,
          name: name,
          artists: artists,
          album: (album?['name'] as String?) ?? '',
          durationMs: duration,
          coverUrl: cover,
          isrc: (isrc != null && isrc.isNotEmpty) ? isrc : null,
          year: SpotifyTrackItem.albumYear(album),
        ));
      }
    } catch (_) {}
    return out;
  }

  /// 歌單封面（playlistV2.images.items[0]，與 home _extractCover 同規則）。
  /// 抓不到回 null（呼叫端用首曲封面兜底）。
  static String? parsePlaylistCover(Map<String, dynamic> data) {
    try {
      final playlist =
          (data['data'] as Map?)?['playlistV2'] as Map<String, dynamic>?;
      final imgs = playlist?['images'] as Map<String, dynamic>?;
      final items = imgs?['items'] as List<dynamic>?;
      if (items != null && items.isNotEmpty) {
        final src =
            (items[0] as Map<String, dynamic>)['sources'] as List<dynamic>?;
        return SpotifyTrackItem.coverFromSources(src);
      }
    } catch (_) {}
    return null;
  }
}