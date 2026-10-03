import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/podcast_service.dart';

/// YT 頻道 RAG 服務真實網路 E2E：解析頻道名 → 列影片 → 抓一支字幕。
/// 一次性驗證（會打 yt-dlp + YouTube）；純函式回歸見 yt_channel_test.dart。
void main() {
  test('YT頻道 E2E: 解析名/列影片/抓字幕', () async {
    const channel = 'https://www.youtube.com/@kurzgesagt';
    final sw = Stopwatch()..start();

    final title = await PodcastService.instance.resolveChannelTitle(channel);
    // ignore: avoid_print
    print('resolveChannelTitle -> $title (${sw.elapsedMilliseconds}ms)');
    expect(title, isNotNull);
    expect(title, isNotEmpty);

    sw.reset();
    final videos = await PodcastService.instance.listChannelVideos(channel);
    // ignore: avoid_print
    print('listChannelVideos -> ${videos?.length} 支 (${sw.elapsedMilliseconds}ms)');
    expect(videos, isNotNull);
    expect(videos, isNotEmpty);

    final v = videos!.first;
    // ignore: avoid_print
    print('first: id=${v.id} title=${v.title}');

    sw.reset();
    const outDir = r'C:\Users\CPXru\AppData\Local\Temp\opencode\yt_probe_out';
    await Directory(outDir).create(recursive: true);
    final r = await PodcastService.instance.fetchYtSubtitlesByUrl(
      'https://www.youtube.com/watch?v=${v.id}',
      outDir,
      PodcastService.normalizeFileName(v.title),
      onLog: (m) => print('    $m'),
    );
    // ignore: avoid_print
    print('fetchYtSubtitlesByUrl -> $r (${sw.elapsedMilliseconds}ms)');
    // ignore: avoid_print
    print('first title repr: ${v.title}');
    final srt = Directory(outDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.toLowerCase().endsWith('.srt'))
        .toList();
    for (final f in srt) {
      // ignore: avoid_print
      print('  srt: ${f.uri.pathSegments.last} (${f.lengthSync()} bytes)');
    }
    expect(r, PodcastSubtitleResult.found);
    expect(srt, isNotEmpty);
  },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: Platform.environment['YT_E2E'] == '1'
          ? false
          : '網路探針（會打 YouTube/yt-dlp）：set YT_E2E=1 再跑');
}
