import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/config_service.dart';
import '../services/download_service.dart';
import '../services/i18n.dart';
import '../widgets/dark_theme.dart';

class SpotubePage extends StatefulWidget {
  const SpotubePage({super.key});
  @override
  State<SpotubePage> createState() => _SpotubePageState();
}

class _SpotubePageState extends State<SpotubePage> {
  final _logs = <String>[];
  final _scrollCtrl = ScrollController();
  bool _running = false;
  String _status = '';
  int _ok = 0;
  int _fail = 0;
  int _total = 0;
  int _done = 0;
  final _logPending = <String>[];
  Timer? _logFlushTimer;
  static const int _maxLogLines = 800;

  void _onI18n() { if (mounted) setState(() {}); }

  @override
  void initState() {
    super.initState();
    _status = '就緒';
    I18N.instance.addListener(_onI18n);
  }

  @override
  void dispose() {
    _logFlushTimer?.cancel();
    I18N.instance.removeListener(_onI18n);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _log(String msg) {
    _logPending.add(msg);
    if (_logFlushTimer?.isActive ?? false) return;
    _logFlushTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) { _logPending.clear(); return; }
      setState(() {
        _logs.addAll(_logPending);
        _logPending.clear();
        if (_logs.length > _maxLogLines) {
          _logs.removeRange(0, _logs.length - _maxLogLines);
        }
      });
      if (_scrollCtrl.hasClients) {
        final pos = _scrollCtrl.position;
        if (pos.hasContentDimensions && pos.maxScrollExtent - pos.pixels <= 200) {
          try { _scrollCtrl.jumpTo(pos.maxScrollExtent); } catch (_) {}
        }
      }
    });
  }

  String _findBridge() {
    final exeDir = Directory(File(Platform.resolvedExecutable).parent.path);
    Directory? d = exeDir;
    while (d != null) {
      final candidate = '${d.path}\\tools\\flutter_download_bridge.py';
      if (File(candidate).existsSync()) return candidate;
      d = d.parent.path == d.path ? null : d.parent;
    }
    return '';
  }

  void _cancelDownload() {
    // _running=false 會讓下載迴圈在當前這首結束後停下（單首最多等 yt-dlp 180s timeout）。
    setState(() { _running = false; _status = '已取消'; });
    _log('⏹️ 已取消（當前歌曲完成後停止）');
  }

  Future<void> _downloadAll() async {
    if (_running) return;
    setState(() { _running = true; _status = '下載中...'; _ok = 0; _fail = 0; _done = 0; });
    try {
      await _downloadAllInner();
    } finally {
      // 任何 throw 路徑都要重置，否則 UI 永遠卡「下載中」。
      _logFlushTimer?.cancel();
      _flushLogsNow();
      if (mounted) setState(() { _running = false; });
    }
  }

  void _flushLogsNow() {
    if (_logPending.isEmpty) return;
    _logs.addAll(_logPending);
    _logPending.clear();
    if (_logs.length > _maxLogLines) {
      _logs.removeRange(0, _logs.length - _maxLogLines);
    }
    if (mounted) setState(() {});
  }

  Future<void> _downloadAllInner() async {

    final cfg = ConfigService.instance.config;
    final bridge = _findBridge();
    if (bridge.isEmpty) {
      _log('❌ 找不到 flutter_download_bridge.py');
      setState(() { _running = false; _status = '錯誤'; });
      return;
    }

    // Load snapshot
    final snapFile = File('${cfg.basePath}\\original_snapshot.json');
    if (!await snapFile.exists()) {
      _log('❌ 找不到 original_snapshot.json');
      setState(() { _running = false; _status = '錯誤'; });
      return;
    }
    final snap = jsonDecode(await snapFile.readAsString()) as Map<String, dynamic>;
    final playlists = snap['playlists'] as Map<String, dynamic>? ?? {};

    final allSongs = <String>{};
    for (final tracks in playlists.values) {
      for (final t in (tracks as List<dynamic>)) {
        allSongs.add(t as String);
      }
    }
    _total = allSongs.length;
    _log('播放清單共 $_total 首歌曲');

    // Check existing
    final musicDir = Directory(cfg.musicPath);
    final existing = <String>{};
    if (await musicDir.exists()) {
      await for (final f in musicDir.list()) {
        if (f is File) {
          final stem = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
          existing.add(stem);
        }
      }
    }
    final missing = allSongs.where((s) {
      final stem = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      return !existing.contains(stem);
    }).toList();
    _log('已有 ${existing.length} 首，需下載 ${missing.length} 首');

    if (missing.isEmpty) {
      _log('✅ 所有歌曲已下載');
      setState(() { _running = false; _status = '完成'; });
      return;
    }

    // Download using native Dart
    for (final song in missing) {
      if (!_running) break;
      try {
        await DownloadService.instance.downloadSong(
          songName: song,
          libraryPath: cfg.musicPath,
          format: 'mp3',
          onLog: _log,
          onProgress: (_) {},
        );
        _ok++;
      } catch (e) {
        _fail++;
        _log('❌ $song: $e');
      }
      _done++;
      setState(() => _status = '$_done/$_total (成功 $_ok，失敗 $_fail)');
    }

    _log('✅ 下載完成: 成功 $_ok，失敗 $_fail');
    _recordDownloadStats(_ok, _fail, missing.length);
    if (_running) {
      // Mark all playlists as updated today (like old Spotube flow)
      final today = DateTime.now().toIso8601String().substring(0, 10);
      for (final name in cfg.urlNames.values) {
        cfg.lastUpdated[name] = today;
      }
      await ConfigService.instance.save();
    }
    if (mounted) setState(() { _status = '完成'; });
  }

  void _resetRecords() {
    ConfigService.instance.config.lastUpdated.clear();
    ConfigService.instance.save();
    setState(() {});
    _log('📝 已重置下載紀錄');
  }

  void _recordDownloadStats(int ok, int fail, int total) {
    try {
      final cfg = ConfigService.instance.config;
      final f = File('${cfg.cachePath}\\downloads_log.json');
      Map<String, dynamic> log = {};
      if (f.existsSync()) {
        log = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      }
      final runs = (log['runs'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      runs.add({
        'time': DateTime.now().toIso8601String(),
        'ok': ok,
        'fail': fail,
        'total': total,
        'success_rate': total > 0 ? (ok / total * 100).toStringAsFixed(1) : '0',
      });
      if (runs.length > 100) runs.removeAt(0);
      log['runs'] = runs;
      f.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(log));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        if (_running)
          const SingleActivator(LogicalKeyboardKey.escape): _cancelDownload,
      },
      child: Focus(
        autofocus: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Column(children: [
            Row(children: [
              Container(width: 10, height: 10,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _running ? Colors.orange : (_status == '完成' ? AppColors.accent : AppColors.textMuted)),
              ),
              const SizedBox(width: 8),
              Text(_status, style: TextStyle(color: _running ? Colors.orange : AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w500)),
              const Spacer(),
              if (_total > 0) Text('$_done/$_total', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _SButton('一鍵補全', Icons.download_rounded, _downloadAll, _running, isPrimary: true),
              _SButton('取消', Icons.stop_rounded, _cancelDownload, !_running, color: AppColors.error),
              _SButton('重置紀錄', Icons.delete_outline_rounded, _resetRecords, false),
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        Text('下載紀錄 (${ConfigService.instance.config.lastUpdated.length})',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(flex: 2, child: Container(
          decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
          clipBehavior: Clip.antiAlias,
          child: ConfigService.instance.config.lastUpdated.isEmpty
              ? const Center(child: Text('尚無下載紀錄', style: TextStyle(color: AppColors.textMuted)))
              : ListView.builder(itemCount: ConfigService.instance.config.lastUpdated.length,
                  itemBuilder: (ctx, i) {
                    final e = ConfigService.instance.config.lastUpdated.entries.elementAt(i);
                    return ListTile(dense: true,
                      leading: const Icon(Icons.check_circle, color: AppColors.accent, size: 18),
                      title: Text(e.key, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(e.value, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
                    );
                  }),
        )),
        const SizedBox(height: 8),
        const Text('執行紀錄', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(flex: 3, child: Container(
          decoration: BoxDecoration(color: const Color(0xFF080808), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
          clipBehavior: Clip.antiAlias,
          child: _logs.isEmpty
              ? const Center(child: Text('按下「一鍵補全」開始下載', style: TextStyle(color: AppColors.textMuted, fontSize: 12)))
              : SelectionArea(child: ListView.builder(controller: _scrollCtrl, padding: const EdgeInsets.all(10),
                  itemCount: _logs.length, itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(_logs[i], style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: AppColors.textMuted, height: 1.4)),
                  ))),
        )),
        const SizedBox(height: 16),
          ]),
      ),
    );
  }
}

class _SButton extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onPressed;
  final bool disabled; final bool isPrimary; final Color? color;
  const _SButton(this.label, this.icon, this.onPressed, this.disabled, {this.isPrimary = false, this.color});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: disabled ? null : onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color ?? (isPrimary ? AppColors.accent : AppColors.surfaceLight),
        foregroundColor: isPrimary ? Colors.black : AppColors.text,
        disabledBackgroundColor: AppColors.surfaceLight.withValues(alpha: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    );
  }
}
