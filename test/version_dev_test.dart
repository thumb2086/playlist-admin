import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/version_checker.dart';

/// 開發版偵測回歸：flutter test 預設不帶 --dart-define，
/// appVersion = '0.0.0-dev'，必須被認成開發版（自動更新檢查會跳過）。
void main() {
  test('預設版本是開發版（不帶 dart-define）', () {
    expect(VersionChecker.isDevBuild, true);
    expect(VersionChecker.currentVersion, 'v0.0.0-dev');
  });
}
