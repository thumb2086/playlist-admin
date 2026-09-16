import 'dart:convert';
import 'dart:io';
import 'metadata_reader.dart';
import 'app_data_dir.dart';
import 'chinese_converter.dart';

class LibraryIndex {
  Map<List<String>, List<String>> _filenameIndex = {};
  Map<List<String>, List<String>> _metadataIndex = {};
  Map<String, FileInfo> _fileInfoMap = {};
  // List 當 Map key 用的是 identity hash：每次 _normalize 都是新 List，
  // 內容相同的 key 會失散成多條。全部經 _intern 拿同一實例，grouping 才正確。
  final Map<String, List<String>> _keyPool = {};
  int _mp3Count = 0;
  int _podcastMp3Count = 0;
  int _podcastOtherCount = 0;
  bool _built = false;

  // key 用 jsonEncode：['New','York'] vs ['Newyork'] 不可撞 key。
  List<String> _intern(List<String> tokens) =>
      _keyPool.putIfAbsent(jsonEncode(tokens), () => tokens);

  static String _cacheDir() => AppDataDir.dir;
  static String _fingerprintFile(String libraryPath) =>
      '${_cacheDir()}\\index_fingerprint.json';

  // Static in-memory cache: reuse across pipeline steps within the same process
  static LibraryIndex? _cache;
  static String? _cacheKey;
  // Disk-backed fingerprint: persists across app restarts
  static Set<String>? _cachedFingerprint;

  int get mp3Count => _mp3Count;
  int get podcastMp3Count => _podcastMp3Count;
  int get podcastOtherCount => _podcastOtherCount;
  bool get isBuilt => _built;

  static void invalidateCache() { _cache = null; _cacheKey = null; _cachedFingerprint = null; }

  static Set<String> _buildFingerprint(List<String> files) {
    final fp = <String>{};
    for (final f in files) {
      final file = File(f);
      try {
        fp.add('$f|${file.lastModifiedSync().millisecondsSinceEpoch}');
      } catch (_) {
        fp.add('$f|0');
      }
    }
    return fp;
  }

  static String _metaIndexFile(String libraryPath) =>
      '${_cacheDir()}\\index_metadata.json';

  static Set<String>? _loadDiskFingerprint(String libraryPath) {
    try {
      final f = File(_fingerprintFile(libraryPath));
      if (!f.existsSync()) return null;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final list = data['fingerprint'] as List<dynamic>?;
      if (list == null) return null;
      return list.map((e) => e as String).toSet();
    } catch (_) {
      return null;
    }
  }

  static void _saveDiskFingerprint(String libraryPath, Set<String> fp) {
    try {
      final file = File(_fingerprintFile(libraryPath));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({'fingerprint': fp.toList()}), flush: true);
    } catch (_) {}
  }

  static Map<String, List<String>>? _loadMetaIndex(String libraryPath) {
    try {
      final f = File(_metaIndexFile(libraryPath));
      if (!f.existsSync()) return null;
      return (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()));
    } catch (_) {
      return null;
    }
  }

  static void _saveMetaIndex(String libraryPath, Map<String, List<String>> index) {
    try {
      final file = File(_metaIndexFile(libraryPath));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(index), flush: true);
    } catch (_) {}
  }

  Future<void> build(String libraryPath, void Function(String) log, {String? basePath}) async {
    // Check static in-memory cache first
    if (_cache != null && _cacheKey == _resolvePath(libraryPath)) {
      _copyFrom(_cache!);
      log('MP3: $_mp3Count (記憶體快取)${_podcastSummary()}');
      return;
    }

    log('掃描音檔…');
    final allFiles = await _walkDir(libraryPath);
    // Also scan basePath if it's different
    if (basePath != null && basePath != libraryPath) {
      final baseFiles = await _walkDir(basePath);
      for (final f in baseFiles) {
        if (!allFiles.contains(f)) allFiles.add(f);
      }
    }
    final mp3s = <String>[];
    for (final f in allFiles) {
      final low = f.toLowerCase();
      if (low.endsWith('.mp3')) { mp3s.add(f); }
    }

    _mp3Count = mp3s.length;
    _fileInfoMap = {};
    for (final f in allFiles) {
      final file = File(f);
      if (await file.exists()) {
        _fileInfoMap[f] = FileInfo(
          size: await file.length(),
          mtime: await file.lastModified(),
        );
      }
    }
    _filenameIndex = _buildFilenameIndex(mp3s);

    // Determine which mp3s need metadata re-index
    _cachedFingerprint ??= _loadDiskFingerprint(libraryPath);
    final currentFp = _buildFingerprint(allFiles);
    final changedStems = <String>{};
    if (_cachedFingerprint != null) {
      // Find files that changed or were added
      for (final entry in currentFp) {
        if (!_cachedFingerprint!.contains(entry)) {
          // Extract file path from the fingerprint entry "path|mtime"
          final pipeIdx = entry.indexOf('|');
          if (pipeIdx > 0) {
            final path = entry.substring(0, pipeIdx);
            changedStems.add(File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
          }
        }
      }
    }

    // Also detect deleted files (in cache but not on disk)
    if (_cachedFingerprint != null) {
      for (final entry in _cachedFingerprint!) {
        if (!currentFp.contains(entry)) {
          final pipeIdx = entry.indexOf('|');
          if (pipeIdx > 0) {
            final path = entry.substring(0, pipeIdx);
            changedStems.add(File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase());
          }
        }
      }
    }

    if (changedStems.isEmpty && _cachedFingerprint != null) {
      log('MP3: $_mp3Count (無變動，載入快取索引)${_podcastSummary()}');
      final cached = _loadMetaIndex(libraryPath);
      if (cached != null) {
        _metadataIndex = <List<String>, List<String>>{};
        for (final e in cached.entries) {
          final tokens = (jsonDecode(e.key) as List<dynamic>).cast<String>();
          _metadataIndex[_intern(tokens)] = e.value;
        }
        log('  metadata 索引載入完成: ${_metadataIndex.length} 首');
        _built = true;
        _saveToMemoryCache(libraryPath);
        return;
      }
    }

    // Build metadata index (only for new/changed mp3s, plus unchanged from cache)
    log('MP3: $_mp3Count${_podcastSummary()}');
    log('建立檔名索引…');

    if (changedStems.isNotEmpty) {
      log('metadata 新增/變更: ${changedStems.length} 個檔案');
    }

    _metadataIndex = <List<String>, List<String>>{};

    // Load cached metadata for unchanged files first
    final cached = _loadMetaIndex(libraryPath);
    final cachedPaths = <String>{};
    if (cached != null) {
      for (final e in cached.entries) {
        final tokens = (jsonDecode(e.key) as List<dynamic>).cast<String>();
        final kept = <String>[];
        for (final path in e.value) {
          final stem = File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
          if (!changedStems.contains(stem)) {
            kept.add(path);
            cachedPaths.add(path);
          }
        }
        if (kept.isNotEmpty) {
          _metadataIndex.putIfAbsent(_intern(tokens), () => []).addAll(kept);
        }
      }
    }

    // Only ffprobe files not in cache or that changed
    final toIndex = mp3s.where((f) {
      if (changedStems.isEmpty) return true; // full rebuild
      final stem = File(f).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
      return changedStems.contains(stem);
    }).toList();

    log('讀取 metadata 索引 (${toIndex.length}/${mp3s.length} 個檔案)…');
    final beforeCount = _metadataIndex.length;
    final newEntries = await _buildMetadataIndex(toIndex, log);
    // 用 merge 不用 addAll：key 是 identity hash，addAll 會把同內容建成重複條目。
    for (final e in newEntries.entries) {
      _metadataIndex.putIfAbsent(_intern(e.key), () => []).addAll(e.value);
    }
    final addedCount = _metadataIndex.length - beforeCount;

    // Remove cache entries for files that no longer exist on disk
    final onDisk = mp3s.toSet();
    final toRemove = <List<String>>[];
    for (final e in _metadataIndex.entries) {
      e.value.removeWhere((p) => !onDisk.contains(p));
      if (e.value.isEmpty) toRemove.add(e.key);
    }
    for (final k in toRemove) {
      _metadataIndex.remove(k);
    }

    if (changedStems.isNotEmpty) {
      log('索引完成 (新增 $addedCount，快取 ${_metadataIndex.length - addedCount})');
      if (toRemove.isNotEmpty) log('  清除 ${toRemove.length} 條已刪除檔案的快取');
    } else {
      log('索引完成');
    }

    // Save metadata index to disk
    final serializable = <String, List<String>>{};
    for (final e in _metadataIndex.entries) {
      serializable[jsonEncode(e.key)] = e.value;
    }
    _saveMetaIndex(libraryPath, serializable);

    _saveToMemoryCache(libraryPath);
    _saveDiskFingerprint(libraryPath, currentFp);
  }

  void _saveToMemoryCache(String libraryPath) {
    _cache = LibraryIndex();
    _cache!._copyFrom(this);
    _cacheKey = _resolvePath(libraryPath);
    _cachedFingerprint = null; // Force disk reload on next build
  }

  String _resolvePath(String p) {
    try { return Directory(p).resolveSymbolicLinksSync(); }
    catch (_) { return p; }
  }

  void _copyFrom(LibraryIndex other) {
    // 深拷貝 value list：淺拷貝會讓呼叫端改動污染靜態快取。
    // key 是 canonical 實例（永不修改），可共用；pool 一併帶過。
    _filenameIndex = {for (final e in other._filenameIndex.entries) e.key: List<String>.from(e.value)};
    _metadataIndex = {for (final e in other._metadataIndex.entries) e.key: List<String>.from(e.value)};
    _fileInfoMap = Map<String, FileInfo>.from(other._fileInfoMap);
    _keyPool.addAll(other._keyPool);
    _mp3Count = other._mp3Count;
    _podcastMp3Count = other._podcastMp3Count;
    _podcastOtherCount = other._podcastOtherCount;
    _built = true;
  }

  String _podcastSummary() {
    final parts = <String>[
      if (_podcastMp3Count > 0) 'Podcast MP3 $_podcastMp3Count',
      if (_podcastOtherCount > 0) 'Podcast 其他 $_podcastOtherCount',
    ];
    return parts.isEmpty ? '' : ' (${parts.join(', ')})';
  }

  Future<List<String>> _walkDir(String path) async {
    final result = <String>[];
    final dir = Directory(path);
    if (!await dir.exists()) return result;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final low = entity.path.toLowerCase();
          if (low.endsWith('.mp3') || low.endsWith('.m4a') || low.endsWith('.flac')) {
            // Podcast audio is NOT part of the music library: excluding it
            // prevents M4As from being fuzzy-matched against podcast files.
            // Track it separately so podcast stats stay visible.
            if (low.contains('podcasts') || low.contains('podcast_rag')) {
              if (low.endsWith('.mp3')) {
                _podcastMp3Count++;
              } else {
                _podcastOtherCount++;
              }
              continue;
            }
            result.add(entity.path);
          }
        }
      }
    } catch (_) {}
    return result;
  }

  Map<List<String>, List<String>> _buildFilenameIndex(List<String> files) {
    final index = <List<String>, List<String>>{};
    for (final f in files) {
      final name = File(f).uri.pathSegments.last;
      final stem = name.replaceAll(RegExp(r'\.\w+$'), '');
      final tokens = _normalize(stem);
      if (tokens.isNotEmpty) {
        index.putIfAbsent(_intern(tokens), () => []).add(f);
      }
    }
    return index;
  }

  Future<Map<List<String>, List<String>>> _buildMetadataIndex(
      List<String> files, void Function(String) log) async {
    final index = <List<String>, List<String>>{};
    int count = 0;
    const batchSize = 20;
    for (int i = 0; i < files.length; i += batchSize) {
      final batch = files.skip(i).take(batchSize).toList();
      final metas = await Future.wait(batch.map((f) => MetadataReader.read(f)));
      for (int j = 0; j < batch.length; j++) {
        final meta = metas[j];
        if (meta.title != null && meta.title!.isNotEmpty) {
          final tokens = _normalize(meta.title!);
          if (tokens.isNotEmpty) {
            index.putIfAbsent(_intern(tokens), () => []).add(batch[j]);
          }
        }
      }
      count += batch.length;
      if (count % 500 == 0 || count >= files.length) log('  metadata 索引: $count/${files.length}');
    }
    return index;
  }

  static const Map<String, String> artistAliases = {
    'claire kuo': '郭靜', 'jolin': '蔡依林', 'jolin tsai': '蔡依林',
    'crowd lu': '盧廣仲', 'pets tseng': '曾沛慈', 'evangeline wong': '王艷薇',
    'sabrina': '胡恂舞', 'sabrina hu': '胡恂舞', 'eric chou': '周興哲',
    'shi shi': '孫盛希', 'boon hui lu': '文慧如', 'vicky chen': '陳忻玥',
    'feng ze': '邱鋒澤', 'ivy': '艾薇', 'genblue': '幻藍小熊',
    'lbi': '利比', 'erin': '連穎', 'eleanor': '李芷婷',
    'ann bai': '白安', 'diana wang': '王詩安', 'ethan': '陳威全',
    'chih siou': '持修', 'show luo': '羅志祥',
  };

  static const _noisePatterns = [
    r'全新單曲', r'單曲', r'官方完整版', r'官方', r'完整版',
    r'高清', r'動態歌詞版', r'歌詞版', r'官方版', r'全新',
    r'music video', r'official video', r'official music video',
    r'video', r'loop', r'lyrics',
  ];

  List<String> _normalize(String text) {
    var t = text.toLowerCase().trim();

    // Remove spaces between CJK chars
    t = t.replaceAllMapped(
      RegExp(r'(?<=[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff])\s+(?=[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff])'),
      (_) => '',
    );

    // Convert to Simplified Chinese
    if (ChineseConverter.instance.isLoaded) {
      t = ChineseConverter.instance.toSimplified(t);
    }

    // Apply artist aliases
    for (final e in artistAliases.entries) {
      t = t.replaceAllMapped(
        RegExp('\\b${RegExp.escape(e.key)}\\b', caseSensitive: false),
        (_) => ChineseConverter.instance.isLoaded
            ? ChineseConverter.instance.toSimplified(e.value)
            : e.value.toLowerCase(),
      );
    }

    // Remove "E " prefix artifact (common in Spotify scrapes)
    t = t.replaceAll(RegExp(r'(?:^|(?<=[^a-z0-9]))e(?=[a-z\u4e00-\u9fff\u3040-\u30ff])'), '');

    // Remove noise phrases
    for (final p in _noisePatterns) {
      t = t.replaceAll(RegExp(p, caseSensitive: false), ' ');
    }

    // Standardize separators
    t = t.replaceAll(RegExp(r'\s*(feat|ft|vs)\.?\s*|\s*[&,x]\s*'), ' ');

    // Remove bracket content with keywords
    t = t.replaceAll(
      RegExp(r"[\(\[【（［][^\)\]】）］]*(?:live|remix|mv|official|lyrics?\s*video|music\s*video)[^\)\]】）］]*[\)\]】）］]",
          caseSensitive: false),
      ' ',
    );

    // Add space between Latin and CJK
    t = t.replaceAllMapped(RegExp(r'([a-z])([\u4e00-\u9fff])'), (m) => '${m[1]} ${m[2]}');
    t = t.replaceAllMapped(RegExp(r'([\u4e00-\u9fff])([a-z])'), (m) => '${m[1]} ${m[2]}');

    final parts = t.split(RegExp(r'[\s\-_()\[\]【】,./:：，。、！？（）「」""''（）【】《》〈〉\u3000]'));
    return parts.where((p) => p.isNotEmpty).toList();
  }

  Future<String?> findMp3ForM4a(String m4aPath, {bool useMtime = true, TrackMetadata? cachedMeta}) async {
    final basename = File(m4aPath).uri.pathSegments.last;
    final stem = basename.replaceAll(RegExp(r'\.\w+$'), '');
    final tokens = _normalize(stem);

    final m4aInfo = _fileInfoMap[m4aPath];

    // 0. Own-stem zero-byte guard: if an MP3 with the exact same filename
    // exists but is corrupt (0 bytes), force re-conversion instead of letting
    // fuzzy/metadata matching skip this M4A (it could match a different song
    // with a similar title, e.g. "Somebody Else" -> "Somebody Else - Diana Wang").
    for (final entry in _filenameIndex.entries) {
      if (_listEq(entry.key, tokens)) {
        for (final own in entry.value) {
          if (own.toLowerCase().endsWith('.mp3')) {
            final ownInfo = _fileInfoMap[own];
            if (ownInfo == null || ownInfo.size == 0) {
              return null;
            }
          }
        }
      }
    }

    // 1. Try exact filename match
    final exact = _findInIndex(tokens, _filenameIndex);
    if (exact != null) {
      final mp3Info = _fileInfoMap[exact];
      if (_isValidMp3(exact, mp3Info) &&
          (!useMtime || (m4aInfo != null && mp3Info != null && mp3Info.mtime.compareTo(m4aInfo.mtime) >= 0))) {
        return exact;
      }
    }

    // 2. Try fuzzy filename match
    for (final entry in _filenameIndex.entries) {
      if (_isSubset(tokens, entry.key) || _isSubset(entry.key, tokens)) {
        for (final f in entry.value) {
          if (f.toLowerCase().endsWith('.mp3')) {
            final mp3Info = _fileInfoMap[f];
            if (_isValidMp3(f, mp3Info) &&
                (!useMtime || (mp3Info != null && m4aInfo != null && mp3Info.mtime.compareTo(m4aInfo.mtime) >= 0))) {
              return f;
            }
          }
        }
      }
    }

    // 3. Try matching by M4A metadata (title/artist) against metadata index
    if (cachedMeta != null) {
      try {
        if (cachedMeta.title != null && cachedMeta.title!.isNotEmpty) {
          final titleTokens = _normalize(cachedMeta.title!);
          final metaMatch = _metadataIndex.keys.firstWhere(
            (k) => _isSubset(titleTokens, k) || _isSubset(k, titleTokens),
            orElse: () => [],
          );
          if (metaMatch.isNotEmpty) {
            for (final f in _metadataIndex[metaMatch]!) {
              if (f.toLowerCase().endsWith('.mp3') && _fileInfoMap.containsKey(f) && _isValidMp3(f, _fileInfoMap[f])) return f;
            }
          }
          if (cachedMeta.artist != null && cachedMeta.artist!.isNotEmpty) {
            final combined = _normalize('${cachedMeta.title} - ${cachedMeta.artist}');
            final combinedMatch = _filenameIndex.keys.firstWhere(
              (k) => _isSubset(combined, k) || _isSubset(k, combined),
              orElse: () => [],
            );
            if (combinedMatch.isNotEmpty) {
              for (final f in _filenameIndex[combinedMatch]!) {
                if (f.toLowerCase().endsWith('.mp3') && _fileInfoMap.containsKey(f) && _isValidMp3(f, _fileInfoMap[f])) return f;
              }
            }
          }
        }
      } catch (_) {}
    }

    return null;
  }

  /// A 0-byte MP3 is a failed/corrupt conversion output — never treat it as
  /// the converted product, so the M4A source gets re-converted.
  bool _isValidMp3(String path, FileInfo? info) =>
      info != null && info.size > 0;

  String? _findInIndex(List<String> tokens, Map<List<String>, List<String>> index) {
    for (final entry in index.entries) {
      if (_listEq(entry.key, tokens)) {
        for (final f in entry.value) {
          if (f.toLowerCase().endsWith('.mp3') && _isValidMp3(f, _fileInfoMap[f])) return f;
        }
      }
    }
    return null;
  }

  bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _isSubset(List<String> small, List<String> big) {
    if (small.length > big.length) return false;
    return small.every((s) => big.any((b) => b.contains(s)));
  }

  bool isSongInPlaylists(String songName, List<String> playlistSongs) {
    final tokens = _normalize(songName);
    if (tokens.isEmpty) return false;
    for (final ps in playlistSongs) {
      final psTokens = _normalize(ps);
      if (_listEq(tokens, psTokens)) return true;
      if (_isSubset(tokens, psTokens) || _isSubset(psTokens, tokens)) return true;
    }
    return false;
  }
}

class FileInfo {
  final int size;
  final DateTime mtime;
  FileInfo({required this.size, required this.mtime});
}
