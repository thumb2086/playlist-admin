// ignore_for_file: public_member_api_docs

/// Plugin manager for playlist-admin.
/// 
/// Handles plugin registration, initialization, and provides
/// a clean API for accessing plugins.

library plugin_manager;

import 'package:flutter/foundation.dart';
import 'plugin_interface.dart';
import 'podcast_plugin.dart';

/// Global plugin manager instance.
class PluginManager {
  static final PluginManager _instance = PluginManager._internal();
  factory PluginManager() => _instance;
  PluginManager._internal();
  
  final PluginRegistry _registry = pluginRegistry;
  bool _initialized = false;
  
  /// Whether the manager has been initialized.
  bool get isInitialized => _initialized;
  
  /// Get the podcast plugin.
  PodcastPlugin get podcast => _registry.requirePlugin('podcast') as PodcastPlugin;
  
  /// Initialize all plugins.
  Future<void> initialize() async {
    if (_initialized) return;
    
    // Register built-in plugins
    _registerBuiltInPlugins();
    
    // Initialize all plugins
    await _registry.initializeAll();
    
    // Check for failed plugins
    final failed = _registry._plugins.entries
        .where((e) => _registry.getState(e.key) == PluginState.error)
        .toList();
    
    if (failed.isNotEmpty) {
      final errors = failed.map((e) => 
        '${e.key}: ${_registry.getError(e.key)}'
      ).join('\n');
      throw StateError('Failed to initialize plugins:\n$errors');
    }
    
    _initialized = true;
  }
  
  void _registerBuiltInPlugins() {
    // Register podcast plugin
    _registry.register(PodcastPlugin.instance);
    
    // Future plugins can be registered here
    // _registry.register(SomeOtherPlugin.instance);
  }
  
  /// Dispose all plugins.
  Future<void> dispose() async {
    await _registry.disposeAll();
    _initialized = false;
  }
  
  /// Get a plugin by ID.
  Plugin? getPlugin(String id) => _registry.getPlugin(id);
  
  /// Get plugin state.
  PluginState getState(String id) => _registry.getState(id);
  
  /// Get error for plugin.
  String? getError(String id) => _registry.getError(id);
}

/// Global plugin manager instance.
final pluginManager = PluginManager();