import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'spotify_oauth_service.dart';
import 'config_service.dart';

class SpotifyLibraryService {
  SpotifyLibraryService._();
  static final instance = SpotifyLibraryService._();

  String _dir() => '${ConfigService.instance.config.cachePath}\\spotify_library';

  File _file(String name) {
    final d = Directory(_dir());
    if (!d.existsSync()) d.createSync(recursive: true);
    return File('${_dir()}\\$name.json');
  }

  Future<String?> _token() => SpotifyOAuthService.instance.accessToken();

  Future<Map<String, dynamic>?> _authedGet(Uri uri) async {
    final t = await _token();
    if (t == null || t.isEmpty) return null;
    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $t',
      'Accept': 'application/json',
      'User-Agent': 'playlist-admin/2.0',
    }).timeout(const Duration(seconds: 20));
    if (resp.statusCode == 401) {
      await SpotifyOAuthService.instance.accessToken();
      return _authedGet(uri);
    }
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<T?> _cachedOrFetch<T>(
      String cacheName, Future<T?> Function() fetch, Duration ttl) async {
    final f = _file(cacheName);
    try {
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final fetchedAt = (data['fetchedAt'] as num?)?.toInt() ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - fetchedAt < ttl.inMilliseconds) {
          return data['payload'] as T?;
        }
      }
    } catch (_) {}
    final payload = await fetch();
    if (payload != null) {
      f.writeAsStringSync(jsonEncode({'fetchedAt': DateTime.now().millisecondsSinceEpoch, 'payload': payload}));
    }
    return payload;
  }

  // ---------- Playlists ----------
  Future<List<Map<String, dynamic>>> fetchPlaylists({bool force = false}) async {
    final ttl = force ? Duration.zero : const Duration(minutes: 30);
    final v = await _cachedOrFetch<List<Map<String, dynamic>>>(
      'playlists',
      () async {
        final out = <Map<String, dynamic>>[];
        String? url = 'https://api.spotify.com/v1/me/playlists?limit=50';
        while (url != null && url.isNotEmpty) {
          final data = await _authedGet(Uri.parse(url));
          if (data == null) break;
          for (final it in (data['items'] as List? ?? const [])) {
            if (it is Map<String, dynamic>) out.add(it);
          }
          final next = data['next'];
          url = next is String && next.isNotEmpty ? next : null;
        }
        return out;
      },
      ttl,
    );
    return v ?? <Map<String, dynamic>>[];
  }

  // ---------- Saved tracks (Liked Songs) ----------
  Future<List<Map<String, dynamic>>> fetchSavedTracks({bool force = false, int max = 2000}) async {
    final ttl = force ? Duration.zero : const Duration(minutes: 30);
    final v = await _cachedOrFetch<List<Map<String, dynamic>>>(
      'saved_tracks',
      () async {
        final out = <Map<String, dynamic>>[];
        String? url = 'https://api.spotify.com/v1/me/tracks?limit=50';
        while (url != null && url.isNotEmpty && out.length < max) {
          final data = await _authedGet(Uri.parse(url));
          if (data == null) break;
          for (final it in (data['items'] as List? ?? const [])) {
            if (it is Map<String, dynamic>) out.add(it);
          }
          final next = data['next'];
          url = next is String && next.isNotEmpty ? next : null;
        }
        return out;
      },
      ttl,
    );
    return v ?? <Map<String, dynamic>>[];
  }

  // ---------- Saved albums ----------
  Future<List<Map<String, dynamic>>> fetchSavedAlbums({bool force = false}) async {
    final ttl = force ? Duration.zero : const Duration(minutes: 30);
    final v = await _cachedOrFetch<List<Map<String, dynamic>>>(
      'saved_albums',
      () async {
        final out = <Map<String, dynamic>>[];
        String? url = 'https://api.spotify.com/v1/me/albums?limit=50';
        while (url != null && url.isNotEmpty) {
          final data = await _authedGet(Uri.parse(url));
          if (data == null) break;
          for (final it in (data['items'] as List? ?? const [])) {
            if (it is Map<String, dynamic>) out.add(it);
          }
          final next = data['next'];
          url = next is String && next.isNotEmpty ? next : null;
        }
        return out;
      },
      ttl,
    );
    return v ?? <Map<String, dynamic>>[];
  }

  // ---------- Saved shows (podcasts) ----------
  Future<List<Map<String, dynamic>>> fetchSavedShows({bool force = false}) async {
    final ttl = force ? Duration.zero : const Duration(minutes: 30);
    final v = await _cachedOrFetch<List<Map<String, dynamic>>>(
      'saved_shows',
      () async {
        final out = <Map<String, dynamic>>[];
        String? url = 'https://api.spotify.com/v1/me/shows?limit=50';
        while (url != null && url.isNotEmpty) {
          final data = await _authedGet(Uri.parse(url));
          if (data == null) break;
          for (final it in (data['items'] as List? ?? const [])) {
            if (it is Map<String, dynamic>) out.add(it);
          }
          final next = data['next'];
          url = next is String && next.isNotEmpty ? next : null;
        }
        return out;
      },
      ttl,
    );
    return v ?? <Map<String, dynamic>>[];
  }

  /// True if OAuth token exists (logged in).
  Future<bool> isAuthenticated() async {
    final t = await SpotifyOAuthService.instance.accessToken();
    return t != null && t.isNotEmpty;
  }

  void invalidateCache() {
    for (final name in ['playlists', 'saved_tracks', 'saved_albums', 'saved_shows']) {
      final f = _file(name);
      if (f.existsSync()) {
        try { f.deleteSync(); } catch (_) {}
      }
    }
  }
}
