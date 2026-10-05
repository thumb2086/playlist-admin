import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/sync_client.dart';
import '../services/sync_server.dart';
import '../services/config_service.dart';
import '../widgets/dark_theme.dart';

/// 手機一鍵同步：從區網電腦把 mp3 拉下來（全程區網、不耗行動數據）。
/// 電腦端先在「設定 → 手機同步（區網）」打開開關。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final _ipCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '${SyncServer.httpPortBase}');
  List<SyncHost> _hosts = [];
  SyncHost? _host;
  bool _busy = false;
  String _status = '';
  List<SyncTrack> _missing = [];
  int _done = 0, _total = 0, _failed = 0;
  int _plsDone = 0, _plsTotal = 0;
  String _current = '';
  double _fileProgress = 0;
  bool _cancel = false;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  void _say(String s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  Future<void> _discover() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _hosts = [];
      _host = null;
      _missing = [];
    });
    _say('正在搜尋區網電腦…（手機電腦須連同一個 Wi-Fi）');
    try {
      final hosts = await SyncClient.discover();
      if (!mounted) return;
      setState(() => _hosts = hosts);
      _say(hosts.isEmpty
          ? '沒找到。確認電腦端開關已開，或改手輸 IP。'
          : '找到 ${hosts.length} 台，點一台連線。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(SyncHost h) async {
    setState(() {
      _host = h;
      _missing = [];
      _done = 0;
      _total = 0;
      _failed = 0;
      _plsDone = 0;
      _plsTotal = 0;
    });
    // 記住電腦位址：直連播不動時，播放器經這台轉播（免再掃描）。
    try {
      final c = ConfigService.instance.config;
      c.lastSyncHost = '${h.ip}:${h.port}';
      await ConfigService.instance.save();
    } catch (_) {}
    _say('已連線 ${h.ip}:${h.port}（電腦共 ${h.tracks} 首），按「比對差異」。');
  }

  /// 掃電腦設定頁的 QR（內容就是 http://ip:port）：掃到→ping→連線。
  /// 相機被拒/掃到別的東西都有文字回報，不靜默失敗。
  Future<void> _scanQr() async {
    if (_busy) return;
    String? code;
    try {
      code = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _ScanPage()),
      );
    } catch (e) {
      _say('開相機失敗：$e（檢查相機權限）');
      return;
    }
    if (!mounted || code == null || code.isEmpty) return;
    final m =
        RegExp(r'http://([\d.]+):(\d+)').firstMatch(code.trim());
    if (m == null) {
      _say('這個 QR 不是電腦同步網址（要掃設定頁「手機同步」的 QR）');
      return;
    }
    final port = int.tryParse(m.group(2)!) ?? 0;
    if (port <= 0) return;
    _ipCtrl.text = m.group(1)!;
    _portCtrl.text = '$port';
    setState(() => _busy = true);
    _say('QR 掃到 ${m.group(1)}:$port，連線中…');
    try {
      final h = await SyncClient.ping(m.group(1)!, port);
      if (!mounted) return;
      if (h == null) {
        _say('連不上（電腦開關沒開？不同 Wi-Fi？熱點 IP 變了？重看電腦 QR）');
      } else {
        await _connect(h);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectManual() async {    final ip = _ipCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 0;
    if (ip.isEmpty || port <= 0) {
      _say('IP 或 port 不對。port 預設 ${SyncServer.httpPortBase}。');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    _say('連線中…');
    try {
      final h = await SyncClient.ping(ip, port);
      if (!mounted) return;
      if (h == null) {
        _say('連不上 $ip:$port（電腦開關沒開？不同 Wi-Fi？IP 打錯？）');
      } else {
        await _connect(h);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _diff() async {
    final h = _host;
    if (h == null || _busy) return;
    setState(() {
      _busy = true;
      _missing = [];
    });
    _say('抓電腦清單、掃本機…');
    try {
      final remote = await SyncClient.fetchTracks(h);
      final local = await SyncClient.localIndex();
      final missing = SyncClient.diff(remote, local);
      if (!mounted) return;
      setState(() => _missing = missing);
      _say(missing.isEmpty
          ? '已經完全同步，不缺歌。'
          : '手機缺 ${missing.length} 首，按「一鍵同步」。');
    } catch (e) {
      _say('比對失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 歌單同步：清單→逐一下載 m3u8→urlNames 補上缺的（音樂庫卡片靠它長出來）。
  /// 覆寫本機同名歌單（電腦是唯一真相來源）。
  Future<void> _syncPlaylists() async {
    final h = _host;
    if (h == null || _busy) return;
    setState(() {
      _busy = true;
      _plsDone = 0;
      _plsTotal = 0;
    });
    _say('抓電腦歌單清單…');
    try {
      final remote = await SyncClient.fetchPlaylists(h);
      if (!mounted) return;
      if (remote.isEmpty) {
        _say('電腦沒有歌單。');
        return;
      }
      setState(() => _plsTotal = remote.length);
      var ok = 0;
      final cfg = ConfigService.instance.config;
      var urlAdded = 0;
      for (final p in remote) {
        if (!mounted) break;
        final good = await SyncClient.downloadPlaylist(h, p.name);
        if (!mounted) break;
        if (good) {
          ok++;
          // urlNames 補上：音樂庫卡片列表讀它；已有不覆蓋（手機端不改名）。
          if (p.url.isNotEmpty && !cfg.urlNames.containsKey(p.url)) {
            cfg.urlNames[p.url] = p.name;
            urlAdded++;
          }
        }
        if (mounted) setState(() => _plsDone = ok);
      }
      if (urlAdded > 0) {
        try {
          await ConfigService.instance.save();
        } catch (_) {}
      }
      _say('歌單同步完成：$ok/${remote.length}（音樂庫多了 $urlAdded 個歌單）');
    } catch (e) {
      _say('歌單同步失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncAll() async {
    final h = _host;
    if (h == null || _busy || _missing.isEmpty) return;
    setState(() {
      _busy = true;
      _cancel = false;
      _done = 0;
      _failed = 0;
      _total = _missing.length;
      _fileProgress = 0;
    });
    for (final t in List.of(_missing)) {
      if (_cancel || !mounted) break;
      setState(() => _current = t.path.split('/').last);
      final ok = await SyncClient.download(h, t,
          onProgress: (d, total) {
        if (!mounted) return;
        // 每 5% 更新一次就好，一直 setState 會卡。
        final p = total > 0 ? d / total : 0.0;
        if ((p - _fileProgress).abs() > 0.05 || p >= 1) {
          setState(() => _fileProgress = p);
        }
      });
      if (!mounted) break;
      setState(() {
        if (ok) {
          _done++;
          _missing.remove(t);
        } else {
          _failed++;
          _done++;
        }
        _fileProgress = 0;
      });
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = _cancel
        ? '已取消：成功 $_done 首、失敗 $_failed 首'
        : '同步完成：成功 $_done 首${_failed > 0 ? '、失敗 $_failed 首' : ''}';
    _say(msg);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final h = _host;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('從電腦同步',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        backgroundColor: AppColors.bg,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('全程走區網 Wi-Fi，不耗行動數據。電腦端先開「設定 → 手機同步」。',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _discover,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.radar_rounded, size: 16),
                  label: const Text('搜尋區網電腦'),
                ),
              ),
            ]),
            if (_hosts.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final host in _hosts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    onTap: _busy ? null : () => _connect(host),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: h?.ip == host.ip && h?.port == host.port
                            ? AppColors.accentDim
                            : AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(children: [
                        const Icon(Icons.computer_rounded,
                            size: 16, color: AppColors.textMuted),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text('$host',
                                style: const TextStyle(fontSize: 13))),
                        if (h?.ip == host.ip && h?.port == host.port)
                          const Icon(Icons.check_circle,
                              size: 16, color: AppColors.accent),
                      ]),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _ipCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: '手輸 IP，如 192.168.1.5',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  )),
              const SizedBox(width: 8),
              Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'port',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                  )),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _busy ? null : _connectManual,
                child: const Text('連線'),
              ),
              const SizedBox(width: 8),
              // 掃電腦設定頁的 QR（http://ip:port）：免手輸。
              IconButton(
                onPressed: _busy ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                tooltip: '掃電腦 QR 連線',
                style: IconButton.styleFrom(
                    backgroundColor: AppColors.surfaceLight),
              ),
            ]),
            const SizedBox(height: 12),
            if (_status.isNotEmpty)
              Text(_status,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 8),
            if (h != null) ...[
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _diff,
                    icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                    label: Text(_missing.isEmpty ? '比對差異' : '重新比對'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_busy || _missing.isEmpty) ? null : _syncAll,
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: Text(_missing.isEmpty
                        ? '一鍵同步'
                        : '一鍵同步（${_missing.length}）'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              // 歌單同步：m3u8 拉回來＋urlNames 補上，音樂庫卡片才長得出來。
              // （之前只同步音樂檔，手機音乐庫永遠是空的。）
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _syncPlaylists,
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 16),
                  label: Text(_plsTotal > 0
                      ? '同步歌單（$_plsDone/$_plsTotal）'
                      : '同步歌單'),
                ),
              ),
              if (_busy && _total > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _total > 0 ? _done / _total : 0,
                    minHeight: 5,
                    backgroundColor: AppColors.surfaceLight,
                    valueColor:
                        const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 4),
                Text('$_done/$_total${_failed > 0 ? '（失敗 $_failed）' : ''} · $_current',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMuted)),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: () => setState(() => _cancel = true),
                  icon: const Icon(Icons.stop_rounded, size: 14),
                  label: const Text('取消',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// QR 掃描頁（同步電腦用）：對準電腦設定頁的 QR 即自動回傳網址。
class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _ctl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('掃電腦 QR', style: TextStyle(fontSize: 15)),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: MobileScanner(
        controller: _ctl,
        onDetect: (cap) {
          if (_done || cap.barcodes.isEmpty) return;
          final v = cap.barcodes.first.rawValue;
          if (v == null || v.isEmpty) return;
          _done = true;
          Navigator.of(context).pop(v);
        },
      ),
    );
  }
}
