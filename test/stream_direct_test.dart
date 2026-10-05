import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playlist_admin/services/youtube_service.dart';

/// 手機直連串流（Spotube 同款路徑：youtube_explode 直鏈，無 yt-dlp）。
void main() {
  group('resolveStreamDirect', () {
    test('parseVideoId 照舊可用（純函式，常跑）', () {
      expect(YoutubeService.parseVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ')?.value,
          'dQw4w9WgXcQ');
      expect(YoutubeService.parseVideoId('dQw4w9WgXcQ')?.value, 'dQw4w9WgXcQ');
      expect(YoutubeService.parseVideoId('https://youtu.be/dQw4w9WgXcQ')?.value,
          'dQw4w9WgXcQ');
      expect(YoutubeService.parseVideoId('not a url at all'), isNull);
    });

    test('E2E：搜尋→直鏈→HEAD 可達', () async {
      final r = await YoutubeService.instance
          .resolveStreamDirect('周杰倫 晴天');
      expect(r, isNotNull, reason: '直連解析失敗（可能被 YouTube bot 擋）');
      expect(r!.audioUrl.startsWith('http'), true);
      expect(r.thumbnailUrl.contains('i.ytimg.com'), true);
      // ignore: avoid_print
      print('direct: ${r.title} - ${r.author} [${r.videoId}]');
      final resp = await http.head(Uri.parse(r.audioUrl));
      // ignore: avoid_print
      print('HEAD status: ${resp.statusCode}');
      expect(resp.statusCode, 200, reason: '直鏈 HEAD 非 200，手機播會 404');
    },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: Platform.environment['YT_E2E'] == '1'
            ? false
            : '網路探針（會打 YouTube）：set YT_E2E=1 再跑');

    test('E2E：手機獨立下載（直鏈→存檔 m4a/webm，無 yt-dlp/ffmpeg）', () async {
      final r = await YoutubeService.instance
          .resolveStreamDirect('周杰倫 晴天');
      expect(r, isNotNull, reason: '直連解析失敗（可能被 YouTube bot 擋）');
      final tmp =
          await Directory.systemTemp.createTemp('dl_direct_test_');
      try {
        final saved = await YoutubeService.instance.downloadDirect(
          videoId: r!.videoId,
          dir: tmp.path,
          stem: 'test-song',
        );
        expect(saved.isNotEmpty, true, reason: '下載失敗（直鏈被擋？）');
        expect(saved.endsWith('.m4a') || saved.endsWith('.webm'), true,
            reason: '副檔名非 m4a/webm：$saved');
        expect(File(saved).lengthSync(), greaterThan(65536),
            reason: '檔案過小，疑似截斷');
        // ignore: avoid_print
        print('downloaded: $saved (${File(saved).lengthSync()} B)');
      } finally {
        try { await tmp.delete(recursive: true); } catch (_) {}
      }
    },
        timeout: const Timeout(Duration(minutes: 5)),
        skip: Platform.environment['YT_E2E'] == '1'
            ? false
            : '網路探針（會打 YouTube）：set YT_E2E=1 再跑');
  });
}
