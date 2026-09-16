import 'dart:async';
import 'dart:io';
import 'metadata_reader.dart';

class AudioConverter {
  /// Returns (success, inputLufs) where inputLufs is the Input Integrated
  /// LUFS captured from loudnorm's own measurement during conversion —
  /// no separate full-file scan needed.
  static Future<(bool, double?)> convert({
    required String inputPath,
    required String outputPath,
    String format = 'mp3',
    String? ffmpegPath,
    TrackMetadata? meta,
    bool Function()? isCancelled,
  }) async {
    String ffmpeg = ffmpegPath ?? 'ffmpeg';
    if (!ffmpeg.contains('\\') && !ffmpeg.contains('/')) {
      // Already a simple name like 'ffmpeg' — keep as-is
    } else if (!await File(ffmpeg).exists()) {
      ffmpeg = 'ffmpeg'; // Fallback to PATH if configured path doesn't exist
    }
    if (!await File(inputPath).exists()) return (false, null);

    // Ensure output directory exists
    await File(outputPath).parent.create(recursive: true);

    if (inputPath.toLowerCase().endsWith('.$format')) {
      await File(inputPath).copy(outputPath);
      return (true, null);
    }

    meta ??= await MetadataReader.read(inputPath);

    final args = <String>[
      '-y', '-i', inputPath,
      '-map_metadata', '0',
      '-id3v2_version', '3',
      '-threads', '0',
    ];

    // Apply EBU R128 loudnorm to MP3 output (YouTube/Spotify standard -14 LUFS)
    if (format == 'mp3') {
      args.addAll(['-af', 'loudnorm=I=-14:TP=-1:LRA=7',
        '-filter_threads', '0']);
    }

    args.addAll([
      '-codec:a', format == 'mp3' ? 'libmp3lame' : 'flac',
      '-q:a', '0',
      outputPath,
    ]);

    try {
      final proc = await Process.start(ffmpeg, args, runInShell: false);
      // MUST drain stdout/stderr or ffmpeg blocks forever when pipe buffer fills.
      // Capture stderr to parse loudnorm's own LUFS measurement.
      proc.stdout.drain<void>();
      final stderrBuf = <int>[];
      proc.stderr.listen(stderrBuf.addAll);
      // Poll for cancellation while ffmpeg runs, kill immediately if cancelled.
      // 總超時 120 分鐘：hang 住不可無限等（舊寫法 catch 全吞 + 無 deadline）。
      final start = DateTime.now();
      const limit = Duration(minutes: 120);
      while (true) {
        if (isCancelled?.call() ?? false) {
          proc.kill(ProcessSignal.sigkill);
          return (false, null);
        }
        if (DateTime.now().difference(start) > limit) {
          proc.kill(ProcessSignal.sigkill);
          try { if (await File(outputPath).exists()) await File(outputPath).delete(); } catch (_) {}
          return (false, null);
        }
        final exited = await proc.exitCode.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () => -1,
        );
        if (exited != -1) {
          if (exited != 0) {
            // Remove the partial/empty output so it is not treated as done.
            try { if (await File(outputPath).exists()) await File(outputPath).delete(); } catch (_) {}
            return (false, null);
          }
          final stderr = String.fromCharCodes(stderrBuf);
          final m = RegExp(r'Input Integrated:\s+([-\d.]+)').firstMatch(stderr);
          final lufs = m != null ? double.tryParse(m.group(1)!) : null;
          return (true, lufs);
        }
      }
    } catch (_) {
      return (false, null);
    }
  }
}
