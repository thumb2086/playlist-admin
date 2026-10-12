import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/models/config_model.dart';
import 'package:playlist_admin/services/config_service.dart';
import 'package:playlist_admin/services/upload_budget.dart';

/// 驗證能讀到 Windows 介面層級的真實流量（不對外發任何請求）。
void main() {
  test('讀 Windows 介面流量', () async {
    final tmp = Directory.systemTemp.createTempSync('netuse_');
    ConfigService.instance.config =
        AppConfig(basePath: tmp.path, language: 'zh-TW');

    final (rx, tx) = WindowsNetUsage.totals();
    // ignore: avoid_print
    print('rx=$rx tx=$tx total=${rx + tx}');
    // ignore: avoid_print
    print('as GB: ${(rx + tx) / 1073741824.0}');

    UploadBudget.reset();
    // ignore: avoid_print
    print('describe (no limit): ${UploadBudget.describe()}');

    final d1 = WindowsNetUsage.consumedSinceBaseline();
    // ignore: avoid_print
    print('baseline delta1=$d1');
    await Future<void>.delayed(const Duration(seconds: 3));
    final d2 = WindowsNetUsage.consumedSinceBaseline();
    // ignore: avoid_print
    print('baseline delta2=$d2 (>= delta1: ${d2 >= d1})');

    expect(rx, greaterThanOrEqualTo(0), reason: '應讀到收發位元組');
    expect(d1, greaterThanOrEqualTo(0));
    expect(d2, greaterThanOrEqualTo(d1));
  }, timeout: const Timeout(Duration(minutes: 2)));
}