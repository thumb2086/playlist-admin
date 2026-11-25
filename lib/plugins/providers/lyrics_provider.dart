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

  /// 全域冷卻：lrclib 回 429 時，所有 provider 呼叫都先等到這個時間點。
  /// 沒有這個，5520 個檔案會把 429 打得更兇（實測：一次 pipeline 之後
  /// 連單純的 curl 都吃 429），而且看起來像「卡住」但其實每檔都在失敗。
  static DateTime? _blockedUntil;

  /// 外部（例如 search 回 429）要標記冷卻時用這個。
  static void markBlocked(int seconds) {
    _blockedUntil = DateTime.now().add(Duration(seconds: seconds));
  }

  static int? _retryAfterSec(http.Response resp) {
    final v = resp.headers['retry-after'];
    if (v == null || v.isEmpty) return null;
    final n = int.tryParse(v.trim());
    if (n != null) return n;
    final t = DateTime.tryParse(v.trim());
    if (t != null) return t.difference(DateTime.now()).inSeconds;
    return null;
  }

  @override
  Future<LyricsResult?> fetch(String artist, String track,
      {String? album, int? durationSec}) async {
    // 全域 429 冷卻中就不打，直接放棄這一筆（讓上層繼續下一個檔案）
    final blocked = _blockedUntil;
    if (blocked != null && DateTime.now().isBefore(blocked)) return null;

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
        } else if (resp.statusCode == 429) {
          // 被限流：撐住全域冷卻（預設 60s，尊重 Retry-After），別再硬打
          final wait = _retryAfterSec(resp) ?? 60;
          _blockedUntil = DateTime.now().add(Duration(seconds: wait));
          return null;
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
