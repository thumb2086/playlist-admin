import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'widgets/dark_theme.dart';
import 'models/playlist_item.dart';
import 'pages/home_page.dart';
import 'pages/search_page.dart';
import 'pages/jam_page.dart';
import 'pages/library_page.dart';
import 'pages/pipeline_page.dart';
import 'pages/stats_page.dart';
import 'pages/settings_page.dart';
import 'pages/playlist_detail_page.dart';
import 'services/i18n.dart';
import 'services/config_service.dart';
import 'services/playlist_parser.dart';
import 'services/update_service.dart';
import 'services/version_checker.dart';
import 'widgets/update_dialog.dart';
import 'widgets/onboarding_dialog.dart';
import 'widgets/queue_panel.dart';
import 'widgets/player_bar.dart';
import 'services/player_controller.dart';
import 'services/sync_server.dart';

class PlaylistAdminApp extends StatefulWidget {
  const PlaylistAdminApp({super.key});
  @override
  State<PlaylistAdminApp> createState() => _PlaylistAdminAppState();
}

class _PlaylistAdminAppState extends State<PlaylistAdminApp> {
  @override
  void initState() {
    super.initState();
    I18N.instance.addListener(_onChanged);
    ConfigService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    I18N.instance.removeListener(_onChanged);
    ConfigService.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final isDark = ConfigService.instance.config.theme != 'light';
    return MaterialApp(
      title: t('app.title'),
      theme: isDark ? buildDarkTheme() : buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      home: const MainShell(),
      debugShowCheckedModeBanner: false,
      // 桌面版滑鼠拖拽預設不滾動（widget test 實證：touch 滾、mouse 不滾）
      // → 明示把 mouse/trackpad 加回 dragDevices，橫向歌單列才滑得動。
      builder: (context, child) => ScrollConfiguration(
        behavior: DesktopScrollBehavior(),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// 全域捲動行為：比 Material 預設多開 mouse/trackpad 拖拽。
class DesktopScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  /// Show a detail page in the content area (replaces IndexedStack).
  static void showDetail(Widget page) {
    _showDetail?.call(page);
  }

  /// Dismiss the detail page (back to normal tabs).
  static void dismissDetail() {
    _dismissDetail?.call();
  }

  /// 右側佇列面板開關（Spotify 式三欄的右欄）— 播放列佇列鈕切換。
  static final ValueNotifier<bool> queueOpen = ValueNotifier<bool>(false);
  static void toggleQueue() => queueOpen.value = !queueOpen.value;

  /// 逐頁新手導覽：從第 1 頁開始（引導卡片浮在頁面上、自動切頁）。
  static void Function()? _startTourFn;
  static void startTour() => _startTourFn?.call();

  static void Function(Widget)? _showDetail;
  static VoidCallback? _dismissDetail;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
  /// 逐頁導覽步驟：-1 = 關閉；0..n-1 = 目前導覽頁（同步切 nav）。
  int _tourStep = -1;
  final _updateSvc = UpdateService.instance;
  BuildContext? _context;
  Timer? _updateTimer;
  Widget? _detailWidget;

  late List<_NavItemData> _navItems;
  late List<Widget> _pages;

  final _allPages = const [
    HomePage(),
    SearchPage(),
    JamPage(),
    LibraryPage(),
    PipelinePage(),
    StatsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    MainShell._showDetail = (page) {
      if (mounted) setState(() { _detailWidget = page; });
    };
    MainShell._dismissDetail = () {
      if (mounted) setState(() { _detailWidget = null; });
    };
    MainShell._startTourFn = () {
      if (!mounted) return;
      setState(() => _applyTourStep(0));
    };
    _rebuildNav();
    I18N.instance.addListener(_rebuildNav);
    _updateSvc.addListener(_onUpdate);
    _checkForUpdates();
    // 上次開著區網同步 → 接著服（手機隨開隨連，不用每次手動開）。
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
        ConfigService.instance.config.syncServerEnabled) {
      SyncServer.instance.start().catchError((_) {});
    }
    // 首次啟動（setupCompleted=false）→ 新手導引。複用既有死旗標，不加新欄位。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !ConfigService.instance.config.setupCompleted) {
        showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const OnboardingDialog());
      }
    });
    // Periodic check every 10 minutes while app is running
    //（註解曾寫 10 分鐘但程式是 1 分鐘：每分鐘打 GitHub API 太頻繁，改回 10 分鐘）
    _updateTimer = Timer.periodic(const Duration(minutes: 10), (_) => _checkForUpdates());
  }

  void _onUpdate() {
    if (mounted) setState(() {});
    if (_updateSvc.state == UpdateState.ready && mounted && _context != null) {
      ScaffoldMessenger.maybeOf(_context!)?.showSnackBar(
        SnackBar(
          content: const Text('更新已下載完成，點擊側邊欄「安裝更新」'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: '安裝', onPressed: _updateSvc.launchInstaller),
        ),
      );
    }
  }

  bool _updateChecking = false;

  void _checkForUpdates() {
    if (!VersionChecker.shouldCheck()) return;
    if (_updateChecking) return;
    _updateChecking = true;
    Future.delayed(const Duration(seconds: 3), () async {
      try {
        final info = await VersionChecker.checkForUpdate();
        if (!info.hasUpdate) return;
        if (!VersionChecker.isNewerThanSkipped(info.latestVersion)) return;
        if (!mounted) return;
        // Always show dialog — user decides when to download.
        showDialog(context: context, builder: (_) => UpdateDialog(info: info));
      } finally {
        _updateChecking = false;
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _updateSvc.removeListener(_onUpdate);
    I18N.instance.removeListener(_rebuildNav);
    super.dispose();
  }

  // ── 逐頁新手導覽 ──────────────────────────────────────
  void _applyTourStep(int step) {
    _tourStep = step;
    _selectedIndex = step.clamp(0, _navItems.length - 1);
    _detailWidget = null;
  }

  void _tourNext() {
    if (_tourStep >= _navItems.length - 1) {
      setState(() => _tourStep = -1); // 最後一頁 → 完成
      return;
    }
    setState(() => _applyTourStep(_tourStep + 1));
  }

  void _tourPrev() {
    if (_tourStep <= 0) return;
    setState(() => _applyTourStep(_tourStep - 1));
  }

  Widget _tourCard() {
    final idx = _tourStep.clamp(0, _navItems.length - 1);
    final item = _navItems[idx];
    final last = idx >= _navItems.length - 1;
    return Positioned(
      right: 16,
      bottom: 16,
      child: Container(
        width: 330,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.accent),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(item.icon, size: 16, color: AppColors.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${idx + 1}/${_navItems.length}　${item.label}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis),
            ),
            InkWell(
              onTap: () => setState(() => _tourStep = -1),
              child: const Icon(Icons.close_rounded, size: 16, color: AppColors.textMuted),
            ),
          ]),
          const SizedBox(height: 8),
          for (final tip in item.tips)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Icon(Icons.circle, size: 4, color: AppColors.accent),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(tip, style: const TextStyle(fontSize: 11.5, height: 1.4))),
              ]),
            ),
          const SizedBox(height: 6),
          Row(children: [
            TextButton(
              onPressed: () => setState(() => _tourStep = -1),
              child: const Text('跳過', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
            ),
            const Spacer(),
            if (idx > 0)
              TextButton(
                onPressed: _tourPrev,
                child: const Text('上一頁', style: TextStyle(fontSize: 11)),
              ),
            ElevatedButton(
              onPressed: _tourNext,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              ),
              child: Text(last ? '完成' : '下一頁', style: const TextStyle(fontSize: 11)),
            ),
          ]),
        ]),
      ),
    );
  }

  void _rebuildNav() {    if (!mounted) return;
    setState(() {
      // 手機版只顯示：首頁、搜尋、一起聽、音樂庫、設定
      final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      final showPipeline = !isMobile;
      final showStats = !isMobile;

      _navItems = [
        const _NavItemData(Icons.home_outlined, Icons.home, '首頁', tips: [
          '為你推薦：橫向歌單列可用滑鼠拖或捲軸往右滑',
          '全部 / 歌單 / Podcast 三顆分類快速過濾',
          '左側「你的音樂庫」點歌單直開詳情',
          '播放列佇列鈕：開關右側常駐佇列面板',
        ]),
        const _NavItemData(Icons.search_outlined, Icons.search, '搜尋', tips: [
          '搜尋 Spotify 歌曲、歌手、專輯',
          '結果直接播放，或下載進本機音樂庫',
          '本機找不到會自動改走線上串流',
        ]),
        const _NavItemData(Icons.groups_outlined, Icons.groups_rounded, '一起聽', tips: [
          '開房拿 6 位代碼或 QR 給朋友',
          '任何網路都能加入，不用同一個 Wi-Fi',
          '大家一起加歌、投票、聊天、播放同步',
          '房主建議用電腦：由房主解析音訊',
        ]),
        _NavItemData(Icons.library_music_outlined, Icons.library_music, t('app.sidebar.library'), tips: [
          '歌單同步覆蓋率卡片（matched / total）',
          '新增 / 移除歌單',
          '「整理」：歌單外歌曲移入未分類資料夾',
          'USB 匯出：按歌單分資料夾匯出',
        ]),
        if (showPipeline)
          _NavItemData(Icons.play_circle_outline, Icons.play_circle_filled, t('app.sidebar.pipeline'), tips: [
            '「下載與訂閱」→ 貼 RSS 或 YouTube 頻道網址',
            '同步歌單 + 批次下載缺歌',
            'Podcast 自動抓新集與逐字稿；YT 頻道抓字幕進 RAG',
            '跑完自動更新 RAG 向量索引',
          ]),
        if (showStats)
          _NavItemData(Icons.bar_chart_rounded, Icons.bar_chart_rounded, t('app.sidebar.stats'), tips: [
            '曲庫統計：歌手、專輯、時長分佈',
            '最近播放與收藏成長',
          ]),
        _NavItemData(Icons.settings_outlined, Icons.settings, t('app.sidebar.settings'), tips: [
          '路徑、主題、串流音質、睡眠定時',
          'Groq：下拉選 推薦 router / 官方 / 自訂',
          'Spotify 登入（僅桌面版）',
          '更新檢查；「新手導引」隨時重看本導覽',
        ]),
      ];

      _pages = [
        _allPages[0], // 首頁
        _allPages[1], // 搜尋
        _allPages[2], // 一起聽
        _allPages[3], // 音樂庫
        if (showPipeline) _allPages[4], // Pipeline
        if (showStats) _allPages[5],    // Stats
        _allPages[6], // 設定
      ];

      if (_selectedIndex >= _pages.length) {
        _selectedIndex = _pages.length - 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _context = context;
    // 空格鍵 = 播放/暫停（全專案原本沒有任何鍵盤快捷鍵綁定）。
    // 焦點在控制鈕上時由該鈕先吃掉空格（行為一致），無焦點時走這裡。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): () =>
            PlayerController.instance.togglePlay(),
      },
      child: LayoutBuilder(builder: (context, constraints) {
      final mobile = constraints.maxWidth < 760;
      return Scaffold(
        body: Column(children: [
          Expanded(
            child: mobile
                ? Column(children: [
                    _MobileHeader(
                      title: _detailWidget != null ? '返回' : _navItems[_selectedIndex].label,
                      onBack: _detailWidget != null
                          ? () => setState(() => _detailWidget = null)
                          : null,
                    ),
                    Expanded(
                      child: Stack(children: [
                        IndexedStack(index: _selectedIndex, children: _pages),
                        if (_detailWidget != null) _detailWidget!,
                        if (_tourStep >= 0) _tourCard(),
                      ]),
                    ),
                  ])
                : Row(children: [
                    _Sidebar(
                      items: _navItems,
                      selectedIndex: _selectedIndex,
                      onSelected: (i) {
                        setState(() {
                          _selectedIndex = i;
                          _detailWidget = null;
                        });
                      },
                    ),
                    Expanded(
                      child: Column(children: [
                        _Header(
                            title: _detailWidget != null ? '返回' : _navItems[_selectedIndex].label,
                            onBack: _detailWidget != null
                                ? () => setState(() => _detailWidget = null)
                                : null),
                        Expanded(
                          child: Stack(children: [
                            IndexedStack(index: _selectedIndex, children: _pages),
                            if (_detailWidget != null) _detailWidget!,
                            if (_tourStep >= 0) _tourCard(),
                          ]),
                        ),
                      ]),
                    ),
                    // 右欄：常駐佇列面板（Spotify 式三欄）。
                    ValueListenableBuilder<bool>(
                      valueListenable: MainShell.queueOpen,
                      builder: (_, open, __) => open
                          ? const QueuePanel(onClose: MainShell.toggleQueue)
                          : const SizedBox.shrink(),
                    ),
                  ]),
          ),
          const PlayerBar(),
          if (mobile)
            NavigationBar(
              selectedIndex: _selectedIndex.clamp(0, _navItems.length - 1),
              onDestinationSelected: (i) {
                setState(() {
                  _selectedIndex = i;
                  _detailWidget = null;
                });
              },
              destinations: [
                for (final it in _navItems.take(5))
                  NavigationDestination(
                    icon: Icon(it.icon),
                    selectedIcon: Icon(it.activeIcon),
                    label: it.label,
                  ),
              ],
            ),
        ]),
      );
      }),
    );
  }
}

class _NavItemData {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  /// 逐頁新手導覽：本頁功能重點（空 = 不參與導覽）。
  final List<String> tips;
  const _NavItemData(this.icon, this.activeIcon, this.label, {this.tips = const []});
}

/// 開本機歌單：m3u8 → items → 詳情頁（歌單卡原本 onTap 是空的死 UI）。
/// audioQuery = 完整檔名 stem → _findLocalTrack 精準命中本機（含 未分類\）。
/// 封面/時長由詳情頁背景補齊（需 spotifyUrl，這裡從 urlNames 反查帶過去）。
void _openLocalPlaylist(BuildContext context, String name) {
  final cfg = ConfigService.instance.config;
  final path = '${cfg.playlistsPath}${Platform.pathSeparator}$name.m3u8';
  final items = <PlaylistItem>[];
  if (File(path).existsSync()) {
    for (final stem in PlaylistParser.parseTrackNames(path)) {
      // 檔名慣例是「曲名 - 歌手」（下載時 `${name} - ${artist}`），
      // 與 _titleFromPath/_artistFromPath 一致：第一段=曲名。
      final sep = stem.split(' - ');
      items.add(PlaylistItem(
        name: sep.first,
        artist: sep.length > 1 ? sep.sublist(1).join(' - ') : '',
        audioQuery: stem,
      ));
    }
  }
  String? url;
  try {
    url = cfg.urlNames.entries.firstWhere((e) => e.value == name).key;
  } catch (_) {}
  MainShell.showDetail(
      PlaylistDetailPage(title: name, spotifyUrl: url, items: items));
}

/// 側欄音樂庫的歌單項目。
class _PlaylistNavItem extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _PlaylistNavItem({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(children: [
            const Icon(Icons.queue_music_rounded, size: 14, color: AppColors.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Sidebar extends StatefulWidget {
  final List<_NavItemData> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  const _Sidebar({required this.items, required this.selectedIndex, required this.onSelected});

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  static final _updateSvc = UpdateService.instance;
  final _filterCtrl = TextEditingController();
  bool _filterOpen = false;

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        border: Border(right: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  child: const Icon(Icons.queue_music_rounded, color: Colors.black, size: 20),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('app.sidebar.playlist'), style: const TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.bold)),
                    Text(t('app.sidebar.admin'), style: const TextStyle(color: AppColors.textMuted, fontSize: 10, letterSpacing: 1.2)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(indent: 20, endIndent: 20),
          const SizedBox(height: 4),
          ...List.generate(widget.items.length, (i) {
            final item = widget.items[i];
            final selected = i == widget.selectedIndex;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: selected ? AppColors.accentDim : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => widget.onSelected(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Row(
                      children: [
                        Icon(
                          selected ? item.activeIcon : item.icon,
                          color: selected ? AppColors.accent : AppColors.textMuted,
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          item.label,
                          style: TextStyle(
                            color: selected ? AppColors.text : AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        const Spacer(),
                        if (selected)
                          Container(
                            width: 3, height: 16,
                            decoration: const BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.all(Radius.circular(2)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 6, 2),
            child: Row(children: [
              const Expanded(
                child: Text('你的音樂庫',
                    style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        letterSpacing: 1.2)),
              ),
              IconButton(
                icon: const Icon(Icons.playlist_add_rounded, size: 18),
                color: AppColors.textMuted,
                tooltip: '到歌單庫新增/管理',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24),
                onPressed: () {
                  final i = widget.items
                      .indexWhere((e) => e.label == t('app.sidebar.library'));
                  widget.onSelected(i >= 0 ? i : 3);
                },
              ),
              IconButton(
                icon: Icon(_filterOpen ? Icons.close_rounded : Icons.search_rounded,
                    size: 16),
                color: AppColors.textMuted,
                tooltip: '篩選歌單',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24),
                onPressed: () => setState(() {
                  _filterOpen = !_filterOpen;
                  if (!_filterOpen) _filterCtrl.clear();
                }),
              ),
            ]),
          ),
          if (_filterOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: TextField(
                controller: _filterCtrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '輸入關鍵字過濾…',
                  hintStyle:
                      const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  prefixIcon: const Icon(Icons.search_rounded,
                      size: 14, color: AppColors.textMuted),
                  prefixIconConstraints: const BoxConstraints(minWidth: 28),
                  filled: true,
                  fillColor: AppColors.surfaceLight,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Builder(builder: (context) {
              final all =
                  ConfigService.instance.config.urlNames.entries.toList();
              final q = _filterCtrl.text.trim().toLowerCase();
              final entries = q.isEmpty
                  ? all
                  : all
                      .where((e) => e.value.toLowerCase().contains(q))
                      .toList();
              if (entries.isEmpty) {
                return Center(
                    child: Text(
                        q.isEmpty
                            ? '還沒有歌單（＋ 到歌單庫新增）'
                            : '找不到「${_filterCtrl.text.trim()}」',
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 10)));
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final name = entries[i].value;
                  return _PlaylistNavItem(
                    name: name,
                    onTap: () => _openLocalPlaylist(context, name),
                  );
                },
              );
            }),
          ),
          if (_updateSvc.state == UpdateState.downloading)
            GestureDetector(
              onTap: () => widget.onSelected(2),
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(children: [
                  Row(children: [
                    const Icon(Icons.system_update, size: 12, color: AppColors.accent),
                    const SizedBox(width: 4),
                    const Text('更新下載中', style: TextStyle(color: AppColors.accent, fontSize: 9)),
                    const Spacer(),
                    Text('${(_updateSvc.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: AppColors.accent, fontSize: 9)),
                  ]),
                  const SizedBox(height: 4),
                  ClipRRect(borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: _updateSvc.progress, minHeight: 3,
                        backgroundColor: AppColors.surfaceLight,
                        valueColor: const AlwaysStoppedAnimation(AppColors.accent)),
                  ),
                ]),
              ),
            ),
          if (_updateSvc.state == UpdateState.ready)
            GestureDetector(
              onTap: _updateSvc.launchInstaller,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
                child: const Row(children: [
                  Icon(Icons.check_circle, size: 12, color: Color(0xFF000000)),
                  SizedBox(width: 4),
                  Text('安裝更新', style: TextStyle(color: Color(0xFF000000), fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: AppColors.accent, size: 14),
                const SizedBox(width: 8),
                Text(t('app.version'), style: const TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w500)),
                const Spacer(),
                Text('Flutter', style: TextStyle(color: AppColors.accent.withValues(alpha: 0.7), fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  const _Header({required this.title, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              onPressed: onBack,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28),
            ),
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(6),
            ),
              child: const Text('PLAYLIST ADMIN', style: TextStyle(color: AppColors.accent, fontSize: 9, letterSpacing: 1.5)),
          ),
        ],
      ),
    );
  }
}

/// 手機版頂部列（窄螢幕用）。
class _MobileHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  const _MobileHeader({required this.title, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Row(children: [
        if (onBack != null)
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            onPressed: onBack,
            padding: EdgeInsets.zero,
          ),
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.accentDim,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text('PLAYLIST ADMIN',
              style: TextStyle(color: AppColors.accent, fontSize: 8, letterSpacing: 1.2)),
        ),
      ]),
    );
  }
}
