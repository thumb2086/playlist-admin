import 'dart:io';
import 'package:playlist_admin/services/audio_extractor.dart';

Future<void> main() async {
  final cfg = AudioExtractorConfig();
  cfg.sourceDir = 'C:\\videos';
  cfg.outputDir = 'C:\\videos\\out';
  final c2 = AudioExtractorConfig.fromJson(cfg.toJson());
  print('config roundtrip: ${c2.sourceDir} / ${c2.format} / ${c2.bitrate} / workers=${c2.workers}');
  print('deepFilter: ${c2.deepFilterPath} / track3=${c2.trackNames[3]}');
  print('ffmpeg: ${AudioExtractorEngine.ffmpegExe()}');
  print('ffprobe: ${AudioExtractorEngine.ffprobeExe()}');

  for (final d in ['C:\\Users\\CPXru\\Downloads', 'C:\\Users\\CPXru\\Videos', 'C:\\']) {
    final dir = Directory(d);
    if (!await dir.exists()) continue;
    await for (final e in dir.list(recursive: false)) {
      if (e is File && ['.mp4', '.mov', '.mkv', '.avi'].any((x) => e.path.toLowerCase().endsWith(x))) {
        final v = await AudioExtractorEngine.probe(e.path);
        if (v != null) {
          print('probe: ${v.name} -> ${v.trackCount} tracks | ${v.sizeLabel} | ${v.durLabel}');
          for (final t in v.tracks) {
            print('  ${t.detail}');
          }
          exit(0);
        }
      }
    }
  }
  print('(no sample video found to probe)');
}