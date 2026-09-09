import 'dart:convert';
import 'dart:io';
import 'config_service.dart';
import 'youtube_service.dart';

class MissingFlacSong {
  final String name;
  final String playlist;
  final String artistHint;
  MissingFlacSong({required this.name, required this.playlist, required this.artistHint});
  factory MissingFlacSong.fromJson(Map<String, dynamic> json) => MissingFlacSong(
    name: json['name'] as String? ?? '',
    playlist: json['playlist'] as String? ?? '',
    artistHint: json['artist_hint'] as String? ?? '',
  );
}

class DownloadService {
  static DownloadService? _instance;
  static DownloadService get instance => _instance ??= DownloadService._();
  DownloadService._();

  String get _pythonPath => 'python';

  String get _bridgePath {
    final exeDir = Directory(File(Platform.resolvedExecutable).parent.path);
    Directory? d = exeDir;
    while (d != null) {
      final candidate = '${d.path}\\tools\\flutter_download_bridge.py';
      if (File(candidate).existsSync()) return candidate;
      final parent = d.parent;
      d = parent.path == d.path ? null : parent;
    }
    return '';
  }

  // ── 原生下載（取代 Python bridge）─────────────────────

  /// 搜尋 YouTube 並下載歌曲（原生 Dart，取代 bridge download-song）。
  Future<void> downloadSong({
    required String songName,
    String? libraryPath,
    String format = 'mp3',
    required void Function(String log) onLog,
    required void Function(double progress) onProgress,
  }) async {
    final cfg = ConfigService.instance.config;
    final effectivePath = libraryPath ?? cfg.musicPath;
    final safeName = songName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final outPath = '$effectivePath\\$safeName.$format';

    onLog('🔍 搜尋: $songName');
    onProgress(0.05);

    try {
      final result = await YoutubeService.instance.downloadBySearch(
        songName,
        outputPath: outPath,
        format: format,
        onProgress: (p) => onProgress(p),
      );

      if (result != null) {
        onLog('✅ 下載完成: $result');
        onProgress(1.0);
      } else {
        onLog('❌ 下載失敗: $songName');
        throw Exception('下載失敗: $songName');
      }
    } catch (e) {
      onLog('❌ $e');
      rethrow;
    }
  }

  /// 從 YouTube URL 下載音訊（原生 Dart，取代 bridge download-youtube）。
  Future<void> downloadYouTube({
    required String url,
    required String outputPath,
    String format = 'mp3',
    required void Function(String log) onLog,
    required void Function(double progress) onProgress,
  }) async {
    onLog('🔗 解析 YouTube URL...');
    onProgress(0.1);

    try {
      final result = await YoutubeService.instance.downloadFromUrl(
        url,
        outputPath: outputPath,
        format: format,
        onProgress: (p) => onProgress(p),
      );

      if (result != null) {
        onLog('✅ 下載完成: $result');
        onProgress(1.0);
      } else {
        onLog('❌ 下載失敗: $url');
        throw Exception('下載失敗: $url');
      }
    } catch (e) {
      onLog('❌ $e');
      rethrow;
    }
  }

  // ── 仍需 Python bridge 的命令 ─────────────────────────

  Future<List<MissingFlacSong>> listMissing(String format, {
    required void Function(String log) onLog,
  }) async {
    final bridge = _bridgePath;
    if (bridge.isEmpty) throw Exception('找不到 flutter_download_bridge.py（僅影響 list-missing / batch-download）');

    final env = Map<String, String>.from(Platform.environment);
    env['PYTHONIOENCODING'] = 'utf-8';
    final proc = await Process.start(
      _pythonPath,
      [bridge, 'list-missing', format],
      runInShell: true,
      workingDirectory: ConfigService.instance.config.basePath,
      environment: env,
    );

    final songs = <MissingFlacSong>[];
    await proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      if (line.trim().isEmpty) return;
      try {
        final json = jsonDecode(line.trim()) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'missing_list') {
          final list = json['songs'] as List<dynamic>? ?? [];
          for (final s in list) {
            songs.add(MissingFlacSong.fromJson(s as Map<String, dynamic>));
          }
        } else if (type == 'error') {
          onLog('❌ ${json['message']}');
        } else if (type == 'log') {
          onLog(json['message'] as String? ?? '');
        }
      } catch (_) {}
    });

    await proc.exitCode;
    return songs;
  }

  Future<void> downloadBatch(String format, {
    required List<MissingFlacSong> songs,
    required void Function(String log) onLog,
    required void Function(int current, int total, String song) onProgress,
  }) async {
    final bridge = _bridgePath;
    if (bridge.isEmpty) throw Exception('找不到 flutter_download_bridge.py（僅影響 list-missing / batch-download）');

    final songsJson = jsonEncode(songs.map((s) => {
      'name': s.name,
      'playlist': s.playlist,
      'artist_hint': s.artistHint,
    }).toList());

    final env = Map<String, String>.from(Platform.environment);
    env['PYTHONIOENCODING'] = 'utf-8';
    final proc = await Process.start(
      _pythonPath,
      [bridge, 'batch-download', format, songsJson],
      runInShell: true,
      workingDirectory: ConfigService.instance.config.basePath,
      environment: env,
    );

    final fmtLabel = format.toUpperCase();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (line.trim().isEmpty) return;
        try {
          final json = jsonDecode(line.trim()) as Map<String, dynamic>;
          final type = json['type'] as String?;
          if (type == 'log') {
            onLog(json['message'] as String? ?? '');
          } else if (type == 'batch_progress') {
            final idx = (json['index'] as num?)?.toInt() ?? 0;
            final total = (json['total'] as num?)?.toInt() ?? 0;
            final song = json['song'] as String? ?? '';
            onProgress(idx, total, song);
          } else if (type == 'batch_start') {
            final total = (json['total'] as num?)?.toInt() ?? 0;
            onLog('🔽 $fmtLabel 批次下載開始，共 $total 首');
          } else if (type == 'batch_complete') {
            final succ = (json['successful'] as num?)?.toInt() ?? 0;
            final fail = (json['failed'] as num?)?.toInt() ?? 0;
            onLog('✅ $fmtLabel 批次下載完成：成功 $succ 首，失敗 $fail 首');
          } else if (type == 'error') {
            onLog('❌ ${json['message']}');
          }
        } catch (_) {}
      },
    );

    final exitCode = await proc.exitCode;
    if (exitCode != 0) {
      onLog('❌ Python 程序異常退出 (code: $exitCode)');
    }
  }
}
