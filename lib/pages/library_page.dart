import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../services/i18n.dart';
import '../services/usb_exporter.dart';
import '../services/playlist_parser.dart';
import '../services/history_recorder.dart';
import '../models/playlist.dart';
import '../widgets/dark_theme.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  bool _exporting = false;
  final _urlCtrl = TextEditingController();
  Map<String, _PlStats> _stats = {};
  bool _loading = false;
  int _refreshVersion = 0;
  Timer? _refreshDebounce;

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    I18N.instance.removeListener(_onI18n);
    _urlCtrl.dispose();
    ConfigService.instance.removeListener(_onConfigChanged);
    super.dispose();
  }

  void _onI18n() { if (mounted) setState(() {}); }

  @override
  void initState() {
    super.initState();
    I18N.instance.addListener(_onI18n);
    ConfigService.instance.addListener(_onConfigChanged);
    _refresh();
  }

  void _onConfigChanged() {
    // 每次存檔都全量掃描太傷：debounce 500ms 合併。
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh({bool cleanOrphans = false}) async {
    final version = ++_refreshVersion;
    setState(() => _loading = true);
    final cfg = ConfigService.instance.config;
    final plDir = Directory(cfg.playlistsPath);
    final libDir = Directory(cfg.libraryPath);
    final stats = <String, _PlStats>{};

    // Build a set of all audio file stems from the library (recursive)
    // Only match MP3 & FLAC in playlists; M4A stays as source only
    final libStems = <String>{};
    if (await libDir.exists()) {
      await for (final f in libDir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          final low = f.path.toLowerCase();
          if (low.endsWith('.mp3') || low.endsWith('.flac')) {
            libStems.add(File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
          }
        }
      }
    }

    // Also scan mp3/m4a/flac subdirectories of basePath if libraryPath doesn't contain them
    final baseDir = Directory(cfg.basePath);
    if (baseDir.path.toLowerCase() != libDir.path.toLowerCase() && await baseDir.exists()) {
      for (final sub in ['mp3', 'm4a', 'flac']) {
        final subDir = Directory('${cfg.basePath}\\$sub');
        if (await subDir.exists()) {
          await for (final f in subDir.list(recursive: true, followLinks: false)) {
            if (f is File) {
              final low = f.path.toLowerCase();
              if (low.endsWith('.mp3') || low.endsWith('.flac')) {
                libStems.add(File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
              }
            }
          }
        }
      }
    }

    final knownNames = cfg.urlNames.values.map((n) => n.toLowerCase()).toSet();
    if (await plDir.exists()) {
      final toDelete = <String>[];
      await for (final e in plDir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.m3u8')) {
          try {
            final baseName = File(e.path).uri.pathSegments.last;
            if (PlaylistParser.isInternalPlaylist(baseName)) continue;
            final nameNoExt = baseName.replaceAll('.m3u8', '').toLowerCase();

            // Orphan deletion only on explicit manual refresh
            if (cleanOrphans && !knownNames.contains(nameNoExt)) {
              toDelete.add(e.path);
              continue;
            }

            final stat = await e.stat();
            if (stat.size == 0) continue;

            final lines = await e.readAsLines();
            int total = 0, matched = 0;
            for (final line in lines) {
              if (!line.startsWith('#') && line.trim().isNotEmpty) {
                total++;
                // 歌單路徑是 URI-encoded（Echo 相容），先解碼再比對
                var raw = line;
                try { raw = Uri.decodeComponent(raw); } catch (_) {}
                final sep = raw.contains('\\') || raw.contains('/');
                final name = sep ? raw.split(RegExp(r'[\\/]')).last : raw;
                final stem = name.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
                if (libStems.contains(stem)) { matched++; continue; }
                if (stem.contains(' - ')) {
                  final parts = stem.split(' - ');
                  if (parts.length >= 2) {
                    final reversed = '${parts[1]} - ${parts[0]}';
                    if (libStems.contains(reversed)) { matched++; continue; }
                    final titlePart = parts[0].trim();
                    if (titlePart.length >= 2 &&
                        libStems.any((s) => s.startsWith(titlePart) || s.contains(' $titlePart '))) {
                      matched++; continue;
                    }
                  }
                }
              }
            }
            stats[baseName.replaceAll('.m3u8', '')] = _PlStats(total, matched);
          } catch (e) {
            debugPrint('[LibraryPage] 處理檔案失敗: $e');
          }
        }
      }
      for (final path in toDelete) {
        try { await File(path).delete(); } catch (e) {
          debugPrint('[LibraryPage] 刪除 $path 失敗: $e');
        }
      }
    }
    if (version != _refreshVersion) return;
    if (mounted) setState(() { _stats = stats; _loading = false; });
    HistoryRecorder.record().ignore();
  }

  void _addUrl() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    final cfg = ConfigService.instance.config;
    final id = url.split('/').last.split('?').first;
    cfg.urlNames[url] = id.substring(0, id.length.clamp(0, 12)).replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202f\u2060-\u206f\ufeff]'), '').trim();
    ConfigService.instance.save();
    _urlCtrl.clear();
    setState(() {});
  }

  Future<void> _export() async {
    if (_exporting) return;
    final plDir = Directory(ConfigService.instance.config.playlistsPath);
    if (!await plDir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('播放清單資料夾不存在')));
      }
      return;
    }

    final files = <String>[];
    await for (final e in plDir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.m3u8')) {
        files.add(e.path);
      }
    }

    if (files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('沒有可匯出的播放清單')));
      }
      return;
    }

    setState(() => _exporting = true);
    final exporter = UsbExporter(log: (msg) => debugPrint(msg));
    final result = await exporter.exportPlaylists(files);
    setState(() => _exporting = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('匯出完成: ${result.copied}/${result.total} 首 → ${result.targetPath}'),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ConfigService.instance.config.playlists;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // URL input
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    decoration: InputDecoration(
                      hintText: t('library.url_hint'),
                      prefixIcon: const Icon(Icons.link, size: 18),
                      border: const OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 13),
                    onSubmitted: (_) => _addUrl(),
                  ),
                ),
                const SizedBox(width: 10),
                _GradientBtn(t('library.add_btn'), Icons.add, _addUrl),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _refresh(cleanOrphans: true),
                  icon: _loading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh_rounded),
                  tooltip: t('library.refresh'),
                  style: IconButton.styleFrom(backgroundColor: AppColors.surfaceLight),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _export,
                  icon: const Icon(Icons.usb_rounded),
                  tooltip: '匯出到 USB',
                  style: IconButton.styleFrom(backgroundColor: AppColors.surfaceLight),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Stats bar
          _buildStatsBar(playlists),
          const SizedBox(height: 14),
          // Grid
          Expanded(
            child: playlists.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.library_music_outlined, size: 64, color: AppColors.textMuted.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(t('library.empty_title'), style: const TextStyle(color: AppColors.textMuted, fontSize: 15)),
                        const SizedBox(height: 4),
                        Text(t('library.empty_subtitle'), style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () => _refresh(cleanOrphans: true),
                    child: GridView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 240,
                        mainAxisExtent: 190,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: playlists.length,
                      itemBuilder: (ctx, i) => _PlaylistCard(
                        playlist: playlists[i],
                        stats: _stats[playlists[i].name],
                        onRemove: () {
                          ConfigService.instance.config.urlNames.remove(playlists[i].url);
                          ConfigService.instance.save();
                          setState(() {});
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsBar(List<PlaylistConfig> playlists) {
    int totalTracks = 0, totalMatched = 0;
    for (final p in playlists) {
      final s = _stats[p.name];
      if (s != null) { totalTracks += s.total; totalMatched += s.matched; }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        _Chip(Icons.playlist_play, '${playlists.length}', t('library.stats_playlists')),
        const SizedBox(width: 20),
        _Chip(Icons.music_note, '$totalTracks', t('library.stats_songs')),
        const SizedBox(width: 20),
        _Chip(Icons.check_circle, '$totalMatched', t('library.stats_matched'), color: AppColors.accent),
        if (totalTracks > 0) ...[
          const SizedBox(width: 20),
          _Chip(Icons.trending_up, totalTracks > 0 ? '${(totalMatched / totalTracks * 100).toStringAsFixed(0)}%' : '0%', t('library.stats_completion')),
        ],
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon; final String value; final String label; final Color? color;
  const _Chip(this.icon, this.value, this.label, {this.color});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 14, color: color ?? AppColors.textMuted),
    const SizedBox(width: 6),
    Text(value, style: TextStyle(color: color ?? AppColors.text, fontWeight: FontWeight.bold, fontSize: 13)),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
  ]);
}

class _PlStats { final int total; final int matched; _PlStats(this.total, this.matched); }

class _PlaylistCard extends StatelessWidget {
  final PlaylistConfig playlist; final _PlStats? stats; final VoidCallback onRemove;
  const _PlaylistCard({required this.playlist, this.stats, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final total = stats?.total ?? 0;
    final matched = stats?.matched ?? 0;
    final pct = total > 0 ? matched / total : 0.0;
    final full = total > 0 && matched >= total;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: full ? AppColors.accent.withValues(alpha: 0.3) : AppColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: full ? AppColors.accentDim : AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        full ? Icons.check_circle : Icons.playlist_play_rounded,
                        color: full ? AppColors.accent : AppColors.textMuted,
                        size: 20,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: onRemove,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        child: const Icon(Icons.close, color: AppColors.textMuted, size: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(playlist.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.3),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const Spacer(),
                if (total > 0) ...[
                  Row(
                    children: [
                      Text('$matched/$total ${t('library.stats_songs')}', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
                      const Spacer(),
                      Text('${(pct * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: full ? AppColors.accent : AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: pct),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    builder: (ctx, v, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: v,
                        backgroundColor: AppColors.surfaceLight,
                        valueColor: AlwaysStoppedAnimation(full ? AppColors.accent : AppColors.textMuted.withValues(alpha: 0.4)),
                        minHeight: 5,
                      ),
                    ),
                  ),
                ] else ...[
                  const Spacer(),
                  Row(
                    children: [
                      Icon(Icons.cloud_download_outlined, size: 12, color: AppColors.textMuted.withValues(alpha: 0.5)),
                      const SizedBox(width: 4),
                      Text('尚未同步', style: TextStyle(color: AppColors.textMuted.withValues(alpha: 0.5), fontSize: 11)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GradientBtn extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onPressed;
  const _GradientBtn(this.label, this.icon, this.onPressed);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [AppColors.accent, Color(0xFF169C46)]),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.black,
        ),
      ),
    );
  }
}
