import 'dart:io';
import 'metadata_reader.dart';

class RenameResult {
  final bool success;
  final String oldPath;
  final String newPath;
  final String? message;
  RenameResult({required this.success, required this.oldPath, required this.newPath, this.message});
}

class FileRenamer {
  final String libraryPath;
  final void Function(String) log;

  FileRenamer({required this.libraryPath, required this.log});

  Future<RenameResult> renameFile(String filePath, {bool dryRun = false}) async {
    final meta = await MetadataReader.read(filePath);
    if ((meta.title == null || meta.title!.isEmpty) && (meta.artist == null || meta.artist!.isEmpty)) {
      return RenameResult(success: false, oldPath: filePath, newPath: filePath, message: '無 metadata');
    }

    final artist = meta.artist?.trim() ?? '';
    final title = meta.title?.trim() ?? '';
    // 副檔名取檔名段的最後一段：路徑目錄含點時 split('.').last 會取錯。
    final fileName = File(filePath).uri.pathSegments.last;
    final dotIdx = fileName.lastIndexOf('.');
    final ext = (dotIdx > 0) ? fileName.substring(dotIdx + 1) : '';

    String newName;
    if (artist.isNotEmpty && title.isNotEmpty) {
      newName = '$title - $artist.$ext';
    } else if (title.isNotEmpty) {
      newName = '$title.$ext';
    } else {
      newName = '$artist.$ext';
    }

    newName = newName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final dir = Directory(filePath).parent.path;
    final newPath = '$dir\\$newName';

    if (newPath == filePath) {
      return RenameResult(success: true, oldPath: filePath, newPath: filePath, message: '檔名已正確');
    }

    if (await File(newPath).exists()) {
      return RenameResult(success: false, oldPath: filePath, newPath: newPath, message: '目標檔案已存在');
    }

    if (!dryRun) {
      await File(filePath).rename(newPath);
      log('  ✅ 已重新命名: ${filePath.split('\\').last} → $newName');
    } else {
      log('  📝 將重新命名: ${filePath.split('\\').last} → $newName');
    }

    return RenameResult(success: true, oldPath: filePath, newPath: newPath, message: 'OK');
  }

  Future<Map<String, int>> batchRename({bool dryRun = false}) async {
    final dir = Directory(libraryPath);
    if (!await dir.exists()) return {'total': 0, 'renamed': 0, 'errors': 0, 'skipped': 0};

    int total = 0, renamed = 0, errors = 0, skipped = 0;
    final files = <String>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        final low = e.path.toLowerCase();
        if (low.endsWith('.mp3') || low.endsWith('.m4a') || low.endsWith('.flac')) {
          files.add(e.path);
        }
      }
    }

    total = files.length;
    log('🔍 掃描到 $total 個音檔');

    for (int i = 0; i < files.length; i++) {
      // 單檔 throw（保留名/權限/被佔用）不可中斷整批：計錯繼續。
      RenameResult r;
      try {
        r = await renameFile(files[i], dryRun: dryRun);
      } catch (e) {
        errors++;
        log('  ❌ ${files[i].split('\\').last}: $e');
        continue;
      }
      if (r.success) {
        if (r.newPath != r.oldPath) {
          renamed++;
        } else {
          skipped++;
        }
      } else {
        errors++;
        log('  ❌ ${files[i].split('\\').last}: ${r.message}');
      }
      if ((i + 1) % 50 == 0 || i == files.length - 1) { log('  進度: ${i + 1}/$total (重新命名: $renamed)'); }
    }

    log('✅ 完成: $renamed 個重新命名, $skipped 個跳過, $errors 個錯誤');
    return {'total': total, 'renamed': renamed, 'errors': errors, 'skipped': skipped};
  }
}
