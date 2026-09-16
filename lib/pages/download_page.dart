import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../services/i18n.dart';
import '../services/download_service.dart';
import '../services/podcast_service.dart';
import '../models/podcast_episode.dart';
import '../models/podcast_search_result.dart';
import '../widgets/dark_theme.dart';
import 'pipeline_page.dart';
import 'spotube_page.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  int _tabIndex = 0;

  void _onI18n() { if (mounted) setState(() {}); }

  @override
  void initState() {
    super.initState();
    I18N.instance.addListener(_onI18n);
  }

  @override
  void dispose() {
    I18N.instance.removeListener(_onI18n);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                _tabButton(0, Icons.podcasts, t('download.tab_podcast')),
                _tabButton(1, Icons.music_note, t('download.tab_song')),
                _tabButton(2, Icons.download, '批量下載'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: IndexedStack(
              index: _tabIndex,
              children: const [
                _PodcastTab(),
                _SongDownloadTab(),
                SpotubePage(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(int index, IconData icon, String label) {
    final selected = _tabIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tabIndex = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.card : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: selected ? AppColors.accent : AppColors.textMuted),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? AppColors.text : AppColors.textMuted,
              )),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadJob {
  String title;
  double progress = 0;
  bool done = false;
  bool skipped = false;
  bool failed = false;
  bool cancelled = false;
  _DownloadJob({required this.title});
}

class _PodcastTab extends StatefulWidget {
  const _PodcastTab();
  @override
  State<_PodcastTab> createState() => _PodcastTabState();
}

class _PodcastTabState extends State<_PodcastTab> {
  final _searchCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _logs = <String>[];
  final _scrollCtrl = ScrollController();
  List<PodcastSearchResult> _searchResults = [];
  List<PodcastEpisode> _episodes = [];
  String _podcastTitle = '';
  String _currentRssUrl = '';
  bool _loading = false;
  bool _searching = false;
  bool _showUrlInput = false;
  final Set<int> _selected = {};
  int _maxEpisodes = 100;
  final List<_DownloadJob> _jobs = [];
  // log 節流：下載進度每 chunk 一次 setState 會卡 UI，300ms 批量 flush。
  final _logPending = <String>[];
  Timer? _logFlushTimer;
  static const int _maxLogLines = 800;

  Map<String, String> get _history => ConfigService.instance.config.podcastHistory;
  Map<String, String> get _subscriptions => ConfigService.instance.config.podcastSubscriptions;

  void _saveHistory(String title, String url) {
    final cfg = ConfigService.instance.config;
    cfg.podcastHistory[title] = url;
    while (cfg.podcastHistory.length > 30) { cfg.podcastHistory.remove(cfg.podcastHistory.keys.first); }
    ConfigService.instance.save();
  }

  void _toggleSubscription(String name, String rssUrl) {
    final cfg = ConfigService.instance.config;
    if (cfg.podcastSubscriptions.containsKey(name)) {
      cfg.podcastSubscriptions.remove(name);
      _log('🔔 已取消訂閱: $name');
    } else {
      cfg.podcastSubscriptions[name] = rssUrl;
      _log('🔔 已訂閱: $name');
    }
    ConfigService.instance.save();
    if (mounted) setState(() {});
  }

  bool _isSubscribed(String name) => _subscriptions.containsKey(name);

  @override
  void dispose() { _logFlushTimer?.cancel(); _searchCtrl.dispose(); _urlCtrl.dispose(); _scrollCtrl.dispose(); super.dispose(); }

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

  Future<void> _searchPodcasts() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() { _searching = true; _searchResults = []; _episodes = []; _podcastTitle = ''; _currentRssUrl = ''; _selected.clear(); });
    try {
      final results = await PodcastService.instance.searchPodcasts(query);
      setState(() { _searchResults = results; _searching = false; });
      _log('✅ 找到 ${results.length} 個節目');
    } catch (e) { _log('❌ 搜尋失敗: $e'); setState(() => _searching = false); }
  }

  Future<void> _selectPodcast(PodcastSearchResult pod) async {
    setState(() { _loading = true; _episodes = []; _podcastTitle = ''; _currentRssUrl = pod.feedUrl; _selected.clear(); });
    try {
      final result = await PodcastService.instance.fetchEpisodes(pod.feedUrl);
      setState(() { _podcastTitle = result.title; _episodes = result.episodes; _maxEpisodes = result.episodes.length; _loading = false; _searchCtrl.text = pod.title; _searchResults = []; });
      _refreshDiskNames();
      _saveHistory(pod.title, pod.feedUrl);
      _log('✅ ${result.title}: ${result.episodes.length} 集');
    } catch (e) { _log('❌ 讀取節目失敗: $e'); setState(() => _loading = false); }
  }

  void _loadFromHistory(String title) {
    final url = _history[title];
    if (url == null) return;
    _searchCtrl.text = title;
    _urlCtrl.text = url;
    _fetchByUrl();
  }

  Future<void> _fetchByUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() { _loading = true; _episodes = []; _podcastTitle = ''; _currentRssUrl = url; _selected.clear(); });
    try {
      final result = await PodcastService.instance.fetchEpisodes(url);
      setState(() { _podcastTitle = result.title; _episodes = result.episodes; _maxEpisodes = result.episodes.length; _loading = false; });
      _refreshDiskNames();
      _saveHistory(result.title, url);
      _log('✅ 找到 ${result.episodes.length} 集');
    } catch (e) { _log('❌ 讀取 RSS 失敗: $e'); setState(() => _loading = false); }
  }

  List<PodcastEpisode> get _displayEpisodes => _episodes.take(_maxEpisodes).toList();

  /// 當前節目錄磁碟檔名快取：每列每 rebuild 都打 disk 太傷，
  /// 载入清單/下載完成時刷一次，列內純記憶體比對 + 慢速 fallback。
  /// EP 號也建成常駐 map（舊寫法 miss 時全目錄 listSync）。
  Set<String> _diskNames = {};
  Map<int, String> _epNumIndex = {};

  Future<void> _refreshDiskNames() async {
    final names = <String>{};
    final epMap = <int, String>{};
    final epRe = RegExp(r'EP(\d+)', caseSensitive: false);
    try {
      final dir = Directory(PodcastService.instance.podcastDir(_podcastTitle));
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File) {
            final stem = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
            names.add(stem.toLowerCase());
            final m = epRe.firstMatch(stem);
            if (m != null) {
              final n = int.tryParse(m.group(1)!);
              if (n != null) epMap.putIfAbsent(n, () => f.path);
            }
          }
        }
      }
    } catch (_) {}
    _diskNames = names;
    _epNumIndex = epMap;
    if (mounted) setState(() {});
  }

  bool _isDownloaded(int index) {
    if (index >= _episodes.length) return false;
    final ep = _episodes[index];
    if (_diskNames.contains(PodcastService.normalizeFileName(ep.title).toLowerCase())) return true;
    // EP 號走常駐 map，不再全目錄掃描。
    final titleEp = RegExp(r'EP(\d+)', caseSensitive: false).firstMatch(ep.title);
    if (titleEp != null) {
      final n = int.tryParse(titleEp.group(1)!);
      if (n != null && _epNumIndex.containsKey(n)) return true;
    }
    return PodcastService.instance.isEpisodeDownloaded(ep.title, ep.audioUrl, podcastName: _podcastTitle);
  }

  void _cancelAllDownloads() {
    // 真取消：flag 會中斷底層 downloadEpisode 串流（殘檔自動清），
    // 不再只是改 UI 狀態讓底層照跑。
    for (final j in _jobs) {
      if (!j.done && !j.failed) {
        j.cancelled = true;
        j.failed = true;
        _log('⏹️ 已取消: ${j.title}');
      }
    }
    setState(() {});
  }

  /// 進度節流：每 chunk 都 setState 會卡 UI，變化夠大或完成才更新。
  void _jobProgress(_DownloadJob job, double p) {
    if (!mounted) return;
    if (p < 1.0 && (p - job.progress).abs() < 0.02) return;
    setState(() => job.progress = p);
  }

  Future<void> _downloadEpisode(int index) async {
    if (_currentRssUrl.isEmpty) return;
    if (_isDownloaded(index)) { _log('⏭️ 已有檔案: ${_episodes[index].title}'); return; }
    final job = _DownloadJob(title: _episodes[index].title);
    setState(() { _jobs.add(job); });
    try {
      // 回傳 false = 已存在跳過，不可打 ✅ 當新增。
      final fresh = await PodcastService.instance.downloadEpisode(_currentRssUrl, index,
          (p) => _jobProgress(job, p),
          podcastName: _podcastTitle,
          knownTitle: _episodes[index].title,
          knownAudioUrl: _episodes[index].audioUrl,
          isCancelled: () => job.cancelled);
      job.done = true;
      _diskNames.add(PodcastService.normalizeFileName(_episodes[index].title).toLowerCase());
      _log(fresh ? '✅ ${_episodes[index].title}' : '⏭️ 已有檔案: ${_episodes[index].title}');
    } catch (e) {
      job.failed = true;
      // 取消不算錯誤（_cancelAllDownloads 已 log 過）。
      if (e is! DownloadCancelled) _log('❌ ${_episodes[index].title}: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _downloadSelected() async {
    if (_selected.isEmpty || _currentRssUrl.isEmpty) return;
    final indices = _selected.toList()..sort();
    _selected.clear();
    for (final idx in indices) {
      if (_isDownloaded(idx)) { _log('⏭️ 已有檔案: ${_episodes[idx].title}'); continue; }
      final job = _DownloadJob(title: _episodes[idx].title);
      setState(() { _jobs.add(job); });
      _downloadSingleInBg(idx, job);
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _downloadSingleInBg(int idx, _DownloadJob job) async {
    try {
      final fresh = await PodcastService.instance.downloadEpisode(_currentRssUrl, idx,
          (p) => _jobProgress(job, p),
          podcastName: _podcastTitle,
          knownTitle: _episodes[idx].title,
          knownAudioUrl: _episodes[idx].audioUrl,
          isCancelled: () => job.cancelled);
      job.done = true;
      _diskNames.add(PodcastService.normalizeFileName(_episodes[idx].title).toLowerCase());
      _log(fresh ? '✅ ${_episodes[idx].title}' : '⏭️ 已有檔案: ${_episodes[idx].title}');
    } catch (e) {
      job.failed = true;
      if (e is! DownloadCancelled) _log('❌ ${_episodes[idx].title}: $e');
    }
    if (mounted) setState(() {});
  }

  void _clearCompletedJobs() { _jobs.removeWhere((j) => j.done || j.failed); setState(() {}); }

  void _toggleSelect(int index) { setState(() { if (_selected.contains(index)) {
    _selected.remove(index);
  } else {
    _selected.add(index);
  } }); }

  void _selectAll() {
    // _displayEpisodes 恆為 _episodes 的前綴：index 直接 0..n-1，
    // 舊寫法每集 indexOf 全表掃描 O(n²)。
    final count = _displayEpisodes.length;
    final displayedIndices = Set<int>.from(List.generate(count, (i) => i));
    setState(() { if (_selected.containsAll(displayedIndices)) {
      _selected.removeAll(displayedIndices);
    } else {
      _selected.addAll(displayedIndices);
    } });
  }

  @override
  Widget build(BuildContext context) {
    final activeJobs = _jobs.where((j) => !j.done && !j.failed).toList();
    final activeCount = activeJobs.length;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Column(
            children: [
              if (_history.isNotEmpty) ...[
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      const Icon(Icons.history, size: 14, color: AppColors.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: null,
                            hint: Text(t('download.podcast_history_hint'), style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                            isExpanded: true,
                            style: const TextStyle(fontSize: 12, color: AppColors.text),
                            items: _history.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.key, overflow: TextOverflow.ellipsis))).toList(),
                            onChanged: (v) { if (v != null) _loadFromHistory(v); },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(child: TextField(controller: _searchCtrl,
                    decoration: InputDecoration(hintText: t('download.podcast_search_hint'), prefixIcon: const Icon(Icons.search, size: 18), border: const OutlineInputBorder()),
                    style: const TextStyle(fontSize: 13), onSubmitted: (_) => _searchPodcasts())),
                  const SizedBox(width: 10),
                  _ActionBtn(t('download.search'), Icons.search, _searchPodcasts, _searching, isPrimary: true),
                ],
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => setState(() => _showUrlInput = !_showUrlInput),
                child: Row(children: [
                  const Icon(Icons.link, size: 12, color: AppColors.textMuted),
                  const SizedBox(width: 4),
                  Text(_showUrlInput ? t('download.hide_url_input') : t('download.use_rss_url'), style: const TextStyle(color: AppColors.accent, fontSize: 11)),
                ]),
              ),
              if (_showUrlInput) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: TextField(controller: _urlCtrl,
                      decoration: InputDecoration(hintText: t('download.podcast_hint'), prefixIcon: const Icon(Icons.rss_feed, size: 18), border: const OutlineInputBorder()),
                      style: const TextStyle(fontSize: 13), onSubmitted: (_) => _fetchByUrl())),
                    const SizedBox(width: 10),
                    _ActionBtn(t('download.fetch'), Icons.download, _fetchByUrl, _loading),
                  ],
                ),
              ],
],
            ),
          ),
        if (_subscriptions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.notifications_active, size: 14, color: Color(0xFFCE93D8)),
                const SizedBox(width: 4),
                Text('已訂閱 (${_subscriptions.length})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const Spacer(),
                SizedBox(
                  height: 26,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PipelinePage()),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 12),
                    label: const Text('Podcast 流程', style: TextStyle(fontSize: 10)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFCE93D8), foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              ..._subscriptions.entries.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.podcasts, size: 14, color: AppColors.textMuted),
                  const SizedBox(width: 6),
                  Expanded(child: Text(e.key, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  SizedBox(
                    height: 22,
                    child: TextButton(
                      onPressed: () {
                        _searchCtrl.text = e.key;
                        _urlCtrl.text = e.value;
                        _fetchByUrl();
                      },
                      child: const Text('檢視', style: TextStyle(fontSize: 10, color: AppColors.accent)),
                    ),
                  ),
                  SizedBox(
                    height: 22,
                    child: TextButton(
                      onPressed: () => _toggleSubscription(e.key, e.value),
                      child: Text('取消訂閱', style: TextStyle(fontSize: 10, color: Colors.red[300])),
                    ),
                  ),
                ]),
              )),
            ]),
          ),
        ],
        if (_searchResults.isNotEmpty && _episodes.isEmpty)
          Expanded(flex: 5, child: ListView.builder(
            itemCount: _searchResults.length,
            itemBuilder: (ctx, i) {
              final pod = _searchResults[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
                child: ListTile(
                  dense: true,
                  leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: AppColors.surfaceLight, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.podcasts, size: 20, color: AppColors.textMuted)),
                  title: Text(pod.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(pod.author, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                  trailing: const Icon(Icons.chevron_right, size: 16, color: AppColors.textMuted),
                  onTap: () => _selectPodcast(pod),
                ),
              );
            },
          )),
        if (_podcastTitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_podcastTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                SizedBox(
                  height: 26,
                  child: ElevatedButton.icon(
                    onPressed: () => _toggleSubscription(_podcastTitle, _currentRssUrl),
                    icon: Icon(_isSubscribed(_podcastTitle) ? Icons.notifications_off : Icons.notifications_none, size: 12),
                    label: Text(_isSubscribed(_podcastTitle) ? '訂閱中' : '訂閱', style: const TextStyle(fontSize: 10)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isSubscribed(_podcastTitle) ? AppColors.accentDim : AppColors.surfaceLight,
                      foregroundColor: _isSubscribed(_podcastTitle) ? AppColors.accent : AppColors.text,
                      padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact),
                  ),
                ),
                const SizedBox(width: 4),
                if (_episodes.isNotEmpty) ...[
                  SizedBox(height: 28, child: DropdownButton<int>(
                    value: _maxEpisodes, underline: const SizedBox(),
                    items: [
                      ...[50, 100, 200, 500].map((n) => DropdownMenuItem(value: n, child: Text('$n', style: const TextStyle(fontSize: 11)))),
                      DropdownMenuItem(value: _episodes.length, child: const Text('全部', style: TextStyle(fontSize: 11))),
                    ],
                    onChanged: (v) { if (v != null) setState(() => _maxEpisodes = v); },
                  )),
                  TextButton.icon(
                    onPressed: _selectAll,
                    icon: Icon(_selected.length == _displayEpisodes.length ? Icons.deselect : Icons.select_all, size: 14),
                    label: Text(_selected.length == _displayEpisodes.length ? t('download.deselect_all') : t('download.select_all'), style: const TextStyle(fontSize: 11)),
                  ),
                  if (_selected.isNotEmpty)
                    _ActionBtn('${t('download.dl_selected')} (${_selected.length})', Icons.download, _downloadSelected, false, isPrimary: true),
                ],
              ]),
              Text('${_episodes.length} 集  · 顯示 ${_displayEpisodes.length} 集', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ]),
          ),
        if (_episodes.isNotEmpty)
          Expanded(flex: 3, child: ListView.builder(
            itemCount: _displayEpisodes.length,
            itemBuilder: (ctx, i) {
              // _displayEpisodes 恆為 _episodes 前綴：直接用 i，不 take().toList() + indexOf。
              final ep = _episodes[i];
              final origIndex = i;
              final alreadyDl = _isDownloaded(origIndex);
              final selected = _selected.contains(origIndex);
              final isActive = activeJobs.any((j) => j.title == ep.title);
              final job = _jobs.where((j) => j.title == ep.title).lastOrNull;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: AppColors.card, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? AppColors.accent.withValues(alpha: 0.4) : (alreadyDl ? AppColors.accent.withValues(alpha: 0.15) : AppColors.border)),
                ),
                child: ListTile(
                  dense: true,
                  leading: isActive
                      ? Container(width: 32, height: 32, decoration: BoxDecoration(color: AppColors.accentDim, borderRadius: BorderRadius.circular(8)),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, value: job!.progress)))
                      : GestureDetector(
                          onTap: () => _toggleSelect(origIndex),
                          child: Container(width: 32, height: 32,
                            decoration: BoxDecoration(color: alreadyDl ? AppColors.accentDim : (selected ? AppColors.accentDim : AppColors.surfaceLight),
                                borderRadius: BorderRadius.circular(8),
                                border: selected ? Border.all(color: AppColors.accent, width: 2) : null),
                            child: Icon(alreadyDl ? Icons.check_circle : (selected ? Icons.check : Icons.headphones),
                                size: 16, color: alreadyDl ? AppColors.accent : (selected ? AppColors.accent : AppColors.textMuted)),
                          ),
                        ),
                  title: Row(children: [
                    Expanded(child: Text(ep.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis)),
                    if (alreadyDl) Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(color: AppColors.accentDim, borderRadius: BorderRadius.circular(4)),
                        child: const Text('✓', style: TextStyle(color: AppColors.accent, fontSize: 9))),
                  ]),
                  subtitle: ep.pubDate != null ? Text(ep.pubDate!, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)) : null,
                  trailing: isActive
                      ? Text('${(job!.progress * 100).toStringAsFixed(0)}%', style: const TextStyle(color: AppColors.accent, fontSize: 10))
                      : (alreadyDl ? const Icon(Icons.check_circle, size: 16, color: AppColors.accent)
                          : IconButton(icon: const Icon(Icons.download, size: 18), color: AppColors.accent, onPressed: () => _downloadEpisode(origIndex))),
                  onTap: () => _toggleSelect(origIndex),
                ),
              );
            },
          )),
        if (_episodes.isEmpty && _searchResults.isEmpty)
          Expanded(flex: 3, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.podcasts, size: 48, color: AppColors.textMuted.withValues(alpha: 0.3)),
            const SizedBox(height: 8),
            Text(t('download.podcast_search_empty'), style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ]))),
        if (activeCount > 0) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _jobs.fold(0.0, (sum, j) => sum + j.progress) / (_jobs.isNotEmpty ? _jobs.length : 1),
              backgroundColor: AppColors.surfaceLight,
              valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_jobs.where((j) => j.done || j.failed).length}/${_jobs.length}  正在下載: ${activeJobs.firstOrNull?.title ?? ''}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (activeCount > 0 || _jobs.where((j) => j.done || j.failed).isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.download, size: 14, color: AppColors.accent),
                const SizedBox(width: 6),
                Text('下載佇列 (${_jobs.length})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (activeCount > 0)
                  SizedBox(height: 24, child: ElevatedButton.icon(
                    onPressed: _cancelAllDownloads, icon: const Icon(Icons.stop_rounded, size: 12),
                    label: const Text('取消全部', style: TextStyle(fontSize: 10)),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.error, foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact))),
                if (activeCount == 0) TextButton(onPressed: _clearCompletedJobs, child: const Text('清除已完成', style: TextStyle(fontSize: 10))),
              ]),
              const SizedBox(height: 6),
              ..._jobs.reversed.take(10).map((j) {
                final icon = j.failed ? '❌' : (j.done ? (j.skipped ? '⏭️' : '✅') : '⬇️');
                return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Row(children: [
                  Text(icon, style: const TextStyle(fontSize: 10)),
                  const SizedBox(width: 4),
                  Expanded(child: Text(j.title, style: const TextStyle(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (!j.done && !j.failed) SizedBox(width: 40, child: LinearProgressIndicator(value: j.progress, backgroundColor: AppColors.surfaceLight, minHeight: 4)),
                ]));
              }),
            ]),
          ),
        ],
        if (_episodes.isNotEmpty || _searchResults.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(t('download.log'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Expanded(flex: 2, child: Container(
            decoration: BoxDecoration(color: const Color(0xFF080808), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            clipBehavior: Clip.antiAlias,
            child: _logs.isEmpty
                ? Center(child: Text(t('download.log_empty'), style: const TextStyle(color: AppColors.textMuted, fontSize: 11)))
                : ListView.builder(controller: _scrollCtrl, padding: const EdgeInsets.all(8), itemCount: _logs.length,
                    itemBuilder: (ctx, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(_logs[i], style: const TextStyle(fontSize: 12, fontFamily: 'Consolas', color: AppColors.textMuted, height: 1.4)))),
          )),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}

class _SongDownloadTab extends StatefulWidget {
  const _SongDownloadTab();
  @override
  State<_SongDownloadTab> createState() => _SongDownloadTabState();
}

class _SongDownloadTabState extends State<_SongDownloadTab> {
  final _queryCtrl = TextEditingController();
  final _logs = <String>[];
  final _scrollCtrl = ScrollController();
  bool _running = false;
  double _progress = 0;

  // MP3 batch state
  List<MissingFlacSong> _mp3Missing = [];
  bool _mp3Scanning = false;
  bool _mp3Downloading = false;
  int _mp3Current = 0;
  int _mp3Total = 0;
  String _mp3CurrentSong = '';
  final _logPending = <String>[];
  Timer? _logFlushTimer;
  static const int _maxLogLines = 800;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _scanMissing('mp3'); });
  }

  @override
  void dispose() { _logFlushTimer?.cancel(); _queryCtrl.dispose(); _scrollCtrl.dispose(); super.dispose(); }

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

  Future<void> _startDownload() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() { _running = true; _progress = 0; _logs.clear(); });
    try {
      await DownloadService.instance.downloadSong(songName: query, format: 'mp3',
        onLog: _log, onProgress: (p) { if (mounted) setState(() => _progress = p); });
    } catch (e) { _log('❌ $e'); }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _startYtDownload() async {
    final url = _queryCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() { _running = true; _progress = 0; _logs.clear(); });
    final cfg = ConfigService.instance.config;
    final outPath = '${cfg.libraryPath}\\${DateTime.now().millisecondsSinceEpoch}.mp3';
    try {
      await DownloadService.instance.downloadYouTube(url: url, outputPath: outPath, format: 'mp3',
        onLog: _log, onProgress: (p) { if (mounted) setState(() => _progress = p); });
    } catch (e) { _log('❌ $e'); }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _scanMissing(String format) async {
    setState(() { _mp3Scanning = true; });
    _log('🔍 掃描歌單中，尋找缺漏的 ${format.toUpperCase()}...');
    try {
      final songs = await DownloadService.instance.listMissing(format, onLog: _log);
      if (mounted) setState(() { _mp3Missing = songs; _mp3Scanning = false; });
      _log('📋 找到 ${songs.length} 首缺少 ${format.toUpperCase()}');
    } catch (e) {
      _log('❌ 掃描失敗: $e');
      if (mounted) setState(() { _mp3Scanning = false; });
    }
  }

  Future<void> _startBatch(String format) async {
    final songs = _mp3Missing;
    if (songs.isEmpty) return;
    setState(() { _mp3Downloading = true; _mp3Current = 0; _mp3Total = songs.length; _mp3CurrentSong = ''; });
    try {
      await DownloadService.instance.downloadBatch(format,
        songs: songs,
        onLog: _log,
        onProgress: (current, total, song) {
          if (mounted) setState(() { _mp3Current = current + 1; _mp3Total = total; _mp3CurrentSong = song; });
        },
      );
    } catch (e) {
      _log('❌ $format 批次下載異常: $e');
    }
    if (mounted) setState(() { _mp3Downloading = false; });
    _scanMissing(format);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(child: Column(children: [
      // Manual download section
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(controller: _queryCtrl,
              decoration: InputDecoration(hintText: t('download.song_hint'), prefixIcon: const Icon(Icons.search, size: 18), border: const OutlineInputBorder()),
              style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 8),
            _ActionBtn(t('download.dl_song'), Icons.download, _startDownload, _running, isPrimary: true),
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: Text(t('download.or_enter_yt'), style: const TextStyle(color: AppColors.textMuted, fontSize: 11))),
          const SizedBox(height: 4),
          SizedBox(width: double.infinity, child: _ActionBtn(t('download.dl_yt_url'), Icons.link, _startYtDownload, _running)),
        ]),
      ),
      if (_running) ...[
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: _progress, backgroundColor: AppColors.surfaceLight, valueColor: const AlwaysStoppedAnimation(AppColors.accent), minHeight: 6)),
        const SizedBox(height: 6),
        Text('${(_progress * 100).toStringAsFixed(0)}%', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
      ],
      const SizedBox(height: 16),
      // MP3 batch section
      _buildBatchSection('mp3', Icons.music_note_rounded, const Color(0xFF4FC3F7),
        _mp3Missing, _mp3Scanning, _mp3Downloading, _mp3Current, _mp3Total, _mp3CurrentSong),
      const SizedBox(height: 16),
      Text(t('download.log'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      SizedBox(
        height: 200,
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF080808), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
          clipBehavior: Clip.antiAlias,
          child: _logs.isEmpty
              ? Center(child: Text(t('download.log_empty'), style: const TextStyle(color: AppColors.textMuted, fontSize: 11)))
              : ListView.builder(controller: _scrollCtrl, padding: const EdgeInsets.all(8), itemCount: _logs.length,
                  itemBuilder: (ctx, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(_logs[i], style: const TextStyle(fontSize: 12, fontFamily: 'Consolas', color: AppColors.textMuted, height: 1.4))))),
      ),
      const SizedBox(height: 12),
    ]));
  }

  Widget _buildBatchSection(String format, IconData icon, Color color,
      List<MissingFlacSong> songs, bool scanning, bool downloading,
      int current, int total, String currentSong) {
    final label = format.toUpperCase();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text('$label 批次下載', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (scanning)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          if (!scanning && !downloading)
            _ActionBtn('掃描', Icons.refresh, () => _scanMissing(format), false),
        ]),
        if (downloading) ...[
          const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: total > 0 ? current / total : 0,
              backgroundColor: AppColors.surfaceLight, valueColor: AlwaysStoppedAnimation(color), minHeight: 6)),
          const SizedBox(height: 6),
          Text('$current / $total  $currentSong',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
        if (songs.isNotEmpty && !downloading) ...[
          const SizedBox(height: 10),
          Text('${songs.length} 首歌曲缺少 $label', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          SizedBox(
            height: 120,
            child: ListView.separated(
              itemCount: songs.length.clamp(0, 20),
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
              itemBuilder: (ctx, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${i + 1}. ${songs[i].name}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          if (songs.length > 20)
            Padding(padding: const EdgeInsets.only(top: 4),
              child: Text('...還有 ${songs.length - 20} 首', style: const TextStyle(color: AppColors.textMuted, fontSize: 10))),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: _ActionBtn('下載全部 $label (${songs.length})', Icons.download,
              () => _startBatch(format), false, isPrimary: true)),
        ],
        if (songs.isEmpty && !scanning)
          Padding(padding: const EdgeInsets.only(top: 8),
            child: Text('✅ 所有歌曲已有 $label 版本', style: const TextStyle(color: Color(0xFFA5D6A7), fontSize: 12))),
      ]),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onPressed; final bool disabled; final bool isPrimary;
  const _ActionBtn(this.label, this.icon, this.onPressed, this.disabled, {this.isPrimary = false});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: disabled ? null : onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: isPrimary ? AppColors.accent : AppColors.surfaceLight,
        foregroundColor: isPrimary ? Colors.black : AppColors.text,
        disabledBackgroundColor: AppColors.surfaceLight.withValues(alpha: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    );
  }
}
