with open('lib/services/snapshot_manager.dart', 'w', encoding='utf-8') as f:
    f.write("""import 'dart:convert';
import 'dart:io';
import 'config_service.dart';
import 'package:path/path.dart' as p;

class SnapshotManager {
  static const _cacheFile = 'snapshot_cache.json';

  static String get _cachePath =>
      '\${ConfigService.instance.config.basePath}\\\\$_cacheFile';

  static File _lockFile() {
    return File('\${ConfigService.instance.config.basePath}\\\\snapshot_cache.lock');
  }

  static Future<T> _withLock<T>(File lockFile, Future<T> Function() action) async {
    const maxRetries = 50;
    const retryDelay = Duration(milliseconds: 100);

    for (int i = 0; i < maxRetries; i++) {
      if (!await lockFile.exists()) {
        try {
          await lockFile.create(recursive: true);
          break;
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    try {
      return await action();
    } finally {
      try {
        await lockFile.delete();
      } catch (_) {}
    }
  }

  static Map<String, dynamic> _loadCache() {
    try {
      final f = File(_cachePath);
      if (!f.existsSync()) return {'playlists': <String, dynamic>{}, 'version': '1.0'};
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      if (data.containsKey('playlists')) return data;
      return {'playlists': <String, dynamic>{}, 'version': '1.0'};
    } catch (_) {
      return {'playlists': <String, dynamic>{}, 'version': '1.0'};
    }
  }

  static void _saveCache(Map<String, dynamic> cache) {
    try {
      File(_cachePath).writeAsStringSync(jsonEncode(cache), flush: true);
    } catch (_) {}
  }

  static List<String> detectRemovedSongs(String playlistName, List<String> currentTracks) {
    final cache = _loadCache();
    final playlists = cache['playlists'] as Map<String, dynamic>;
    final old = playlists[playlistName];
    if (old == null) return [];

    final oldTracks = (old['tracks'] as List<dynamic>?)?.cast<String>() ?? [];
    final oldSet = oldTracks.toSet();
    final currentSet = currentTracks.toSet();
    return oldSet.difference(currentSet).toList();
  }

  static void updateSnapshot(String playlistName, List<String> tracks) {
    final cache = _loadCache();
    final playlists = cache['playlists'] as Map<String, dynamic>;
    playlists[playlistName] = {
      'tracks': tracks,
      'last_updated': DateTime.now().toIso8601String(),
    };
    _saveCache(cache);
  }

  static int appendRemovedSongs(List<String> removedTracks) {
    if (removedTracks.isEmpty) return 0;
    return removedTracks.length;
  }

  static int processPlaylist(String playlistName, List<String> currentTracks) {
    final removed = detectRemovedSongs(playlistName, currentTracks);
    int count = 0;
    if (removed.isNotEmpty) {
      count = appendRemovedSongs(removed);
    }
    updateSnapshot(playlistName, currentTracks);
    return count;
  }

  static Map<String, int> processAll(Map<String, List<String>> playlists) {
    final result = <String, int>{};
    if (playlists.isEmpty) return result;

    return _withLock(File('\${ConfigService.instance.config.basePath}\\\\snapshot_cache.lock'), () async {
      final result = <String, int>{};
      if (playlists.isEmpty) return result;
      final cache = _loadCache();
      final all = cache['playlists'] as Map<String, dynamic>;
      for (final entry in playlists.entries) {
        final name = entry.key;
        final raw = entry.value;
        final current = raw.where((t) => t.trim().isNotEmpty).toSet().toList();
        int count = 0;
        try {
          final old = all[name];
          if (old != null) {
            final oldTracks = (old['tracks'] as List<dynamic>?)?.cast<String>() ?? [];
            final removed = oldTracks.toSet().difference(current.toSet());
            count = removed.length;
          }
          all[name] = {
            'tracks': current,
            'last_updated': DateTime.now().toIso8601String(),
          };
        } catch (_) {}
        result[name] = count;
      }
      _saveCache(cache);
      return result;
    });
  }

  static Future<T> _withLock<T>(File lockFile, Future<T> Function() action) async {
    const maxRetries = 50;
    const retryDelay = Duration(milliseconds: 100);

    for (int i = 0; i < maxRetries; i++) {
      if (!await lockFile.exists()) {
        try {
          await lockFile.create(recursive: true);
          break;
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    try {
      return await action();
    } finally {
      try {
        await lockFile.delete();
      } catch (_) {}
    }
  }
}
""")
print('Done')