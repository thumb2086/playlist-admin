import 'dart:io';
import '../models/playlist.dart';

class AppConfig {
  static const String defaultDiscordAppId = '1537277062098980944';
  String basePath;
  String language;
  String audioFormat;
  int maxThreads;
  bool debugMode;
  bool enableMetadataEnrichment;
  String ffmpegPath;
  String lyricsFolderName;
  bool autoUpdateCheck;
  bool autoDownloadUpdate;
  String githubToken;
  bool enableRetroactiveLyrics;
  String theme;
  String skippedVersion;
  bool setupCompleted;
  bool podcastRagInMusic;
  String groqApiKey;
  int groqConcurrency;
  bool discordPresenceEnabled;
  String discordApplicationId;
  double volume;
  bool crossfadeEnabled;
  double crossfadeSeconds;
  bool streamCacheEnabled;
  int streamCacheMaxMb;
  bool receiveBetaUpdates;
  Map<String, String> podcastSubscriptions;
  Map<String, String> podcastHistory;
  Map<String, String> urlNames;
  Map<String, String> searchNames;
  Map<String, String> lastUpdated;
  Map<String, double> lyricsOffsets;

  AppConfig({
    this.basePath = '',
    this.language = 'zh-TW',
    this.audioFormat = 'mp3',
    this.maxThreads = 4,
    this.debugMode = false,
    this.enableMetadataEnrichment = false,
    this.ffmpegPath = 'bin/ffmpeg.exe',
    this.lyricsFolderName = 'Lyrics',
    this.autoUpdateCheck = true,
    this.autoDownloadUpdate = false,
    this.githubToken = '',
    this.enableRetroactiveLyrics = false,
    this.theme = 'dark',
    this.skippedVersion = '',
    this.setupCompleted = false,
    this.podcastRagInMusic = false,
    this.groqApiKey = '',
    this.groqConcurrency = 3,
    this.discordPresenceEnabled = true,
    this.discordApplicationId = defaultDiscordAppId,
    this.volume = 0.7,
    this.crossfadeEnabled = false,
    this.crossfadeSeconds = 3.0,
    this.streamCacheEnabled = true,
    this.streamCacheMaxMb = 2048,
    this.receiveBetaUpdates = false,
    Map<String, String>? podcastSubscriptions,
    Map<String, String>? podcastHistory,
    Map<String, String>? urlNames,
    Map<String, String>? searchNames,
    Map<String, String>? lastUpdated,
    Map<String, double>? lyricsOffsets,
  })  : podcastSubscriptions = podcastSubscriptions ?? {},
        podcastHistory = podcastHistory ?? {},
        urlNames = urlNames ?? {},
        searchNames = searchNames ?? {},
        lastUpdated = lastUpdated ?? {},
        lyricsOffsets = lyricsOffsets ?? {};

  List<PlaylistConfig> get playlists =>
      urlNames.entries.map((e) => PlaylistConfig(url: e.key, name: e.value)).toList();

  /// Music library root — the single directory for all audio files.
  String get musicPath {
    final p = '$basePath${Platform.pathSeparator}music';
    if (Directory(p).existsSync()) return p;
    final legacy = '$basePath${Platform.pathSeparator}native';
    if (Directory(legacy).existsSync()) return legacy;
    return basePath;
  }

  /// Legacy alias — same as musicPath.
  String get libraryPath => musicPath;

  String get playlistsPath => '$basePath${Platform.pathSeparator}playlists';
  String get exportPath => '$basePath${Platform.pathSeparator}exports';
  String get lyricsPath => '$basePath${Platform.pathSeparator}$lyricsFolderName';
  String get cachePath => '$basePath${Platform.pathSeparator}cache';
  String get spotifyCachePath => '$cachePath${Platform.pathSeparator}spotify';
  String get lufsCachePath => '$cachePath${Platform.pathSeparator}lufs';
  String get streamCachePath => '$cachePath${Platform.pathSeparator}stream';
  String get podcastsPath => '$basePath${Platform.pathSeparator}podcasts';
  String get toolsPath => '$basePath${Platform.pathSeparator}tools';

  /// Resolve ffmpeg path — try config first, then PATH, then common locations.
  static String resolveFfmpeg(String configPath) {
    if (configPath.isNotEmpty && File(configPath).existsSync()) return configPath;
    // Try the configured path relative to basePath.
    if (configPath.isNotEmpty) {
      final resolved = File(configPath);
      if (resolved.existsSync()) return resolved.absolute.path;
    }
    // Try PATH.
    try {
      final result = Process.runSync('where', ['ffmpeg']);
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).trim().split('\n');
        if (lines.isNotEmpty && lines.first.trim().isNotEmpty) {
          return lines.first.trim();
        }
      }
    } catch (_) {}
    // Common Windows locations.
    final candidates = [
      r'C:\ffmpeg\bin\ffmpeg.exe',
      r'C:\tools\ffmpeg.exe',
      r'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
      r'C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe',
    ];
    // WinGet package location.
    final userProfile = Platform.environment['LOCALAPPDATA'] ?? '';
    if (userProfile.isNotEmpty) {
      final wingetDir = Directory('$userProfile\\Microsoft\\WinGet\\Packages');
      if (wingetDir.existsSync()) {
        for (final d in wingetDir.listSync().whereType<Directory>()) {
          if (d.path.toLowerCase().contains('ffmpeg')) {
            for (final f in d.listSync(recursive: true).whereType<File>()) {
              if (f.path.toLowerCase().endsWith('ffmpeg.exe')) return f.path;
            }
          }
        }
      }
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return 'ffmpeg'; // fallback to PATH
  }

  /// Getter that auto-resolves ffmpeg path.
  String get resolvedFfmpegPath => resolveFfmpeg(ffmpegPath);

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        basePath: json['base_path'] as String? ?? '',
        language: json['language'] as String? ?? 'zh-TW',
        audioFormat: json['audio_format'] as String? ?? 'mp3',
        maxThreads: json['max_threads'] as int? ?? 4,
        debugMode: json['debug_mode'] as bool? ?? false,
        enableMetadataEnrichment: json['enable_metadata_enrichment'] as bool? ?? false,
        ffmpegPath: json['ffmpeg_path'] as String? ?? 'bin/ffmpeg.exe',
        lyricsFolderName: json['lyrics_folder_name'] as String? ?? 'Lyrics',
        autoUpdateCheck: json['auto_update_check'] as bool? ?? true,
        autoDownloadUpdate: json['auto_download_update'] as bool? ?? false,
        githubToken: json['github_token'] as String? ?? '',
        enableRetroactiveLyrics: json['enable_retroactive_lyrics'] as bool? ?? false,
        theme: json['theme'] as String? ?? 'dark',
        skippedVersion: json['skipped_version'] as String? ?? '',
        setupCompleted: json['setup_completed'] as bool? ?? false,
        podcastRagInMusic: json['podcast_rag_in_music'] as bool? ?? false,
        groqApiKey: json['groq_api_key'] as String? ?? '',
        groqConcurrency: json['groq_concurrency'] as int? ?? 3,
        discordPresenceEnabled: json['discord_presence_enabled'] as bool? ?? true,
        discordApplicationId: (json['discord_application_id'] as String?)
                ?.isNotEmpty == true
            ? json['discord_application_id'] as String
            : defaultDiscordAppId,
        volume: (json['volume'] as num?)?.toDouble() ?? 0.7,
        crossfadeEnabled: json['crossfade_enabled'] as bool? ?? false,
        crossfadeSeconds: (json['crossfade_seconds'] as num?)?.toDouble() ?? 3.0,
        streamCacheEnabled: json['stream_cache_enabled'] as bool? ?? true,
        streamCacheMaxMb: json['stream_cache_max_mb'] as int? ?? 2048,
        receiveBetaUpdates: json['receive_beta_updates'] as bool? ?? false,
        podcastSubscriptions: (json['podcast_subscriptions'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? {},
        podcastHistory: (json['podcast_history'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? {},
        urlNames: (json['url_names'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? {},
        searchNames: (json['search_names'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? {},
        lastUpdated: (json['last_updated'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? {},
        lyricsOffsets: (json['lyrics_offsets'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, (v as num).toDouble())) ?? {},
      );

  Map<String, dynamic> toJson() => {
        'base_path': basePath,
        'language': language,
        'audio_format': audioFormat,
        'max_threads': maxThreads,
        'debug_mode': debugMode,
        'enable_metadata_enrichment': enableMetadataEnrichment,
        'ffmpeg_path': ffmpegPath,
        'lyrics_folder_name': lyricsFolderName,
        'auto_update_check': autoUpdateCheck,
        'auto_download_update': autoDownloadUpdate,
        'github_token': githubToken,
        'enable_retroactive_lyrics': enableRetroactiveLyrics,
        'theme': theme,
        'skipped_version': skippedVersion,
        'setup_completed': setupCompleted,
        'podcast_rag_in_music': podcastRagInMusic,
        'groq_api_key': groqApiKey,
        'groq_concurrency': groqConcurrency,
        'discord_presence_enabled': discordPresenceEnabled,
        'discord_application_id': discordApplicationId,
        'volume': volume,
        'crossfade_enabled': crossfadeEnabled,
        'crossfade_seconds': crossfadeSeconds,
        'stream_cache_enabled': streamCacheEnabled,
        'stream_cache_max_mb': streamCacheMaxMb,
        'receive_beta_updates': receiveBetaUpdates,
        'podcast_subscriptions': podcastSubscriptions,
        'podcast_history': podcastHistory,
        'url_names': urlNames,
        'search_names': searchNames,
        'last_updated': lastUpdated,
        'lyrics_offsets': lyricsOffsets,
      };
}
