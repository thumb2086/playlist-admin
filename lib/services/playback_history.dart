import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'config_service.dart';

/// Playback history: records a track when the user has listened to at least
/// 50% of it (or 4 minutes, whichever is less) — the same rule Spotube uses
/// for scrobbling. Stored in cache/playback_history.json.
class PlaybackHistory {
  static PlaybackHistory? _instance;
  static PlaybackHistory get instance => _instance ??= PlaybackHistory._();
  PlaybackHistory._();

  List<PlaybackEntry> _entries = [];
  bool _loaded = false;
  // 寫檔 debounce：每首歌都全量重寫 5000 筆 JSON 會卡主 thread，2s 合併一次。
  Timer? _saveTimer;

  static String get _path =>
      '${ConfigService.instance.config.cachePath}\\playback_history.json';

  List<PlaybackEntry> get entries {
    if (!_loaded) load();
    return _entries;
  }

  void load() {
    _loaded = true;
    try {
      final f = File(_path);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync()) as List<dynamic>;
      _entries = data
          .map((e) => PlaybackEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      if (_entries.length > 5000) {
        _entries = _entries.sublist(_entries.length - 5000);
      }
    } catch (_) {}
  }

  void record(String title, String artist, Duration duration) {
    _entries.add(PlaybackEntry(
      title: title,
      artist: artist,
      durationMs: duration.inMilliseconds,
      playedAt: DateTime.now(),
    ));
    if (_entries.length > 5000) {
      _entries = _entries.sublist(_entries.length - 5000);
    }
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      try {
        _save();
      } catch (_) {}
    });
  }

  void _save() {
    try {
      final f = File(_path);
      f.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (_) {}
  }

  void clear() {
    _entries.clear();
    _save();
  }

  // --- Stats queries -----------------------------------------------------

  /// Top tracks by play count within [windowDays] (null = all time).
  List<({String title, String artist, int count, int totalMs})> topTracks(
      {int? windowDays, int limit = 10}) {
    final cutoff = windowDays != null
        ? DateTime.now().subtract(Duration(days: windowDays))
        : null;
    final counts = <String, ({String title, String artist, int count, int totalMs})>{};
    for (final e in entries) {
      if (cutoff != null && e.playedAt.isBefore(cutoff)) continue;
      final key = '${e.title}\u0000${e.artist}';
      final cur = counts[key];
      counts[key] = (
        title: e.title,
        artist: e.artist,
        count: (cur?.count ?? 0) + 1,
        totalMs: (cur?.totalMs ?? 0) + e.durationMs,
      );
    }
    final list = counts.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return list.take(limit).toList();
  }

  /// Total listening time in minutes within [windowDays] (null = all time).
  int totalMinutes({int? windowDays}) {
    final cutoff = windowDays != null
        ? DateTime.now().subtract(Duration(days: windowDays))
        : null;
    var ms = 0;
    for (final e in entries) {
      if (cutoff != null && e.playedAt.isBefore(cutoff)) continue;
      ms += e.durationMs;
    }
    return ms ~/ 60000;
  }

  /// Unique tracks / artists within [windowDays] (null = all time).
  ({int tracks, int artists}) uniqueCount({int? windowDays}) {
    final cutoff = windowDays != null
        ? DateTime.now().subtract(Duration(days: windowDays))
        : null;
    final tracks = <String>{};
    final artists = <String>{};
    for (final e in entries) {
      if (cutoff != null && e.playedAt.isBefore(cutoff)) continue;
      tracks.add('${e.title}\u0000${e.artist}');
      if (e.artist.isNotEmpty) artists.add(e.artist);
    }
    return (tracks: tracks.length, artists: artists.length);
  }

  /// Most recent plays (newest first).
  List<PlaybackEntry> recent({int limit = 20}) {
    final list = List<PlaybackEntry>.from(entries);
    return list.reversed.take(limit).toList();
  }
}

class PlaybackEntry {
  final String title;
  final String artist;
  final int durationMs;
  final DateTime playedAt;

  PlaybackEntry({
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.playedAt,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'durationMs': durationMs,
        'playedAt': playedAt.toIso8601String(),
      };

  factory PlaybackEntry.fromJson(Map<String, dynamic> j) => PlaybackEntry(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        playedAt: DateTime.tryParse(j['playedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}