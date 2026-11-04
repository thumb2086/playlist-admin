import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../services/config_service.dart';

class SpotifyOAuthService {
  SpotifyOAuthService._();
  static final instance = SpotifyOAuthService._();

  static const _scopes = 'user-read-private user-read-email user-library-read '
      'user-library-modify playlist-read-private playlist-read-collaborative '
      'user-follow-read user-top-read';

  HttpServer? _server;
  int _port = 0;
  String? _clientId;
  String? _accessToken;
  String? _refreshToken;
  int _expiryMs = 0;
  Completer<Map<String, String>>? _pendingCompleter;

  bool get isConfigured => (_clientId ?? '').isNotEmpty;
  bool get isLoggedIn =>
      (_accessToken ?? '').isNotEmpty && _expiryMs > DateTime.now().millisecondsSinceEpoch;

  String get _path => '${ConfigService.instance.config.cachePath}\\spotify\\spotify_oauth.json';

  Future<void> load() async {
    try {
      final f = File(_path);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _clientId = data['client_id'] as String?;
      _accessToken = data['access_token'] as String?;
      _refreshToken = data['refresh_token'] as String?;
      _expiryMs = (data['expiry_ms'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  Future<void> setClientId(String id) async {
    _clientId = id.trim();
    await _save();
  }

  Future<String?> _ensurePort() async {
    if (_server != null) return 'http://127.0.0.1:$_port/callback';
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _server!.listen(_onRequest);
      return 'http://127.0.0.1:$_port/callback';
    } catch (_) {
      return null;
    }
  }

  void _onRequest(HttpRequest req) {
    if (req.uri.path != '/callback') {
      req.response.statusCode = 404;
      req.response.close();
      return;
    }
    final code = req.uri.queryParameters['code'] ?? '';
    final state = req.uri.queryParameters['state'] ?? '';
    req.response.headers.contentType = ContentType.html;
    req.response.write('<html><body><h2>OK, return to playlist-admin.</h2></body></html>');
    req.response.close();
    if (code.isNotEmpty && state.isNotEmpty && _pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete({'code': code, 'state': state});
    }
  }

  Future<bool> login() async {
    final cid = _clientId;
    if (cid == null || cid.isEmpty) {
      throw StateError('請先設定 Spotify Client ID（Developer Dashboard -> Create app）');
    }
    final redirect = await _ensurePort();
    if (redirect == null) return false;

    final verifier = _randomString(64);
    final challenge = _base64Url(sha256.convert(verifier.codeUnits).bytes);
    final state = _randomString(16);
    _pendingCompleter = Completer<Map<String, String>>();

    final authUri = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': cid,
      'response_type': 'code',
      'redirect_uri': redirect,
      'scope': _scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    try {
      await Process.start('cmd', ['/c', 'start', '', authUri.toString()]);
    } catch (_) {}

    Map<String, String>? result;
    try {
      result = await _pendingCompleter!.future.timeout(const Duration(minutes: 3));
    } catch (_) {
      return false;
    }
    if (result['state'] != state) return false;
    return _exchangeToken(result['code']!, redirect, verifier);
  }

  Future<bool> _exchangeToken(String code, String redirect, String verifier) async {
    final cid = _clientId;
    if (cid == null || cid.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirect,
          'client_id': cid,
          'code_verifier': verifier,
        }.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'),
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String?;
      _refreshToken = data['refresh_token'] as String? ?? _refreshToken;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;
      _expiryMs = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
      await _save();
      return _accessToken != null;
    } catch (_) {
      return false;
    }
  }

  Future<String?> accessToken() async {
    if ((_accessToken ?? '').isEmpty) await load();
    if ((_accessToken ?? '').isEmpty) return null;
    if (_expiryMs - DateTime.now().millisecondsSinceEpoch < 60000 && _refreshToken != null) {
      await _refresh();
    }
    return _accessToken;
  }

  Future<bool> _refresh() async {
    final cid = _clientId;
    final rt = _refreshToken;
    if (cid == null || cid.isEmpty || rt == null || rt.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': rt,
          'client_id': cid,
        }.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'),
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String? ?? _accessToken;
      if (data['refresh_token'] is String) _refreshToken = data['refresh_token'] as String;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;
      _expiryMs = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
      await _save();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _save() async {
    try {
      final f = File(_path);
      f.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'client_id': _clientId,
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'expiry_ms': _expiryMs,
      }));
    } catch (_) {}
  }

  void disposeServer() {
    _server?.close(force: true);
    _server = null;
  }

  static String _randomString(int len) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final rnd = Random.secure();
    return String.fromCharCodes(List.generate(len, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }

  static String _base64Url(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
