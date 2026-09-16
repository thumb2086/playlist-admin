import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/config_model.dart';
import 'app_data_dir.dart';

class ConfigService extends ChangeNotifier {
  ConfigService._();
  static final ConfigService instance = ConfigService._();

  late AppConfig config;
  String? _configPath;

  String get _appDataDir => AppDataDir.dir;

  /// 平台路徑拼接：舊寫法硬編碼 \\，Android/iOS 會變成檔名含反斜線。
  static String _join(String a, String b) =>
      a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

  Future<void> load() async {
    await AppDataDir.ensureMigrated();
    final localDir = Directory(_appDataDir);
    final localFile = File(_join(localDir.path, 'config.json'));

    if (await localFile.exists()) {
      try {
        final data = jsonDecode(await localFile.readAsString()) as Map<String, dynamic>;
        final basePath = data['base_path'] as String?;
        if (basePath != null && basePath.isNotEmpty) {
          final mainFile = File(_join(basePath, 'config.json'));
          if (await mainFile.exists()) {
            _configPath = mainFile.path;
            config = AppConfig.fromJson(jsonDecode(await mainFile.readAsString()) as Map<String, dynamic>);
            config.basePath = basePath;
            return;
          }
        }
      } catch (e) {
        debugPrint('[ConfigService] 載入設定失敗: $e');
      }
    }

    config = AppConfig();
    _configPath = null;
    notifyListeners();
  }

  Future<void> save() async {
    final cfg = config;
    final basePath = cfg.basePath;

    // Ensure spotify_urls is synchronized from urlNames keys
    final urlList = cfg.urlNames.keys.toList();
    final json = cfg.toJson();
    json['spotify_urls'] = urlList;

    String savePath;
    if (_configPath != null) {
      savePath = _configPath!;
    } else if (basePath.isNotEmpty) {
      await Directory(basePath).create(recursive: true);
      savePath = _join(basePath, 'config.json');
      _configPath = savePath;

      final pointerDir = Directory(_appDataDir);
      await pointerDir.create(recursive: true);
      final pointerFile = File(_join(pointerDir.path, 'config.json'));
      await pointerFile.writeAsString(jsonEncode({
        'base_path': basePath,
        'language': cfg.language,
      }));
    } else {
      return;
    }

    // File lock to prevent concurrent writes from Python pipeline
    final lockFile = File('$savePath.lock');
    for (int i = 0; i < 100; i++) {  // wait up to ~10s
      if (!await lockFile.exists()) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (await lockFile.exists()) {
      // Stale lock: break it
      try { await lockFile.delete(); } catch (_) {}
    }
    try {
      await lockFile.writeAsString('');
      await File(savePath).writeAsString(jsonEncode(json));
    } finally {
      try { await lockFile.delete(); } catch (_) {}
    }
    notifyListeners();
  }
}
