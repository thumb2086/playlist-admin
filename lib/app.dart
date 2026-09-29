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

  static void Function(Widget)? _showDetail;
  static VoidCallback? _dismissDetail;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
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
    _rebuildNav();
    I18N.instance.addListener(_rebuildNav);
    _updateSvc.addListener(_onUpdate);
    _checkForUpdates();
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

  void _rebuildNav() {
    if (!mounted) return;
    setState(() {
      // 手機版只顯示：首頁、搜尋、一起聽、音樂庫、設定
      final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      final showPipeline = !isMobile;
      final showStats = !isMobile;

      _navItems = [
        const _NavItemData(Icons.home_outlined, Icons.home, '首頁'),
        const _NavItemData(Icons.search_outlined, Icons.search, '搜尋'),
        const _NavItemData(Icons.groups_outlined, Icons.groups_rounded, '一起聽'),
        _NavItemData(Icons.library_music_outlined, Icons.library_music, t('app.sidebar.library')),
        if (showPipeline)
          _NavItemData(Icons.play_circle_outline, Icons.play_circle_filled, t('app.sidebar.pipeline')),
        if (showStats)
          _NavItemData(Icons.bar_chart_rounded, Icons.bar_chart_rounded, t('app.sidebar.stats')),
        _NavItemData(Icons.settings_outlined, Icons.settings, t('app.sidebar.settings')),
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
  const _NavItemData(this.icon, this.activeIcon, this.label);
}

/// 開本機歌單：m3u8 → items → 詳情頁（歌單卡原本 onTap 是空的死 UI）。
/// audioQuery = 完整檔名 stem → _findLocalTrack 精準命中本機（含 未分類\）。
void _openLocalPlaylist(BuildContext context, String name) {
  final cfg = ConfigService.instance.config;
  final path = '${cfg.playlistsPath}${Platform.pathSeparator}$name.m3u8';
  final items = <PlaylistItem>[];
  if (File(path).existsSync()) {
    for (final stem in PlaylistParser.parseTrackNames(path)) {
      final sep = stem.split(' - ');
      items.add(PlaylistItem(
        name: sep.length > 1 ? sep.sublist(1).join(' - ') : stem,
        artist: sep.length > 1 ? sep.first : '',
        audioQuery: stem,
      ));
    }
  }
  MainShell.showDetail(PlaylistDetailPage(title: name, items: items));
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(children: [
            const Icon(Icons.queue_music_rounded, size: 15, color: AppColors.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final List<_NavItemData> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  static final _updateSvc = UpdateService.instance;
  const _Sidebar({required this.items, required this.selectedIndex, required this.onSelected});

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
          const SizedBox(height: 8),
          ...List.generate(items.length, (i) {
            final item = items[i];
            final selected = i == selectedIndex;
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
                  onTap: () => onSelected(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(
                          selected ? item.activeIcon : item.icon,
                          color: selected ? AppColors.accent : AppColors.textMuted,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          item.label,
                          style: TextStyle(
                            color: selected ? AppColors.text : AppColors.textSecondary,
                            fontSize: 13,
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
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 6, 20, 4),
            child: Text('你的音樂庫',
                style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    letterSpacing: 1.2)),
          ),
          Expanded(
            child: Builder(builder: (context) {
              final entries =
                  ConfigService.instance.config.urlNames.entries.toList();
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
              onTap: () => onSelected(2),
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
