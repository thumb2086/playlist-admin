import 'dart:io';
import 'package:playlist_admin/services/audio_extractor.dart';

/// 端到端測試：用真實影片跑完整抽取管線（含長檔切段/拼接、GPU deep）。
Future<void> main() async {
  const srcDir = r'C:\Users\CPXru\Videos\Overwolf\Insights Capture';
  const outDir = r'C:\Users\CPXru\AppData\Local\Temp\ae_e2e_out';
  await Directory(outDir).create(recursive: true);

  final files = Directory(srcDir)
      .listSync()
      .whereType<File>()
      .where((f) => ['.mp4', '.mkv', '.mov'].any((x) => f.path.toLowerCase().endsWith(x)))
      .toList();
  print('影片數: ${files.length}');

  // 挑 1 條短 Highlight + 1 條最長的錄音（逼出分段路徑）
  files.sort((a, b) => a.path.compareTo(b.path));
  final highlight = files.firstWhere((f) => f.path.contains('Highlight'), orElse: () => files.first);
  final long = files.reduce((a, b) => a.lengthSync() > b.lengthSync() ? a : b);
  print('短檔: ${highlight.uri.pathSegments.last}');
  print('長檔: ${long.uri.pathSegments.last}');

  // 探測音軌（只留 Mic=track3 + 145k，模擬頁面行為）
  final jobs = <({String src, int trackId, int sampleRate, String trackName, bool denoise})>[];
  for (final f in [highlight, long]) {
    final v = await AudioExtractorEngine.probe(f.path);
    if (v == null) { print('probe 失敗: ${f.uri.pathSegments.last}'); continue; }
    for (final t in v.tracks) {
      if (t.bitRate <= 0 || t.bitRate >= 10000) {
        jobs.add((src: f.path, trackId: t.index, sampleRate: t.sampleRate,
            trackName: 'E2E_${t.index}', denoise: true));
      }
    }
  }
  print('測試任務數: ${jobs.length}（全部強制降噪，測試 deep 路徑）');

  final cfg = AudioExtractorConfig()
    ..sourceDir = srcDir
    ..outputDir = outDir
    ..format = 'aac'
    ..bitrate = '128k'
    ..lufsTarget = -14
    ..deepFilterDevice = 'cuda'
    ..workers = 2;
  // 不覆蓋 toJson：直接跑

  final sw = Stopwatch()..start();
  await AudioExtractorEngine.runParallel(
    jobs: jobs,
    cfg: cfg,
    onLog: (m) => print(m),
    onProgress: () {},
    canceled: () => false,
  );
  sw.stop();
  print('\n===== 完成，花費 ${sw.elapsedMilliseconds ~/ 60000} 分 ${(sw.elapsedMilliseconds ~/ 1000) % 60} 秒 =====');
  final outs = Directory(outDir).listSync().whereType<File>().toList();
  print('輸出檔案數: ${outs.length}');
  for (final o in outs) {
    print('  ${o.uri.pathSegments.last} (${(o.lengthSync() / 1048576).toStringAsFixed(1)} MB)');
  }
  final leakedWavs = Directory.systemTemp
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('df_') && f.path.endsWith('.wav'))
      .toList();
  print('temp 殘留 df_*.wav: ${leakedWavs.length}');
}