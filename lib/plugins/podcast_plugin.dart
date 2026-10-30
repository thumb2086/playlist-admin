// ignore_for_file: public_member_api_docs

/// Podcast Plugin
/// 
/// Provides podcast functionality: RSS feed parsing, episode downloading,
/// subtitle fetching, transcription, and RAG integration.
/// 
/// This plugin wraps the existing podcast pipeline and services.

library podcast_plugin;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/pipeline_step.dart';
import '../models/podcast_episode.dart';
import '../models/podcast_subtitle_result.dart';
import '../models/podcast_subscription.dart';
import '../services/podcast_service.dart';
import '../services/groq_service.dart';
import '../services/groq_native_service.dart';
import '../services/upload_budget.dart';
import '../services/chinese_converter.dart';
import '../services/rag_service.dart';
import '../services/config_service.dart';
import '../pipeline/podcast_pipeline.dart';
import 'plugin_interface.dart';

/// Podcast plugin implementation.
/// 
/// Wraps the existing podcast pipeline and services as a plugin.
class PodcastPlugin extends Plugin {
  PodcastPlugin._();
  
  static final PodcastPlugin _instance = PodcastPlugin._();
  static PodcastPlugin get instance => _instance;
  
  // Internal services
  final PodcastService _podcastService = PodcastService.instance;
  final GroqService _groqService = GroqService.instance;
  final GroqNativeService _groqNativeService = GroqNativeService.instance;
  final UploadBudget _uploadBudget = UploadBudget.instance;
  final ChineseConverter _chineseConverter = ChineseConverter.instance;
  final RagService _ragService = RagService.instance;
  final ConfigService _configService = ConfigService.instance;
  
  // State
  PluginState _state = PluginState.uninitialized;
  String? _errorMessage;
  Map<String, dynamic> _config = {};
  PipelineState? _pipelineState;
  PodcastPipeline? _pipeline;
  
  @override
  PluginManifest get manifest => const PluginManifest(
    id: 'podcast',
    name: 'Podcast',
    version: '1.0.0',
    description: 'Podcast RSS parsing, episode downloading, subtitle fetching, transcription, and RAG integration',
    author: 'playlist-admin',
    minAppVersion: '3.0.0',
    configSchema: {
      'type': 'object',
      'properties': {
        'enabled': {'type': 'boolean', 'default': true},
        'groqConcurrency': {'type': 'integer', 'minimum': 1, 'maximum': 16, 'default': 3},
        'chunkConcurrency': {'type': 'integer', 'minimum': 1, 'maximum': 8, 'default': 4},
        'enableRetroactiveLyrics': {'type': 'boolean', 'default': false},
        'podcastSubscriptions': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
              'rssUrl': {'type': 'string', 'format': 'uri'},
            },
            'required': ['name', 'rssUrl'],
          },
        },
      },
    },
  );
  
  @override
  PluginState get state => _state;
  
  @override
  String? get errorMessage => _errorMessage;
  
  // Pipeline access
  PodcastPipeline? get pipeline => _pipeline;
  PipelineState? get pipelineState => _pipelineState;
  
  // Podcast service access
  PodcastService get podcastService => _podcastService;
  String get podcastDir => _configService.config.podcastsPath;
  
  @override
  Future<void> initialize() async {
    _state = PluginState.initializing;
    _errorMessage = null;
    
    try {
      // Load config
      final cfg = _configService.config;
      _config = {
        'enabled': true,
        'groqConcurrency': cfg.groqConcurrency.clamp(1, 16),
        'chunkConcurrency': int.tryParse(Platform.environment['PA_CHUNK_CONCURRENCY'] ?? '') ?? 4,
        'enableRetroactiveLyrics': cfg.enableRetroactiveLyrics,
        'podcastSubscriptions': cfg.podcastSubscriptions,
      };
      
      // Initialize Groq
      await _groqService.loadFromEnv();
      if (_groqService.apiKey == null || _groqService.apiKey!.isEmpty) {
        final cfgKey = _configService.config.groqApiKey;
        if (cfgKey.isNotEmpty) _groqService.setApiKey(cfgKey);
      }
      final hasGroq = _groqService.apiKey != null && _groqService.apiKey!.isNotEmpty;
      
      if (hasGroq) {
        _groqNativeService.preloadProxy();
      }
      
      // Initialize pipeline
      _pipelineState = PipelineState();
      _pipeline = PodcastPipeline(
        onLog: _log,
        onProgress: _onProgress,
        state: _pipelineState,
      );
      
      _state = PluginState.active;
    } catch (e, st) {
      _state = PluginState.error;
      _errorMessage = '$e\n$st';
      rethrow;
    }
  }
  
  @override
  Future<void> dispose() async {
    _state = PluginState.disposing;
    
    try {
      _pipelineState?.cancel();
      await _pipelineState?.waitIfPaused(); // Wait for any running operations
      _pipeline = null;
      _pipelineState = null;
      _state = PluginState.disposed;
    } catch (e) {
      _state = PluginState.error;
      _errorMessage = '$e';
      rethrow;
    }
  }
  
  @override
  Map<String, dynamic> getConfig() => Map.unmodifiable(_config);
  
  @override
  Future<void> updateConfig(Map<String, dynamic> config) async {
    _config.addAll(config);
    
    // Update ConfigService if needed
    final cfg = _configService.config;
    if (config.containsKey('groqConcurrency')) {
      cfg.groqConcurrency = (config['groqConcurrency'] as int).clamp(1, 16);
    }
    if (config.containsKey('enableRetroactiveLyrics')) {
      cfg.enableRetroactiveLyrics = config['enableRetroactiveLyrics'] as bool;
    }
    if (config.containsKey('podcastSubscriptions')) {
      cfg.podcastSubscriptions = Map<String, String>.from(config['podcastSubscriptions']);
    }
    _configService.notifyListeners();
    
    // Update internal config
    _config.addAll(config);
    
    // Update pipeline if running
    if (_pipeline != null) {
      // Note: Pipeline reads config on each run, so no need to update here
    }
  }
  
  /// Run the podcast pipeline.
  /// 
  /// Returns a [Future] that completes when the pipeline finishes.
  /// The [onProgress] callback receives (current, total, stepIndex).
  Future<void> runPipeline({
    required void Function(String) onLog,
    required void Function(int current, int total, int stepIndex) onProgress,
  }) async {
    if (_state != PluginState.active) {
      throw StateError('Plugin not active');
    }
    if (_pipeline == null || _pipelineState == null) {
      throw StateError('Pipeline not initialized');
    }
    
    // Update pipeline callbacks
    // Note: PodcastPipeline doesn't support updating callbacks after construction
    // We create a new pipeline with the new callbacks
    _pipelineState = PipelineState();
    _pipeline = PodcastPipeline(
      onLog: onLog,
      onProgress: onProgress,
      state: _pipelineState!,
    );
    
    await _pipeline!.run();
  }
  
  /// Cancel the running pipeline.
  void cancelPipeline() {
    _pipelineState?.cancel();
  }
  
  /// Pause the running pipeline.
  void pausePipeline() {
    _pipelineState?.pause();
  }
  
  /// Resume the paused pipeline.
  void resumePipeline() {
    _pipelineState?.resume();
  }
  
  /// Add a podcast subscription.
  Future<void> addSubscription(String name, String rssUrl) async {
    final cfg = ConfigService.instance.config;
    cfg.podcastSubscriptions[name] = rssUrl;
    _configService.notifyListeners();
    _config['podcastSubscriptions'] = Map<String, String>.from(cfg.podcastSubscriptions);
  }
  
  /// Remove a podcast subscription.
  Future<void> removeSubscription(String name) async {
    final cfg = ConfigService.instance.config;
    cfg.podcastSubscriptions.remove(name);
    _configService.notifyListeners();
    _config['podcastSubscriptions'] = Map<String, String>.from(cfg.podcastSubscriptions);
  }
  
  /// Get all podcast subscriptions.
  Map<String, String> getSubscriptions() {
    return Map.unmodifiable(ConfigService.instance.config.podcastSubscriptions);
  }
  
  /// Refresh RAG index for podcast transcripts.
  Future<void> refreshRagIndex({required void Function(String) onLog}) async {
    try {
      await _ragService.build((line) => _log(line));
    } catch (e) {
      _log('RAG index update failed: $e');
      rethrow;
    }
  }
  
  /// Get podcast directory for a podcast name.
  String getPodcastDir(String podcastName) {
    return _podcastService.podcastDir(podcastName);
  }
  
  /// Check if podcast episode is downloaded.
  bool isEpisodeDownloaded(String title, String audioUrl, {String? podcastName}) {
    return _podcastService.isEpisodeDownloaded(title, audioUrl, podcastName: podcastName);
  }
  
  /// Get audio URL for episode.
  Future<String?> getAudioUrl(String rssUrl, int index) {
    return _podcastService.getAudioUrl(rssUrl, index);
  }
  
  /// Download a single episode.
  Future<bool> downloadEpisode(
    String rssUrl,
    int index, {
    String? podcastName,
    String? knownTitle,
    String? knownAudioUrl,
    bool Function()? isCancelled,
  }) {
    return _podcastService.downloadEpisode(
      rssUrl,
      index,
      (_) {},
      podcastName: podcastName,
      knownTitle: knownTitle,
      knownAudioUrl: knownAudioUrl,
      isCancelled: isCancelled,
    );
  }
  
  /// Search YouTube subtitles for an episode.
  Future<PodcastSubtitleResult> fetchYtSubtitles(
    String episodeTitle,
    String podcastName, {
    required void Function(String) onLog,
    required bool Function() isCancelled,
  }) {
    return _podcastService.downloadSubtitles(
      episodeTitle,
      podcastName,
      onLog: onLog,
      isCancelled: isCancelled,
    );
  }
  
  /// Fetch YouTube subtitles by URL.
  Future<PodcastSubtitleResult> fetchYtSubtitlesByUrl(
    String videoUrl,
    String podcastName,
    String safeName, {
    required void Function(String) onLog,
    required bool Function() isCancelled,
  }) {
    return _podcastService.fetchYtSubtitlesByUrl(
      videoUrl,
      podcastName,
      safeName,
      isCancelled: isCancelled,
      onLog: onLog,
    );
  }
  
  /// List channel videos (for YouTube channel mode).
  Future<List<({String id, String title})>?> listChannelVideos(
    String url, {
    required bool Function() isCancelled,
  }) {
    return _podcastService.listChannelVideos(url, isCancelled: isCancelled);
  }
  
  /// Get cache for a podcast.
  Future<Map<String, Map<String, dynamic>>> getCache(String podcastName) async {
    final cache = await _loadCacheAsync(podcastName);
    return cache;
  }
  
  /// Save cache for a podcast.
  Future<void> saveCache(String podcastName, Map<String, Map<String, dynamic>> cache) async {
    await _saveCacheAsync(podcastName, cache);
  }
  
  // Internal methods (exposed for advanced use)
  
  Future<Map<String, Map<String, dynamic>>> _loadCacheAsync(String podcastName) async {
    try {
      final cachePath = '${ConfigService.instance.config.cachePath}\\podcast\\${podcastName}_cache.json';
      final f = File(cachePath);
      if (!await f.exists()) return {};
      final json = await f.readAsString();
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }
  
  Future<void> _saveCacheAsync(String podcastName, Map<String, Map<String, dynamic>> cache) async {
    try {
      final cachePath = '${ConfigService.instance.config.cachePath}\\podcast\\${podcastName}_cache.json';
      await File(cachePath).writeAsString(jsonEncode(cache), flush: true);
    } catch (_) {}
  }
  
  // Logging helper
  void _log(String message) {
    // In a real implementation, this would go to the app's logging system
    print('[PodcastPlugin] $message');
  }
  
  void _onProgress(int current, int total, int stepIndex) {
    // Progress callback - override in consumer
  }
}

// Extension to make PodcastPlugin easily accessible
extension PodcastPluginExtension on PluginRegistry {
  PodcastPlugin get podcastPlugin => requirePlugin('podcast') as PodcastPlugin;
}