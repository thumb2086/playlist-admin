import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/audio_extractor.dart';
import '../widgets/dark_theme.dart';

/// 音軌抽取（DeepFilterNet 降噪）：從影片批次抽音軌 → m4a/wav/flac。
class AudioExtractorPage extends StatefulWidget {
  const AudioExtractorPage({super.key});
  @override
  State<AudioExtractorPage> createState() => _AudioExtractorPageState();
}

class _AudioExtractorPageState extends State<AudioExtractorPage> {
  String _profile = 'default';
  AudioExtractorConfig _cfg = AudioExtractorStore.loadConfig();
  List<VideoFile> _files = [];
  final Set<int> _sel = {};
  bool _scanning = false, _running = false, _cancel = false;
  int _done = 0, _total = 1;
  final List<String> _logs = [];
  final _logCtrl = ScrollController();
  // onLog 高頻（deepFilter 進度行）：300ms 批量 flush，否則 setState 風暴卡 UI。
  final _logPending = <String>[];
  Timer? _logFlushTimer;

  @override
  void initState() {
    super.initState();
    _profile = AudioExtractorStore.activeProfile();
    _cfg = AudioExtractorStore.loadConfig(_profile);
    if (_cfg.sourceDir.isNotEmpty && Directory(_cfg.sourceDir).existsSync()) {
      _tryCache();
    }
  }

  @override
  void dispose() {
    _logFlushTimer?.cancel();
    _logCtrl.dispose();
    super.dispose();
  }

  void _pushLog(String l) {
    _logPending.add(l);
    if (_logFlushTimer?.isActive ?? false) return;
    _logFlushTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) { _logPending.clear(); return; }
      setState(() {
        _logs.addAll(_logPending);
        _logPending.clear();
        if (_logs.length > 1000) _logs.removeRange(0, _logs.length - 1000);
      });
      if (_logCtrl.hasClients) {
        final pos = _logCtrl.position;
        if (pos.hasContentDimensions && pos.maxScrollExtent - pos.pixels <= 200) {
          try { _logCtrl.jumpTo(pos.maxScrollExtent); } catch (_) {}
        }
      }
    });
  }

  void _switchProfile(String name) {
    if (name == _profile) return;
    AudioExtractorStore.setActiveProfile(name);
    setState(() {
      _profile = name;
      _cfg = AudioExtractorStore.loadConfig(name);
      _files = [];
      _sel.clear();
      _logs.clear();
    });
    if (_cfg.sourceDir.isNotEmpty && Directory(_cfg.sourceDir).existsSync()) _tryCache();
  }

  void _tryCache() {
    // async 載入：舊同步版在 initState 逐檔 stat，大目錄凍結首幀。
    _tryCacheAsync();
  }

  Future<void> _tryCacheAsync() async {
    final cached = await AudioExtractorStore.loadCacheAsync(_cfg.sourceDir);
    if (!mounted) return;
    if (cached != null) {
      _files = cached;
      final thr = _cfg.silenceThreshold;
      for (int i = 0; i < _files.length; i++) {
        if (_files[i].tracks.any((t) => t.bitRate <= 0 || t.bitRate >= thr)) _sel.add(i);
      }
    } else {
      // 換目錄無快取：清空舊清單，避免 _start 抽到舊資料夾的檔案
      _files = [];
      _sel.clear();
    }
    if (mounted) setState(() {});
  }

  Future<void> _pickSource() async {
    final d = await FilePicker.getDirectoryPath();
    if (d == null) return;
    if (!mounted) return;
    _cfg.sourceDir = d;
    _cfg.outputDir = p.join(d, 'extracted_audio');
    AudioExtractorStore.saveConfig(_cfg, _profile);
    _tryCache();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    final targetDir = _cfg.sourceDir;
    setState(() {
      _scanning = true;
      _files = [];
      _sel.clear();
    });
    try {
      const exts = {'.mp4', '.mov', '.mkv', '.avi', '.m4v', '.ts', '.webm'};
      final paths = (await Directory(targetDir).list()
          .where((e) => e is File && exts.contains(p.extension(e.path).toLowerCase()))
          .map((e) => e.path).toList())
        ..sort();
      final files = <VideoFile>[];
      for (int i = 0; i < paths.length; i++) {
        final f = await AudioExtractorEngine.probe(paths[i]);
        if (f != null) files.add(f);
      }
      AudioExtractorStore.saveCache(targetDir, files);
      if (!mounted) return;
      // 掃描期間可能切換設定檔/目錄：只採用「仍是當前目錄」的結果
      if (targetDir != _cfg.sourceDir) return;
      setState(() {
        _files = files;
        final thr = _cfg.silenceThreshold;
        for (int i = 0; i < files.length; i++) {
          if (files[i].tracks.any((t) => t.bitRate <= 0 || t.bitRate >= thr)) _sel.add(i);
        }
      });
    } catch (_) {
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _selAll() => setState(() => _sel.addAll(List.generate(_files.length, (i) => i)));
  void _selNone() => setState(() => _sel.clear());
  void _selN(int n) {
    setState(() {
      _sel.clear();
      for (int i = 0; i < _files.length; i++) {
        if (_files[i].trackCount == n) _sel.add(i);
      }
    });
  }

  Future<void> _pickOut() async {
    final d = await FilePicker.getDirectoryPath();
    if (d != null) {
      _cfg.outputDir = d;
      AudioExtractorStore.saveConfig(_cfg, _profile);
      setState(() {});
    }
  }

  Future<void> _start() async {
    if (_sel.isEmpty) {
      _snack('沒有選取檔案');
      return;
    }
    _done = 0;
    _total = 0;
    _logs.clear();
    final thr = _cfg.silenceThreshold;
    for (final i in _sel) {
      _total += _files[i].tracks.where((t) => t.bitRate <= 0 || t.bitRate >= thr).length;
    }
    if (_total == 0) _total = 1;
    setState(() {
      _running = true;
      _cancel = false;
    });
    final jobs = <({String src, int trackId, int sampleRate, String trackName, bool denoise})>[];
    for (final i in _sel) {
      final f = _files[i];
      final tks = f.tracks.where((t) => t.bitRate <= 0 || t.bitRate >= thr).toList();
      if (tks.isEmpty) continue;
      for (final t in tks) {
        jobs.add((
          src: f.path,
          trackId: t.index,
          sampleRate: t.sampleRate,
          trackName: _cfg.trackNames[t.index] ?? '',
          denoise: _cfg.denoiseTracks.contains(t.index),
        ));
      }
    }
    await AudioExtractorEngine.runParallel(
      jobs: jobs,
      cfg: _cfg,
      onLog: (l) { if (mounted) _pushLog(l); },
      onProgress: () {
        if (!mounted) return;
        setState(() => _done++);
      },
      canceled: () => _cancel,
    );
    if (!mounted) return;
    setState(() => _running = false);
    _snack(_cancel ? '已取消（完成 $_done tracks）' : '完成 $_done tracks');
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void _showSettings() {
    int lufs = _cfg.lufsTarget;
    int thr = _cfg.silenceThreshold;
    int workers = _cfg.workers;
    final pnameCtrl = TextEditingController(text: _profile);
    final dfpCtrl = TextEditingController(text: _cfg.deepFilterPath);
    final nameCtrls = <int, TextEditingController>{};
    final denoiseSel = <int, bool>{};
    for (int t = 1; t <= 6; t++) {
      nameCtrls[t] = TextEditingController(text: _cfg.trackNames[t] ?? '');
      denoiseSel[t] = _cfg.denoiseTracks.contains(t);
    }
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('抽取設定'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('設定檔', style: Theme.of(ctx).textTheme.labelMedium),
                TextField(
                  controller: pnameCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                ),
                Text('改成新名稱存檔 = 另存為新設定檔',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
                const SizedBox(height: 12),
                Text('LUFS 目標', style: Theme.of(ctx).textTheme.labelMedium),
                Slider(
                  value: lufs.toDouble(), min: -30, max: 0, divisions: 30,
                  label: '$lufs LUFS',
                  onChanged: (v) => setDlg(() => lufs = v.round()),
                ),
                Text('$lufs LUFS ${lufs == -14 ? '(YouTube)' : lufs == -16 ? '(Podcast)' : lufs == -23 ? '(Broadcast)' : ''}',
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 12),
                Text('靜音閾值（bitrate，低於此視為靜音軌）', style: Theme.of(ctx).textTheme.labelMedium),
                DropdownButtonFormField<int>(
                  initialValue: thr,
                  items: [5000, 10000, 20000, 50000, 100000]
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v bps')))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDlg(() => thr = v);
                  },
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                Text('並行 ffmpeg（deepFilter 自動序列化，記憶體安全）', style: Theme.of(ctx).textTheme.labelMedium),
                Slider(
                  value: workers.toDouble(), min: 1, max: 2, divisions: 1,
                  label: '$workers',
                  onChanged: (v) => setDlg(() => workers = v.round()),
                ),
                Text('$workers 個 ffmpeg 同時跑；降噪一次只跑 1 個', style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 12),
                Text('DeepFilterNet 降噪（deepFilter.exe 路徑）', style: Theme.of(ctx).textTheme.labelMedium),
                TextField(
                  controller: dfpCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: 'deepFilter（PATH 或完整路徑）',
                  ),
                ),
                const SizedBox(height: 12),
                Text('降噪裝置', style: Theme.of(ctx).textTheme.labelMedium),
                DropdownButtonFormField<String>(
                  initialValue: _cfg.deepFilterDevice,
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自動（GPU 忙就 CPU）')),
                    DropdownMenuItem(value: 'cuda', child: Text('只用 GPU')),
                    DropdownMenuItem(value: 'cpu', child: Text('只用 CPU（不打遊戲最穩）')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDlg(() => _cfg.deepFilterDevice = v);
                  },
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                Text('記憶體模式', style: Theme.of(ctx).textTheme.labelMedium),
                DropdownButtonFormField<String>(
                  initialValue: _cfg.memoryMode,
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自動（依可用 RAM：≥18G品質／≥9G均衡／其餘節能）')),
                    DropdownMenuItem(value: 'quality', child: Text('品質（DF3 fp32，建議可用 RAM ≥18GB，~8GB 佔用）')),
                    DropdownMenuItem(value: 'balanced', child: Text('均衡（DF3 fp16，建議 ≥9GB，~5GB 佔用）')),
                    DropdownMenuItem(value: 'eco', child: Text('節能（DF2 fp16，建議 ≥6GB，~3-4GB 佔用）')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDlg(() => _cfg.memoryMode = v);
                  },
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                ),
                Text('結論：選「自動」最省心；想保證邊看影片邊跑就選「節能」',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
                const SizedBox(height: 12),
                Text('音軌名稱（輸出檔名）｜勾選 = 降噪（通常只有 Mic 需要）', style: Theme.of(ctx).textTheme.labelMedium),
                for (int t = 1; t <= 6; t++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      SizedBox(width: 56, child: Text('Track $t', style: Theme.of(ctx).textTheme.bodySmall)),
                      Expanded(
                        child: TextField(
                          controller: nameCtrls[t],
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            hintText: 'track$t',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Checkbox(
                        value: denoiseSel[t],
                        onChanged: (v) => setDlg(() => denoiseSel[t] = v ?? false),
                        visualDensity: VisualDensity.compact,
                      ),
                    ]),
                  ),
                Text('只對勾選的軌跑 DeepFilterNet（記憶體/速度都會快很多）',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final c in nameCtrls.values) {
                  c.dispose();
                }
                dfpCtrl.dispose();
                Navigator.pop(ctx);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                _cfg.lufsTarget = lufs;
                _cfg.silenceThreshold = thr;
                _cfg.workers = workers;
                _cfg.deepFilterPath = dfpCtrl.text.trim().isEmpty ? 'deepFilter' : dfpCtrl.text.trim();
                _cfg.trackNames = {
                  for (int t = 1; t <= 6; t++)
                    if (nameCtrls[t]!.text.trim().isNotEmpty) t: nameCtrls[t]!.text.trim()
                };
                _cfg.denoiseTracks = {
                  for (int t = 1; t <= 6; t++)
                    if (denoiseSel[t] == true) t
                };
                final newName = pnameCtrl.text.trim();
                AudioExtractorStore.saveConfig(_cfg, newName.isEmpty ? _profile : newName);
                if (newName.isNotEmpty && newName != _profile) {
                  _profile = newName;
                  AudioExtractorStore.setActiveProfile(newName);
                }
                for (final c in nameCtrls.values) {
                  c.dispose();
                }
                dfpCtrl.dispose();
                pnameCtrl.dispose();
                setState(() {});
                Navigator.pop(ctx);
              },
              child: const Text('儲存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('音軌抽取', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          const Text('影片音軌 → m4a/wav/flac（DeepFilterNet 降噪）',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: '設定',
            onPressed: _running ? null : _showSettings,
          ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            Expanded(
              child: Text(
                _cfg.sourceDir.isEmpty ? '(尚未選擇資料夾)' : _cfg.sourceDir,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _running ? null : _pickSource,
              icon: const Icon(Icons.folder_open, size: 14),
              label: const Text('瀏覽'),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: _running ? null : _scan,
              icon: _scanning
                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 14),
              label: Text(_scanning ? '掃描中…' : '掃描'),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ]),
        ),
        if (_files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              const Text('選取: ', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
              _chip('全部', _selAll),
              _chip('無', _selNone),
              _chip('單音軌', () => _selN(1)),
              _chip('5 音軌', () => _selN(5)),
              const Spacer(),
              Text('${_files.length} 檔 | 已選 ${_sel.length}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ]),
          ),
        Expanded(
          child: _files.isEmpty
              ? Center(
                  child: Text(_scanning ? '掃描中…' : '選擇資料夾後按「掃描」',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                )
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (_, i) => _fileTile(i),
                ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<String>(
                initialValue: _profile, key: ValueKey('pl_$_profile'),
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '設定檔',
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                items: AudioExtractorStore.listProfiles()
                    .map((pn) => DropdownMenuItem(
                        value: pn,
                        child: Text(pn, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: _running ? null : (v) {
                  if (v != null) _switchProfile(v);
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<String>(
                initialValue: _cfg.format, key: ValueKey('fmt_${_cfg.format}'),
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '格式', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                items: ['aac', 'wav', 'flac']
                    .map((f) => DropdownMenuItem(
                        value: f,
                        child: Text(f == 'aac' ? 'AAC (m4a)' : f.toUpperCase(), style: const TextStyle(fontSize: 13))))
                    .toList(),
                onChanged: _running
                    ? null
                    : (v) {
                        _cfg.format = v!;
                        _cfg.bitrate = v == 'aac' ? '384k' : '-';
                        AudioExtractorStore.saveConfig(_cfg, _profile);
                        setState(() {});
                      },
              ),
            ),
            if (_cfg.format == 'aac') ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: DropdownButtonFormField<String>(
                  initialValue: _cfg.bitrate, key: ValueKey('br_${_cfg.bitrate}'),
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Bitrate', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  items: ['128k', '192k', '256k', '320k', '384k', '512k']
                      .map((b) => DropdownMenuItem(value: b, child: Text(b, style: const TextStyle(fontSize: 13))))
                      .toList(),
                  onChanged: _running
                      ? null
                      : (v) {
                          _cfg.bitrate = v!;
                          AudioExtractorStore.saveConfig(_cfg, _profile);
                          setState(() {});
                        },
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _showSettings,
                child: Text('${_cfg.lufsTarget} LUFS',
                    style: const TextStyle(fontSize: 12, color: AppColors.accent, decoration: TextDecoration.underline)),
              ),
            ],
            const Spacer(),
            FilledButton.icon(
              onPressed: _running ? null : _start,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('開始抽取'),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text('輸出: ${_cfg.outputDir.isEmpty ? '(未設定)' : _cfg.outputDir}',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted), overflow: TextOverflow.ellipsis),
          ),
          TextButton(onPressed: _running ? null : _pickOut, child: const Text('變更', style: TextStyle(fontSize: 11))),
        ]),
        if (_running || _done > 0) ...[
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: LinearProgressIndicator(value: _total > 0 ? _done / _total : 0),
            ),
            const SizedBox(width: 8),
            Text('$_done / $_total tracks', style: const TextStyle(fontSize: 11)),
            if (_running) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _cancel = true,
                icon: const Icon(Icons.stop, size: 14),
                label: const Text('取消', style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ]),
        ],
        if (_logs.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            height: 140,
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            padding: const EdgeInsets.all(6),
            child: ListView.builder(
              controller: _logCtrl,
              itemCount: _logs.length,
              itemBuilder: (_, i) {
                final l = _logs[i];
                return Text(l,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: l.startsWith('FAIL') ? Colors.redAccent : AppColors.textSecondary,
                    ));
              },
            ),
          ),
        ],
      ]),
    );
  }

  Widget _chip(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ActionChip(
          label: Text(label, style: const TextStyle(fontSize: 11)),
          onPressed: _running ? null : onTap,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
      );

  Widget _fileTile(int i) {
    final f = _files[i];
    final checked = _sel.contains(i);
    return InkWell(
      onTap: _running ? null : () => setState(() {
            if (checked) {
              _sel.remove(i);
            } else {
              _sel.add(i);
            }
          }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.4))),
        ),
        child: Row(children: [
          Checkbox(
            value: checked,
            onChanged: _running
                ? null
                : (v) => setState(() {
                      if (v == true) {
                        _sel.add(i);
                      } else {
                        _sel.remove(i);
                      }
                    }),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
              Text('${f.trackCount} tracks | ${f.sizeLabel} | ${f.durLabel}',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
              if (f.trackCount > 0)
                Text(f.tracks.map((t) => t.detail).join('  |  '),
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
                    overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }
}