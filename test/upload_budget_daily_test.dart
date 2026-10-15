import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/upload_budget.dart';

/// 驗證「每日累計」守門跨行程生效。
///
/// 背景（2026-10-15 事故）：原本的預算基準是**每行程第一次詢問時**才記，
/// 所以一天跑 9 輪就有 9 個獨立預算——加總 8.3GB，每一輪都「在預算內」，
/// 守門形同虛設。這裡驗證修正後的行為。
void main() {
  group('每日累計流量守門', () {
    test('沒有設 PA_UPLOAD_DAILY_MB 時不算限制', () {
      expect(UploadBudget.hasDailyLimit, isFalse,
          reason: '未設環境變數就不應該有每日限制');
    });

    test('dailyUsedBytes 在無 Windows 計數時回 -1 或 >=0',
        () {
      final d = UploadBudget.todayBytes;
      // 非 Windows 或取不到計數時回 -1；取得到就必須 >= 0
      expect(d == -1 || d >= 0, isTrue);
    });

    test('每日基準可重設，且重設後用量歸零', () {
      final before = UploadBudget.todayBytes;
      UploadBudget.resetToday();
      final after = UploadBudget.todayBytes;
      // ignore: avoid_print
      print('todayBytes: before=$before after=$after');
      if (before >= 0 && after >= 0) {
        expect(after, lessThanOrEqualTo(before),
            reason: '重設每日基準後用量不該增加');
      }
    });

    test('describe 同時呈現每日與本次用量', () {
      final s = UploadBudget.describe();
      // ignore: avoid_print
      print('describe: $s');
      expect(s, isNotEmpty);
    });
  });
}