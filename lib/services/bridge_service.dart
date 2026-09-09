import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;

class BridgeService {
  static final BridgeService _instance = BridgeService._();
  static BridgeService get instance => _instance;
  BridgeService._();

  String? _extractedPath;
  Future<void>? _pendingExtract;

  Future<String> get bridgePath async {
    if (_extractedPath != null && await File(_extractedPath!).exists()) {
      return _extractedPath!;
    }
    if (_pendingExtract != null) {
      try {
        await _pendingExtract;
        return _extractedPath!;
      } catch (e) {
        _pendingExtract = null; // 失敗不黏住，下次重試
        rethrow;
      }
    }
    final f = _resolve();
    _pendingExtract = f;
    try {
      return await f;
    } catch (e) {
      if (identical(_pendingExtract, f)) _pendingExtract = null;
      rethrow;
    }
  }

  Future<String> _resolve() async {
    try {
      return await _extractFromAssets();
    } catch (_) {}

    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final assetDir = '$exeDir\\data\\flutter_assets\\assets\\tools';
      if (await Directory(assetDir).exists()) {
        return await _copyFromDir(assetDir);
      }
    } catch (_) {}

    // Always check source tree for fresh bridge (dev mode or portable install)
    try {
      Directory? d = Directory(Platform.resolvedExecutable).parent;
      while (d != null) {
        final candidate = '${d.path}\\tools\\flutter_download_bridge.py';
        if (File(candidate).existsSync()) {
          // Auto-update temp cache if source is newer
          final tmpDir = Directory.systemTemp.path;
          final cached = File('$tmpDir\\playlist_admin_tools\\flutter_download_bridge.py');
          if (!cached.existsSync() ||
              File(candidate).lastModifiedSync().isAfter(cached.lastModifiedSync())) {
            await File(candidate).copy(cached.path);
          }
          // RAG scripts travel with the bridge — always keep them in sync
          // (unconditional; timestamp shortcuts hurt parity here).
          try {
            final ragDst = Directory('$tmpDir\\playlist_admin_tools\\rag');
            await ragDst.create(recursive: true);
            final rags = <File>[];
            final ragSrc = Directory('${d.path}\\rag');
            if (await ragSrc.exists()) {
              await for (final f in ragSrc.list()) {
                if (f is File && f.path.toLowerCase().endsWith('.py')) {
                  rags.add(f);
                }
              }
            }
            // also the asset copy may be newer/only source
            final assetRag = Directory('${d.path}\\assets\\tools\\rag');
            if (await assetRag.exists()) {
              await for (final f in assetRag.list()) {
                if (f is File && f.path.toLowerCase().endsWith('.py')) {
                  rags.add(f);
                }
              }
            }
            for (final f in rags) {
              final dest = File('${ragDst.path}\\${f.uri.pathSegments.last}');
              if (!dest.existsSync() ||
                  f.lastModifiedSync().isAfter(dest.lastModifiedSync())) {
                await f.copy(dest.path);
              }
            }
            // deepFilter daemon 也要跟隨 bridge（音軌抽取需要它）
            for (final cand in [
              '${d.path}\\tools\\deepfilter_daemon.py',
              '${d.path}\\assets\\tools\\deepfilter_daemon.py',
            ]) {
              final src = File(cand);
              if (src.existsSync()) {
                final dest = File('$tmpDir\\playlist_admin_tools\\deepfilter_daemon.py');
                if (!dest.existsSync() ||
                    src.lastModifiedSync().isAfter(dest.lastModifiedSync())) {
                  await src.copy(dest.path);
                }
                break;
              }
            }
          } catch (_) {}
          return _extractedPath = cached.path;
        }
        final parent = d.parent;
        d = parent.path == d.path ? null : parent;
      }
    } catch (_) {}

    final cwd = Directory.current.path;
    final cwdCandidate = '$cwd\\tools\\flutter_download_bridge.py';
    if (File(cwdCandidate).existsSync()) {
      return _extractedPath = cwdCandidate;
    }

    try {
      Directory? d = Directory(Platform.resolvedExecutable).parent;
      while (d != null) {
        if (File('${d.path}\\pubspec.yaml').existsSync()) {
          final candidate = '${d.path}\\tools\\flutter_download_bridge.py';
          if (File(candidate).existsSync()) {
            return _extractedPath = candidate;
          }
        }
        final parent = d.parent;
        d = parent.path == d.path ? null : parent;
      }
    } catch (_) {}

    throw Exception('找不到 bridge script');
  }

  Future<String> _extractFromAssets() async {
    await rootBundle.loadString('AssetManifest.json');
    final tmpDir = Directory.systemTemp.path;
    final targetDir = '$tmpDir\\playlist_admin_tools';
    final bridgeScript = '$targetDir\\flutter_download_bridge.py';

    await Directory(targetDir).create(recursive: true);
    final manifest = await rootBundle.loadString('AssetManifest.json');
    final assets = (jsonDecode(manifest) as Map<String, dynamic>).keys
        .where((k) => k.startsWith('assets/tools/'));
    for (final asset in assets) {
      final relative = asset.replaceFirst('assets/tools/', '');
      if (relative.isEmpty) continue;
      final data = await rootBundle.load(asset);
      final file = File('$targetDir\\$relative');
      await file.parent.create(recursive: true);
      // Always overwrite: the temp cache may hold a stale bridge from an
      // older app version, which silently kept old (buggy) behavior.
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return _extractedPath = bridgeScript;
  }

  Future<String> _copyFromDir(String sourceDir) async {
    final tmpDir = Directory.systemTemp.path;
    final targetDir = '$tmpDir\\playlist_admin_tools';
    final bridgeScript = '$targetDir\\flutter_download_bridge.py';

    final rootLen = sourceDir.length;
    Future<void> copyTree(Directory src) async {
      await for (final f in src.list()) {
        final rel = f.path.substring(rootLen).replaceAll('/', '\\').replaceAll('\\\\', '\\');
        final dest = File('$targetDir$rel');
        if (f is File) {
          // Always overwrite, see _extractFromAssets.
          await dest.parent.create(recursive: true);
          await f.copy(dest.path);
        } else if (f is Directory) {
          await Directory('$targetDir$rel').create(recursive: true);
          await copyTree(f);
        }
      }
    }

    await Directory(targetDir).create(recursive: true);
    await copyTree(Directory(sourceDir));
    return _extractedPath = bridgeScript;
  }
}
