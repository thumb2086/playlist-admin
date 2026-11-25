import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../services/lyrics_service.dart';
import 'lyrics_provider.dart';

/// Lyrics.ovh 歌詞供應商（第二來源，非中國服務）。
///
/// 為什麼要它：LRCLib 的 `/api/get` 在大量請求後會 429（實測一次 pipeline
/// 之後連單純 curl 都吃 429），而唯一 fallback 若不存在，5000+ 首會全數失敗。
/// Lyrics.ovh 免註冊、免 key、無明確配額，回傳純歌詞（無 LRC 時間軸）。
///
/// 注意：它只有 plain lyrics，沒有 syncedLyrics → 顯示上會是「非同步歌詞」。
class LyricsOvhProvider implements LyricsProvider {
  LyricsOvhProvider({this.priority = 30});

  @override
  String get id => 'lyricsovh';

  @override
  String get displayName => 'Lyrics.ovh';

  @override
  bool get enabled => true;

  @override
  final int priority;

  static const _base = 'https://api.lyrics.ovh/v1';

  @override
  Future<LyricsResult?> fetch(String artist, String track,
      {String? album, int? durationSec}) async {
    final a = artist.trim();
    final t = track.trim();
    if (a.isEmpty || t.isEmpty) return null;
    try {
      final uri = Uri.parse('$_base/${Uri.encodeComponent(a)}/${Uri.encodeComponent(t)}');
      final resp = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final lyrics = (data['lyrics'] as String?)?.trim() ?? '';
      if (lyrics.isEmpty) return null;
      return LyricsResult(
        artist: a,
        track: t,
        album: album ?? '',
        syncedLyrics: null,
        plainLyrics: lyrics,
        durationSec: durationSec ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}