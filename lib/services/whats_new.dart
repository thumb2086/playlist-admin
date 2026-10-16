import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../version.dart';
import 'config_service.dart';

/// 首次啟動新版本時顯示一次「這次更新了什麼」。
///
/// 為什麼需要：v2.15.53~72 一天內發了 20 個版本，全部是修「逐字稿看起來
/// 成功但內容是壞的」這類問題——使用者從介面上完全看不出差別，
/// 只有版本說明才知道程式改了什麼。
///
/// 每個版本只跳一次：把看過的版本號記在 cache/whats_new.json，
/// 下次啟動若版本相同就不再跳。
class WhatsNew {
  WhatsNew._();

  /// 版本 → 更新重點（依序顯示）。
  ///
  /// 新增版本的寫法：在最前面加一條，並把 [latest] 的值一起更新。
  static const Map<String, List<String>> notes = {
    '2.15.73': [
      '__H__新增：更新說明',
      '每次更新後第一次開啟程式，會跳出這個視窗告訴你這次改了什麼。'
          '每個版本只跳一次，之後啟動不再顯示。',
      '要新增說明：在 whats_new.dart 的 notes 最前面加一筆即可。',
    ],
    '2.15.72': [
      '__H__修正：每次 pipeline 都重複下載已存在的歌',
      'Windows 檔名非法字元（/ * : 等）落盤時會被替換，但比對「已有歌曲」'
          '時沒做同樣的替換，導致永遠匹配不上、每次都重抓。',
      '修正後：需下載數量從 9 首降到 3 首（那 6 首本來就存在）。',
    ],
    '2.15.71': [
      '__H__修正：空白歌名讓 yt-dlp 收到無效的 ytsearch1 查詢',
      'Spotify 偶爾給沒有標題的項目，會產生 '
          '"Unsupported url scheme: ytsearch1" 的莫名錯誤。',
    ],
    '2.15.70': [
      '__H__修正：yt-dlp 失敗訊息被「更新檢查」警告蓋掉',
      '你會看到「To suppress this warning…」這種沒有意義的訊息，'
          '真正的錯誤（例如 403 Forbidden）被藏起來了。',
    ],
    '2.15.69': [
      '__H__CLI 補上標準指令',
      'playlist-admin -v 現在會同時顯示 CLI 與 GUI 版本，並在不一致時提醒。'
          '另新增 -h / --help / update / where。',
    ],
    '2.15.68': [
      '__H__新增：音訊庫健康檢查（CLI doctor + 設定頁按鈕）',
      '用獨立標準驗證：逐字稿覆蓋率、音檔能否完整解碼、'
          '內容密度（字數 ÷ 片長）、語言是否被自動翻譯。',
      '修正：npm CLI 不再需要手動設定 PA_ROOT。',
    ],
    '2.15.67': [
      '__H__新增：doctor 命令（音訊庫健康檢查）',
      '一條指令驗整個庫，不用再寫臨時腳本。'
          '--fast 模式約 1 秒掃完 1899 個檔。',
    ],
  };

  static String get _current => appVersion.startsWith('v')
      ? appVersion.substring(1)
      : appVersion;

  static File get _store {
    final base = ConfigService.instance.config.basePath;
    final dir = Directory(
        '$base${Platform.pathSeparator}cache${Platform.pathSeparator}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}whats_new.json');
  }

  /// 讀出上次看過的版本號（沒有則回 null）。
  static String? _lastSeen() {
    try {
      final f = _store;
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return j['last_seen'] as String?;
    } catch (_) {
      return null;
    }
  }

  static void _markSeen(String v) {
    try {
      _store.writeAsStringSync(jsonEncode({'last_seen': v, 'at': DateTime.now().toIso8601String()}));
    } catch (_) {}
  }

  /// 判斷要不要顯示，並順便記錄「已看過」。
  ///
  /// 規則：
  /// - 版本必須比上次看過的新（字串比大小寫無關的數字序）
  /// - 該版本要有 [notes] 才有東西可顯示
  /// - 開發版（-dev）不跳，避免自己改一版就被提醒
  static String? pendingNotes() {
    final cur = _current;
    if (cur.contains('-dev')) return null;

    final notesForCur = notes[cur];
    if (notesForCur == null || notesForCur.isEmpty) {
      // 沒有更新說明也要記錄，否則每次啟動都會重新比對舊版本
      final last = _lastSeen();
      if (last == null || _cmp(cur, last) > 0) _markSeen(cur);
      return null;
    }

    final last = _lastSeen();
    if (last != null && _cmp(cur, last) <= 0) return null;
    _markSeen(cur);
    return cur;
  }

  /// 純數字序比較（忽略非數字前綴，例如 v2.15.72）。
  static int _cmp(String a, String b) {
    int val(String s) {
      final m = RegExp(r'(\d+)').allMatches(s).map((e) => int.parse(e.group(1)!));
      final parts = m.take(3).toList();
      while (parts.length < 3) {
        parts.add(0);
      }
      return parts[0] * 1000000 + parts[1] * 1000 + parts[2];
    }

    final d = val(a) - val(b);
    return d == 0 ? a.compareTo(b) : d;
  }

  /// 在首個 frame 之後呼叫，避免在 build 期間操作 context。
  static void schedule(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => show(context));
  }

  /// 顯示更新說明對話框。
  static Future<void> show(BuildContext context) async {
    final version = pendingNotes();
    if (version == null) return;
    final items = notes[version] ?? const <String>[];

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.auto_awesome, size: 32),
        title: Text('已更新到 v$version'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in items) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 3, right: 8),
                          child: Icon(Icons.circle, size: 7),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (t.startsWith('__H__'))
                                Text(t.substring(4),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold))
                              else
                                Text(t),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}