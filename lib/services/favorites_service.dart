import 'dart:io';
import 'config_service.dart';

class FavoritesService {
  static const playlistName = '_Favorites';

  // toggle 是 load→改→write：連點兩下會交錯丟失一次更新，串行化。
  static Future<void> _mutex = Future.value();
  static Future<T> _locked<T>(Future<T> Function() fn) {
    final next = _mutex.then((_) => fn());
    _mutex = next.then((_) {}, onError: (_) {});
    return next;
  }

  static String get _filePath =>
      '${ConfigService.instance.config.playlistsPath}\\$playlistName.m3u8';

  static Future<Set<String>> load() async {
    final path = _filePath;
    final file = File(path);
    if (!await file.exists()) return {};
    final favs = <String>{};
    final plAbs = Directory(ConfigService.instance.config.playlistsPath).absolute.path;
    try {
      final lines = await file.readAsLines();
      for (final line in lines) {
        final raw = line.trim();
        if (raw.isEmpty || raw.startsWith('#')) continue;
        String decoded;
        try {
          decoded = Uri.decodeComponent(raw);
        } catch (_) {
          decoded = raw;
        }
        final abs = File(decoded).isAbsolute
            ? File(decoded).absolute.path
            : File('$plAbs\\$decoded').absolute.path;
        favs.add(_norm(abs));
      }
    } catch (_) {}
    return favs;
  }

  static Future<bool> isFavorite(String songPath) async {
    final favs = await load();
    return favs.contains(_norm(File(songPath).absolute.path));
  }

  static Future<bool> toggle(String songPath) {
    return _locked(() async {
      final favs = await load();
      final target = _norm(File(songPath).absolute.path);
      if (favs.contains(target)) {
        favs.remove(target);
      } else {
        favs.add(target);
      }
      await _write(favs);
      return favs.contains(target);
    });
  }

  static String normalize(String p) => _norm(p);

  static String _norm(String p) {
    final segs = p.replaceAll('\\', '/').split('/');
    final parts = <String>[];
    for (final seg in segs) {
      if (seg == '..') {
        if (parts.isNotEmpty &&
            parts.last != '..' &&
            !parts.last.contains(':')) {
          parts.removeLast();
        }
      } else if (seg.isNotEmpty && seg != '.') {
        parts.add(seg);
      }
    }
    return parts.join('/').toLowerCase();
  }

  static Future<void> _write(Set<String> favs) async {
    final plAbs = Directory(ConfigService.instance.config.playlistsPath).absolute.path;
    final sb = StringBuffer('#EXTM3U\n');
    for (final fav in favs) {
      String rel;
      try {
        rel = _relativePath(File(fav).path, plAbs);
      } catch (_) {
        rel = File(fav).path.replaceAll('\\', '/');
      }
      final name = File(fav).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      sb.writeln('#EXTINF:-1,$name');
      sb.writeln(rel);
    }
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(sb.toString());
  }

  static String _relativePath(String absPath, String relativeTo) {
    final absParts = absPath.replaceAll('\\', '/').split('/');
    final relParts = relativeTo.replaceAll('\\', '/').split('/');
    int common = 0;
    while (common < absParts.length && common < relParts.length &&
        absParts[common].toLowerCase() == relParts[common].toLowerCase()) {
      common++;
    }
    final up = List.filled(relParts.length - common, '..');
    final down = absParts.sublist(common);
    return [...up, ...down].join('/');
  }
}