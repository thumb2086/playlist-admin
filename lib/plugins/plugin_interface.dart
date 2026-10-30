// ignore_for_file: public_member_api_docs

/// Base interface for all plugins in playlist-admin.
/// 
/// Plugins extend playlist-admin with additional functionality
/// (e.g., podcast processing, music source providers, etc.).
/// 
/// Each plugin must implement [initialize], [dispose], and provide
/// metadata via [PluginManifest].
library plugin_interface;

import 'dart:async';

/// Manifest describing a plugin's capabilities and metadata.
class PluginManifest {
  /// Unique identifier (e.g., "podcast", "spotify", "local-files").
  final String id;
  
  /// Human-readable name.
  final String name;
  
  /// Version in semver format.
  final String version;
  
  /// Short description of what this plugin does.
  final String description;
  
  /// Author/organization.
  final String author;
  
  /// Minimum playlist-admin version required.
  final String minAppVersion;
  
  /// Plugin-specific configuration schema (JSON Schema).
  final Map<String, dynamic>? configSchema;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.minAppVersion,
    this.configSchema,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'author': author,
    'minAppVersion': minAppVersion,
    'configSchema': configSchema,
  };
}

/// Lifecycle status of a plugin.
enum PluginState {
  /// Plugin not yet initialized.
  uninitialized,
  
  /// Plugin is initializing.
  initializing,
  
  /// Plugin is active and ready.
  active,
  
  /// Plugin encountered an error.
  error,
  
  /// Plugin is being disposed.
  disposing,
  
  /// Plugin has been disposed.
  disposed,
}

/// Base class for all plugins.
/// 
/// Implement [initialize] to set up resources, [dispose] to clean up,
/// and provide a [manifest] describing the plugin.
abstract class Plugin {
  /// Plugin metadata.
  PluginManifest get manifest;
  
  /// Current lifecycle state.
  PluginState get state;
  
  /// Error message if state is [PluginState.error].
  String? get errorMessage;
  
  /// Initialize the plugin.
  /// 
  /// Called once at app startup. Should set up resources, register
  /// services, and prepare for use.
  /// 
  /// Returns a [Future] that completes when initialization is done.
  /// Throws on failure, which will set state to [PluginState.error].
  Future<void> initialize();
  
  /// Dispose the plugin.
  /// 
  /// Called at app shutdown. Should release resources, close connections,
  /// and clean up.
  Future<void> dispose();
  
  /// Get plugin-specific configuration.
  /// 
  /// Returns the plugin's config section from the app config.
  Map<String, dynamic> getConfig();
  
  /// Update plugin configuration.
  /// 
  /// Called when user changes plugin settings in UI.
  Future<void> updateConfig(Map<String, dynamic> config);
}

/// Registry for managing plugins.
/// 
/// Handles plugin discovery, initialization, and lifecycle.
class PluginRegistry {
  final Map<String, Plugin> _plugins = {};
  final Map<String, PluginState> _states = {};
  final Map<String, String?> _errors = {};
  
  /// All registered plugins.
  Iterable<Plugin> get plugins => _plugins.values;
  
  /// Get plugin by ID.
  Plugin? getPlugin(String id) => _plugins[id];
  
  /// Get plugin state.
  PluginState getState(String id) => _states[id] ?? PluginState.uninitialized;
  
  /// Get error message for plugin.
  String? getError(String id) => _errors[id];
  
  /// Register a plugin.
  /// 
  /// Throws if a plugin with the same ID already exists.
  void register(Plugin plugin) {
    final id = plugin.manifest.id;
    if (_plugins.containsKey(id)) {
      throw StateError('Plugin with id "$id" already registered');
    }
    _plugins[id] = plugin;
    _states[id] = PluginState.uninitialized;
  }
  
  /// Initialize all registered plugins.
  /// 
  /// Plugins are initialized in registration order.
  /// Failed plugins are marked as error but don't stop others.
  Future<void> initializeAll() async {
    for (final plugin in _plugins.values) {
      final id = plugin.manifest.id;
      _states[plugin.manifest.id] = PluginState.initializing;
      try {
        await plugin.initialize();
        _states[id] = PluginState.active;
        _errors[id] = null;
      } catch (e, st) {
        _states[id] = PluginState.error;
        _errors[id] = '$e\n$st';
        // Continue initializing other plugins
      }
    }
  }
  
  /// Dispose all plugins.
  /// 
  /// Plugins are disposed in reverse registration order.
  Future<void> disposeAll() async {
    final pluginsList = _plugins.values.toList().reversed.toList();
    for (final plugin in pluginsList) {
      final id = plugin.manifest.id;
      _states[id] = PluginState.disposing;
      try {
        await plugin.dispose();
        _states[id] = PluginState.disposed;
      } catch (e) {
        _errors[id] = '$e';
        _states[id] = PluginState.error;
      }
    }
  }
  
  /// Get plugin by ID, throws if not found.
  Plugin requirePlugin(String id) {
    final plugin = _plugins[id];
    if (plugin == null) {
      throw StateError('Plugin "$id" not found');
    }
    if (_states[id] != PluginState.active) {
      throw StateError('Plugin "$id" is not active (state: ${_states[id]})');
    }
    return plugin;
  }
}

/// Global plugin registry instance.
final pluginRegistry = PluginRegistry();