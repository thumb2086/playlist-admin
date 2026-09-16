import 'dart:async';
import 'dart:io';
import 'config_service.dart';

class UsbExportResult {
  final int copied;
  final int total;
  final int missing;
  final String targetPath;
  UsbExportResult({required this.copied, required this.total, required this.missing, required this.targetPath});
}

class UsbExporter {
  final void Function(String) log;

  UsbExporter({required this.log});

  Future<UsbExportResult> exportPlaylists(
    List<String> playlistFiles, {
    String? targetDir,
    String quality = 'original', // 'original', 'mp3', 'flac'
  }) async {
    final cfg = ConfigService.instance.config;
    final exportPath = targetDir ?? cfg.exportPath;
    final libraryPath = cfg.libraryPath;

    // 防呆：exportPath 誤設會刪光使用者資料（recursive delete 不可逆）。
    final norm = exportPath.replaceAll('/', '\\').toLowerCase();
    bool sameAs(String p) => p.isNotEmpty && p.replaceAll('/', '\\').toLowerCase() == norm;
    final isRoot = RegExp(r'^[a-z]:\\?$').hasMatch(norm);
    if (exportPath.trim().isEmpty || isRoot ||
        sameAs(libraryPath) || sameAs(cfg.basePath) || sameAs(cfg.playlistsPath)) {
      log('  ❌ 匯出路徑不合法（空白/磁碟根目錄/與音樂庫相同），拒絕執行: $exportPath');
      throw Exception('匯出路徑不合法: $exportPath');
    }

    // Clean and recreate export dir
    final exportDir = Directory(exportPath);
    if (await exportDir.exists()) {
      await exportDir.delete(recursive: true);
    }
    await exportDir.create(recursive: true);

    int total = 0;
    int copied = 0;
    int missing = 0;

    for (final plFile in playlistFiles) {
      final plName = File(plFile).uri.pathSegments.last.replaceAll(RegExp(r'\.m3u8?$'), '');
      final destFolder = Directory('$exportPath\\$plName');
      await destFolder.create();

      try {
        final lines = await File(plFile).readAsLines();
        int plCopied = 0;
        int plTotal = 0;

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

          plTotal++;
          total++;

          // Resolve source file
          String src = trimmed;
          if (!File(src).existsSync()) {
            final fname = File(src).uri.pathSegments.last;
            src = '$libraryPath\\$fname';
          }
          if (!File(src).existsSync()) {
            log('  ⚠️ 找不到檔案: $trimmed');
            missing++;
            continue;
          }

          // Handle quality conversion (temp 放 systemTemp，crash 不殘留匯出目錄)
          String finalSrc = src;
          String? tmpConverted;
          if (quality == 'mp3' || quality == 'flac') {
            final srcExt = src.toLowerCase().split('.').last;
            if (srcExt != quality) {
              final stem = File(src).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
              tmpConverted = '${Directory.systemTemp.path}\\usb_exp_${stem.hashCode.toRadixString(16)}_${plTotal}_$total.$quality';
              final cmd = <String>[
                'ffmpeg', '-y', '-i', src,
                if (quality == 'mp3') ...['-codec:a', 'libmp3lame', '-qscale:a', '0'],
                if (quality == 'flac') ...['-codec:a', 'flac'],
                tmpConverted,
              ];
              try {
                // runInShell:false：路徑含空格/& 不會被拆錯；單檔 300s timeout。
                final r = await Process.run(cmd[0], cmd.sublist(1), runInShell: false)
                    .timeout(const Duration(seconds: 300));
                if (r.exitCode == 0) {
                  finalSrc = tmpConverted;
                } else {
                  log('  ⚠️ 轉換失敗，使用原始檔案: ${File(src).uri.pathSegments.last}');
                }
              } on TimeoutException {
                log('  ⚠️ 轉換逾時，使用原始檔案: ${File(src).uri.pathSegments.last}');
              } catch (e) {
                log('  ⚠️ 轉換異常，使用原始檔案: ${File(src).uri.pathSegments.last} ($e)');
              }
            }
          }

          // Copy to destination
          final destName = File(finalSrc).uri.pathSegments.last;
          final destPath = '${destFolder.path}\\$destName';
          try {
            await File(finalSrc).copy(destPath);
            plCopied++;
            copied++;
          } catch (e) {
            log('  ❌ 複製失敗 ${File(src).uri.pathSegments.last}: $e');
          }

          // Clean temp file
          if (tmpConverted != null) {
            try { if (await File(tmpConverted).exists()) await File(tmpConverted).delete(); } catch (_) {}
          }
        }

        log('  📁 $plName: $plCopied/$plTotal 首已匯出');
      } catch (e) {
        log('  ❌ 處理 $plName 失敗: $e');
      }
    }

    log('\n✅ 匯出完成: $copied/$total 首 (缺少 $missing 首)');
    return UsbExportResult(copied: copied, total: total, missing: missing, targetPath: exportPath);
  }
}
