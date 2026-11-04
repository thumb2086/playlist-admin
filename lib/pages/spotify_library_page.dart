import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../services/spotify_oauth_service.dart';
import '../services/spotify_library_service.dart';
import '../widgets/dark_theme.dart';

/// Spotify 官方音樂庫（PKCE 驗證）— 本機歌單之外的 browse / import 入口。
class SpotifyLibraryPage extends StatefulWidget {
  const SpotifyLibraryPage({super.key});
  @override
  State<SpotifyLibraryPage> createState() => _SpotifyLibraryPageState();
}

class _SpotifyLibraryPageState extends State<SpotifyLibraryPage> {
  final _clientIdCtrl = TextEditingController();
  bool _loading = false;
  bool _loggingIn = false;
  String? _status;
  String _tab = 'playlists';
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    SpotifyOAuthService.instance.load().then((_) async {
      _clientIdCtrl.text = ''; // clientId stored in oauth file; not prepopulated here
      if (!mounted) return;
      if (SpotifyOAuthService.instance.isLoggedIn) await _refresh();
      setState(() {});
    });
  }

  Future<void> _refresh() async {
    setState(() { _loading = true; _status = null; });
    try {
      List<Map<String, dynamic>> data = const [];
      switch (_tab) {
        case 'playlists':
          data = await SpotifyLibraryService.instance.fetchPlaylists(force: true);
          break;
        case 'tracks':
          data = await SpotifyLibraryService.instance.fetchSavedTracks(force: true);
          break;
        case 'albums':
          data = await SpotifyLibraryService.instance.fetchSavedAlbums(force: true);
          break;
        case 'shows':
          data = await SpotifyLibraryService.instance.fetchSavedShows(force: true);
          break;
      }
      if (!mounted) return;
      setState(() { _items = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _status = '載入失敗: $e'; _loading = false; });
    }
  }

  Future<void> _loginFlow() async {
    final cid = _clientIdCtrl.text.trim();
    if (cid.isEmpty) {
      setState(() => _status = '請先填 Client ID');
      return;
    }
    setState(() { _loggingIn = true; _status = '等待瀏覽器授權…'; });
    await SpotifyOAuthService.instance.setClientId(cid);
    final ok = await SpotifyOAuthService.instance.login();
    if (!mounted) return;
    if (ok) {
      setState(() { _loggingIn = false; _status = '登入成功'; });
      await _refresh();
    } else {
      setState(() { _loggingIn = false; _status = '登入失敗或超時'; });
    }
  }

  Future<void> _logout() async {
    SpotifyOAuthService.instance.disposeServer();
    // logout by clearing oauth file
    final f = File('${ConfigService.instance.config.cachePath}\\spotify\\spotify_oauth.json');
    if (f.existsSync()) f.deleteSync();
    SpotifyOAuthService.instance.load();
    setState(() { _items = []; _status = '已登出'; });
  }

  /// 由目前 tab 資料產生 m3u8 檔，供本機 pipeline 同步 missing tracks。
  Future<void> _importPlaylist(String id, String name) async {
    try {
      // fetch tracks for that playlist
      final tracks = <String>[];
      String? url = 'https://api.spotify.com/v1/playlists/$id/tracks?limit=100';
      while (url != null && url.isNotEmpty) {
        final data = await _authedGet(url);
        if (data == null) break;
        for (final it in (data['items'] as List? ?? [])) {
          final tr = (it is Map ? it['track'] : null);
          if (tr is Map) {
            final n = (tr['name'] ?? '').toString();
            final a = (tr['artists'] is List && (tr['artists'] as List).isNotEmpty)
                ? (tr['artists'][0]['name'] ?? '').toString()
                : '';
            if (n.isNotEmpty) tracks.add('$n - $a');
          }
        }
        final next = data['next'];
        url = next is String && next.isNotEmpty ? next : null;
      }
      if (tracks.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('歌單沒有曲目可匯入')));
        return;
      }
      final dir = Directory(ConfigService.instance.config.playlistsPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final safe = name.replaceAll(RegExp(r'[\\\\/:*?\"<>|]'), '_');
      final file = File('${dir.path}\\$safe.m3u8');
      file.writeAsStringSync('#EXTM3U\n' + tracks.map((t) => '#EXTINF:-1,$t\n../music/$t.mp3').join('\n') + '\n');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已匯入「$name」(${tracks.length} 首)，執行 pipeline 即可下載 missing')));
      await _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('匯入失敗: $e')));
    }
  }

  // helper wrappers
  Future<Map<String, dynamic>?> _authedGet(String url) async {
    final t = await SpotifyOAuthService.instance.accessToken();
    if (t == null) return null;
    final req = await _httpGet(url, t);
    return req;
  }

  Future<Map<String, dynamic>?> _httpGet(String url, String token) async {
    try {
      // use dart io HttpClient
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/json');
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(const SystemEncoding().decoder).join();
      client.close();
      final data = jsonDecode(body);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = SpotifyOAuthService.instance.isLoggedIn;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Spotify Library', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (logged) IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh_rounded), tooltip: '重新整理'),
          if (logged) IconButton(onPressed: _logout, icon: const Icon(Icons.logout_rounded), tooltip: '登出'),
        ]),
        const SizedBox(height: 12),
        if (!logged) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: _clientIdCtrl, decoration: const InputDecoration(labelText: 'Spotify Client ID', hintText: 'from developer.spotify.com → Create app', border: OutlineInputBorder()), style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              ElevatedButton.icon(onPressed: _loggingIn ? null : _loginFlow, icon: _loggingIn ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login_rounded), label: const Text('登入 Spotify (PKCE)')),
              const SizedBox(height: 8),
              Text('步驟：1) developer.spotify.com 建立 app → Redirect URI 註冊 http://127.0.0.1 (任意端口) → 複製 Client ID → 貼上上方。\n2) 按登入 → 瀏覽器授權 → 自動回傳 token。\nScopes：library/playlists read。', style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
              if (_status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status!, style: const TextStyle(color: AppColors.accent, fontSize: 12))),
            ]),
          ),
        ] else ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in const [('playlists', '歌單'), ('tracks', '收藏'), ('albums', '專輯'), ('shows', 'Podcast')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(f.$2, style: const TextStyle(fontSize: 12)), selected: _tab == f.$1, onSelected: (_) { setState(() => _tab = f.$1); _refresh(); }),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          if (_loading) const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_status != null) Expanded(child: Center(child: Text(_status!, style: const TextStyle(color: AppColors.error))))
          else Expanded(child: ListView.builder(
            itemCount: _items.length,
            itemBuilder: (ctx, i) {
              final it = _items[i];
              final name = (it['name'] ?? it['track']?['name'] ?? '').toString();
              String sub = '';
              String? cover;
              String id = (it['id'] ?? '').toString();
              if (_tab == 'playlists') {
                sub = '${it['tracks']?['total'] ?? '?'} 首 · ${(it['owner']?['display_name'] ?? '')}';
                cover = _cover(it['images']);
                id = (it['id'] ?? '').toString();
              } else if (_tab == 'tracks') {
                final tr = it['track'] is Map ? it['track'] as Map : it;
                sub = (tr['artists'] is List && (tr['artists'] as List).isNotEmpty) ? (tr['artists'][0]['name'] ?? '').toString() : '';
                cover = _cover(tr['album']?['images']);
                id = '';
              } else if (_tab == 'albums') {
                sub = (it['artists'] is List && (it['artists'] as List).isNotEmpty) ? (it['artists'][0]['name'] ?? '').toString() : '';
                cover = _cover(it['images']);
              } else if (_tab == 'shows') {
                sub = (it['publisher'] ?? '').toString();
                cover = _cover(it['images']);
              }
              return ListTile(
                dense: true,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: cover != null ? Image.network(cover, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholderIcon())
                      : _placeholderIcon(),
                ),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                trailing: _tab == 'playlists'
                    ? IconButton(icon: const Icon(Icons.download_rounded, size: 18, color: AppColors.accent), tooltip: '匯入為本機歌單', onPressed: () => _importPlaylist(id, name))
                    : null,
              );
            },
          )),
        ],
      ]),
    );
  }

  Widget _placeholderIcon() => Container(width: 40, height: 40, color: AppColors.surfaceLight, child: const Icon(Icons.music_note_rounded, size: 18, color: AppColors.textMuted));

  String? _cover(dynamic images) {
    if (images is! List || images.isEmpty) return null;
    final first = images.first;
    if (first is Map) return first['url'] as String?;
    return null;
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    super.dispose();
  }
}
