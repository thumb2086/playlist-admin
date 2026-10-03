import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/artwork_embedder.dart';
import 'package:playlist_admin/services/spotify_gql_client.dart';

/// 封面配對純函式回歸（不碰網路）：檔名慣例 + 三層 tiers。
void main() {
  group('splitStem（慣例：曲名 - 歌手）', () {
    test('標準兩段', () {
      final r = ArtworkEmbedder.splitStem('夜市王 - GENBLUE幻藍小熊');
      expect(r.$1, '夜市王');
      expect(r.$2, 'GENBLUE幻藍小熊');
    });

    test('曲名含分隔符（取第一段為曲名，其餘為歌手）', () {
      final r = ArtworkEmbedder.splitStem('殼 - HBO原創影集 - Eric Chou');
      expect(r.$1, '殼');
      expect(r.$2, 'HBO原創影集 - Eric Chou');
    });

    test('無分隔符', () {
      final r = ArtworkEmbedder.splitStem('純音樂');
      expect(r.$1, '純音樂');
      expect(r.$2, '');
    });
  });

  SpotifyTrackItem track(String name, String artists, String cover) =>
      SpotifyTrackItem(
        uri: 'spotify:track:x',
        name: name,
        artists: artists.isEmpty ? [] : [artists],
        album: '',
        durationMs: 200000,
        coverUrl: cover,
      );

  group('matchTrack tiers', () {
    final tracks = [
      track('夜市王', 'GENBLUE幻藍小熊', 'https://x/1.jpg'),
      track('觀自在 (Remix) [feat. Kanho Yakushiji]', 'Marz23, Kanho Yakushiji',
          'https://x/2.jpg'),
      track('隱痛', 'JOYY', 'https://x/3.jpg'),
    ];

    test('全等命中（含順序反轉）', () {
      expect(
          ArtworkEmbedder.matchTrack('夜市王 - GENBLUE幻藍小熊', tracks)!
              .coverUrl,
          'https://x/1.jpg');
      // 檔名順序反了也命中（同一張圖）。
      expect(
          ArtworkEmbedder.matchTrack('GENBLUE幻藍小熊 - 夜市王', tracks)!
              .coverUrl,
          'https://x/1.jpg');
    });

    test('both-parts 不分順序', () {
      expect(
          ArtworkEmbedder.matchTrack('一起走 - SCOOL 小巨蛋版', [
            track('一起走', 'SCOOL', 'https://x/9.jpg'),
          ])!
              .coverUrl,
          'https://x/9.jpg');
    });

    test('曲名單獨命中', () {
      expect(
          ArtworkEmbedder.matchTrack('隱痛 (Live) - JOYY', tracks)!.coverUrl,
          'https://x/3.jpg');
    });

    test('對不上回 null（不亂貼圖）', () {
      expect(ArtworkEmbedder.matchTrack('不存在的歌 - 沒這人', tracks), isNull);
    });

    test('無封面曲目不參與配對', () {
      expect(
          ArtworkEmbedder.matchTrack('夜市王 - GENBLUE幻藍小熊', [
            track('夜市王', 'GENBLUE幻藍小熊', ''),
          ]),
          isNull);
    });
  });

  group('playlistIdFromUrl', () {
    test('open Url 與 uri 格式', () {
      expect(
          ArtworkEmbedder.playlistIdFromUrl(
              'https://open.spotify.com/playlist/37i9dQZF1E3ahvZ5s71oFH'),
          '37i9dQZF1E3ahvZ5s71oFH');
      expect(
          ArtworkEmbedder.playlistIdFromUrl('spotify:playlist:abc123'),
          'abc123');
      expect(ArtworkEmbedder.playlistIdFromUrl('not a url'), isNull);
      expect(ArtworkEmbedder.playlistIdFromUrl(null), isNull);
    });
  });
}
