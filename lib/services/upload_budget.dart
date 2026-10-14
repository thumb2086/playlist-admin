import 'dart:convert';
import 'dart:io';

import 'config_service.dart';

/// Windows 介面層級流量（真實位元組，Windows 設定裡看到的同一份數字）。
///
/// 為什麼用這個而不是自己估算：自己 charge 會高估 27%+
/// （請求送出前就記帳，429/逾時/斷線的位元組實際一個都沒傳出去）。
/// 介面計數不會漏，缺點是含其他程式的流量——對「今天不要用超過 N GB」
/// 這種上限來說，含別人反而更安全。
class WindowsNetUsage {
  const WindowsNetUsage._();

  static bool get _isWindows => Platform.isWindows;

  /// 累計收發（bytes）。非 Windows 或取不到回 (-1, -1)。
  static (int rx, int tx) totals() {
    if (!_isWindows) return (-1, -1);
    // Get-NetAdapterStatistics：所有介面加總（實測可讀、無需管理員）
    const script =
        "Get-NetAdapterStatistics | "
        "Measure-Object -Property ReceivedBytes -Sum | "
        "ForEach-Object { \$_.Sum }; "
        "Get-NetAdapterStatistics | "
        "Measure-Object -Property SentBytes -Sum | "
        "ForEach-Object { \$_.Sum }";
    try {
      final r = Process.runSync('powershell',
          ['-NoProfile', '-NonInteractive', '-Command', script],
          stdoutEncoding: null);
      final out = (r.stdout is String
              ? r.stdout as String
              : utf8.decode((r.stdout as List<int>?) ?? const [],
                  allowMalformed: true))
          .trim();
      final lines = out
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .map((e) => int.tryParse(e) ?? -1)
          .toList();
      if (lines.length >= 2 && lines[0] >= 0 && lines[1] >= 0) {
        return (lines[0], lines[1]);
      }
    } catch (_) {}
    return (-1, -1);
  }

  /// 把介面累計值寫進 usage 檔作為基準（首次呼叫時記一次，之後算差值）。
  static int? _baselineTotal;
  static String? get _usagePath => UploadBudget._usagePathPublic;

  /// 自上次呼叫以來全機流量（bytes）。取不到回 -1。
  /// 本次執行已用的流量（bytes）。
  ///
  /// 基準 = **這個行程第一次詢問時的當前值** → 預算值就是「本次執行
  /// 的上限」，符合直覺，且不需要人工程序先跑 `budget reset`
  /// （舊版把基準寫進檔案跨行程重用，結果拿「開機累計」去比 1GB 上限，
  ///  數字早就爆了守門卻形同虛設 —— 2026-10-14 白跑 1.97GB）。
  static int consumedSinceBaseline() {
    final (rx, tx) = totals();
    if (rx < 0) return -1;
    final total = rx + tx;
    if (_baselineTotal == null) {
      _baselineTotal = total;
      try {
        File(_usagePath ?? '').writeAsStringSync(jsonEncode({
          'net_baseline': _baselineTotal,
          'baseline_at': DateTime.now().toIso8601String(),
        }));
      } catch (_) {}
      return 0;
    }
    final d = total - _baselineTotal!;
    return d < 0 ? 0 : d; // 重開機/介面重置 → 歸零
  }

  static void setBaseline(int total) {
    _baselineTotal = total;
    try {
      final f = File(_usagePath ?? '');
      final prev = f.existsSync()
          ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      prev['net_baseline'] = total;
      prev['net_baseline_at'] = DateTime.now().toIso8601String();
      f.writeAsStringSync(jsonEncode(prev));
    } catch (_) {}
  }

  static void resetBaseline() {
    _baselineTotal = null;
    try {
      final f = File(_usagePath ?? '');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// 上傳流量預算守門員（Groq STT）。
///
/// 為什麼需要：逐字稿全庫重抓會上傳 11.9GB 音檔，扣的是使用者行動/家用
/// 頻寬與 Groq 額度。用戶要求「不要超過 12GB 硬上限」。
///
/// 規則：
/// - 預算從環境變數 `PA_UPLOAD_BUDGET_MB` 讀（0 或未設 = 不限）
/// - 累計計入**每次嘗試**（含重試）——重試會再上一次傳，瞞報等於沒上限
/// - 用量寫在 `cache/groq_upload_usage.json`，跨行程累積（分批跑不會重算）
/// - 超額時丟 `UploadBudgetExceeded`，呼叫端應視為「跳過」而非「失敗」
class UploadBudget {
  UploadBudget._();

  static const _envKey = 'PA_UPLOAD_BUDGET_MB';
  static const _usageFile = 'upload_usage.json';

  static int? _limitBytes;
  static int _usedBytes = -1;

  /// 預算上限（bytes）。null = 不限。
  static int? get limitBytes {
    if (_limitBytes == null) {
      final mb = int.tryParse(Platform.environment[_envKey] ?? '') ?? 0;
      _limitBytes = mb > 0 ? mb * 1024 * 1024 : null;
    }
    return _limitBytes;
  }

  static bool get hasLimit => limitBytes != null;

  /// usage 檔路徑（給 WindowsNetUsage 共用）。
  static String? get _usagePathPublic {
    final p = _usagePath;
    return p.path;
  }

  static File get _usagePath {
    final base = ConfigService.instance.config.basePath;
    // basePath 可能被換（測試/多資料夾）→ 快取路徑
    final key = '$base|$_usageFile';
    if (_path == key && _cachedFile != null) return _cachedFile!;
    final dir = Directory(
        '$base${Platform.pathSeparator}cache${Platform.pathSeparator}groq');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _path = key;
    _cachedFile = File('${dir.path}${Platform.pathSeparator}$_usageFile');
    return _cachedFile!;
  }

  static File? _cachedFile;
  /// usage 檔路徑的快取鍵（basePath 換了就失效重算）
  static String? _path;

  /// 跨行程累計用量（bytes）。
  static int get usedBytes {
    if (_usedBytes >= 0) return _usedBytes;
    try {
      final f = _usagePath;
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        _usedBytes = (j['bytes'] as num?)?.toInt() ?? 0;
      } else {
        _usedBytes = 0;
      }
    } catch (_) {
      _usedBytes = 0;
    }
    return _usedBytes;
  }

  static int get remainingBytes {
    final lim = limitBytes;
    if (lim == null) return 1 << 62;
    final r = lim - usedBytes;
    return r < 0 ? 0 : r;
  }

  /// 預留 n bytes；超過預算丟 [UploadBudgetExceeded]，否則記帳並放行。
  ///
  /// 判定以 **Windows 介面層級實測值**為準（`netUsedBytes`），
  /// 不用自己累加：自己 charge 會高估 27%+（429/逾時/斷線的位元組
  /// 實際一個都沒傳出去卻被記了帳）。取不到 Windows 數值時才退回 charge。
  static void charge(int n, {String kind = 'up'}) {
    if (n <= 0) return;
    final lim = limitBytes;
    if (lim == null) return;

    // 1) 優先用 Windows 實測流量（真實、可與設定畫面對照）
    final net = WindowsNetUsage.consumedSinceBaseline();
    if (net >= 0) {
      _netUsed = net;
      if (net > lim) {
        throw UploadBudgetExceeded(
          '流量已達上限：${(net / 1048576).toStringAsFixed(0)} MB'
          ' / ${(lim / 1048576).toStringAsFixed(0)} MB（Windows 實測值）',
        );
      }
      _saveNet(net, lim);
      return;
    }
    // 2) 取不到 → 退回自己估算
    if (usedBytes + n > lim) {
      throw UploadBudgetExceeded(
        '流量預算用盡（估算）：已用 '
        '${(usedBytes / 1048576).toStringAsFixed(0)} MB'
        ' / ${(lim / 1048576).toStringAsFixed(0)} MB',
      );
    }
    _usedBytes = usedBytes + n;
  }

  static int _netUsed = 0;

  /// 依 Windows 實測值顯示。
  static int get netUsedBytes {
    final d = WindowsNetUsage.consumedSinceBaseline();
    if (d >= 0) _netUsed = d;
    return _netUsed;
  }

  static void _saveNet(int net, int lim) {
    try {
      _usagePath.writeAsStringSync(jsonEncode({
        'net_bytes': net,
        'limit_mb': lim ~/ 1048576,
        'source': 'windows_adapter',
        'updated': DateTime.now().toIso8601String(),
      }));
    } catch (_) {}
  }

  static void reset() {
    _usedBytes = 0;
    _netUsed = 0;
    WindowsNetUsage.resetBaseline();
    try {
      final f = _usagePath;
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 設定「今日基準」＝現在的介面累計值，之後 todayBytes 就是今日用量。
  /// Windows 只提供「開機累計」（Get-NetAdapterStatistics），
  /// 要算「今天用了多少」必須自己記一個起點。
  ///
  /// 用法：每天（或重開機後）跑一次 `playlist-admin budget reset`。
  /// 以後的流量判定都以此為基準線做差值。
  static void markTodayBaseline() {
    final (rx, tx) = WindowsNetUsage.totals();
    if (rx < 0) return;
    WindowsNetUsage.setBaseline(rx + tx);
    _netUsed = 0;
    final lim = limitBytes;
    if (lim != null) _saveNet(0, lim);
  }

  /// 今日用量（bytes）＝ 介面累計 − 今日基準。
  static int get todayBytes => WindowsNetUsage.consumedSinceBaseline();

  /// 今日用量（顯示用）。
  static String todayText() {
    final b = todayBytes;
    if (b < 0) return '今日用量：無法讀取';
    return '今日用量：${(b / 1073741824.0).toStringAsFixed(2)} GB';
  }

  static String describe() {
    final lim = limitBytes;
    if (lim == null) return '流量：無限制（設 PA_UPLOAD_BUDGET_MB 才會擋）';
    final net = netUsedBytes;
    if (net >= 0) {
      return '流量：${(net / 1048576).toStringAsFixed(0)}'
          ' / ${(lim / 1048576).toStringAsFixed(0)} MB（Windows 實測）';
    }
    return '流量：${(usedBytes / 1048576).toStringAsFixed(0)}'
        ' / ${(lim / 1048576).toStringAsFixed(0)} MB（估算，取不到 Windows 值）';
  }
}

/// 上傳預算用盡（呼叫端應跳過，不要當錯誤重試）。
class UploadBudgetExceeded implements Exception {
  final String message;
  UploadBudgetExceeded(this.message);
  @override
  String toString() => message;
}