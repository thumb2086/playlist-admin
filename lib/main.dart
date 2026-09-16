import 'dart:convert';
import 'dart:ffi';
import 'dart:io' as io; // dk: Platform 與 Flutter 的 Platform 衝突，用別名
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:win32/win32.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'cli_main.dart' show runCli;
import 'services/config_service.dart';
import 'services/groq_service.dart';
import 'services/i18n.dart';
import 'services/log_manager.dart';
import 'services/spotify_session.dart';
import 'services/player_controller.dart';

int _foundHwnd = 0;

int _enumFindFlutter(int h, int _) {
  final len = GetWindowTextLength(h) + 1;
  final buf = calloc<Uint16>(len);
  GetWindowText(h, buf.cast<Utf16>(), len);
  final title = buf.cast<Utf16>().toDartString();
  calloc.free(buf);
  if (title.toLowerCase().contains('playlist') || title.contains('播放清單')) {
    _foundHwnd = h;
    return FALSE;
  }
  return TRUE;
}

void _bringToFront() {
  _foundHwnd = 0;
  final callback = Pointer.fromFunction<WNDENUMPROC>(_enumFindFlutter, FALSE);
  EnumWindows(callback, 0);
  if (_foundHwnd != 0) {
    if (IsIconic(_foundHwnd) != 0) ShowWindow(_foundHwnd, SW_RESTORE);
    SetForegroundWindow(_foundHwnd);
  }
}

io.RandomAccessFile? _lockFile;

void _ensureSingleInstance() {
  final lockPath = '${io.Directory.systemTemp.path}\\PlaylistAdmin.lock';
  try {
    _lockFile = io.File(lockPath).openSync(mode: io.FileMode.write);
    _lockFile!.lockSync();
  } catch (_) {
    _bringToFront();
    io.exit(0);
  }
}

/// CLI args are delivered via the PA_CLI_ARGS environment variable
/// (JSON array): Flutter's Dart `Platform.executableArguments` is empty in
/// release on this SDK, so the `playlist-admin` npm wrapper passes args
/// through env instead. Kept in the app so GUI and CLI share one binary.
List<String> _cliArgs() {
  final raw = io.Platform.environment['PA_CLI_ARGS'];
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final list = (jsonDecode(raw) as List<dynamic>).cast<String>();
    return list;
  } catch (_) {
    return raw.split(' ').where((s) => s.isNotEmpty).toList();
  }
}

void main() async {
  // Single binary, two surfaces: pass CLI args to use the headless engine
  // (playlist-admin pipeline / status / podcast ...), which is
  // what the `playlist-admin` npm package spawns.
  final args = _cliArgs();
  if (args.isNotEmpty) {
    await runCli(args);
    // The runner keeps a window message loop alive even without runApp —
    // force-exit so the CLI returns to the caller.
    io.exit(0);
  }

  WidgetsFlutterBinding.ensureInitialized();
  // 單一實例鎖（Win32 專用）只在 Windows 桌面執行，手機上跳過。
  if (!kIsWeb && io.Platform.isWindows) {
    _ensureSingleInstance();
  }
  await ConfigService.instance.load();
  final basePath = ConfigService.instance.config.basePath;
  if (basePath.isNotEmpty) {
    LogManager.instance.enable(basePath);
  }
  await SpotifySession.instance.load();
  MediaKit.ensureInitialized();
  PlayerController.instance.init();
  FlutterError.onError = (details) {
    LogManager.instance.error('FlutterError: ${details.exception}\n${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    LogManager.instance.error('PlatformDispatcher: $error\n$stack');
    return true;
  };
  await GroqService.instance.loadFromEnv();
  if (GroqService.instance.apiKey != null && GroqService.instance.apiKey!.isNotEmpty) {
    ConfigService.instance.config.groqApiKey = GroqService.instance.apiKey!;
  } else if (ConfigService.instance.config.groqApiKey.isNotEmpty) {
    GroqService.instance.setApiKey(ConfigService.instance.config.groqApiKey);
  }
  I18N.instance.setLanguage(ConfigService.instance.config.language);
  runApp(const PlaylistAdminApp());
}
