import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'config_service.dart';

/// Spotify session: derives a web-player access token from the sp_dc cookie
/// (the same flow the spotube-plugin-spotify uses):
///   1. read TOTP secret from the public "nuances" gist
///   2. get server time
///   3. compute TOTP (RFC 6238, SHA1, Base32, 30s period)
///   4. GET open.spotify.com/api/token with Cookie: sp_dc=...
/// Cookies are captured from a WebView2 login (see SpotifyLoginDialog).
class SpotifySession extends ChangeNotifier {
  static SpotifySession? _instance;
  static SpotifySession get instance => _instance ??= SpotifySession._();
  SpotifySession._();

  static const _nuancesUrl =
      'https://gist.githubusercontent.com/raw/22ed9c6ba463899e933427f7de1f0eef/nuances.json';

  String? _spDc;
  String? _spT;
  String? _accessToken;
  int _tokenExpiryMs = 0;
  Timer? _refreshTimer;

  bool get isLoggedIn => _spDc != null && _spDc!.isNotEmpty;
  bool get hasToken => _accessToken != null;

  String? get accessToken => _accessToken;
  String? get spT => _spT;
  String? get spDc => _spDc;

  static String get _sessionPath =>
      '${ConfigService.instance.config.cachePath}\\spotify\\session.json';

  Future<void> load() async {
    try {
      final f = File(_sessionPath);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _spDc = data['sp_dc'] as String?;
      _spT = data['sp_t'] as String?;
      _accessToken = data['access_token'] as String?;
      _tokenExpiryMs = (data['expiry_ms'] as num?)?.toInt() ?? 0;
      // Load cached nuances from session file（int key 化，容忍髒值）。
      final nuRaw = data['nuances'];
      if (nuRaw is Map) {
        _nuancesCache = {
          for (final e in nuRaw.entries)
            if (int.tryParse(e.key.toString()) != null)
              int.parse(e.key.toString()): e.value.toString(),
        };
        if (_nuancesCache!.isEmpty) _nuancesCache = null;
      }
      if (_spDc == null || _spDc!.isEmpty) return;
      // 已過期或快過期（<10 分鐘）就立刻續；否則排定時續期。
      if (_tokenExpiryMs - DateTime.now().millisecondsSinceEpoch <
          const Duration(minutes: 10).inMilliseconds) {
        await refreshToken();
      } else {
        _scheduleRefresh();
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Called from the login dialog with the cookies captured from the webview.
  Future<void> setCookies({required String spDc, String? spT}) async {
    _spDc = spDc;
    _spT = spT;
    await refreshToken();
    _save();
    notifyListeners();
  }

  void logout() {
    _refreshTimer?.cancel();
    _spDc = null;
    _spT = null;
    _accessToken = null;
    _tokenExpiryMs = 0;
    try {
      final f = File(_sessionPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    notifyListeners();
  }

  /// 續 token（sp_dc → TOTP → open.spotify.com/api/token）。
  /// 回傳是否成功；失敗會指明原因，方便 UI 提示「需重登」。
  Future<bool> refreshToken() async {
    final dc = _spDc;
    if (dc == null || dc.isEmpty) {
      _lastError = '尚未登入（沒有 sp_dc cookie）';
      return false;
    }
    try {
      final nuances = await _fetchNuances();
      final version = nuances.keys.reduce(max);
      final secret = nuances[version]!;
      final serverTime = await _fetchServerTime();
      final otp = _generateTotp(secret, serverTime);

      final uri = Uri.parse(
          'https://open.spotify.com/api/token?reason=transport&productType=web-player'
          '&totp=$otp&totpServer=$otp&totpVer=$version');
      final resp = await http.get(uri, headers: {
        'User-Agent': '${DateTime.now().millisecondsSinceEpoch}'
            '${Random().nextInt(100000) * 1000}'
            '${_randomHex(16)}',
        'Cookie': 'sp_dc=$dc;',
      }).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        // 400 = sp_dc 被 Spotify 淘汰（重登也救不了，要走完整登入流程）。
        _lastError = resp.statusCode == 400
            ? 'sp_dc 已失效（HTTP 400），需重新登入 Spotify'
            : '續期失敗 HTTP ${resp.statusCode}';
        return false;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final token = data['accessToken'] as String?;
      final expiry =
          (data['accessTokenExpirationTimestampMs'] as num?)?.toInt() ?? 0;
      if (token == null || token.isEmpty || expiry <= 0) {
        _lastError = '續期回應缺少 token/expiry';
        return false;
      }
      _accessToken = token;
      _tokenExpiryMs = expiry;
      _lastError = null;
      _refreshFails = 0;
      _save();
      _scheduleRefresh();
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = '續期例外: $e';
      return false;
    }
  }

  /// 上次續期失敗原因（null = 正常）。UI 可顯示「需重登」提示。
  String? _lastError;
  String? get lastError => _lastError;

  /// 續期連續失敗次數。
  int _refreshFails = 0;
  int get refreshFails => _refreshFails;

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final remainMs = _tokenExpiryMs - DateTime.now().millisecondsSinceEpoch;
    if (remainMs <= 0) {
      // 已過期：短延遲重試（下次續期成功就恢復正常節奏）。
      _refreshTimer = Timer(const Duration(seconds: 30), () async {
        final ok = await refreshToken();
        if (!ok) {
          _refreshFails++;
          // 連續失敗別無限重試轟 API：拉長到 5 分鐘一次。
          _refreshTimer = Timer(
              const Duration(minutes: 5), () => refreshToken());
        }
      });
      return;
    }
    // remain<60s 時 Duration 會是負值直接拋 ArgumentError：clamp 保底。
    final delayMs = (remainMs - 120000).clamp(0, remainMs);
    _refreshTimer = Timer(Duration(milliseconds: delayMs), () async {
      final ok = await refreshToken();
      if (!ok) {
        _refreshFails++;
        // 續期失敗：2 分鐘後再試（短暫 5xx/網路抖動通常就好了）。
        _refreshTimer =
            Timer(const Duration(minutes: 2), () => refreshToken());
      }
    });
  }

  void _save() {
    try {
      final f = File(_sessionPath);
      f.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'sp_dc': _spDc,
        'sp_t': _spT,
        'access_token': _accessToken,
        'expiry_ms': _tokenExpiryMs,
        'nuances': _nuancesCache?.map((k, v) => MapEntry(k.toString(), v)),
      }));
    } catch (_) {}
  }

  Future<Map<int, String>> _fetchNuances() async {
    // Try cached first (avoids GitHub rate limits).
    if (_nuancesCache != null && _nuancesCache!.isNotEmpty) return _nuancesCache!;
    try {
      final resp = await http.get(Uri.parse(_nuancesUrl))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        // 格式會變：舊版 {version: secret}，新版 [{v: version, s: secret}]。
        // 兩種都吃，否則 gist 一改格式整條續期鏈就死。
        if (decoded is List) {
          _nuancesCache = {
            for (final e in decoded.cast<Map<String, dynamic>>())
              if (e['v'] is num && e['s'] is String)
                (e['v'] as num).toInt(): e['s'] as String,
          };
        } else if (decoded is Map) {
          _nuancesCache = {
            for (final e in decoded.entries)
              if (int.tryParse(e.key.toString()) != null)
                int.parse(e.key.toString()): e.value.toString(),
          };
        }
        if (_nuancesCache == null || _nuancesCache!.isEmpty) {
          _nuancesCache = null;
        } else {
          _save();
          return _nuancesCache!;
        }
      }
    } catch (_) {}
    // Fallback: try loading from session file cache.
    if (_nuancesCache != null && _nuancesCache!.isNotEmpty) return _nuancesCache!;
    throw Exception('nuances unavailable');
  }

  Map<int, String>? _nuancesCache;

  Future<int> _fetchServerTime() async {
    final resp = await http.get(Uri.parse('https://open.spotify.com/api/server-time'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) throw Exception('server-time ${resp.statusCode}');
    return (jsonDecode(resp.body)['serverTime'] as num).toInt();
  }

  /// RFC 6238 TOTP: SHA1, Base32 key, 6 digits, 30s period.
  String _generateTotp(String base32Secret, int serverTime) {
    final key = _base32Decode(base32Secret);
    final counter = (serverTime ~/ 30).toRadixString(16).padLeft(16, '0');
    final msg = List<int>.generate(8, (i) {
      final idx = i * 2;
      return int.parse(counter.substring(idx, idx + 2), radix: 16);
    });
    final hmac = Hmac(sha1, key).convert(msg).bytes;
    final offset = hmac.last & 0x0f;
    final bin = ((hmac[offset] & 0x7f) << 24) |
        ((hmac[offset + 1] & 0xff) << 16) |
        ((hmac[offset + 2] & 0xff) << 8) |
        (hmac[offset + 3] & 0xff);
    return (bin % 1000000).toString().padLeft(6, '0');
  }

  List<int> _base32Decode(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var bits = '';
    for (final c in input.toUpperCase().split('')) {
      final v = alphabet.indexOf(c);
      if (v < 0) continue;
      bits += v.toRadixString(2).padLeft(5, '0');
    }
    final bytes = <int>[];
    for (var i = 0; i + 8 <= bits.length; i += 8) {
      bytes.add(int.parse(bits.substring(i, i + 8), radix: 2));
    }
    return bytes;
  }

  String _randomHex(int bytes) {
    final rnd = Random();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}