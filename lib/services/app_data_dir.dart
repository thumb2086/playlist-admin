import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// App 資料目錄統一為 `%LOCALAPPDATA%\playlist-admin\data`（Windows）。
/// 首次執行會自動把舊的 `%LOCALAPPDATA%\Playlist Administrator\data`
/// 整個複製過來（config / history / caches / state 全保留）。
///
/// 手機 / 其他平台改用系統的應用程式支援目錄（path_provider）。
class AppDataDir {
  static const _newName = 'playlist-admin';
  static const _legacyName = 'Playlist Administrator';
  static bool _migrated = false;
  static String? _resolved;

  static String get _winBase =>
      Platform.environment['LOCALAPPDATA'] ??
      '${Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default'}\\AppData\\Local';

  static String get dir {
    if (_resolved != null) return _resolved!;
    return '$_winBase\\$_newName\\data';
  }

  static String get legacyDir => '$_winBase\\$_legacyName\\data';

  /// 遷移舊資料（僅搬一次；新目錄已有東西就不動）。
  static Future<void> ensureMigrated() async {
    if (_migrated) return;
    _migrated = true;
    if (!Platform.isWindows) {
      // 手機 / Linux / macOS：用系統支援目錄。
      try {
        final sup = await getApplicationSupportDirectory();
        _resolved = '${sup.path}/$_newName/data';
      } catch (_) {}
      return;
    }
    final d = Directory(dir);
    final l = Directory(legacyDir);
    if (d.existsSync() || !l.existsSync()) return;
    try {
      await _copyTree(l, d);
    } catch (_) {}
  }

  static String _baseName(String path) {
    // Directory 的 URI 尾是 '/'，pathSegments.last 會取到空字串：
    // 用 path 切、濾掉空段，檔名/目錄名都拿得到。
    final segs = path.split(Platform.pathSeparator).where((s) => s.isNotEmpty);
    return segs.isEmpty ? path : segs.last;
  }

  static Future<void> _copyTree(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list()) {
      final target = File('${dst.path}\\${_baseName(e.path)}');
      if (e is File) {
        await e.copy(target.path);
      } else if (e is Directory) {
        await _copyTree(e, Directory('${dst.path}\\${_baseName(e.path)}'));
      }
    }
  }
}