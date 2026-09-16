import 'dart:async';
import 'package:flutter/material.dart';
import '../services/lyrics_service.dart';
import '../services/player_controller.dart';
import '../widgets/dark_theme.dart';

/// 歌詞頁面：同步 LRC 滾動 + 非同步歌詞。
class LyricsPage extends StatefulWidget {
  final String artist;
  final String track;
  final String? album;
  final int? durationSec;

  const LyricsPage({
    super.key,
    required this.artist,
    required this.track,
    this.album,
    this.durationSec,
  });

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  LyricsResult? _result;
  List<LyricLine> _syncedLines = [];
  int _currentLine = 0;
  bool _loading = true;
  Timer? _lineTimer;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchLyrics();
    _lineTimer = Timer.periodic(const Duration(milliseconds: 200), _updateLine);
  }

  @override
  void dispose() {
    _lineTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchLyrics() async {
    try {
      final result = await LyricsService.instance.fetch(
        widget.artist, widget.track,
        album: widget.album, durationSec: widget.durationSec,
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
        if (result?.hasSynced == true) {
          _syncedLines = LyricsService.parseLrc(result!.syncedLyrics!);
        }
      });
    } catch (_) {
      // 失敗/逾時不可永遠轉圈。
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _updateLine(Timer _) {
    if (_syncedLines.isEmpty) return;
    final pos = PlayerController.instance.position;
    final newLine = LyricsService.currentLine(_syncedLines, pos);
    if (newLine != _currentLine) {
      setState(() => _currentLine = newLine);
      _scrollToLine(newLine);
    }
  }

  void _scrollToLine(int line) {
    if (!_scrollCtrl.hasClients) return;
    final target = line * 48.0;
    _scrollCtrl.animateTo(
      target.clamp(0, _scrollCtrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('${widget.track} - ${widget.artist}',
            style: const TextStyle(fontSize: 14)),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_result == null || !_result!.hasAny) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lyrics_outlined, size: 48, color: AppColors.textMuted),
            SizedBox(height: 12),
            Text('找不到歌詞', style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
          ]),
        ),
      );
    }

    if (_syncedLines.isNotEmpty) return _buildSyncedLyrics();
    return _buildPlainLyrics();
  }

  Widget _buildSyncedLyrics() {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      itemCount: _syncedLines.length,
      itemBuilder: (ctx, i) {
        final isCurrent = i == _currentLine;
        return AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: isCurrent ? 18 : 14,
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
            color: isCurrent ? AppColors.accent : AppColors.textMuted,
            height: 1.8,
          ),
          textAlign: TextAlign.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(_syncedLines[i].text),
          ),
        );
      },
    );
  }

  Widget _buildPlainLyrics() {
    final lines = _result!.plainLyrics!.split('\n');
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: lines.length,
      itemBuilder: (ctx, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(lines[i],
            style: const TextStyle(fontSize: 14, height: 1.8, color: AppColors.textSecondary)),
      ),
    );
  }
}
