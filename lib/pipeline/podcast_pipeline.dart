import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/podcast_episode.dart';
import '../models/pipeline_step.dart';
import '../services/config_service.dart';
import '../services/podcast_service.dart';
import '../services/groq_service.dart';
import '../services/groq_native_service.dart';
import '../services/chinese_converter.dart';
import '../services/rag_service.dart';
import '../version.dart';

class PodcastPipeline {
  final void Function(String) onLog;
  final void Function(int current, int total, int stepIndex) onProgress;
  final PipelineState state;

  PodcastPipeline({
    required this.onLog,
    required this.onProgress,
    PipelineState? state,
  }) : state = state ?? PipelineState();

  String get _cachePath =>
      '${ConfigService.instance.config.cachePath}\\podcast\\podcast_processed_cache.json';

  Future<Map<String, Map<String, dynamic>>> _loadCacheAsync() async {
    try {
      final f = File(_cachePath);
      if (!await f.exists()) return {};
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return json.map((k, v) => MapEntry(k, (v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveCacheAsync(Map<String, Map<String, dynamic>> cache) async {
    try {
      await File(_cachePath).writeAsString(jsonEncode(cache), flush: true);
    } catch (_) {}
  }

  Future<void> run() async {
    final config = ConfigService.instance.config;
    final subs = config.podcastSubscriptions;
    if (subs.isEmpty) {
      onLog('沒有訂閱任何 Podcast');
      return;
    }

    final _stamp = DateTime.now().toString().substring(0, 19);
    final _ver = appVersion.startsWith('v') ? appVersion : 'v$appVersion';
    onLog('$_stamp  playlist-admin $_ver');

    await GroqService.instance.loadFromEnv();
    // Also load from config if env didn't provide
    if (GroqService.instance.apiKey == null || GroqService.instance.apiKey!.isEmpty) {
      final cfgKey = ConfigService.instance.config.groqApiKey;
      if (cfgKey.isNotEmpty) GroqService.instance.setApiKey(cfgKey);
    }
    final hasGroq = GroqService.instance.apiKey != null &&
        GroqService.instance.apiKey!.isNotEmpty;

    // Async preload proxy (non-blocking)
    if (hasGroq) {
      GroqNativeService.instance.preloadProxy();
    }

    onLog('Podcast 訂閱數: ${subs.length}');
    int stepIndex = 0;
    final subEntries = subs.entries.toList();

    for (int si = 0; si < subEntries.length; si++) {
      if (state.isCancelled) break;
      await state.waitIfPaused();

      final sub = subEntries[si];
      final ts = DateTime.now().toString().substring(0, 19);
      onLog('\n$ts --- [${si + 1}/${subEntries.length}] ${sub.key} ---');

      try {
        await _processPodcast(sub.key, sub.value, hasGroq, stepIndex);
      } catch (e) {
        onLog('  ❌ ${sub.key} 失敗: $e');
      }
      stepIndex++;
    }

    if (state.isCancelled) {
      onLog('Podcast Pipeline 已取消');
    } else {
      onLog('Podcast Pipeline 完成');
    }

    await _updateRagIndex();
  }

  /// Podcast 處理完後，把新逐字稿納入 RAG 向量庫（增量，失敗不影響主流程）。
  Future<void> _updateRagIndex() async {
    if (state.isCancelled) return;
    onLog('\n🌐 更新 Podcast RAG 索引…');
    try {
      await RagService.instance.build((line) {
        if (state.isCancelled) return;
        onLog('  $line');
      });
    } catch (e) {
      onLog('  ⏭️ RAG 索引更新失敗（可稍後在 Podcast RAG 頁面重建）: $e');
    }
  }

  Future<void> _processPodcast(
      String podcastName, String rssUrl, bool hasGroq, int stepIndex) async {
    final cache = await _loadCacheAsync();
    final podDir = PodcastService.instance.podcastDir(podcastName);
    final ext = 'mp3';

    // ── Cache validation: purge stale entries ─────────────────────
    // If cache says txt/srt=true but the file doesn't exist on disk,
    // reset to false so the episode gets re-processed.
    int staleCount = 0;
    final staleKeys = <String>{};
    final prefix = '$podcastName|';
    final keysToCheck = cache.keys.where((k) => k.startsWith(prefix)).toList();
    for (int ci = 0; ci < keysToCheck.length; ci++) {
      final key = keysToCheck[ci];
      final entry = cache[key];
      if (entry == null) continue;
      final epTitle = key.substring(prefix.length);
      final name = PodcastService.normalizeFileName(epTitle);
      final txtPath = '$podDir\\$name.txt';
      final txtExists = File(txtPath).existsSync();
      final srtExists = await _findSrtAsync(podDir, name) != null;
      if (entry['txt'] == true && !txtExists) {
        entry['txt'] = false;
        entry['status'] = '';
        staleCount++;
        staleKeys.add(key);
      }
      if (entry['srt'] == true && !srtExists) {
        entry['srt'] = false;
        entry['status'] = '';
        staleCount++;
        staleKeys.add(key);
      }
      // Yield every 100 entries to keep UI responsive
      if (ci % 100 == 0) await Future<void>.delayed(Duration.zero);
    }
    if (staleCount > 0) {
      onLog('  ⚠️ 修正 $staleCount 筆過期 cache（檔案已消失）');
      await _saveCacheAsync(cache);
    }

    onLog('  讀取 RSS Feed...');
    final result = await PodcastService.instance.fetchEpisodes(rssUrl);
    final episodes = result.episodes;
    onLog('  Feed: ${result.title} (${episodes.length} 集)');

    // Build task list — check disk synchronously so episodes that already
    // have srt/txt are resolved instantly (no network, no batch waiting).
    // Only episodes truly missing files enter the parallel batch.
    final tasks = <_PodTask>[];
    int alreadyHave = 0;
    // Pre-scan: build canonical lookup for all existing files.
    // Canonical form: lowercase, strip all non-alphanumeric/CJK chars.
    final canonicalToStem = <String, String>{};
    try {
      final dir = Directory(podDir);
      if (dir.existsSync()) {
        await for (final f in dir.list()) {
          if (f is File) {
            final stem = f.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
            if (stem.length < 5) continue;
            final canonical = _canonicalize(stem);
            if (canonical.isNotEmpty) canonicalToStem[canonical] = stem;
            // Also store without CJK for cross-encoding matches.
            final alphaOnly = stem.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (alphaOnly.length >= 8) canonicalToStem[alphaOnly] = stem;
          }
        }
      }
    } catch (_) {}

    for (int i = 0; i < episodes.length; i++) {
      if (state.isCancelled) break;
      // Yield every 50 episodes to keep UI responsive
      if (i % 50 == 0 && i > 0) await Future<void>.delayed(Duration.zero);
      final ep = episodes[i];
      final key = '$podcastName|${ep.title}';
      final name = PodcastService.normalizeFileName(ep.title);
      var srtPath = await _findSrtAsync(podDir, name);
      final txtPath = '$podDir\\$name.txt';
      var hasSrt = srtPath != null;
      var hasTxt = File(txtPath).existsSync();
      // Canonical match: strip all formatting, compare content characters.
      // Skip for stale-cache keys — we know their files are truly gone.
      if (!hasSrt && !hasTxt && !staleKeys.contains(key)) {
        final canonical = _canonicalize(ep.title);
        final match = canonicalToStem[canonical];
        if (match != null) {
          hasTxt = File('$podDir\\$match.txt').existsSync();
          hasSrt = File('$podDir\\$match.srt').existsSync() || await _findSrtAsync(podDir, match) != null;
          if (hasSrt) srtPath = await _findSrtAsync(podDir, match);
        }
      }
      // EP number fallback.
      if (!hasSrt && !hasTxt && !staleKeys.contains(key)) {
        final fuzzy = _fuzzyFindFile(canonicalToStem.values.toSet(), name, ep.title);
        if (fuzzy != null) {
          hasSrt = fuzzy.endsWith('.srt');
          hasTxt = File('$podDir\\$fuzzy.txt').existsSync();
          if (hasSrt) srtPath = '$podDir\\$fuzzy.srt';
        }
      }
      if (hasSrt || hasTxt) {
        // Backfill missing txt right here (fast, local).
        if (hasSrt && !hasTxt) {
          await _srtToTxt(srtPath!, txtPath);
          // _srtToTxt deletes garbage subtitles (<50 chars): re-detect so the
          // episode is queued for a retry instead of being marked done.
          srtPath = await _findSrtAsync(podDir, name);
          hasSrt = srtPath != null;
          hasTxt = File(txtPath).existsSync();
        }
        cache[key] = {
          'srt': hasSrt,
          'txt': hasTxt,
          'yt_status': hasSrt ? 'found' : (cache[key]?['yt_status'] ?? ''),
          'status': 'ok',
        };
        alreadyHave++;
        continue;
      }
      // Files are gone but cache claims done (e.g. garbage subtitles were
      // deleted) — re-queue so the episode gets a fresh attempt.
      final cacheSaysDone = cache.containsKey(key) &&
          (cache[key]!['srt'] == true || cache[key]!['txt'] == true);
      if (!cacheSaysDone || (!hasSrt && !hasTxt)) {
        tasks.add(_PodTask(index: i, episode: ep, key: key));
      }
    }
    await _saveCacheAsync(cache);

    if (tasks.isEmpty) {
      onLog('  無新集數 (${alreadyHave} 集已處理過)');
      return;
    }
    onLog('  需處理: ${tasks.length} 集 (×4 並行)');
    final total = tasks.length;
    final groqQueue = <_PodTask>[];
    int groqActive = 0;
    final groqLimit = ConfigService.instance.config.groqConcurrency.clamp(1, 8);

    Future<void> _tryGroq() async {
      while (groqActive < groqLimit && groqQueue.isNotEmpty && !state.isCancelled) {
        final t = groqQueue.removeAt(0);
        groqActive++;
        // fire and forget: continue processing queue while this runs
        unawaited(_runGroq(t, podcastName, podDir, ext, cache, onLog, state).then((_) {
          groqActive--;
          _saveCacheAsync(cache);
          _tryGroq(); // kick next
        }));
      }
    }

    for (int i = 0; i < total; i += 4) {
      if (state.isCancelled) break;
      await state.waitIfPaused();
      if (state.isCancelled) break;

      final batch = tasks.skip(i).take(4).toList();
      final batchFutures = <Future<bool>>[];
      for (final e in batch) {
        if (state.isCancelled) break;
        batchFutures.add(_processOne(e, podcastName, rssUrl, podDir, ext, cache, onLog, state));
      }
      final results = await Future.wait(batchFutures);
      await _saveCacheAsync(cache);
      if (hasGroq) {
        for (int j = 0; j < batch.length; j++) {
          if (results[j] && j < batch.length) {
            groqQueue.add(batch[j]);
          }
        }
        _tryGroq();
      }

      final done = (i + batch.length).clamp(0, total);
      onProgress(done * 100 ~/ total, 100, stepIndex);
      onLog('  進度: $done/$total');
    }

    // Wait for remaining Groq
    while (groqActive > 0 && !state.isCancelled) {
      await Future.delayed(const Duration(seconds: 1));
    }

    final srtCount = cache.values.where((v) => v['srt'] == true).length;
    final txtDone = cache.values.where((v) => v['txt'] == true).length;
    final errCount = cache.values.where((v) => v['status'] == 'error').length;
    onLog('  $podcastName 完成: 總處理 ${cache.length} 集 (SRT $srtCount, 逐字稿 $txtDone, 錯誤 $errCount)');
  }

  /// Resolve the actual SRT file for an episode. yt-dlp may save
  /// subtitles as `name.srt` or with a language suffix such as
  /// `name.zh-TW.srt` / `name.zh-Hans.srt`. Returns null when none exists.
  Future<String?> _findSrtAsync(String podDir, String name) async {
    final plain = '$podDir\\$name.srt';
    if (await File(plain).exists()) return plain;
    final dir = Directory(podDir);
    if (!await dir.exists()) return null;
    try {
      final prefix = '$name.';
      await for (final f in dir.list()) {
        final fn = f.uri.pathSegments.last;
        if (fn.startsWith(prefix) && fn.toLowerCase().endsWith('.srt')) {
          return f.path;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Fuzzy find: match by EP number, date prefix, or longest common substring.
  String? _fuzzyFindFile(Set<String> existingStems, String normalizedName, String rawTitle) {
    final lowerName = normalizedName.toLowerCase();

    // 1. EP number matching (most reliable for numbered podcasts).
    final epMatch = RegExp(r'(?:ep|EP)[_\s]?(\d+)').firstMatch(rawTitle);
    final epNum = epMatch?.group(1);
    if (epNum != null) {
      for (final stem in existingStems) {
        if (RegExp(r'ep[\s_]*' + epNum + r'[\s_\b.]', caseSensitive: false).hasMatch(stem)) {
          return stem;
        }
      }
    }

    // 2. Date prefix matching (for daily shows like "2026_8_26(三)...").
    final dateMatch = RegExp(r'(\d{4}[_-]\d{1,2}[_-]\d{1,2})').firstMatch(rawTitle);
    if (dateMatch != null) {
      final dateStr = dateMatch.group(1)!.replaceAll('-', '_');
      for (final stem in existingStems) {
        if (stem.contains(dateStr)) return stem;
      }
    }

    // 3. Longest common substring (12+ chars to avoid date-prefix false positives
    //    like "2026_8_20..." matching "2026_8_27..." which share "2026_8_2" = 8 chars).
    final stripped = lowerName.replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '');
    if (stripped.length >= 12) {
      String best = '';
      String? bestStem;
      for (final stem in existingStems) {
        final stemStripped = stem.replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '');
        // Check if stripped name starts with same 12+ chars as stem.
        final commonLen = _commonPrefixLen(stripped, stemStripped);
        if (commonLen >= 12 && commonLen > best.length) {
          best = stripped.substring(0, commonLen);
          bestStem = stem;
        }
      }
      if (bestStem != null) return bestStem;
    }

    return null;
  }

  /// Canonical form: lowercase + strip all non-alphanumeric/non-CJK chars.
  /// Both Dart XML and Python ET titles will produce the same canonical form.
  static String _canonicalize(String s) {
    return s.toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff\u3400-\u4dbf]'), '')
        .trim();
  }

  static int _commonPrefixLen(String a, String b) {
    int i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) i++;
    return i;
  }

  Future<void> _srtToTxt(String srtPath, String txtPath) async {
    if (!await File(srtPath).exists()) return;
    try {
      final content = await File(srtPath).readAsString(encoding: utf8);
      final lines = content.split('\n');
      final textLines = <String>[];
      String last = '';
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (RegExp(r'^\d+$').hasMatch(t)) continue;
        if (t.contains('-->')) continue;
        final clean = t.replaceAll(RegExp(r'<[^>]+>'), '');
        if (clean.isEmpty || clean == last) continue;
        textLines.add(clean);
        last = clean;
      }
      final text = textLines.join('\n');
      // Convert simplified Chinese to traditional.
      final converted = ChineseConverter.instance.isLoaded
          ? ChineseConverter.instance.toTraditional(text) : text;
      await File(txtPath).writeAsString(converted, flush: true);
      // Guard: a transcript with almost no content means the SRT was garbage
      // (failed subtitle grab, e.g. only "[Music]"/"you"). Keeping it lets
      // the RAG index treat it as "done" forever with zero-value data —
      // delete it instead so the episode is retried on a later run.
      final strippedLen = text.replaceAll(RegExp(r'\s+'), '').length;
      if (strippedLen < 50) {
        try { await File(txtPath).delete(); } catch (_) {}
        try { await File(srtPath).delete(); } catch (_) {}
      }
    } catch (_) {}
  }

  Future<bool> _processOne(
    _PodTask t, String podcastName, String rssUrl, String podDir, String ext,
    Map<String, Map<String, dynamic>> cache, void Function(String) onLog,
    PipelineState state,
  ) async {
    if (state.isCancelled) return false;
    final name = PodcastService.normalizeFileName(t.episode.title);
    final audioPath = '$podDir\\$name.$ext';
    var srtPath = await _findSrtAsync(podDir, name);
    final txtPath = '$podDir\\$name.txt';

    // Download audio if missing
    if (!await File(audioPath).exists()) {
      if (state.isCancelled) return false;
      onLog('  [${t.index}] ⬇️ $name');
      try {
        // title/audioUrl 已在 RSS 抓過，直接傳入避免 downloadEpisode 重抓同一 feed。
        await PodcastService.instance.downloadEpisode(rssUrl, t.index, (pct) {},
          podcastName: podcastName,
          knownTitle: t.episode.title,
          knownAudioUrl: t.episode.audioUrl,
        );
      } catch (e) {
        onLog('    ❌ 下載失敗');
        cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'error'};
        return false;
      }
    }

    // Skip if already have result
    if (srtPath != null || await File(txtPath).exists()) {
      // SRT exists but TXT missing (e.g. subtitles grabbed by external tool):
      // convert now so the transcript is available.
      if (srtPath != null && !await File(txtPath).exists()) {
        await _srtToTxt(srtPath, txtPath);
        // Garbage subtitle? _srtToTxt deleted both files — reflect reality
        // so the episode is re-queued on the next run.
        final srtStill = await _findSrtAsync(podDir, name) != null;
        final txtStill = await File(txtPath).exists();
        cache[t.key] = {'srt': srtStill, 'txt': txtStill, 'yt_status': srtStill ? 'found' : '', 'status': 'ok'};
      }
      return false;
    }

    // YT search (skip if previously failed)
    final prevYt = cache[t.key]?['yt_status'] as String?;
    if (prevYt == 'not_found') {
      if (srtPath != null || await File(txtPath).exists()) {
        if (srtPath != null) await _srtToTxt(srtPath, txtPath);
        cache[t.key] = {'srt': srtPath != null, 'txt': await File(txtPath).exists(), 'yt_status': 'found', 'status': 'ok'};
        return false;
      }
      onLog('    ⏭️ $name (YT 上次已搜過)');
      cache[t.key] = {'srt': false, 'txt': false, 'yt_status': 'not_found', 'status': 'no_sub'};
      return true; // need Groq
    }

    onLog('    🔍 $name');
    if (state.isCancelled) return false;
    // Stagger only real YT searches (0~1.2s) to avoid rate limit,
    // never delay episodes that skip instantly.
    await Future.delayed(Duration(milliseconds: (t.index % 4) * 300));
    final subResult = await PodcastService.instance.downloadSubtitles(t.episode.title, podcastName,
      onLog: (msg) => onLog('      $msg'),
    );
    final srtAfter = await _findSrtAsync(podDir, name);
    if (subResult == PodcastSubtitleResult.found && srtAfter != null) {
      await _srtToTxt(srtAfter, txtPath);
      // Re-check: _srtToTxt deletes garbage subtitles (<50 chars).
      final srtStill = await _findSrtAsync(podDir, name) != null;
      final txtStill = await File(txtPath).exists();
      cache[t.key] = {'srt': srtStill, 'txt': txtStill, 'yt_status': srtStill ? 'found' : '', 'status': 'ok'};
      return false; // SRT found, no Groq needed
    }
    if (subResult == PodcastSubtitleResult.notFound) {
      cache[t.key] = {'srt': false, 'txt': false, 'yt_status': 'not_found', 'status': 'no_sub'};
    } else {
      // Transient failure (network / rate limit): do NOT burn not_found
      // into the cache, so YouTube is retried on a later run.
      cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'no_sub'};
    }
    return true; // need Groq
  }

  Future<void> _runGroq(
    _PodTask t, String podcastName, String podDir, String ext,
    Map<String, Map<String, dynamic>> cache, void Function(String) onLog,
    PipelineState state,
  ) async {
    if (state.isCancelled) return;
    final name = PodcastService.normalizeFileName(t.episode.title);
    final audioPath = '$podDir\\$name.$ext';
    final srtPath = await _findSrtAsync(podDir, name);
    final txtPath = '$podDir\\$name.txt';
    if (!await File(audioPath).exists()) return;
    if (srtPath != null || await File(txtPath).exists()) return;
    onLog('    🎤 $name');
    try {
      final text = await GroqService.instance.transcribeFile(
        filePath: audioPath, model: GroqService.instance.defaultModel, language: 'zh',
      );
      // Garbage guard: a transcript with almost no content means the audio
      // was bad/empty or ASR failed — do NOT mark done, retry next run.
      final strippedLen = text.replaceAll(RegExp(r'\s+'), '').length;
      if (strippedLen < 50) {
        try { if (await File(txtPath).exists()) await File(txtPath).delete(); } catch (_) {}
        cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'no_sub'};
        onLog('      ⚠️ 逐字稿內容過短 ($strippedLen 字)，已跳過待下次重試');
        return;
      }
      // Convert simplified Chinese to traditional.
      final converted = ChineseConverter.instance.isLoaded
          ? ChineseConverter.instance.toTraditional(text) : text;
      await File(txtPath).writeAsString(converted, flush: true);
      cache[t.key] = {'srt': false, 'txt': true, 'yt_status': 'not_found', 'status': 'ok'};
      onLog('      ✅ ($strippedLen 字)');
    } catch (e) {
      onLog('      ❌ $e');
      // Record failure so the episode is retried on next run instead of
      // being treated as done. Keep yt_status='' so YouTube (free) is
      // retried before spending Groq credits again.
      cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'error'};
    }
  }
}

class _PodTask {
  final int index;
  final PodcastEpisode episode;
  final String key;
  _PodTask({required this.index, required this.episode, required this.key});
}
