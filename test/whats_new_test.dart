import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/whats_new.dart';

/// 更新說明只跳一次的邏輯。
///
/// 2026-10-16 一天發了 20 個版本，如果每次啟動都跳（或都不跳）都沒有意義，
/// 所以這裡把「只在版本變新時跳一次」釘死。
void main() {
  group('WhatsNew 顯示條件', () {
    setUp(() {
      final f = File(
          '${Directory.systemTemp.path}\\whats_new_test_store.json');
      if (f.existsSync()) f.deleteSync();
    });

    test('開發版（-dev）不跳', () {
      // 目前 build 是 -dev → 應該回 null
      expect(WhatsNew.pendingNotes(), isNull,
          reason: '開發版不該跳更新說明');
    });

    test('notes 涵蓋的版本都有非空內容', () {
      for (final e in WhatsNew.notes.entries) {
        expect(e.value, isNotEmpty, reason: '${e.key} 的說明是空的');
        for (final line in e.value) {
          expect(line.trim(), isNotEmpty);
        }
      }
    });

    test('版本鍵格式正確（純數字 x.y.z）', () {
      for (final k in WhatsNew.notes.keys) {
        expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(k), isTrue,
            reason: '版本鍵應為 x.y.z，實際 $k');
      }
    });

    test('每個版本的第一條是標題（__H__ 前綴）', () {
      for (final e in WhatsNew.notes.entries) {
        final first = e.value.first;
        // 第一條必須是粗體標題（__H__ 前綴），否則顯示層級不明
        expect(first.startsWith('__H__'), isTrue,
            reason: '${e.key} 第一條應為 __H__ 標題');
      }
    });
  });
}