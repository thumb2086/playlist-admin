import 'dart:io';
import 'package:http/http.dart' as http;

class FfmpegInstaller {
  static const _downloadUrl =
      'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip';

  static Future<bool> isAvailable() async {
    try {
      final r = await Process.run('ffmpeg', ['-version'],
          runInShell: true).timeout(const Duration(seconds: 15));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> checkLocal(String path) async {
    if (path.isEmpty) return false;
    try {
      final resolved = path.contains(RegExp(r'^[A-Za-z]:\\'))
          ? path
          : '${Directory.current.path}\\$path';
      if (!File(resolved).existsSync()) return false;
      final r = await Process.run(resolved, ['-version'],
          runInShell: true).timeout(const Duration(seconds: 15));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> ensureAvailable(String configPath, void Function(String) log) async {
    if (await isAvailable()) {
      log('✅ 系統已安裝 FFmpeg');
      return true;
    }
    if (configPath.isNotEmpty && await checkLocal(configPath)) {
      log('✅ 本地 FFmpeg 可用: $configPath');
      return true;
    }
    log('📥 正在自動安裝 FFmpeg…');
    return _downloadAndInstall(log);
  }

  static Future<bool> _downloadAndInstall(void Function(String) log) async {
    final tempDir = Directory.systemTemp.createTempSync('ffmpeg_');
    try {
      log('  下載中: $_downloadUrl');
      // 串流下載：~80MB zip 不可全放 RAM；各段 timeout 防 hang。
      final zipPath = '${tempDir.path}\\ffmpeg.zip';
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(_downloadUrl));
        final resp = await client.send(request).timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          log('  ❌ 下載失敗: HTTP ${resp.statusCode}');
          return false;
        }
        final sink = File(zipPath).openWrite();
        try {
          await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
          }
          await sink.flush();
          await sink.close();
        } catch (e) {
          try { await sink.close(); } catch (_) {}
          log('  ❌ 下載中斷: $e');
          return false;
        }
      } finally {
        client.close();
      }

      // Extract using PowerShell (Windows)
      final exeDir = '${Directory.current.path}\\bin';
      await Directory(exeDir).create(recursive: true);

      log('  解壓縮中…');
      await Process.run('powershell', [
        '-Command',
        'Expand-Archive -Path "$zipPath" -DestinationPath "${tempDir.path}\\extracted" -Force',
      ], runInShell: true).timeout(const Duration(minutes: 5));

      // Find ffmpeg.exe
      final extracted = Directory('${tempDir.path}\\extracted');
      String? found;
      await for (final e in extracted.list(recursive: true)) {
        if (e is File && e.path.endsWith('ffmpeg.exe')) {
          found = e.path;
          break;
        }
      }

      if (found == null) {
        log('  ❌ 在壓縮檔中找不到 ffmpeg.exe');
        return false;
      }

      await File(found).copy('$exeDir\\ffmpeg.exe');
      log('  ✅ FFmpeg 已安裝到: $exeDir\\ffmpeg.exe');
      return true;
    } catch (e) {
      log('  ❌ 安裝失敗: $e');
      return false;
    } finally {
      // 任何路徑都清 temp（舊寫法 catch 裡漏刪）。
      try { tempDir.deleteSync(recursive: true); } catch (_) {}
    }
  }
}
