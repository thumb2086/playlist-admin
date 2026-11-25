import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../services/lyrics_service.dart';
import 'lyrics_provider.dart';

/// 網易雲音樂歌詞供應商（第二來源）。
///
/// 為什麼要它：lrclib.net 的 `/api/get` 會 429（實測：一次 pipeline 之後
/// 連單純 curl 都吃 429，而 `/api/search` 卻還是 200）。有第二個來源，
/// provider chain 才真的發揮作用 —— 這正是 Spotube lyrics provider 的設計目的。
///
/// 不需要 API key。回傳的 LRC 是 `[mm:ss.xx]` 格式，parseLrc 吃得下。
class NeteaseLyricsProvider implements LyricsProvider {
  NeteaseLyricsProvider({this.priority = 20});

  @override
  String get id => 'netease';

  @override
  String get displayName => '網易雲音樂';

  @override
  bool get enabled => true;

  @override
  final int priority;

  static const _searchApi = 'https://music.163.com/api/search/get';
  static const _lyricApi = 'https://music.163.com/api/song/lyric';

  static final Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36',
    'Referer': 'https://music.163.com/',
    'Cookie': 'appver=2.0.2',
  };

  @override
  Future<LyricsResult?> fetch(String artist, String track,
      {String? album, int? durationSec}) async {
    try {
      final q = '$track $artist'.trim();
      if (q.isEmpty) return null;

      // 1) 搜尋拿到 song id
      final sResp = await http
          .get(Uri.parse('$_searchApi?s=${Uri.encodeQueryComponent(q)}&type=1&limit=3'),
              headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (sResp.statusCode != 200) return null;
      final sJson = jsonDecode(sResp.body) as Map<String, dynamic>;
      final songs = (sJson['result'] as Map<String, dynamic>?)?['songs'] as List<dynamic>?;
      if (songs == null || songs.isEmpty) return null;

      // 2) 取第一首的同步歌詞
      final id = (songs.first as Map<String, dynamic>)['id'];
      if (id == null) return null;
      final lResp = await http
          .get(Uri.parse('$_lyricApi?id=$id&lv=-1&kv=-1&tv=-1'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (lResp.statusCode != 200) return null;
      final lJson = jsonDecode(lResp.body) as Map<String, dynamic>;

      final lrc = (lJson['lrc'] as Map<String, dynamic>?)?['lyric'] as String?;
      final plain = (lJson['tlyric'] as Map<String, dynamic>?)?['lyric'] as String?;
      if ((lrc == null || lrc.trim().isEmpty) && (plain == null || plain.trim().isEmpty)) {
        return null;
      }
      return LyricsResult(
        artist: artist,
        track: track,
        album: album ?? '',
        syncedLyrics: (lrc != null && lrc.trim().isNotEmpty) ? lrc : null,
        plainLyrics: (plain != null && plain.trim().isNotEmpty) ? plain : null,
        durationSec: durationSec ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}