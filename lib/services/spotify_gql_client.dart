import 'dart:convert';
import 'package:http/http.dart' as http;
import 'spotify_session.dart';

/// Spotify internal GraphQL client (APQ persisted queries against
/// api-partner.spotify.com/pathfinder/v2/query), mirroring the
/// spotube-plugin-spotify implementation. Metadata + library only —
/// audio streaming is handled separately via yt-dlp.
class SpotifyGqlClient {
  static const _endpoint = 'https://api-partner.spotify.com/pathfinder/v2/query';

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
  Future<Map<String, dynamic>> searchTracks(String query, {int limit = 20}) async {
    return _query(_searchDesktop, 'searchTracks', {
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
  Future<Map<String, dynamic>> libraryPlaylists({int offset = 0, int limit = 50}) async {
    return _query(_libraryV3, 'libraryV3', {
      'filters': ['Playlists'],
      'order': 'AUDIO_ITEM_CREATED_AT_DESC',
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
      'order': 'AUDIO_ITEM_CREATED_AT_DESC',
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

  SpotifyTrackItem({
    required this.uri,
    required this.name,
    required this.artists,
    required this.album,
    required this.durationMs,
    this.coverUrl,
    this.isrc,
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
}