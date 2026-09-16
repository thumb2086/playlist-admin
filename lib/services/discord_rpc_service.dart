import 'dart:io';

import 'package:discord_rich_presence/discord_rich_presence.dart';

import 'log_manager.dart';

/// Discord Rich Presence（使用 discord_rich_presence 純 Dart 套件）。
/// 從 .env 讀取 Client ID。
class DiscordRpcService {
  static final DiscordRpcService instance = DiscordRpcService._();
  DiscordRpcService._();

  Client? _client;
  bool _enabled = false;
  bool _connected = false;
  Activity? _pending;

  bool get usable => _enabled && _connected;

  /// 從 .env 檔案載入 Discord Client ID。
  static String _loadClientId() {
    try {
      final envFile = File('.env');
      if (envFile.existsSync()) {
        for (final line in envFile.readAsLinesSync()) {
          if (line.startsWith('DISCORD_CLIENT_ID=')) {
            return line.substring('DISCORD_CLIENT_ID='.length).trim();
          }
        }
      }
    } catch (_) {}
    return '1537277062098980944';
  }

  Future<void> attach({
    required bool enabled,
    required String applicationId,
    void Function()? onReady,
  }) async {
    // 如果 applicationId 是預設值，嘗試從 .env 覆蓋。
    final clientId = (applicationId.isNotEmpty && applicationId != '1537277062098980944')
        ? applicationId
        : _loadClientId();
    if (enabled == _enabled && _client != null) {
      if (onReady != null && _connected) onReady();
      return;
    }

    _enabled = enabled;
    LogManager.instance.info(
        'DiscordRPC attach enabled=$enabled appId=${clientId.isNotEmpty ? 'ok' : 'EMPTY'}');

    if (_enabled && clientId.isNotEmpty) {
      try {
        _client = Client(clientId: clientId);
        // Discord 沒開時 connect 會 hang 住 UI：15s timeout。
        await _client!.connect().timeout(const Duration(seconds: 15));
        _connected = true;
        LogManager.instance.info('DiscordRPC connected');
        if (onReady != null) onReady();
        _pump();
      } catch (e) {
        _connected = false;
        LogManager.instance.error('DiscordRPC connect FAILED: $e');
      }
    } else if (!_enabled) {
      await clear();
      await disconnect();
    }
  }

  /// 推送播放狀態到 Discord（details=歌名, state=藝人, listening）。
  Future<void> update({
    required String title,
    required String artist,
    String? album,
    String? artworkUrl,
    bool playing = false,
    Duration? position,
    Duration? duration,
  }) async {
    if (title.isEmpty) return;
    final now = DateTime.now();
    final elapsed = position ?? Duration.zero;
    final start = playing ? now.subtract(elapsed) : now;
    final end = playing && duration != null ? start.add(duration) : null;

    final activity = Activity(
      name: 'Playlist Admin',
      details: title,
      state: artist,
      assets: ActivityAssets(
        largeImage: artworkUrl?.isNotEmpty == true
            ? artworkUrl!
            : 'playlist-admin-logo',
        largeText: album ?? '',
      ),
      timestamps: ActivityTimestamps(start: start, end: end),
      type: ActivityType.listening,
    );

    _pending = activity;
    if (!usable) {
      LogManager.instance.info(
          'DiscordRPC update skipped (usable=$usable) title=$title');
      return;
    }
    try {
      await _client!.setActivity(activity).timeout(const Duration(seconds: 10));
      LogManager.instance.info('DiscordRPC activity pushed: $title - $artist');
    } catch (e) {
      LogManager.instance.error('DiscordRPC setActivity FAILED: $e');
    }
  }

  void _pump() {
    if (!usable || _pending == null) return;
    LogManager.instance.info('DiscordRPC connect retry -> push pending');
    try {
      _client!.setActivity(_pending!);
    } catch (e) {
      LogManager.instance.error('DiscordRPC pump FAILED: $e');
    }
  }

  Future<void> clear() async {
    _pending = null;
    if (!usable) return;
    try {
      _client!.setActivity(Activity(name: 'Playlist Admin', type: ActivityType.playing));
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      await _client?.disconnect();
    } catch (_) {}
    _client = null;
    _connected = false;
  }

  Future<void> dispose() async {
    await clear();
    await disconnect();
    _enabled = false;
  }
}
