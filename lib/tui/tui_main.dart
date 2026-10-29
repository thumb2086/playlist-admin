import 'dart:io';
import 'dart:async';

import 'package:ansi_styles/ansi_styles.dart';
import 'package:media_kit/media_kit.dart';
import '../models/config_model.dart';
import '../version.dart';
import '../services/config_service.dart';
import '../services/favorites_service.dart';
import '../services/library_organizer.dart';
import '../services/library_doctor.dart';
import '../services/cookie_export.dart';
import '../services/artwork_embedder.dart';
import '../services/lyrics_service.dart';
import '../services/metadata_enricher.dart';
import '../services/upload_budget.dart';
import '../services/spotify_session.dart';
import '../services/stream_server.dart';
import '../pipeline/pipeline_orchestrator.dart';
import '../pipeline/podcast_pipeline.dart';
import '../models/pipeline_step.dart';
import 'input.dart';
import 'widgets.dart';

/// Main TUI application
class TuiApp {
  final ScreenManager _screenManager = ScreenManager();
  final TuiInput _input = TuiInput();
  AppConfig? _config;
  PipelineState? _pipelineState;
  bool _running = true;

  /// Run the TUI application
  Future<void> run() async {
    // Initialize
    await ConfigService.instance.load();
    _config = ConfigService.instance.config;

    // Setup terminal
    stdout.write(Ansi.altScreenEnter);
    stdout.write(Ansi.cursorHide);
    _input.init();

    // Handle Ctrl+C
    ProcessSignal.sigint.watch().listen((_) => _requestExit());

    try {
      // Show main menu
      _screenManager.push(MainMenuScreen(app: this));

      // Main loop
      while (_running && _screenManager.current != null) {
        _screenManager.render();

        final event = await _input.waitForKey();
        _handleGlobalKeys(event);
        _screenManager.handleKey(event);

        // Check if current screen wants exit
        if (_screenManager.current?.wantsExit == true) {
          _screenManager.pop();
        }
      }
    } finally {
      _cleanup();
    }
  }

  void _handleGlobalKeys(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.ctrlC:
        _requestExit();
        break;
      case TuiKey.ctrlL:
        _screenManager.clear();
        _screenManager.render();
        break;
      case TuiKey.escape:
        if (_screenManager.stackDepth > 1) {
          _screenManager.pop();
        } else {
          _requestExit();
        }
        break;
      default:
        break;
    }
  }

  void _requestExit() {
    _running = false;
  }

  void _cleanup() {
    _input.dispose();
    stdout.write(Ansi.cursorShow);
    stdout.write(Ansi.altScreenExit);
  }

  // Screen navigation helpers
  void pushScreen(TuiScreen screen) => _screenManager.push(screen);
  void popScreen() => _screenManager.pop();
  void replaceScreen(TuiScreen screen) => _screenManager.replace(screen);

  // Accessors
  AppConfig get config => _config!;
  ScreenManager get screenManager => _screenManager;
  PipelineState get pipelineState => _pipelineState ??= PipelineState();
}

/// Main menu screen
class MainMenuScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;

  MainMenuScreen({required this.app}) {
    _menu = MenuWidget(
      title: '🎵 playlist-admin TUI v${appVersion}',
      items: [
        MenuItem(label: 'Pipeline', shortcut: '1', onSelect: () => app.pushScreen(PipelineMenuScreen(app: app))),
        MenuItem(label: 'Podcast Pipeline', shortcut: '2', onSelect: () => app.pushScreen(PodcastScreen(app: app))),
        MenuItem(label: 'Status', shortcut: '3', onSelect: () => app.pushScreen(StatusScreen(app: app))),
        MenuItem(label: 'Play Music', shortcut: '4', onSelect: () => app.pushScreen(PlayScreen(app: app))),
        MenuItem(label: 'Organize Library', shortcut: '5', onSelect: () => _runOrganize()),
        MenuItem(label: 'Artwork Backfill', shortcut: '6', onSelect: () => app.pushScreen(ArtworkScreen(app: app))),
        MenuItem(label: 'Doctor (Health Check)', shortcut: '7', onSelect: () => app.pushScreen(DoctorScreen(app: app))),
        MenuItem(label: 'Cookie Management', shortcut: '8', onSelect: () => app.pushScreen(CookieScreen(app: app))),
        MenuItem(label: 'Metadata Tools', shortcut: '9', onSelect: () => app.pushScreen(MetadataScreen(app: app))),
        MenuItem(label: 'Lyrics Download', shortcut: 'L', onSelect: () => app.pushScreen(LyricsScreen(app: app))),
        MenuItem(label: 'Favorites', shortcut: 'F', onSelect: () => app.pushScreen(FavoritesScreen(app: app))),
        MenuItem(label: 'Budget', shortcut: 'B', onSelect: () => app.pushScreen(BudgetScreen(app: app))),
        MenuItem(label: 'Quit', shortcut: 'Q', onSelect: () => app._requestExit()),
      ],
    );
  }

  @override
  String get title => 'Main Menu';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.char:
        // Quick select by number/letter
        final idx = _charToIndex(event.char!);
        if (idx >= 0 && idx < _menu.items.length) {
          _menu.selectedIndex = idx;
          _menu.selected?.onSelect?.call();
        }
        break;
      default:
        break;
    }
  }

  int _charToIndex(String c) {
    if (c.codeUnitAt(0) >= 49 && c.codeUnitAt(0) <= 57) { // 1-9
      return c.codeUnitAt(0) - 49;
    }
    if (c.toLowerCase() == 'l') return 10; // Lyrics
    if (c.toLowerCase() == 'f') return 11; // Favorites
    if (c.toLowerCase() == 'b') return 12; // Budget
    if (c.toLowerCase() == 'q') return 13; // Quit
    return -1;
  }

  Future<void> _runOrganize() async {
    app.pushScreen(ActionScreen(
      screenTitle: 'Organize Library',
      message: 'Moving non-playlist songs to _Unsorted.m3u8...',
      action: () async {
        await LibraryOrganizer.organize(log: (msg) {
          // Add to log panel via action screen's log panel
          // We can't easily access it here, so just use print
          print(msg);
        });
      },
      onComplete: () => app.popScreen(),
      onPop: () => app.popScreen(),
    ));
  }

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);

    // Help panel at bottom
    final help = HelpPanel(
      shortcuts: [
        ('↑/↓', 'Navigate'),
        ('Enter', 'Select'),
        ('1-9', 'Quick select'),
        ('Esc', 'Quit'),
        ('Ctrl+L', 'Redraw'),
      ],
      width: 30,
    );
    help.render(sb, x: TermSize.width - 32, y: 2);
  }
}

/// Pipeline menu screen
class PipelineMenuScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;

  PipelineMenuScreen({required this.app}) {
    _menu = MenuWidget(
      title: 'Pipeline',
      items: [
        MenuItem(label: 'Run Full Pipeline', shortcut: '1', onSelect: () => _runPipeline(0)),
        MenuItem(label: 'Run Single Step', shortcut: '2', onSelect: () => app.pushScreen(PipelineStepSelectScreen(app: app))),
        MenuItem(label: 'Back', shortcut: 'Esc', onSelect: () => app.popScreen()),
      ],
    );
  }

  @override
  String get title => 'Pipeline Menu';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.char:
        final idx = _charToIndex(event.char!);
        if (idx >= 0 && idx < _menu.items.length) {
          _menu.selectedIndex = idx;
          _menu.selected?.onSelect?.call();
        }
        break;
      default:
        break;
    }
  }

  int _charToIndex(String c) {
    if (c.codeUnitAt(0) >= 49 && c.codeUnitAt(0) <= 50) return c.codeUnitAt(0) - 49;
    return -1;
  }

  void _runPipeline(int fromStep) {
    app.pushScreen(PipelineRunScreen(app: app, fromStep: fromStep));
  }

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);
  }
}

/// Pipeline step selection screen
class PipelineStepSelectScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;

  PipelineStepSelectScreen({required this.app}) {
    _menu = MenuWidget(
      title: 'Select Pipeline Step',
      items: [
        MenuItem(label: 'Step 0: Scrape Spotify', shortcut: '0', onSelect: () => _run(0)),
        MenuItem(label: 'Step 1: Download Missing', shortcut: '1', onSelect: () => _run(1)),
        MenuItem(label: 'Step 2: Build M3U8', shortcut: '2', onSelect: () => _run(2)),
        MenuItem(label: 'Step 3: Organize Unsorted', shortcut: '3', onSelect: () => _run(3)),
        MenuItem(label: 'Step 4: Enrich Metadata', shortcut: '4', onSelect: () => _run(4)),
        MenuItem(label: 'Step 5: Download Lyrics', shortcut: '5', onSelect: () => _run(5)),
        MenuItem(label: 'Step 6: Measure LUFS', shortcut: '6', onSelect: () => _run(6)),
        MenuItem(label: 'Step 7: Podcast RAG', shortcut: '7', onSelect: () => _run(7)),
        MenuItem(label: 'Back', shortcut: 'Esc', onSelect: () => app.popScreen()),
      ],
    );
  }

  @override
  String get title => 'Select Step';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.char:
        final idx = int.tryParse(event.char!) ?? -1;
        if (idx >= 0 && idx < 8) {
          _menu.selectedIndex = idx;
          _run(idx);
        }
        break;
      default:
        break;
    }
  }

  void _run(int step) {
    app.pushScreen(PipelineRunScreen(app: app, fromStep: step, toStep: step));
  }

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);
  }
}

/// Pipeline run screen with progress
class PipelineRunScreen extends TuiScreen {
  final TuiApp app;
  final int fromStep;
  final int? toStep;
  late final LogPanel _logPanel;
  bool _running = false;
  bool _completed = false;
  String _status = 'Starting...';

  PipelineRunScreen({required this.app, required this.fromStep, this.toStep}) {
    _logPanel = LogPanel(
      lines: [],
      width: TermSize.width - 4,
      height: TermSize.height - 8,
    );
  }

  @override
  String get title => 'Pipeline Running';

  @override
  void onEnter() {
    _running = true;
    _runPipeline();
  }

  @override
  void onExit() {
    _running = false;
  }

  @override
  void handleKey(TuiKeyEvent event) {
    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        app.popScreen();
      }
      return;
    }

    switch (event.key) {
      case TuiKey.escape:
        if (_running) {
          app.pipelineState.cancel();
          _logPanel.lines.add('⚠️ Cancel requested...');
        } else {
          app.popScreen();
        }
        break;
      case TuiKey.up:
        _logPanel.scrollUp();
        break;
      case TuiKey.down:
        _logPanel.scrollDown();
        break;
      case TuiKey.pageUp:
        for (int i = 0; i < 10; i++) _logPanel.scrollUp();
        break;
      case TuiKey.pageDown:
        for (int i = 0; i < 10; i++) _logPanel.scrollDown();
        break;
      default:
        break;
    }
  }

  Future<void> _runPipeline() async {
    final orch = PipelineOrchestrator(
      config: app.config,
      onLog: (msg) {
        _logPanel.lines.add(msg);
        _logPanel.scrollToBottom();
        app.screenManager.render();
      },
      onProgress: (current, total, stepProgress) {
        _status = 'Step ${current + 1}/$total (${stepProgress}%)';
        app.screenManager.render();
      },
      state: app.pipelineState,
    );

    try {
      await orch.run(fromStep: fromStep, toStep: toStep);
      _logPanel.lines.add('✅ Pipeline completed successfully!');
    } catch (e) {
      _logPanel.lines.add('❌ Pipeline failed: $e');
    } finally {
      _running = false;
      _completed = true;
      _status = 'Completed - Press Enter/Esc to return';
      app.screenManager.render();
    }
  }

  @override
  void render(StringBuffer sb) {
    // Header
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call('Pipeline'));
    const stepNames = ['Scrape Spotify', 'Download Missing', 'Build M3U8', 'Organize Unsorted', 'Enrich Metadata', 'Download Lyrics', 'Measure LUFS', 'Podcast RAG'];
    sb.write(': ${stepNames[fromStep]}');
    if (toStep != null && toStep != fromStep) {
      sb.write(' to ${stepNames[toStep!]}');
    }
    sb.write(AnsiStyles.bold.call(''));
    sb.write('  |  ');
    sb.write(AnsiStyles.cyan.call(_status));
    sb.write(AnsiStyles.cyan.call(''));

    // Progress bar
    if (_running) {
      final pb = ProgressBar(progress: 0.5, width: TermSize.width - 4, label: 'Running...');
      pb.render(sb, x: 2, y: 2);
    }

    // Log panel
    _logPanel.render(sb, x: 2, y: 4, width: TermSize.width - 4);

    // Footer
    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call('Pipeline completed. Press Enter or Esc to return.'));
    } else {
      sb.write(AnsiStyles.yellow.call('Running... Press Esc to cancel. ↑/↓/PgUp/PgDn to scroll.'));
    }
  }
}

/// Podcast pipeline screen
class PodcastScreen extends TuiScreen {
  final TuiApp app;
  late final LogPanel _logPanel;
  bool _running = false;
  bool _completed = false;

  PodcastScreen({required this.app}) {
    _logPanel = LogPanel(
      lines: [],
      width: TermSize.width - 4,
      height: TermSize.height - 8,
    );
  }

  @override
  String get title => 'Podcast Pipeline';

  @override
  void onEnter() {
    _running = true;
    _runPodcast();
  }

  @override
  void onExit() {
    _running = false;
  }

  @override
  void handleKey(TuiKeyEvent event) {
    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        app.popScreen();
      }
      return;
    }

    switch (event.key) {
      case TuiKey.escape:
        if (_running) {
          app.pipelineState.cancel();
          _logPanel.lines.add('⚠️ Cancel requested...');
        } else {
          app.popScreen();
        }
        break;
      case TuiKey.up:
        _logPanel.scrollUp();
        break;
      case TuiKey.down:
        _logPanel.scrollDown();
        break;
      default:
        break;
    }
  }

  Future<void> _runPodcast() async {
    final pipeline = PodcastPipeline(
      onLog: (msg) {
        _logPanel.lines.add(msg);
        _logPanel.scrollToBottom();
        app.screenManager.render();
      },
      onProgress: (c, t, s) {
        app.screenManager.render();
      },
      state: app.pipelineState,
    );

    try {
      await pipeline.run();
      _logPanel.lines.add('✅ Podcast pipeline completed!');
    } catch (e) {
      _logPanel.lines.add('❌ Failed: $e');
    } finally {
      _running = false;
      _completed = true;
      app.screenManager.render();
    }
  }

  @override
  void render(StringBuffer sb) {
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call);
    sb.write('Podcast Pipeline');
    sb.write(AnsiStyles.bold.call);

    _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call);
      sb.write('Completed. Press Enter or Esc to return.');
      sb.write(AnsiStyles.green.call);
    } else {
      sb.write(AnsiStyles.yellow.call);
      sb.write('Running... Esc to cancel. ↑/↓ to scroll.');
      sb.write(AnsiStyles.yellow.call);
    }
  }
}

/// Status screen
class StatusScreen extends TuiScreen {
  final TuiApp app;
  late final StatusPanel _statusPanel;

  StatusScreen({required this.app}) {
    _statusPanel = StatusPanel(
      fields: {
        'Library': app.config.libraryPath,
        'Music': app.config.musicPath,
        'Playlists': app.config.urlNames.length.toString(),
        'Downloaded': app.config.lastUpdated.length.toString(),
        'Base Path': app.config.basePath,
      },
      width: 60,
    );
  }

  @override
  String get title => 'Status';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
      app.popScreen();
    }
  }

  @override
  void render(StringBuffer sb) {
    _statusPanel.render(sb, x: 2, y: 2);

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    sb.write(AnsiStyles.dim.call);
    sb.write('Press Enter or Esc to return');
    sb.write(AnsiStyles.dim.call);
  }
}

/// Generic action screen with spinner
class ActionScreen extends TuiScreen {
  final String message;
  final Future<void> Function() action;
  final void Function() onComplete;
  final String screenTitle;
  late final LogPanel _logPanel;
  bool _running = false;
  bool _completed = false;
  final void Function() onPop;

  ActionScreen({
    required this.screenTitle,
    required this.message,
    required Future<void> Function() action,
    required this.onComplete,
    required this.onPop,
  }) : action = action,
       _logPanel = LogPanel(
         lines: [message],
         width: TermSize.width - 4,
         height: TermSize.height - 8,
       );

  @override
  String get title => screenTitle;

  @override
  void onEnter() {
    _running = true;
    _execute();
  }

  @override
  void onExit() {
    _running = false;
  }

  @override
  void handleKey(TuiKeyEvent event) {
    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        onPop();
      }
      return;
    }

    if (event.key == TuiKey.escape) {
      _logPanel.lines.add('⚠️ Cancelled by user');
      _completed = true;
      onComplete();
    }
  }

  Future<void> _execute() async {
    try {
      await action();
      _logPanel.lines.add('✅ Completed successfully!');
    } catch (e) {
      _logPanel.lines.add('❌ Error: $e');
    } finally {
      _running = false;
      _completed = true;
      onComplete();
    }
  }

  @override
  void render(StringBuffer sb) {
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call(screenTitle));
    sb.write(AnsiStyles.bold.call(''));

    _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call('Done. Press Enter or Esc to return.'));
    } else {
      sb.write(AnsiStyles.yellow.call('Working... Press Esc to cancel.'));
    }
  }
}

/// Play music screen
class PlayScreen extends TuiScreen {
  final TuiApp app;
  late final InputDialog _inputDialog;
  late final LogPanel _logPanel = LogPanel(
    lines: [],
    width: TermSize.width - 4,
    height: TermSize.height - 8,
  );

  PlayScreen({required this.app}) {
    _inputDialog = InputDialog(prompt: 'Enter song name or keyword:');
  }

  @override
  String get title => 'Play Music';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    if (!_inputDialog.isFinished) {
      _inputDialog.handleKey(event);
      if (_inputDialog.isFinished) {
        if (_inputDialog.result != null && _inputDialog.result!.isNotEmpty) {
          _play(_inputDialog.result!);
        } else {
          app.popScreen();
        }
      }
      return;
    }

    if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
      app.popScreen();
    }
  }

  Future<void> _play(String query) async {
    final cfg = app.config;
    String? local;

    // Search local library
    try {
      final dir = Directory(cfg.musicPath);
      if (dir.existsSync()) {
        final lower = query.toLowerCase();
        for (final f in dir.listSync(recursive: true)) {
          if (f is! File || !f.path.toLowerCase().endsWith('.mp3')) continue;
          final stem = f.uri.pathSegments.last
              .replaceAll(RegExp(r'\.\w+$'), '')
              .toLowerCase();
          if (stem == lower || stem.contains(lower) || lower.contains(stem)) {
            local = f.path;
            break;
          }
        }
      }
    } catch (_) {}

    MediaKit.ensureInitialized();
    final player = Player();
    player.setVolume(70);
    player.stream.log.listen((l) {
      if (l.prefix == 'cplayer' && l.text.contains('Exiting')) return;
      print('[mpvlog] ${l.prefix}: ${l.text}');
    });

    try {
      if (local != null) {
        _logPanel.lines.add('Playing (local): ${local.split(Platform.pathSeparator).last}');
        await player.open(Media(Uri.file(local).toString()));
      } else {
        await StreamServer.instance.start();
        final url = '${StreamServer.instance.baseUrl}/stream/${Uri.encodeComponent(query)}';
        _logPanel.lines.add('Playing (stream): $query');
        await player.open(Media(url));
      }
      player.stream.error.listen((e) => _logPanel.lines.add('[mpv] $e'));
      final dur = await player.stream.duration.first.timeout(const Duration(seconds: 20)).catchError((_) => Duration.zero);
      if (dur > Duration.zero) {
        _logPanel.lines.add('Duration: ${dur.inMinutes}:${(dur.inSeconds % 60).toString().padLeft(2, '0')}');
      }
      _logPanel.lines.add('(Playing... Ctrl+C to stop)');
      await Future.any([
        player.stream.completed.first,
        player.stream.error.first.then((e) => throw Exception('Playback failed: $e')),
      ]).timeout(const Duration(hours: 2));
      _logPanel.lines.add('Playback ended');
    } finally {
      try { await player.dispose(); } catch (_) {}
      try { await StreamServer.instance.stop(); } catch (_) {}
    }
  }

  @override
  void render(StringBuffer sb) {
    if (!_inputDialog.isFinished) {
      _inputDialog.render(sb, x: (TermSize.width - 50) ~/ 2, y: (TermSize.height - 5) ~/ 2);
    } else {
      // Show playback log
      _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);
      sb.write(Ansi.moveTo(TermSize.height - 1, 2));
      sb.write(AnsiStyles.dim.call('Playing... Press Ctrl+C to stop'));
    }
  }
}

/// Artwork backfill screen
class ArtworkScreen extends TuiScreen {
  final TuiApp app;
  late final LogPanel _logPanel;
  bool _running = false;
  bool _completed = false;

  ArtworkScreen({required this.app}) {
    _logPanel = LogPanel(
      lines: [],
      width: TermSize.width - 4,
      height: TermSize.height - 8,
    );
  }

  @override
  String get title => 'Artwork Backfill';

  @override
  void onEnter() {
    _running = true;
    _runBackfill();
  }

  @override
  void onExit() {
    _running = false;
  }

  @override
  void handleKey(TuiKeyEvent event) {
    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        app.popScreen();
      }
      return;
    }

    if (event.key == TuiKey.escape) {
      _logPanel.lines.add('⚠️ Cancel requested...');
      app.pipelineState.cancel();
    }
  }

  Future<void> _runBackfill() async {
    try {
      await SpotifySession.instance.load();
    } catch (_) {}

    _logPanel.lines.add(SpotifySession.instance.isLoggedIn
        ? 'Spotify logged in: can search missing covers'
        : '⚠️ Spotify not logged in: only embedding cached covers');

    final stats = await ArtworkEmbedder.instance.backfill(
      onProgress: (done, total, file) {
        if (done % 50 == 0 || done == total) {
          _logPanel.lines.add('  [$done/$total] $file');
          _logPanel.scrollToBottom();
          app.screenManager.render();
        }
      },
    );
    _logPanel.lines.add('Completed: ${stats['total']} total, ${stats['embedded']} embedded, ${stats['skipped']} skipped, ${stats['noCover']} no cover, ${stats['failed']} failed, tagged ${stats['tagged'] ?? 0}');
    _running = false;
    _completed = true;
    app.screenManager.render();
  }

  @override
  void render(StringBuffer sb) {
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call);
    sb.write('Artwork Backfill');
    sb.write(AnsiStyles.bold.call);

    _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call);
      sb.write('Completed. Press Enter or Esc to return.');
      sb.write(AnsiStyles.green.call);
    } else {
      sb.write(AnsiStyles.yellow.call);
      sb.write('Running... Esc to cancel.');
      sb.write(AnsiStyles.yellow.call);
    }
  }
}

/// Doctor screen
class DoctorScreen extends TuiScreen {
  final TuiApp app;
  late final LogPanel _logPanel;
  late final InputDialog _optionsDialog;
  bool _running = false;
  bool _completed = false;
  bool _showOptions = true;
  bool _fast = false;
  bool _noStt = false;

  DoctorScreen({required this.app}) {
    _logPanel = LogPanel(
      lines: [],
      width: TermSize.width - 4,
      height: TermSize.height - 8,
    );
    _optionsDialog = InputDialog(prompt: 'Options: [f]ast mode, [n]o STT, [Enter] to run, [Esc] cancel');
  }

  @override
  String get title => 'Library Doctor';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    if (_showOptions) {
      switch (event.key) {
        case TuiKey.char:
          if (event.char == 'f') _fast = !_fast;
          if (event.char == 'n') _noStt = !_noStt;
          break;
        case TuiKey.enter:
          _showOptions = false;
          _runDoctor();
          break;
        case TuiKey.escape:
          app.popScreen();
          break;
        default:
          break;
      }
      return;
    }

    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        app.popScreen();
      }
      return;
    }

    if (event.key == TuiKey.escape) {
      _logPanel.lines.add('⚠️ Cancel requested...');
      app.pipelineState.cancel();
    }
  }

  Future<void> _runDoctor() async {
    _logPanel.lines.add('Checking audio library (${_fast ? "fast mode" : "full mode"})...');
    final t0 = DateTime.now();

    final report = await LibraryDoctor.run(
      podcastsDir: '${app.config.basePath}${Platform.pathSeparator}podcasts',
      skipAudioProbe: _fast,
      onProgress: (d, t) {
        _logPanel.lines.add('  [$d/$t]');
        _logPanel.scrollToBottom();
        app.screenManager.render();
      },
    );

    _logPanel.lines.add('');
    _logPanel.lines.addAll(LibraryDoctor.format(report, verbose: true).split('\n'));
    _logPanel.lines.add('Duration: ${DateTime.now().difference(t0).inSeconds}s');

    if (!_noStt) {
      _logPanel.lines.add('');
      _logPanel.lines.add('STT quota: ${await LibraryDoctor.probeStt()}');
    }

    _running = false;
    _completed = true;
    app.screenManager.render();
  }

  @override
  void render(StringBuffer sb) {
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call);
    sb.write('Library Doctor');
    sb.write(AnsiStyles.bold.call);

    if (_showOptions) {
      _optionsDialog.render(sb, x: (TermSize.width - 60) ~/ 2, y: (TermSize.height - 7) ~/ 2);
      // Show current options
      sb.write(Ansi.moveTo((TermSize.height - 7) ~/ 2 + 6, (TermSize.width - 40) ~/ 2));
      sb.write('Fast mode: ${_fast ? "ON" : "OFF"}  |  No STT: ${_noStt ? "ON" : "OFF"}');
    } else {
      _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);
    }

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call);
      sb.write('Completed. Press Enter or Esc to return.');
      sb.write(AnsiStyles.green.call);
    } else if (!_showOptions) {
      sb.write(AnsiStyles.yellow.call);
      sb.write('Running... Esc to cancel.');
      sb.write(AnsiStyles.yellow.call);
    } else {
      sb.write(AnsiStyles.dim.call);
      sb.write('f=fast n=no-STT Enter=run Esc=cancel');
      sb.write(AnsiStyles.dim.call);
    }
  }
}

/// Cookie management screen
class CookieScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;

  CookieScreen({required this.app}) {
    _menu = MenuWidget(
      title: 'Cookie Management',
      items: [
        MenuItem(label: 'Check Cookie Status', shortcut: '1', onSelect: () => _check()),
        MenuItem(label: 'Export Login Cookie', shortcut: '2', onSelect: () => _export()),
        MenuItem(label: 'Back', shortcut: 'Esc', onSelect: () => app.popScreen()),
      ],
    );
  }

  @override
  String get title => 'Cookie Management';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.char:
        final idx = int.tryParse(event.char!) ?? -1;
        if (idx >= 0 && idx < 2) {
          _menu.selectedIndex = idx;
          _menu.selected?.onSelect?.call();
        }
        break;
      default:
        break;
    }
  }

  void _check() {
    app.pushScreen(ActionScreen(
      screenTitle: 'Cookie Check',
      message: 'Inspecting yt_cookies.txt...',
      action: () async {
        final r = CookieExport.inspect();
        if (r.path == null) {
          _logPanel.lines.add('Cookie file not found');
          _logPanel.lines.add('Expected: ${CookieExport.defaultOutPath()}');
        } else {
          _logPanel.lines.add('Cookie file: ${r.path}');
          _logPanel.lines.add('Total cookies: ${r.total}');
          _logPanel.lines.add('Auth cookies: ${r.auth} / ${CookieExport.authCookieCount}');
          if (r.auth >= 3) {
            _logPanel.lines.add('Status: LOGGED IN ✅');
          } else {
            _logPanel.lines.add('Status: ANONYMOUS ❌');
            _logPanel.lines.add('Missing: ${r.missing.take(6).join(", ")}...');
          }
        }
      },
      onComplete: () {},
      onPop: () => app.popScreen(),
    ));
  }

  void _export() {
    app.pushScreen(ActionScreen(
      screenTitle: 'Cookie Export',
      message: 'Opening dedicated Chrome window for cookie export...',
      action: () async {
        final (ok, msg) = await CookieExport.interactiveExport(
          basePath: app.config.basePath,
          onStatus: (s) => _logPanel.lines.add(s),
        );
        _logPanel.lines.add(msg);
        if (!ok) throw Exception('Export failed');
      },
      onComplete: () {},
      onPop: () => app.popScreen(),
    ));
  }

  late final LogPanel _logPanel = LogPanel(
    lines: [],
    width: TermSize.width - 4,
    height: TermSize.height - 8,
  );

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);
    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    sb.write(AnsiStyles.dim.call('1=Check 2=Export Esc=Back'));
  }
}

/// Metadata tools screen
class MetadataScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;

  MetadataScreen({required this.app}) {
    _menu = MenuWidget(
      title: 'Metadata Tools',
      items: [
        MenuItem(label: 'Enrich (from cache)', shortcut: '1', onSelect: () => _run('enrich')),
        MenuItem(label: 'Localize Artists', shortcut: '2', onSelect: () => _run('artists')),
        MenuItem(label: 'Fill Years from Spotify', shortcut: '3', onSelect: () => _run('years')),
        MenuItem(label: 'Correct from Spotify', shortcut: '4', onSelect: () => _run('spotify')),
        MenuItem(label: 'Back', shortcut: 'Esc', onSelect: () => app.popScreen()),
      ],
    );
  }

  @override
  String get title => 'Metadata Tools';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.char:
        final idx = int.tryParse(event.char!) ?? -1;
        if (idx >= 1 && idx <= 4) {
          _menu.selectedIndex = idx - 1;
          _menu.selected?.onSelect?.call();
        }
        break;
      default:
        break;
    }
  }

  void _run(String type) {
    app.pushScreen(MetadataActionScreen(app: app, type: type));
  }

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);
  }
}

/// Metadata action screen
class MetadataActionScreen extends TuiScreen {
  final TuiApp app;
  final String type;
  late final LogPanel _logPanel;
  late final InputDialog? _limitDialog;
  bool _running = false;
  bool _completed = false;
  bool _waitingForLimit = false;
  int _limit = 0;

  MetadataActionScreen({required this.app, required this.type}) {
    _logPanel = LogPanel(
      lines: [],
      width: TermSize.width - 4,
      height: TermSize.height - 8,
    );

    if (type == 'years' || type == 'spotify') {
      _limitDialog = InputDialog(prompt: 'Enter limit (0 = all):');
      _waitingForLimit = true;
    } else {
      _limitDialog = null;
      _waitingForLimit = false;
    }
  }

  @override
  String get title => 'Metadata: $type';

  @override
  void onEnter() {
    if (!_waitingForLimit) {
      _running = true;
      _execute();
    }
  }

  @override
  void onExit() {
    _running = false;
  }

  @override
  void handleKey(TuiKeyEvent event) {
    if (_waitingForLimit) {
      _limitDialog!.handleKey(event);
      if (_limitDialog!.isFinished) {
        _limit = int.tryParse(_limitDialog!.result ?? '0') ?? 0;
        _waitingForLimit = false;
        _running = true;
        _execute();
      }
      return;
    }

    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        app.popScreen();
      }
      return;
    }

    if (event.key == TuiKey.escape) {
      _logPanel.lines.add('⚠️ Cancel requested...');
      app.pipelineState.cancel();
    }
  }

  Future<void> _execute() async {
    final enricher = MetadataEnricher(log: (msg) {
      _logPanel.lines.add(msg);
      _logPanel.scrollToBottom();
      app.screenManager.render();
    }, libraryPath: app.config.musicPath);

    try {
      switch (type) {
        case 'enrich':
          await enricher.enrichAll(onProgress: (d, t) {
            if (d % 50 == 0 || d == t) {
              _logPanel.lines.add('  [$d/$t]');
              app.screenManager.render();
            }
          });
          break;
        case 'artists':
          await enricher.localizeArtists(onProgress: (d, t) {
            if (d % 100 == 0 || d == t) {
              _logPanel.lines.add('  [$d/$t]');
              app.screenManager.render();
            }
          });
          break;
        case 'years':
          await enricher.fillYearsFromSpotify(limit: _limit, onProgress: (d, t, f) {
            if (d % 50 == 0 || d == t) {
              _logPanel.lines.add('  [$d/$t] $f');
              app.screenManager.render();
            }
          });
          break;
        case 'spotify':
          await enricher.correctFromSpotify(onlyProblems: true, limit: _limit, onProgress: (d, t, f) {
            if (d % 50 == 0 || d == t) {
              _logPanel.lines.add('  [$d/$t] $f');
              app.screenManager.render();
            }
          });
          break;
      }
      _logPanel.lines.add('✅ Completed!');
    } catch (e) {
      _logPanel.lines.add('❌ Error: $e');
    } finally {
      _running = false;
      _completed = true;
      app.screenManager.render();
    }
  }

  @override
  void render(StringBuffer sb) {
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call);
    sb.write('Metadata: $type');
    sb.write(AnsiStyles.bold.call);

    if (_waitingForLimit) {
      _limitDialog!.render(sb, x: (TermSize.width - 50) ~/ 2, y: (TermSize.height - 5) ~/ 2);
    } else {
      _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);
    }

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call);
      sb.write('Completed. Press Enter or Esc to return.');
      sb.write(AnsiStyles.green.call);
    } else if (_waitingForLimit) {
      sb.write(AnsiStyles.dim.call);
      sb.write('Enter limit (0=all) then Enter to run, Esc to cancel');
      sb.write(AnsiStyles.dim.call);
    } else {
      sb.write(AnsiStyles.yellow.call);
      sb.write('Running... Esc to cancel.');
      sb.write(AnsiStyles.yellow.call);
    }
  }
}

/// Lyrics download screen
class LyricsScreen extends TuiScreen {
  final TuiApp app;
  late final LogPanel _logPanel;
  late final InputDialog _limitDialog;
  bool _running = false;
  bool _completed = false;
  bool _waitingForLimit = true;
  int _limit = 0;

  LyricsScreen({required this.app}) {
    _logPanel = LogPanel(
      lines: [],
      width: TermSize.width - 4,
      height: TermSize.height - 8,
    );
    _limitDialog = InputDialog(prompt: 'Enter limit (0 = all):');
  }

  @override
  String get title => 'Lyrics Download';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    if (_waitingForLimit) {
      _limitDialog.handleKey(event);
      if (_limitDialog.isFinished) {
        _limit = int.tryParse(_limitDialog.result ?? '0') ?? 0;
        _waitingForLimit = false;
        _running = true;
        _runDownload();
      }
      return;
    }

    if (_completed) {
      if (event.key == TuiKey.enter || event.key == TuiKey.escape) {
        app.popScreen();
      }
      return;
    }

    if (event.key == TuiKey.escape) {
      _logPanel.lines.add('⚠️ Cancel requested...');
      app.pipelineState.cancel();
    }
  }

  Future<void> _runDownload() async {
    if (!app.config.enablePipelineLyricsDownload) {
      _logPanel.lines.add('Lyrics download disabled in config');
      _completed = true;
      app.screenManager.render();
      return;
    }

    _logPanel.lines.add('Downloading lyrics for library tracks...');
    final lyricsDir = Directory('${app.config.basePath}${Platform.pathSeparator}${app.config.lyricsFolderName ?? "Lyrics"}');
    if (!lyricsDir.existsSync()) lyricsDir.createSync(recursive: true);

    final libDir = Directory(app.config.libraryPath);
    if (!libDir.existsSync()) {
      _logPanel.lines.add('Library path does not exist: ${app.config.libraryPath}');
      _completed = true;
      app.screenManager.render();
      return;
    }

    final files = <File>[];
    await for (final e in libDir.list(recursive: true, followLinks: false)) {
      if (e is File && (e.path.toLowerCase().endsWith('.mp3') || e.path.toLowerCase().endsWith('.flac') || e.path.toLowerCase().endsWith('.m4a'))) {
        files.add(e);
      }
    }

    if (files.isEmpty) {
      _logPanel.lines.add('No music files found');
      _completed = true;
      app.screenManager.render();
      return;
    }

    _logPanel.lines.add('Library has ${files.length} music files. Starting lyrics download...');
    int success = 0, skipped = 0, failed = 0;

    for (int i = 0; i < files.length; i++) {
      if (_limit > 0 && i >= _limit) break;
      if (app.pipelineState.isCancelled) break;

      final file = files[i];
      final stem = file.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      final lrcPath = '${lyricsDir.path}${Platform.pathSeparator}$stem.lrc';

      if (File(lrcPath).existsSync()) {
        skipped++;
        if (i % 50 == 0) {
          _logPanel.lines.add('  [$i/${files.length}] Skipped (exists)');
          app.screenManager.render();
        }
        continue;
      }

      String artist = '', track = '', album = '';
      final parts = stem.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        track = parts[1].trim();
      } else {
        artist = stem;
        track = '';
      }

      try {
        final result = await LyricsService.instance.fetch(
          artist, track,
          album: album.isNotEmpty ? album : null,
        ).timeout(const Duration(seconds: 15));

        if (result != null && result.hasSynced) {
          await File(lrcPath).writeAsString(result.syncedLyrics!, flush: true);
          success++;
        } else if (result != null && result.hasPlain) {
          await File(lrcPath).writeAsString(result.plainLyrics!, flush: true);
          success++;
        } else {
          failed++;
        }
      } catch (e) {
        failed++;
      }

      await Future.delayed(const Duration(milliseconds: 200));

      if (i % 50 == 0 || i == files.length - 1) {
        _logPanel.lines.add('  [$i/${files.length}] Success: $success, Skipped: $skipped, Failed: $failed');
        _logPanel.scrollToBottom();
        app.screenManager.render();
      }
    }

    _logPanel.lines.add('Completed: success $success, skipped $skipped, failed $failed');
    _logPanel.lines.add('Lyrics saved to: ${lyricsDir.path}');
    _running = false;
    _completed = true;
    app.screenManager.render();
  }

  @override
  void render(StringBuffer sb) {
    sb.write(Ansi.moveTo(0, 0));
    sb.write(AnsiStyles.bold.call);
    sb.write('Lyrics Download (LRCLib)');
    sb.write(AnsiStyles.bold.call);

    if (_waitingForLimit) {
      _limitDialog.render(sb, x: (TermSize.width - 50) ~/ 2, y: (TermSize.height - 5) ~/ 2);
    } else {
      _logPanel.render(sb, x: 2, y: 2, width: TermSize.width - 4);
    }

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    if (_completed) {
      sb.write(AnsiStyles.green.call);
      sb.write('Completed. Press Enter or Esc to return.');
      sb.write(AnsiStyles.green.call);
    } else if (_waitingForLimit) {
      sb.write(AnsiStyles.dim.call);
      sb.write('Enter limit (0=all) then Enter to run, Esc to cancel');
      sb.write(AnsiStyles.dim.call);
    } else {
      sb.write(AnsiStyles.yellow.call);
      sb.write('Running... Esc to cancel.');
      sb.write(AnsiStyles.yellow.call);
    }
  }
}

/// Favorites screen
class FavoritesScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;
  List<String> _favs = [];

  FavoritesScreen({required this.app}) {
    _menu = MenuWidget(
      title: 'Favorites',
      items: [],
    );
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final favsSet = await FavoritesService.load();
    _favs = favsSet.toList();
    _menu.items.clear();
    if (_favs.isEmpty) {
      _menu.items.add(MenuItem(label: '(empty)', enabled: false));
    } else {
      final sorted = _favs.toList()..sort();
      for (final f in sorted) {
        final name = File(f).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
        _menu.items.add(MenuItem(label: '★ $name', shortcut: '', onSelect: () => _toggle(f)));
      }
    }
    _menu.items.add(MenuItem(label: 'Back', shortcut: 'Esc', onSelect: () => app.popScreen()));
  }

  Future<void> _toggle(String song) async {
    await FavoritesService.toggle(song);
    await _loadFavorites();
    app.screenManager.render();
  }

  @override
  String get title => 'Favorites (${_favs.length})';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.escape:
        app.popScreen();
        break;
      default:
        break;
    }
  }

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);

    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    sb.write(AnsiStyles.dim.call('Enter=toggle Esc=back'));
  }
}

/// Budget screen
class BudgetScreen extends TuiScreen {
  final TuiApp app;
  late final MenuWidget _menu;

  BudgetScreen({required this.app}) {
    _menu = MenuWidget(
      title: 'Upload Budget',
      items: [
        MenuItem(label: 'Show Status', shortcut: '1', onSelect: _showStatus),
        MenuItem(label: 'Set Today Baseline', shortcut: '2', onSelect: _setBaseline),
        MenuItem(label: 'Back', shortcut: 'Esc', onSelect: () => app.popScreen()),
      ],
    );
  }

  void _showStatus() {
    app.pushScreen(ActionScreen(
      screenTitle: 'Budget Status',
      message: 'Loading...',
      action: () async {
        _logPanel.lines.add(UploadBudget.describe());
        _logPanel.lines.add(UploadBudget.todayText());
        if (!UploadBudget.hasLimit) {
          _logPanel.lines.add('(No PA_UPLOAD_BUDGET_MB set → unlimited)');
        }
      },
      onComplete: () {},
      onPop: () => app.popScreen(),
    ));
  }

  void _setBaseline() {
    UploadBudget.markTodayBaseline();
    app.pushScreen(ActionScreen(
      screenTitle: 'Budget',
      message: 'Setting today baseline...',
      action: () async {
        _logPanel.lines.add('Today baseline set');
        _logPanel.lines.add(UploadBudget.todayText());
      },
      onComplete: () {},
      onPop: () => app.popScreen(),
    ));
  }

  late final LogPanel _logPanel = LogPanel(
    lines: [],
    width: TermSize.width - 4,
    height: TermSize.height - 8,
  );

  @override
  String get title => 'Upload Budget';

  @override
  void onEnter() {}

  @override
  void onExit() {}

  @override
  void handleKey(TuiKeyEvent event) {
    switch (event.key) {
      case TuiKey.up:
        _menu.moveUp();
        break;
      case TuiKey.down:
        _menu.moveDown();
        break;
      case TuiKey.enter:
        _menu.selected?.onSelect?.call();
        break;
      case TuiKey.char:
        final idx = int.tryParse(event.char!) ?? -1;
        if (idx >= 1 && idx <= 2) {
          _menu.selectedIndex = idx - 1;
          _menu.selected?.onSelect?.call();
        }
        break;
      case TuiKey.escape:
        app.popScreen();
        break;
      default:
        break;
    }
  }

  @override
  void render(StringBuffer sb) {
    _menu.render(sb, x: 2, y: 2);
    sb.write(Ansi.moveTo(TermSize.height - 1, 2));
    sb.write(AnsiStyles.dim.call('1=Status 2=Set Baseline Esc=Back'));
  }
}

/// TUI entry point
Future<void> runTui() async {
  final app = TuiApp();
  await app.run();
}