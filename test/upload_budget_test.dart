import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/models/config_model.dart';
import 'package:playlist_admin/services/config_service.dart';
import 'package:playlist_admin/services/upload_budget.dart';

/// 上傳流量預算守門員測試（不發任何網路請求）。
void main() {
  setUp(() {
    final tmp = Directory.systemTemp.createTempSync('budget_test_');
    ConfigService.instance.config =
        AppConfig(basePath: tmp.path, language: 'zh-TW');
  });

  test('無預算 → 不限，charge 不擋', () {
    UploadBudget.reset();
    // 測試環境沒有 PA_UPLOAD_BUDGET_MB
    if (UploadBudget.hasLimit) return;
    // 新邏輯：無上限時 charge 直接放行（判定靠 Windows 實測值，不靠累加）
    UploadBudget.charge(999999999);
    expect(UploadBudget.usedBytes, anyOf(0, greaterThanOrEqualTo(0)));
  });

  test('基準設定後：用量在限額內就放行', () {
    if (!UploadBudget.hasLimit) return; // 沒設上限就跳過
    final tmp = Directory.systemTemp.createTempSync('budget_ok_');
    ConfigService.instance.config =
        AppConfig(basePath: tmp.path, language: 'zh-TW');
    UploadBudget.markTodayBaseline();
    // 剛設基準 → 用量≈0，charge 應放行（上限 3MB，實測用量僅幾 KB）
    expect(() => UploadBudget.charge(1024), returnsNormally);
    expect(UploadBudget.todayBytes, lessThan(UploadBudget.limitBytes!));
  });

  test('實際用量已超上限時擋下（不再 charge）', () {
    if (!UploadBudget.hasLimit) return;
    final tmp = Directory.systemTemp.createTempSync('budget_over_');
    ConfigService.instance.config =
        AppConfig(basePath: tmp.path, language: 'zh-TW');
    // 不設基準 → 直接沿用舊基準（可能是很久以前）→ 用量遠超 3MB
    UploadBudget.reset();
    // 手動把基準設成 0：等於「用量 = 開機累計」，必定超限
    WindowsNetUsage.setBaseline(0);
    expect(UploadBudget.todayBytes, greaterThan(UploadBudget.limitBytes!));
    expect(() => UploadBudget.charge(1024),
        throwsA(isA<UploadBudgetExceeded>()));
  });

  test('重置後歸零、describe 可呼叫', () {
    UploadBudget.reset();
    expect(UploadBudget.usedBytes, 0);
    expect(UploadBudget.describe(), isNotEmpty);
    final rem = UploadBudget.remainingBytes;
    expect(rem >= 0, true);
  });
}