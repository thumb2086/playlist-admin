import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/podcast_service.dart';

/// YT 頻道 RAG 服務的純函式回歸：URL 判定 + 頻道清單輸出解析。
void main() {
  group('isYtChannelUrl', () {
    test('YouTube 頻道/影片/清單 = true', () {
      expect(PodcastService.isYtChannelUrl('https://www.youtube.com/@techwav'), true);
      expect(PodcastService.isYtChannelUrl('https://youtube.com/channel/UCabcdef'), true);
      expect(PodcastService.isYtChannelUrl('https://www.youtube.com/c/somechannel/videos'), true);
      expect(PodcastService.isYtChannelUrl('https://www.youtube.com/watch?v=abcDEF12345'), true);
      expect(PodcastService.isYtChannelUrl('https://youtu.be/abcDEF12345'), true);
      expect(PodcastService.isYtChannelUrl('https://www.youtube.com/playlist?list=PLxyz'), true);
    });

    test('RSS feed 與一般網址 = false', () {
      expect(PodcastService.isYtChannelUrl('https://feeds.simplecast.com/abc123'), false);
      expect(PodcastService.isYtChannelUrl('https://www.soundon.space/feed/xyz'), false);
      expect(PodcastService.isYtChannelUrl('C:\\local\\dir'), false);
      expect(PodcastService.isYtChannelUrl(''), false);
    });
  });

  group('parseFlatListOutput', () {
    test('解析 id\\ttitle，跳過垃圾行，title 內 tab 保留', () {
      const out = 'abcDEF12345\t第一支影片\n'
          '不是id\tXX\n'
          'xyzGHI67890\tTitle\twith tab\n'
          '\n'
          'short\tid';
      final rows = PodcastService.parseFlatListOutput(out);
      expect(rows.length, 2);
      expect(rows[0].id, 'abcDEF12345');
      expect(rows[0].title, '第一支影片');
      expect(rows[1].id, 'xyzGHI67890');
      expect(rows[1].title, 'Title\twith tab');
    });

    test('空輸出 = 空清單', () {
      expect(PodcastService.parseFlatListOutput(''), isEmpty);
      expect(PodcastService.parseFlatListOutput('ERROR: something'), isEmpty);
    });
  });
}
