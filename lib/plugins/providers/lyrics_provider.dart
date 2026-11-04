import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../services/lyrics_service.dart';

abstract class LyricsProvider {
  String get id;
  String get displayName;
  bool get enabled;
  int get priority;
  Future<LyricsResult?> fetch(String artist, String track,
      {String? album, int? durationSec});
}

class LrclibLyricsProvider implements LyricsProvider {
  LrclibLyricsProvider({this.priority = 10});

  @override
  String get id => 'lrclib';

  @override
  String get displayName => 'LRCLib.net';

  @override
  bool get enabled => true;

  @override
  final int priority;

  static const int _maxAttempts = 3;

  @override
  Future<LyricsResult?> fetch(String artist, String track,
      {String? album, int? durationSec}) async {
    for (int attempt = 0; attempt <= _maxAttempts; attempt++) {
      try {
        final params = {
          'artist_name': artist,
          'track_name': track,
        };
        if (album != null && album.isNotEmpty) params['album_name'] = album;
        if (durationSec != null && durationSec > 0) params['duration'] = '$durationSec';

        final uri = Uri.https('lrclib.net', '/api/get', params);
        final resp = await http.get(uri).timeout(const Duration(seconds: 15));

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          return LyricsResult(
            artist: data['artistName'] as String? ?? artist,
            track: data['trackName'] as String? ?? track,
            album: data['albumName'] as String? ?? album ?? '',
            syncedLyrics: data['syncedLyrics'] as String?,
            plainLyrics: data['plainLyrics'] as String?,
            durationSec: data['duration'] as int? ?? durationSec ?? 0,
          );
        } else if (resp.statusCode == 503) {
          if (attempt < _maxAttempts) {
            await Future.delayed(Duration(seconds: 2 * (1 << attempt)));
            continue;
          }
          return null;
        } else {
          return null;
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
