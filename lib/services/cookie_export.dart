import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// YouTube 登入 cookie 的匯出與檢查。
///
/// ## 為什麼不能用 yt-dlp --cookies-from-browser
///
/// Chrome 127 起改用 App-Bound Encryption：cookie 用一個綁定
/// Chrome.exe 路徑的金鑰加密，**外部程式即使拿到 cookie 資料庫也解不開**。
/// 實測（2026-10-16）`yt-dlp --cookies-from-browser chrome` 回
/// `Failed to decrypt with DPAPI`，Edge 同樣失敗。
///
/// ## 為什麼這裡用 DevTools Protocol
///
/// CDP 是 Chrome 自己的除錯介面，**執行在瀏覽器行程內部**，
/// 所以拿得到 cookie 明文。這條路可以在程式裡完全自動完成，
/// 不需要使用者裝擴充或手動複製貼上。
///
/// ## 流程
///
/// 1. 檢查/關閉既有 Chrome（cookie 檔被鎖住時 CDP 也拿不到）
/// 2. 以 `--remote-debugging-port` 啟動 Chrome（使用者的原有設定不動）
/// 3. 連 CDP → `Storage.getCookies` → 篩 `.youtube.com`
/// 4. 寫成 Netscape 格式到 yt_cookies.txt
/// 5. 驗證有沒有登入身份（LOGIN_INFO / SAPISID / SID…）
class CookieExport {
  CookieExport._();

  static const _authCookies = {
    'LOGIN_INFO', 'SAPISID', 'APISID', 'SID', 'HSID', 'SSID', 'SIDCC',
    '__Secure-1PSID', '__Secure-3PSID',
    '__Secure-1PAPISID', '__Secure-3PAPISID',
    '__Secure-1PSIDTS', '__Secure-3PSIDTS',
  };

  static const _debugPort = 9222;

  /// cookie 檔位置（依序找第一個既有檔案的下載目錄）。
  static String? existingCookiePath() {
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isEmpty) return null;
    for (final p in [
      '$home\\Desktop\\yt_cookies.txt',
      '$home\\Downloads\\yt_cookies.txt',
    ]) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static String defaultOutPath() =>
      existingCookiePath() ??
      '${Platform.environment['USERPROFILE'] ?? ''}\\Desktop\\yt_cookies.txt';

  // ── 檢查 ───────────────────────────────────────────

  /// 讀 cookie 檔，回報是否具備登入身分。
  static ({int total, int auth, List<String> missing, String? path}) inspect(
      [String? path]) {
    final p = path ?? existingCookiePath();
    if (p == null || !File(p).existsSync()) {
      return (total: 0, auth: 0, missing: _authCookies.toList(), path: null);
    }
    final names = <String>{};
    try {
      for (final line in File(p).readAsLinesSync()) {
        if (line.startsWith('#') || line.trim().isEmpty) continue;
        final f = line.split('\t');
        if (f.length >= 7) names.add(f[5]);
      }
    } catch (_) {
      return (total: 0, auth: 0, missing: _authCookies.toList(), path: p);
    }
    return (
      total: names.length,
      auth: names.where(_authCookies.contains).length,
      missing: _authCookies.difference(names).toList(),
      path: p,
    );
  }

  // ── 匯出 ───────────────────────────────────────────

  /// Chrome 是否有在跑。
  static Future<bool> chromeRunning() async =>
      (await _procNames()).any((n) => n.toLowerCase() == 'chrome.exe');

  static Future<List<String>> _procNames() async {
    // 用 tasklist 比對 ProcessInfo 可靠（Process 只能拿到自己的）
    try {
      final r = await Process.run('tasklist', ['/fo', 'csv', '/nh'],
          runInShell: true);
      final lines = (r.stdout as String).split('\n');
      return lines
          .map((l) => l.split(',').first.replaceAll('"', '').trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// CDP 是否已經在 listening。
  static Future<bool> cdpAlive() async {
    try {
      final r = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:$_debugPort/json/version'))
          .timeout(const Duration(seconds: 3));
      await r.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 取得 Chrome 執行檔路徑（沒有則回 null）。
  static String? _chromeExe() {
    final la = Platform.environment['LOCALAPPDATA'] ?? '';
    final pf = Platform.environment['ProgramFiles'] ?? 'C:\\Program Files';
    final pf86 = Platform.environment['ProgramFiles(x86)'] ?? '';
    for (final c in [
      if (la.isNotEmpty) '$la\\Google\\Chrome\\Application\\chrome.exe',
      if (pf.isNotEmpty) '$pf\\Google\\Chrome\\Application\\chrome.exe',
      if (pf86.isNotEmpty) '$pf86\\Google\\Chrome\\Application\\chrome.exe',
    ]) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 啟動 Chrome 帶除錯埠。
  static Future<bool> launchChromeWithDebugPort({String? profile}) async {
    final exe = _chromeExe();
    if (exe == null) return false;
    final args = [
      '--remote-debugging-port=$_debugPort',
      // 用獨立的使用者資料目錄，避免與既有 session 搶 cookie 資料庫
      // （同一個 profile 不能同時被兩個 Chrome 行程使用）
      if (profile != null) '--user-data-dir=$profile' else '--new-window',
      'https://www.youtube.com',
    ];
    try {
      await Process.start(exe, args,
          mode: ProcessStartMode.detached, runInShell: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 透過 CDP 取 cookie 並寫檔。
  ///
  /// 回傳 (成功, 說明)。不印 cookie 值。
  static Future<(bool, String)> export({String? outPath, int timeoutSec = 90}) async {
    final target = outPath ?? defaultOutPath();
    final backup = '$target.bak';
    try {
      if (!await cdpAlive()) {
        return (false, 'CDP 沒有在 listening（:$_debugPort）。'
            '請先關閉所有 Chrome，再執行 cookie export。');
      }

      // 1) 找一個可用的 target（有 webSocketDebuggerUrl 的）
      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$_debugPort/json'))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      final list = jsonDecode(body) as List<dynamic>;
      String? wsUrl;
      for (final t in list) {
        final m = t as Map<String, dynamic>;
        final u = m['webSocketDebuggerUrl'] as String?;
        final type = (m['type'] as String?) ?? '';
        if (u != null && type == 'page' && wsUrl == null) wsUrl = u;
      }
      if (wsUrl == null) {
        return (false, 'CDP 找不到可用的分頁（請確認 Chrome 有開 YouTube 分頁）');
      }

      // 2) WebSocket 送 Storage.getCookies
      final ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 15));
      final got = ws.first.timeout(Duration(seconds: timeoutSec));
      ws.add(jsonEncode({
        'id': 1,
        'method': 'Storage.getCookies',
        'params': <String, dynamic>{},
      }));
      final msg = await got;
      ws.close();

      final cookies = ((jsonDecode(msg as String)
              as Map<String, dynamic>)['result'] as Map<String, dynamic>?)??
          {};
      final all = (cookies['cookies'] as List<dynamic>? ?? []);
      final yt = all.where((c) {
        final d = (c as Map<String, dynamic>)['domain'] as String? ?? '';
        return d.contains('youtube.com') || d.contains('google.com');
      }).toList();

      if (yt.isEmpty) {
        return (false, 'CDP 回的 cookie 裡沒有 YouTube 的項目'
            '（請先在 Chrome 開啟並登入 YouTube）');
      }

      // 3) 寫 Netscape 格式
      final sb = StringBuffer()
        ..writeln('# Netscape HTTP Cookie File')
        ..writeln('# 由 playlist-admin cookie export 從 Chrome DevTools Protocol 匯出')
        ..writeln('# 匯出時間: ${DateTime.now().toIso8601String()}');
      for (final c in yt) {
        final m = c as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        final value = m['value'] as String? ?? '';
        final domain = m['domain'] as String? ?? '.youtube.com';
        final path = m['path'] as String? ?? '/';
        final secure = (m['secure'] as bool?) ?? false;
        final expires = (m['expires'] as num?)?.toDouble() ?? -1;
        sb.writeln([
          domain,
          domain.startsWith('.') ? 'TRUE' : 'FALSE',
          path,
          secure ? 'TRUE' : 'FALSE',
          expires < 0 ? 0 : expires.round(),
          name,
          value,
        ].join('\t'));
      }

      final f = File(target);
      if (f.existsSync()) {
        try {
          f.copySync(backup);
        } catch (_) {}
      }
      f.writeAsStringSync(sb.toString());
      f.writeAsStringSync('\n# HttpOnly flags:\n# ' +
          yt.where((c) => (c as Map<String, dynamic>)['httpOnly'] == true)
              .map((c) => (c as Map<String, dynamic>)['name'])
              .join(' '));

      final r = inspect(target);
      return (true, '已匯出 ${r.total} 個 cookie'
          '${r.auth > 0 ? "，其中 ${r.auth} 個是登入 cookie ✅" : "，但沒有登入 cookie（請先在 Chrome 登入 YouTube）"}'
          '\n檔案: $target'
          '${File(backup).existsSync() ? "\n備份: $backup" : ""}');
    } catch (e) {
      return (false, '匯出失敗: $e');
    }
  }
}