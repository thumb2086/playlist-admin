import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'version_checker.dart';

enum UpdateState { idle, downloading, ready, error }

class UpdateService extends ChangeNotifier {
  static final UpdateService _instance = UpdateService._();
  static UpdateService get instance => _instance;
  UpdateService._();

  UpdateState state = UpdateState.idle;
  VersionInfo? info;
  double progress = 0;
  String? _savedPath;

  Future<void> startDownload(VersionInfo info) async {
    if (info.downloadUrl == null) return;
    // 10 分鐘 timer 會重複觸發：下載中/已就緒不重下。
    if (state == UpdateState.downloading || state == UpdateState.ready) {
      return;
    }
    this.info = info;
    state = UpdateState.downloading;
    progress = 0;
    notifyListeners();

    _savedPath = await VersionChecker.downloadUpdate(info.downloadUrl!,
      onProgress: (p) {
        progress = p;
        notifyListeners();
      },
    );

    if (_savedPath != null) {
      state = UpdateState.ready;
    } else {
      state = UpdateState.error;
    }
    notifyListeners();
  }

  void launchInstaller() {
    if (_savedPath != null && File(_savedPath!).existsSync()) {
      Process.start(_savedPath!, []);
      // Give the process a moment to start, then exit
      Future.delayed(const Duration(milliseconds: 500), () => exit(0));
    }
  }

  void reset() {
    state = UpdateState.idle;
    info = null;
    progress = 0;
    _savedPath = null;
    notifyListeners();
  }
}
