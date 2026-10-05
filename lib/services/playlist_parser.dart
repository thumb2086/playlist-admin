import 'dart:convert';
import 'dart:io';
import '../models/playlist_item.dart';

class PlaylistParser {
  static const _internalMarkers = ['_unsorted', 'single tracks', '_unsorted_songs', '_favorites'];

  static bool isInternalPlaylist(String name) {
    final n = name.toLowerCase();
    if (n.contains('_removed songs')) return true;
    return _internalMarkers.any((m) => n.contains(m));
  }

  static List<String> parseTrackNames(String filePath) {
    final songs = <String>[];
    final file = File(filePath);
    if (!file.existsSync()) return songs;

    String content;
    try {
      content = file.readAsStringSync(encoding: utf8);
    } catch (_) {
      try {
        content = file.readAsStringSync();
      } catch (_) {
        return songs;
      }
    }

    final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return songs;

    final isM3u = lines.any((l) => l.contains('#EXTM3U'));

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.isEmpty) { i++; continue; }

      if (isM3u) {
        if (line.startsWith('#EXTINF:')) {
          int j = i + 1;
          while (j < lines.length && (lines[j].startsWith('#') || lines[j].isEmpty)) {
            j++;
          }
          if (j < lines.length) {
            final pathLine = lines[j];
            final name = pathLine.contains('\\') || pathLine.contains('/')
                ? pathLine.split(RegExp(r'[\\/]')).last
                : pathLine;
            songs.add(_decode(name).replaceAll(RegExp(r'\.\w+$'), ''));
            i = j + 1;
          } else {
            i++;
          }
        } else {
          i++;
        }
      } else {
        if (!line.startsWith('#')) {
          songs.add(line);
        }
        i++;
      }
    }
    return songs;
  }

  static String _decode(String s) {
    // Decode URI-encoded paths (e.g. %E5%A4%A2%E6%83%B3 -> 夢想).
    // Raw paths (incl. literal %) must pass through untouched.
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  /// 開本機歌單共用入口（側欄 + 音樂庫卡片共用，差別只在呈現方式）：
  /// m3u8 → items（audioQuery = 完整檔名 stem → _findLocalTrack 精準命中）。
  /// 檔名慣例「曲名 - 歌手」，與 _titleFromPath/_artistFromPath 一致。
  static List<PlaylistItem> loadLocalItems(String playlistsPath, String name) {
    final items = <PlaylistItem>[];
    final sep = Platform.pathSeparator;
    for (final stem in parseTrackNames('$playlistsPath$sep$name.m3u8')) {
      final parts = stem.split(' - ');
      items.add(PlaylistItem(
        name: parts.first,
        artist: parts.length > 1 ? parts.sublist(1).join(' - ') : '',
        audioQuery: stem,
      ));
    }
    return items;
  }

  static List<String> parseTrackEntries(String filePath) {
    final entries = <String>[];
    final file = File(filePath);
    if (!file.existsSync()) return entries;

    String content;
    try {
      content = file.readAsStringSync(encoding: utf8);
    } catch (_) {
      try {
        content = file.readAsStringSync();
      } catch (_) {
        return entries;
      }
    }

    final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return entries;

    final isM3u = lines.any((l) => l.contains('#EXTM3U'));

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.isEmpty) { i++; continue; }

      if (isM3u) {
        if (line.startsWith('#EXTINF:')) {
          int j = i + 1;
          while (j < lines.length && (lines[j].startsWith('#') || lines[j].isEmpty)) {
            j++;
          }
if (j < lines.length) {
          entries.add(_decode(lines[j]));
          i = j + 1;
          } else {
            i++;
          }
        } else {
          i++;
        }
      } else {
        if (!line.startsWith('#')) {
          entries.add(line);
        }
        i++;
      }
    }
    return entries;
  }
}
