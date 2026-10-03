import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/artwork_embedder.dart';
import 'package:playlist_admin/services/config_service.dart';
import 'package:playlist_admin/services/spotify_session.dart';

/// 內嵌封面真實 E2E：在 temp 副本上跑完整鏈（搜尋→抓圖→ffmpeg remux），
/// 驗 ffprobe 有圖 + 音訊時長不變 + 冪等。絕不碰音樂庫原檔。
/// 跑法：set ARTWORK_E2E=1 後 flutter test test/artwork_embed_e2e_test.dart
void main() {
  test('embedForFile 全鏈 + 冪等', () async {
    await ConfigService.instance.load();
    await SpotifySession.instance.load();
    expect(SpotifySession.instance.isLoggedIn, true,
        reason: '需要有效 Spotify session（沒有就先在 app 登入）');
    final musicDir =
        Directory(ConfigService.instance.config.musicPath);
    final samples = musicDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .take(2)
        .toList();
    expect(samples.length, 2, reason: '音樂庫要有至少 2 首 mp3');

    final tmpDir = await Directory(
            r'C:\Users\CPXru\AppData\Local\Temp\opencode\artwork_probe')
        .create(recursive: true);
    final embedder = ArtworkEmbedder.instance;

    for (final src in samples) {
      final stem = src.uri.pathSegments.last
          .replaceAll(RegExp(r'\.\w+$'), '');
      final dst = File('${tmpDir.path}${Platform.pathSeparator}$stem.mp3');
      await src.copy(dst.path);
      // 測試前確認副本真的沒圖（有的話換一首測 embed 冪等路徑）。
      final hadArt = await embedder.hasArtwork(dst.path);
      // ignore: avoid_print
      print('file: $stem hadArt=$hadArt');

      final parts = ArtworkEmbedder.splitStem(stem);
      final r = await embedder.embedForFile(dst.path,
          title: parts.$1, artist: parts.$2);
      // ignore: avoid_print
      print('embed result: $r');
      expect(r == ArtworkResult.embedded || r == ArtworkResult.skippedHasArt,
          true,
          reason: 'noCover/failed 表示搜尋或 ffmpeg 環境有問題：$r');

      if (r == ArtworkResult.embedded) {
        expect(await embedder.hasArtwork(dst.path), true);
        // 音訊時長不變（±2 秒容忍轉碼邊界）。
        Future<double> dur(String p) async {
          final r = await Process.run('ffprobe', [
            '-v', 'quiet', '-print_format', 'json', '-show_format', p
          ]);
          final out = r.stdout as String;
          final m =
              RegExp(r'"duration"\s*:\s*"([\d.]+)"').firstMatch(out);
          return double.tryParse(m?.group(1) ?? '') ?? -1;
        }

        final d0 = await dur(src.path);
        final d1 = await dur(dst.path);
        // ignore: avoid_print
        print('duration: $d0 -> $d1 size: ${src.lengthSync()} -> ${dst.lengthSync()}');
        expect(d1, greaterThan(0));
        if (d0 > 0) expect((d1 - d0).abs(), lessThan(2));
        expect(dst.lengthSync(), greaterThan(src.lengthSync()));

        // 冪等：再跑一次必須 skip。
        final r2 = await embedder.embedForFile(dst.path,
            title: parts.$1, artist: parts.$2);
        expect(r2, ArtworkResult.skippedHasArt);
      }
      await dst.delete();
    }
  }, timeout: const Timeout(Duration(minutes: 10)),
      skip: Platform.environment['ARTWORK_E2E'] == '1'
          ? false
          : '會改檔+打 Spotify+跑 ffmpeg：set ARTWORK_E2E=1 再跑');
}
