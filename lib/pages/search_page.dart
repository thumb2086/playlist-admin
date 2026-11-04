import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../services/spotify_session.dart';
import '../services/spotify_gql_client.dart';
import '../services/player_controller.dart';
import '../widgets/dark_theme.dart';
import '../widgets/spotify_login_dialog.dart';

/// Spotify search: native GQL search → check local library → stream or queue.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _gql = SpotifyGqlClient();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  int _searchGen = 0;
  List<SpotifyTrackItem> _tracks = [];
  List<SpotifyAlbumItem> _albums = [];
  List<SpotifyArtistItem> _artists = [];
  String _filter = 'all'; // all / tracks / albums / artists
  bool _searching = false;
  String _error = '';
  // 本地索引：stem → 路徑。原本 _findLocal 在 itemBuilder 每列都
  // existsSync + listSync 整個音樂目錄，改為建一次、builder 純查表。
  Map<String, String> _localIndex = {};

  @override
  void initState() {
    super.initState();
    SpotifySession.instance.addListener(_onSession);
    _searchCtrl.addListener(_onQueryChanged);
    _rebuildLocalIndex();
  }

  @override
  void dispose() {
    SpotifySession.instance.removeListener(_onSession);
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 重登 Spotify：token 約 40 分鐘過期，sp_dc 也會被 Spotify 淘汰。
  /// 舊版只在「未登入」時顯示登入鈕 → 已登入但 token 過期時無路可走。
  Future<void> _relogin() async {
    await showSpotifyLogin(context);
    await SpotifySession.instance.load();
    if (!mounted) return;
    setState(() {
      _tracks = [];
      _error = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(SpotifySession.instance.isLoggedIn
          ? 'Spotify 已重新登入'
          : '未取得授權（sp_dc 可能已被 Spotify 淘汰，需完整登入流程）'),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 從別頁回來時重建（期間的新下載才會亮本機 badge）。
    _rebuildLocalIndex();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() { _tracks = []; _albums = []; _artists = []; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String query) async {
    if (!SpotifySession.instance.isLoggedIn) return;
    final gen = ++_searchGen;
    setState(() { _searching = true; _error = ''; });
    try {
      final data = await _gql.searchTracks(query, limit: 25);
      // 慢回應先到會覆蓋新結果：世代不符直接丟棄。
      if (!mounted || gen != _searchGen) return;
      final tracks = SpotifyTrackItem.parseSearchTracks(data);
      final albums = SpotifyAlbumItem.parseSearchAlbums(data);
      final artists = SpotifyArtistItem.parseSearchArtists(data);
      if (mounted) setState(() {
        _tracks = tracks;
        _albums = albums;
        _artists = artists;
        _searching = false;
      });
    } catch (e) {
      if (mounted && gen == _searchGen) setState(() { _searching = false; _error = '$e'; });
    }
  }

  /// Rebuild the local stem→path index (async, once per search/page open).
  Future<void> _rebuildLocalIndex() async {
    final idx = <String, String>{};
    try {
      final dir = Directory(ConfigService.instance.config.musicPath);
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File) {
            idx[File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase()] = f.path;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _localIndex = idx);
  }

  /// Returns the local music file for [t] if it exists in the library.
  /// 純查表（_localIndex），無 IO，可安全在 builder 內呼叫。
  String? _findLocal(SpotifyTrackItem t) {
    if (_localIndex.isEmpty) return null;
    final targets = [
      t.displayName.toLowerCase(),
      '${t.name} - ${t.artists.join(' ')}'.toLowerCase(),
      t.name.toLowerCase(),
    ];
    for (final target in targets) {
      final hit = _localIndex[target];
      if (hit != null) return hit;
    }
    for (final target in targets) {
      if (target.isEmpty) continue;
      for (final e in _localIndex.entries) {
        if (e.key.contains(target) || target.contains(e.key)) return e.value;
      }
    }
    return null;
  }

  /// Play: local file if available, else resolve stream URL.
  Future<void> _play(SpotifyTrackItem t) async {
    final local = _findLocal(t);
    if (local != null) {
      PlayerController.instance.play(local, title: t.name, artist: t.artists.join(', '), coverUrl: t.coverUrl, album: t.album);
      return;
    }
    PlayerController.instance.play(t.displayName, title: t.name, artist: t.artists.join(', '), coverUrl: t.coverUrl, album: t.album);
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = SpotifySession.instance.isLoggedIn;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!loggedIn)
          Expanded(
            child: Center(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.search_rounded, size: 56, color: AppColors.textMuted),
                const SizedBox(height: 16),
                const Text('搜尋需要 Spotify 登入', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    await showSpotifyLogin(context);
                    await SpotifySession.instance.load();
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('Spotify 登入'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.black,
                  ),
                ),
              ]),
            ),
          )
        else ...[
          Row(children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: false,
                  decoration: const InputDecoration(
                    hintText: '搜尋歌曲、藝人、專輯…',
                    border: InputBorder.none,
                    icon: Icon(Icons.search_rounded,
                        color: AppColors.textMuted, size: 18),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            // 重登入口：token 約 40 分鐘過期，sp_dc 也會被 Spotify 淘汰。
            // 舊版只有「未登入」時才有鈕 → 過期後使用者只能重開 app。
            const SizedBox(width: 8),
            Tooltip(
              message: SpotifySession.instance.lastError ?? '重登 Spotify',
              child: OutlinedButton.icon(
                onPressed: _relogin,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重登', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      SpotifySession.instance.lastError != null
                          ? AppColors.error
                          : AppColors.text,
                  side: const BorderSide(color: AppColors.border),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (_searching)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error.isNotEmpty)
            Expanded(child: Center(child: Text('搜尋失敗: $_error', style: const TextStyle(color: AppColors.error))))
          else if (_tracks.isEmpty && _albums.isEmpty && _artists.isEmpty)
            const Expanded(
              child: Center(child: Text('輸入關鍵字開始搜尋', style: TextStyle(color: AppColors.textMuted))),
            )
          else
            Expanded(
              child: Column(children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final f in const [('all', '全部'), ('tracks', '歌曲'), ('albums', '專輯'), ('artists', '藝人')])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(f.$2, style: const TextStyle(fontSize: 12)),
                          selected: _filter == f.$1,
                          onSelected: (_) => setState(() => _filter = f.$1),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 6),
                Expanded(child: _buildSearchResults()),
              ]),
            ),
           ],
       ]),
     );
   }


  // placeholder removed
            void _searchByName(String name) {
    _searchCtrl.text = name;
    _search(name);
  }

  Widget _buildSearchResults() {
    if (_filter == 'albums') {
      if (_albums.isEmpty) {
        return const Center(child: Text('無專輯結果', style: TextStyle(color: AppColors.textMuted)));
      }
      return ListView.builder(
        itemCount: _albums.length,
        itemBuilder: (ctx, i) {
          final a = _albums[i];
          return ListTile(
            dense: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: a.coverUrl != null
                  ? CachedNetworkImage(imageUrl: a.coverUrl!, width: 40, height: 40, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(width: 40, height: 40, color: AppColors.surfaceLight),
                      errorWidget: (_, __, ___) => Container(width: 40, height: 40, color: AppColors.surfaceLight,
                          child: const Icon(Icons.album_rounded, size: 18, color: AppColors.textMuted)))
                  : Container(width: 40, height: 40, color: AppColors.surfaceLight,
                      child: const Icon(Icons.album_rounded, size: 18, color: AppColors.textMuted)),
            ),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            subtitle: Text(a.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
            trailing: const Icon(Icons.search_rounded, size: 16, color: AppColors.textMuted),
            onTap: () => _searchByName(a.name),
          );
        },
      );
    }
    if (_filter == 'artists') {
      if (_artists.isEmpty) {
        return const Center(child: Text('無藝人結果', style: TextStyle(color: AppColors.textMuted)));
      }
      return ListView.builder(
        itemCount: _artists.length,
        itemBuilder: (ctx, i) {
          final a = _artists[i];
          return ListTile(
            dense: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: a.coverUrl != null
                  ? CachedNetworkImage(imageUrl: a.coverUrl!, width: 40, height: 40, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(width: 40, height: 40, color: AppColors.surfaceLight),
                      errorWidget: (_, __, ___) => Container(width: 40, height: 40, color: AppColors.surfaceLight,
                          child: const Icon(Icons.person_rounded, size: 18, color: AppColors.textMuted)))
                  : Container(width: 40, height: 40, color: AppColors.surfaceLight,
                      child: const Icon(Icons.person_rounded, size: 18, color: AppColors.textMuted)),
            ),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.search_rounded, size: 16, color: AppColors.textMuted),
            onTap: () => _searchByName(a.name),
          );
        },
      );
    }
    if (_tracks.isEmpty) {
      return const Center(child: Text('無歌曲結果', style: TextStyle(color: AppColors.textMuted)));
    }
    return ListView.builder(
      itemCount: _tracks.length,
      itemBuilder: (ctx, i) {
        final t = _tracks[i];
        final local = _findLocal(t);
        return ListTile(
          dense: true,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: t.coverUrl != null
                ? CachedNetworkImage(imageUrl: t.coverUrl!, width: 40, height: 40, fit: BoxFit.cover,
                    placeholder: (_, __) => Container(width: 40, height: 40, color: AppColors.surfaceLight),
                    errorWidget: (_, __, ___) => Container(width: 40, height: 40, color: AppColors.surfaceLight,
                        child: const Icon(Icons.music_note_rounded, size: 18, color: AppColors.textMuted)))
                : Container(width: 40, height: 40, color: AppColors.surfaceLight,
                    child: const Icon(Icons.music_note_rounded, size: 18, color: AppColors.textMuted)),
          ),
          title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          subtitle: Text(
            '${t.artists.join(', ')}${local != null ? '  ● 已在本機' : ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: local != null ? AppColors.accent : AppColors.textMuted),
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (local != null)
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded, color: AppColors.accent, size: 20),
                onPressed: () => _play(t),
                tooltip: '播放',
              )
            else
              IconButton(
                icon: const Icon(Icons.cloud_upload_outlined, color: AppColors.textMuted, size: 18),
                onPressed: () => _play(t),
                tooltip: '串流播放',
              ),
          ]),
        );
      },
    );
  }

}
