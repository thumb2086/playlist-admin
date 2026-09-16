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
      // Load cached nuances from session file.
      final nuData = data['nuances'] as Map<String, dynamic>?;
      if (nuData != null) {
        _nuancesCache = {for (final e in nuData.entries) int.parse(e.key): e.value as String};
      }
      if (_spDc == null || _spDc!.isEmpty) return;
      if (_tokenExpiryMs - DateTime.now().millisecondsSinceEpoch <
          const Duration(minutes: 5).inMilliseconds) {
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

  Future<void> refreshToken() async {
    final dc = _spDc;
    if (dc == null || dc.isEmpty) return;
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
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _accessToken = data['accessToken'] as String?;
      _tokenExpiryMs =
          (data['accessTokenExpirationTimestampMs'] as num?)?.toInt() ?? 0;
      _save();
      _scheduleRefresh();
      notifyListeners();
    } catch (_) {}
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final remainMs = _tokenExpiryMs - DateTime.now().millisecondsSinceEpoch;
    if (remainMs <= 0) return;
    // remain<60s 時 Duration 會是負值直接拋 ArgumentError：clamp 保底。
    final delayMs = (remainMs - 60000).clamp(0, remainMs);
    _refreshTimer = Timer(Duration(milliseconds: delayMs), refreshToken);
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
        final list = jsonDecode(resp.body) as List<dynamic>;
        _nuancesCache = {
          for (final e in list.cast<Map<String, dynamic>>())
            (e['v'] as num).toInt(): e['s'] as String,
        };
        _save();
        return _nuancesCache!;
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