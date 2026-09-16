import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/config_service.dart';
import '../services/i18n.dart';
import '../services/chinese_converter.dart';
import '../services/rag_service.dart';
import '../services/history_recorder.dart';
import '../pipeline/pipeline_orchestrator.dart';
import '../pipeline/podcast_pipeline.dart';
import '../models/pipeline_step.dart';
import '../widgets/dark_theme.dart';
import 'audio_extractor_page.dart';

class PipelinePage extends StatefulWidget {
  const PipelinePage({super.key});
  @override
  State<PipelinePage> createState() => _PipelinePageState();
}

class _PipelinePageState extends State<PipelinePage> {
  final _musicLogs = <String>[];
  final _podcastLogs = <String>[];
  final _musicScrollCtrl = ScrollController();
  final _podcastScrollCtrl = ScrollController();
  PipelineState _musicState = PipelineState();
  PipelineState _podcastState = PipelineState();
  bool _musicRunning = false;
  bool _podcastRunning = false;
  bool _ragRunning = false;
  double _musicProgress = 0;
  double _podcastProgress = 0;
  double _ragProgress = 0;
  int _musicStep = 0;

  // ── Log 節流：pipeline 每秒幾十行 log，若每行都 setState + animateTo，
  // 兩條一起跑會直接塞爆主 thread。改為 300ms 批量 flush 一次。
  final _musicPending = <String>[];
  final _podcastPending = <String>[];
  Timer? _logFlushTimer;
  static const int _maxLogLines = 1500;
  DateTime _lastMusicProgress = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPodcastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRagProgress = DateTime.fromMillisecondsSinceEpoch(0);

  late List<String> _stepLabels;

  @override
  void initState() {
    super.initState();
    _rebuildStepLabels();
    I18N.instance.addListener(_rebuildStepLabels);
  }

  @override
  void dispose() {
    _logFlushTimer?.cancel();
    I18N.instance.removeListener(_rebuildStepLabels);
    _musicScrollCtrl.dispose();
    _podcastScrollCtrl.dispose();
    super.dispose();
  }

  void _rebuildStepLabels() {
    setState(() {
      _stepLabels = [
        t('pipeline.step_convert'),
        t('pipeline.step_scrape'),
        t('pipeline.step_prune'),
        t('pipeline.step_unsorted'),
        t('pipeline.step_metadata'),
        t('pipeline.step_lufs'),
        t('pipeline.step_rag'),
        t('pipeline.step_srt'),
      ];
    });
  }

  void _musicLog(String msg) {
    _musicPending.add(msg);
    _scheduleLogFlush();
  }

  void _podcastLog(String msg) {
    _podcastPending.add(msg);
    _scheduleLogFlush();
  }

  void _scheduleLogFlush() {
    if (_logFlushTimer?.isActive ?? false) return;
    _logFlushTimer = Timer(const Duration(milliseconds: 300), _flushLogs);
  }

  void _flushLogs() {
    if (!mounted) {
      _musicPending.clear();
      _podcastPending.clear();
      return;
    }
    setState(() {
      if (_musicPending.isNotEmpty) {
        _musicLogs.addAll(_musicPending);
        _musicPending.clear();
        if (_musicLogs.length > _maxLogLines) {
          _musicLogs.removeRange(0, _musicLogs.length - _maxLogLines);
        }
      }
      if (_podcastPending.isNotEmpty) {
        _podcastLogs.addAll(_podcastPending);
        _podcastPending.clear();
        if (_podcastLogs.length > _maxLogLines) {
          _podcastLogs.removeRange(0, _podcastLogs.length - _maxLogLines);
        }
      }
    });
    _autoScroll(_musicScrollCtrl);
    _autoScroll(_podcastScrollCtrl);
  }

  void _autoScroll(ScrollController ctrl) {
    if (!ctrl.hasClients) return;
    final pos = ctrl.position;
    if (!pos.hasContentDimensions) return;
    // 使用者已往上翻看舊 log 時不硬拉到底；貼底才跟隨，且用 jumpTo
    // 避免數百個 animateTo 動畫疊加卡死 UI。
    if (pos.maxScrollExtent - pos.pixels > 200) return;
    try {
      ctrl.jumpTo(pos.maxScrollExtent);
    } catch (_) {}
  }

  /// 進度條節流：250ms 最多一次 setState，完成時一定更新。
  bool _throttleProgress(DateTime last) {
    return DateTime.now().difference(last).inMilliseconds < 250;
  }

  Future<void> _run({int fromStep = 0, int? toStep}) async {
    if (_musicRunning) return;
    setState(() { _musicRunning = true; _musicProgress = 0; _musicStep = fromStep; });
    _musicState = PipelineState();
    _musicLog(t('pipeline.starting'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    try {
      try { await ChineseConverter.instance.load(); } catch (e) { _musicLog('注意: 中文轉換器載入失敗: $e'); }

      final orch = PipelineOrchestrator(
        config: ConfigService.instance.config,
        onLog: _musicLog,
        onProgress: (c, t, stepIdx) {
          final done = t <= 0 || c >= t;
          if (!done && _throttleProgress(_lastMusicProgress)) return;
          _lastMusicProgress = DateTime.now();
          try { if (mounted) setState(() { _musicProgress = t > 0 ? c / t : 0.0; _musicStep = stepIdx; }); } catch (_) {}
        },
        state: _musicState,
      );
      await orch.run(fromStep: fromStep, toStep: toStep);
      HistoryRecorder.record().ignore();
    } catch (e) {
      _musicLog('  ❌ Pipeline 執行錯誤: $e');
    } finally {
      _logFlushTimer?.cancel();
      _flushLogs();
      if (mounted) setState(() { _musicRunning = false; _musicProgress = 0; });
    }
  }

  /// 用 opencode 問 podcast 內容（RAG skill 已安裝）。
  void _openOpencode() {
    try {
      Process.run('cmd', ['/c', 'start', 'opencode'], runInShell: false).ignore();
    } catch (e) {
      _musicLog('⚠️ 無法啟動 opencode: $e');
    }
  }

  void _openExtractor() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const AudioExtractorPage(),
    ));
  }

  Future<void> _runRagOnly() async {
    if (_ragRunning || _musicRunning) return;
    setState(() { _ragRunning = true; _ragProgress = 0; });
    _podcastLog('RAG 索引更新啟動中…');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      final ragStart = DateTime.now();
      await RagService.instance.build((line) {
        _podcastLog(line);
        // Parse progress: [50/1668] 3.0% ...
        final match = RegExp(r'\[(\d+)/(\d+)\]\s+([\d.]+)%').firstMatch(line);
        if (match != null) {
          final pct = (double.tryParse(match.group(3) ?? '') ?? 0) / 100;
          final done = pct >= 1.0;
          if (!done && _throttleProgress(_lastRagProgress)) return;
          _lastRagProgress = DateTime.now();
          if (mounted) setState(() => _ragProgress = pct);
        }
      });
      final elapsed = DateTime.now().difference(ragStart).inMinutes;
      _podcastLog('RAG 完成 ($elapsed分)');
    } catch (e) {
      _podcastLog('  ❌ RAG 更新錯誤: $e');
    } finally {
      _logFlushTimer?.cancel();
      _flushLogs();
      if (mounted) setState(() { _ragRunning = false; _ragProgress = 0; });
    }
  }

  Future<void> _runPodcast() async {
    if (_podcastRunning) return;
    setState(() { _podcastRunning = true; _podcastProgress = 0; });
    _podcastState = PipelineState();
    _podcastLog('Podcast Pipeline 啟動中…');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    try {
      try { await ChineseConverter.instance.load(); } catch (e) { _podcastLog('注意: 中文轉換器載入失敗: $e'); }

      final pipeline = PodcastPipeline(
        onLog: _podcastLog,
        onProgress: (c, t, stepIdx) {
          final done = t <= 0 || c >= t;
          if (!done && _throttleProgress(_lastPodcastProgress)) return;
          _lastPodcastProgress = DateTime.now();
          try { if (mounted) setState(() { _podcastProgress = t > 0 ? c / t : 0.0; }); } catch (_) {}
        },
        state: _podcastState,
      );
      await pipeline.run();
    } catch (e) {
      _podcastLog('  ❌ Podcast Pipeline 錯誤: $e');
    } finally {
      _logFlushTimer?.cancel();
      _flushLogs();
      if (mounted) setState(() { _podcastRunning = false; _podcastProgress = 0; });
    }
  }

  Widget _buildLogPanel({
    required List<String> logs,
    required ScrollController scrollCtrl,
    required String title,
    required Color accentColor,
    bool empty = false,
  }) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
              child: Text(title, style: TextStyle(
                color: accentColor, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF080808),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: logs.isEmpty
                  ? Center(child: Text(empty ? '' : t('pipeline.log_placeholder'),
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12)))
                  : SelectionArea(child: ListView.builder(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.all(10),
                      itemCount: logs.length,
                      itemBuilder: (ctx, i) {
                        final line = logs[i];
                        Color? color;
                        if (line.contains('❌')) { color = Colors.red[300]; }
                        else if (line.contains('✅') || line.contains('完成')) { color = accentColor; }
                        else if (line.contains('---')) { color = Colors.cyan[300]; }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(line, style: TextStyle(fontSize: 11, fontFamily: 'Consolas',
                              color: color ?? AppColors.textMuted, height: 1.4)),
                        );
                      },
                    )),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasLogs = _musicLogs.isNotEmpty || _podcastLogs.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            _PButton(t('pipeline.run_all'), Icons.play_arrow_rounded, () => _run(), _musicRunning, isPrimary: true),
            _PButton(t('pipeline.run_convert'), Icons.transform, () => _run(fromStep: 0, toStep: 1), _musicRunning),
            _PButton(t('pipeline.run_scrape'), Icons.cloud_download, () => _run(fromStep: 1, toStep: 2), _musicRunning),
_PButton(t('pipeline.run_prune'), Icons.cleaning_services, () => _run(fromStep: 2, toStep: 3), _musicRunning),
        _PButton(t('pipeline.run_podcast'), Icons.podcasts, _runPodcast, _podcastRunning, color: const Color(0xFFCE93D8)),
        _PButton(t('pipeline.run_rag'), Icons.auto_awesome, _runRagOnly, _ragRunning || _musicRunning, color: const Color(0xFF4DB6AC)),
        _PButton(t('pipeline.run_opencode'), Icons.forum_outlined, _openOpencode, false, color: const Color(0xFF9575CD)),
        _PButton('音軌抽取', Icons.audio_file_outlined, _openExtractor, false, color: const Color(0xFFFFB74D)),
            if (_musicRunning) ...[
              _PButton(t('pipeline.pause'), Icons.pause_rounded, () {
                _musicState.pause();
                _musicLog('Pipeline 已暫停');
                setState(() {});
              }, false, color: Colors.orange),
              _PButton(t('pipeline.cancel'), Icons.stop_rounded, () {
                _musicState.cancel();
                _musicLog('正在取消 Pipeline…');
                setState(() {});
              }, false, color: AppColors.error),
            ],
            if (_podcastRunning) ...[
              _PButton(t('pipeline.pause'), Icons.pause_rounded, () {
                _podcastState.pause();
                _podcastLog('Podcast Pipeline 已暫停');
                setState(() {});
              }, false, color: Colors.orange),
              _PButton(t('pipeline.cancel'), Icons.stop_rounded, () {
                _podcastState.cancel();
                _podcastLog('正在取消 Podcast Pipeline…');
                setState(() {});
              }, false, color: AppColors.error),
            ],
            if (hasLogs) ...[
              _PButton(t('pipeline.clear_log'), Icons.delete_outline_rounded, () {
                _musicLogs.clear();
                _podcastLogs.clear();
                setState(() {});
              }, false, color: AppColors.textMuted),
              if (_musicLogs.isNotEmpty)
                _PButton('複製音樂', Icons.copy_rounded, () {
                  Clipboard.setData(ClipboardData(text: _musicLogs.join('\n')));
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已複製'), duration: Duration(seconds: 1)),
                    );
                  }
                }, false, color: AppColors.textSecondary),
              if (_podcastLogs.isNotEmpty)
                _PButton('複製 Podcast', Icons.copy_rounded, () {
                  Clipboard.setData(ClipboardData(text: _podcastLogs.join('\n')));
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已複製'), duration: Duration(seconds: 1)),
                    );
                  }
                }, false, color: AppColors.textSecondary),
            ],
          ]),
          const SizedBox(height: 20),
          AnimatedSize(duration: const Duration(milliseconds: 300), curve: Curves.easeOut,
            child: (_musicRunning || _musicProgress > 0 || _podcastRunning || _podcastProgress > 0 || _ragRunning || _ragProgress > 0)
                ? Column(children: [
                    if (_musicRunning || _musicProgress > 0) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _musicProgress, backgroundColor: AppColors.surfaceLight,
                          valueColor: const AlwaysStoppedAnimation(AppColors.accent), minHeight: 7,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('${_stepLabels[_musicStep]}  (${(_musicProgress * 100).toStringAsFixed(0)}%)',
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                        const Spacer(),
                        if (_musicRunning)
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      ]),
                      const SizedBox(height: 16),
                    ],
                    if (_podcastRunning || _podcastProgress > 0) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _podcastProgress, backgroundColor: AppColors.surfaceLight,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFFCE93D8)), minHeight: 7,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('Podcast  (${(_podcastProgress * 100).toStringAsFixed(0)}%)',
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                        const Spacer(),
                        if (_podcastRunning)
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      ]),
                    ],
                    if (_ragRunning || _ragProgress > 0) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _ragProgress, backgroundColor: AppColors.surfaceLight,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFF4DB6AC)), minHeight: 7,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('RAG 向量索引  (${(_ragProgress * 100).toStringAsFixed(0)}%)',
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                        const Spacer(),
                        if (_ragRunning)
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      ]),
                    ],
                  ])
                : const SizedBox.shrink(),
          ),
          if (_musicRunning || _musicProgress > 0 || _podcastRunning || _podcastProgress > 0) const SizedBox(height: 16),
          if (_musicRunning || _musicProgress > 0)
            Row(
              children: List.generate(_stepLabels.length, (i) {
                final active = i == _musicStep && _musicRunning;
                final done = i < _musicStep;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        height: 5,
                        decoration: BoxDecoration(
                          color: done ? AppColors.accent : (active ? AppColors.accent.withValues(alpha: 0.6) : AppColors.surfaceLight),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(_stepLabels[i], style: TextStyle(
                        color: done ? AppColors.accent : (active ? AppColors.text : AppColors.textMuted),
                        fontSize: 10, fontWeight: done || active ? FontWeight.w600 : FontWeight.normal,
                      )),
                    ]),
                  ),
                );
              }),
            ),
          if (_podcastRunning)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Podcast Pipeline 執行中…',
                  style: TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLogPanel(
                  logs: _musicLogs, scrollCtrl: _musicScrollCtrl,
                  title: '🎵 音樂 Pipeline', accentColor: AppColors.accent,
                ),
                const SizedBox(width: 12),
                _buildLogPanel(
                  logs: _podcastLogs, scrollCtrl: _podcastScrollCtrl,
                  title: '🎙️ Podcast Pipeline', accentColor: const Color(0xFFCE93D8),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _PButton extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onPressed;
  final bool disabled; final bool isPrimary; final Color? color;
  const _PButton(this.label, this.icon, this.onPressed, this.disabled,
      {this.isPrimary = false, this.color});

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
        disabledForegroundColor: AppColors.textMuted,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    );
  }
}
