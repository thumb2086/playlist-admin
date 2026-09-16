import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// LRCLib.net 歌詞服務：同步 LRC + 非同步歌詞。
/// API: https://lrclib.net/api/get?artist_name=X&track_name=Y&duration=Z
class LyricsService {
  LyricsService._();
  static final instance = LyricsService._();

  /// 快取: "artist:track" → LyricsResult（LRU 上限 200，只增不減會吃 RAM）。
  final Map<String, LyricsResult> _cache = {};
  static const int _cacheMax = 200;
  void _cachePut(String key, LyricsResult v) {
    _cache.remove(key);
    _cache[key] = v;
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 取得歌詞。優先同步 LRC，再非同步。
  Future<LyricsResult?> fetch(String artist, String track, {String? album, int? durationSec}) async {
    final key = '$artist:$track'.toLowerCase();
    if (_cache.containsKey(key)) return _cache[key];

    try {
      final params = {
        'artist_name': artist,
        'track_name': track,
      };
      if (album != null && album.isNotEmpty) params['album_name'] = album;
      if (durationSec != null && durationSec > 0) params['duration'] = '$durationSec';

      final uri = Uri.https('lrclib.net', '/api/get', params);
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        _log.i('LRCLib 無歌詞: $artist - $track (${resp.statusCode})');
        return null;
      }

      final data = jsonDecode(resp.body);
      final result = LyricsResult(
        artist: data['artistName'] as String? ?? artist,
        track: data['trackName'] as String? ?? track,
        album: data['albumName'] as String? ?? album ?? '',
        syncedLyrics: data['syncedLyrics'] as String?,
        plainLyrics: data['plainLyrics'] as String?,
        durationSec: data['duration'] as int? ?? durationSec ?? 0,
      );

      _cachePut(key, result);
      _log.i('LRCLib 歌詞: $artist - $track '
          '(LRC: ${result.syncedLyrics != null ? "${result.syncedLyrics!.length}c" : "無"}'
          ', plain: ${result.plainLyrics != null ? "${result.plainLyrics!.length}c" : "無"})');
      return result;
    } catch (e) {
      _log.e('LRCLib 失敗: $e');
      return null;
    }
  }

  /// 搜尋歌詞（模糊搜尋）。
  Future<List<LyricsSearchResult>> search(String query, {int limit = 5}) async {
    try {
      final uri = Uri.https('lrclib.net', '/api/search', {'q': query});
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];

      final data = jsonDecode(resp.body) as List;
      return data.take(limit).map((item) => LyricsSearchResult(
        artist: item['artistName'] as String? ?? '',
        track: item['trackName'] as String? ?? '',
        album: item['albumName'] as String? ?? '',
        durationSec: item['duration'] as int? ?? 0,
      )).toList();
    } catch (e) {
      _log.e('LRCLib 搜尋失敗: $e');
      return [];
    }
  }

  /// 解析 LRC 同步歌詞為 (時間, 歌詞) 列表。
  static List<LyricLine> parseLrc(String lrc) {
    final lines = <LyricLine>[];
    final pattern = RegExp(r'\[(\d{2}):(\d{2})\.?(\d{0,3})\]\s*(.*)');
    for (final match in pattern.allMatches(lrc)) {
      final min = int.parse(match.group(1)!);
      final sec = int.parse(match.group(2)!);
      final ms = int.parse(match.group(3)!.padRight(3, '0'));
      final text = match.group(4) ?? '';
      if (text.isNotEmpty) {
        lines.add(LyricLine(
          time: Duration(minutes: min, seconds: sec, milliseconds: ms),
          text: text,
        ));
      }
    }
    return lines..sort((a, b) => a.time.compareTo(b.time));
  }

  /// 根據播放位置找到當前行。
  static int currentLine(List<LyricLine> lines, Duration position) {
    for (int i = lines.length - 1; i >= 0; i--) {
      if (lines[i].time <= position) return i;
    }
    return 0;
  }
}

/// 歌詞結果。
class LyricsResult {
  final String artist;
  final String track;
  final String album;
  final String? syncedLyrics;
  final String? plainLyrics;
  final int durationSec;

  const LyricsResult({
    required this.artist,
    required this.track,
    required this.album,
    this.syncedLyrics,
    this.plainLyrics,
    required this.durationSec,
  });

  bool get hasSynced => syncedLyrics != null && syncedLyrics!.isNotEmpty;
  bool get hasPlain => plainLyrics != null && plainLyrics!.isNotEmpty;
  bool get hasAny => hasSynced || hasPlain;
}

/// 歌詞搜尋結果。
class LyricsSearchResult {
  final String artist;
  final String track;
  final String album;
  final int durationSec;

  const LyricsSearchResult({
    required this.artist,
    required this.track,
    required this.album,
    required this.durationSec,
  });
}

/// LRC 解析後的單行歌詞。
class LyricLine {
  final Duration time;
  final String text;

  const LyricLine({required this.time, required this.text});
}
