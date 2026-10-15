import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/podcast_episode.dart';
import '../models/pipeline_step.dart';
import '../services/config_service.dart';
import '../services/podcast_service.dart';
import '../services/groq_service.dart';
import '../services/groq_native_service.dart';
import '../services/upload_budget.dart';
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

    final stamp = DateTime.now().toString().substring(0, 19);
    final ver = appVersion.startsWith('v') ? appVersion : 'v$appVersion';
    onLog('$stamp  playlist-admin $ver');

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
    const ext = 'mp3';

    // ── YouTube 頻道模式：抓逐字稿進 RAG（無 RSS，全頻道增量）──
    if (PodcastService.isYtChannelUrl(rssUrl)) {
      await _processYtChannel(podcastName, rssUrl, stepIndex);
      return;
    }

    // ── Local directory mode: scan .txt files, no RSS/YouTube ──
    final isLocalDir = _isLocalPath(rssUrl);
    if (isLocalDir) {
      await _processLocalDir(podcastName, rssUrl, cache);
      return;
    }

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
      var hasTxt = _hasUsableTxt(txtPath);
      // Canonical match: strip all formatting, compare content characters.
      // Skip for stale-cache keys — we know their files are truly gone.
      if (!hasSrt && !hasTxt && !staleKeys.contains(key)) {
        final canonical = _canonicalize(ep.title);
        final match = canonicalToStem[canonical];
        if (match != null) {
          hasTxt = _hasUsableTxt('$podDir\\$match.txt');
          hasSrt = File('$podDir\\$match.srt').existsSync() || await _findSrtAsync(podDir, match) != null;
          if (hasSrt) srtPath = await _findSrtAsync(podDir, match);
        }
      }
      // EP number fallback.
      if (!hasSrt && !hasTxt && !staleKeys.contains(key)) {
        final fuzzy = _fuzzyFindFile(canonicalToStem.values.toSet(), name, ep.title);
        if (fuzzy != null) {
          hasSrt = fuzzy.endsWith('.srt');
          hasTxt = _hasUsableTxt('$podDir\\$fuzzy.txt');
          if (hasSrt) srtPath = '$podDir\\$fuzzy.srt';
        }
      }
      if (hasSrt || hasTxt) {
        // Backfill missing txt right here (fast, local).
        if (hasSrt && !hasTxt) {
          await _srtToTxt(srtPath!, txtPath, audioPath: _firstAudio(podDir, name));
          // _srtToTxt 會丟棄品質不合格的字幕（過短／被自動翻譯成英文）：
          // 重新偵測，讓這集被排進去改走 Groq 轉錄，而不是標成已完成。
          srtPath = await _findSrtAsync(podDir, name);
          hasSrt = srtPath != null;
          hasTxt = _hasUsableTxt(txtPath);
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

    // RSS 集數的 canonical 集合，用來判斷哪些本地檔不在 feed 裡。
    final rssCanonical = <String>{};
    for (final ep in episodes) {
      final c = _canonicalize(ep.title);
      if (c.isNotEmpty) rssCanonical.add(c);
      final a = ep.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (a.length >= 8) rssCanonical.add(a);
    }

    // ── 本地補掃 ─────────────────────────────────────
    // RSS feed 只保留最近的集數，舊集會從 feed 裡消失，但音檔還在本地。
    // 2026-10-15 實測：游庭皓本地 566 個 mp3、RSS 只有 501 集，
    // 那 65 個沒有逐字稿的舊集正好就是 feed 滾掉的——只遍歷 RSS 的話
    // 它們永遠不會被排進任務，log 還會顯示「無新集數」看起來像完成了。
    final localOnly = _sweepLocalOnly(podDir, rssCanonical);
    if (localOnly.isNotEmpty) {
      onLog('  本地補掃：另有 ${localOnly.length} 個音檔不在 RSS '
          '（feed 只留近期集數），一併補上');
      for (var i = 0; i < localOnly.length; i++) {
        final ep = localOnly[i];
        final key = '$podcastName|${ep.title}';
        cache[key] = {
          'srt': false,
          'txt': false,
          'yt_status': '',
          'status': 'pending',
        };
        tasks.add(_PodTask(index: episodes.length + i, episode: ep, key: key));
      }
    }

    if (tasks.isEmpty) {
      onLog('  無新集數 ($alreadyHave 集已處理過)');
      return;
    }
    // 上限先算出來，log 要印實際值（舊版硬寫「×4」，但實際是
    // config 的 groq_concurrency，預設 3 → log 一直在騙人）。
    // 集數併發上限從 8 放寬到 16：實測 32 併發（8×4）時端點零錯誤
    // （0 次 DNS/429/連線中斷），瓶頸是端點算力不是頻寬
    // （100Mbps 線路只用到 8.9Mbps），所以往上加是安全的。
    final groqLimit = ConfigService.instance.config.groqConcurrency.clamp(1, 16);
    final chunkConc = int.tryParse(
            Platform.environment['PA_CHUNK_CONCURRENCY'] ?? '') ??
        4;
    onLog('  需處理: ${tasks.length} 集 '
        '(×$groqLimit 集並行 × $chunkConc 分段 = ${groqLimit * chunkConc} 併發)');
    final total = tasks.length;
    final groqQueue = <_PodTask>[];
    int groqActive = 0;
    // 上傳流量預算用盡旗標：一旦被 charge 擋下，整批提早結束不再排新任務。
    var budgetHit = false;

    Future<void> tryGroq() async {
      while (groqActive < groqLimit &&
          groqQueue.isNotEmpty &&
          !state.isCancelled &&
          !budgetHit) {
        final t = groqQueue.removeAt(0);
        groqActive++;
        // fire and forget: continue processing queue while this runs.
        // whenComplete 保證 throw 路徑也扣回計數，否則底部 while 轉不停。
        unawaited(_runGroq(t, podcastName, podDir, ext, cache, onLog, state,
            onBudgetHit: () => budgetHit = true).whenComplete(() {
          groqActive--;
          _saveCacheAsync(cache);
          tryGroq(); // kick next
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
        for (int j = 0; j < results.length; j++) {
          if (results[j] && j < batch.length) {
            groqQueue.add(batch[j]);
          }
        }
        tryGroq();
      }

      final done = (i + batch.length).clamp(0, total);
      onProgress(done * 100 ~/ total, 100, stepIndex);
      onLog('  進度: $done/$total');
      // 上傳流量預算用盡：立刻停止排程，剩餘集數留待下批（不再打任何 API）。
      if (budgetHit) {
        onLog('  ⏹ 上傳流量預算用盡（${UploadBudget.describe()}），'
            '本節目剩餘集數留待下批');
        break;
      }
    }

    // Wait for remaining Groq
    while (groqActive > 0 && !state.isCancelled) {
      await Future.delayed(const Duration(seconds: 1));
    }

    final podEntries = cache.entries.where((e) => e.key.startsWith(prefix)).map((e) => e.value).toList();
    final srtCount = podEntries.where((v) => v['srt'] == true).length;
    final txtDone = podEntries.where((v) => v['txt'] == true).length;
    final errCount = podEntries.where((v) => v['status'] == 'error').length;
    onLog('  $podcastName 完成: 總處理 ${podEntries.length} 集 (SRT $srtCount, 逐字稿 $txtDone, 錯誤 $errCount)');
  }

  /// YouTube 頻道 → 逐支抓字幕 → txt（同 podcast 的 cache/格式）。
  /// build_db 掃 podcasts\**\*.txt 自動進 RAG（show=資料夾名=頻道名）。
  /// v1 不下載音檔、不跑 Groq：無字幕的影片標 not_found 永久跳過。
  Future<void> _processYtChannel(String name, String url, int stepIndex) async {
    final cache = await _loadCacheAsync();
    final podDir = PodcastService.instance.podcastDir(name);
    final prefix = '$name|';

    onLog('  📺 YT 頻道模式（只抓逐字稿，不下載音檔）');
    final videos = await PodcastService.instance.listChannelVideos(url,
        isCancelled: () => state.isCancelled);
    if (state.isCancelled) return;
    if (videos == null || videos.isEmpty) {
      onLog('  ❌ 頻道影片清單取得失敗（yt-dlp / 網路 / 網址）');
      return;
    }
    onLog('  頻道共 ${videos.length} 支影片');

    // 過濾：txt 還在 = 完成；yt_status=not_found = 永久無字幕。
    final tasks = <({String id, String title})>[];
    int have = 0, noSub = 0;
    for (final v in videos) {
      final key = '$prefix${v.title}';
      final safe = PodcastService.normalizeFileName(v.title);
      if (File('$podDir\\$safe.txt').existsSync()) {
        cache[key] = {
          'srt': cache[key]?['srt'] ?? false,
          'txt': true,
          'yt_status': 'found',
          'status': 'ok',
        };
        have++;
        continue;
      }
      if (cache[key]?['yt_status'] == 'not_found') {
        noSub++;
        continue;
      }
      tasks.add(v);
    }
    await _saveCacheAsync(cache);
    onLog('  已完成 $have 支、無字幕跳過 $noSub 支、待處理 ${tasks.length} 支');
    if (tasks.isEmpty) return;

    final total = tasks.length;
    int got = 0, miss = 0, err = 0;
    for (int i = 0; i < total; i++) {
      if (state.isCancelled) break;
      await state.waitIfPaused();
      if (state.isCancelled) break;
      final v = tasks[i];
      final key = '$prefix${v.title}';
      final safe = PodcastService.normalizeFileName(v.title);
      final videoUrl = 'https://www.youtube.com/watch?v=${v.id}';

      // 逐支節流：連續打 YT 易 429（0.6~1.6s 隨機）。
      await Future.delayed(
          Duration(milliseconds: 600 + (v.id.hashCode % 1000).abs()));

      onLog('  [${i + 1}/$total] 🔍 ${v.title}');
      final result = await PodcastService.instance.fetchYtSubtitlesByUrl(
        videoUrl,
        podDir,
        safe,
        isCancelled: () => state.isCancelled,
        onLog: (m) => onLog('      $m'),
      );
      if (state.isCancelled) break;

      if (result == PodcastSubtitleResult.found) {
        final srt = await _findSrtAsync(podDir, safe);
        if (srt != null) await _srtToTxt(srt, '$podDir\\$safe.txt');
        final txtOk = File('$podDir\\$safe.txt').existsSync();
        final srtOk = await _findSrtAsync(podDir, safe) != null;
        if (txtOk) {
          cache[key] = {'srt': srtOk, 'txt': true, 'yt_status': 'found', 'status': 'ok'};
          got++;
          onLog('    ✅ 逐字稿完成');
        } else {
          // _srtToTxt 垃圾守衛刪掉(<50字) → 列可重試，下次再試。
          cache[key] = {'srt': srtOk, 'txt': false, 'yt_status': 'found', 'status': ''};
          onLog('    ⚠️ 字幕過短已丟棄，列入下次重試');
        }
      } else if (result == PodcastSubtitleResult.notFound) {
        cache[key] = {
          'srt': false, 'txt': false,
          'yt_status': 'not_found', 'status': 'no_sub',
        };
        miss++;
        onLog('    ⏭️ 無字幕');
      } else {
        cache[key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'error'};
        err++;
        onLog('    ❌ 失敗（下次重試）');
      }

      if (i % 10 == 9) await _saveCacheAsync(cache);
      onProgress((i + 1) * 100 ~/ total, 100, stepIndex);
    }
    await _saveCacheAsync(cache);

    onLog('  $name 頻道完成: 新逐字稿 $got、無字幕 $miss、錯誤 $err（共 $total 支）');
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

  /// 逐字稿存在**且有實質內容**才算數。
  ///
  /// 只用 existsSync() 會讓 107~196 bytes 的空殼被當成已完成而永遠跳過
  /// （2026-10-15 實測：最後 5 集卡在這，其中 2 集還被 cache 標成
  /// status:ok，RSS 迴圈說「已處理」、本地補掃說「在 RSS 裡」→ 死結）。
  /// 門檻與 [_sweepLocalOnly] 一致（200 bytes）。
  static bool _hasUsableTxt(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() > 200;
    } catch (_) {
      return false;
    }
  }

  /// 掃出「本地有音檔但缺逐字稿、且這輪 RSS 裡沒有」的集數。
  ///
  /// RSS feed 通常只保留最近數十集，舊集會從 feed 消失但音檔還在本地。
  /// 只遍歷 feed 的話，這些集永遠不會被排進任務，而且 log 會印
  /// 「無新集數」讓人誤以為已完成（2026-10-15 實測：游庭皓本地 566 個
  /// mp3、feed 只有 501 集，缺的 65 集正好就是 feed 滾掉的那些）。
  ///
  /// 判斷「不在 RSS」用 [rssCanonical]：把每個 RSS 集數的標題 canonical
  /// 化後比對本地檔名，並額外用「去掉非英數」版本比對（處理繁簡/標點差異）。
  ///
  /// 回傳用本地音檔路徑當 audioUrl 的 PodcastEpisode——下游轉錄只讀
  /// audioUrl，不需要真的去下載。
  List<PodcastEpisode> _sweepLocalOnly(
      String podDir, Set<String> rssCanonical) {
    final out = <PodcastEpisode>[];
    final dir = Directory(podDir);
    if (!dir.existsSync()) return out;

    final withTxt = <String>{};
    final audio = <File>[];
    try {
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        final low = name.toLowerCase();
        if (low.endsWith('.txt')) {
          if (f.lengthSync() > 200) {
            withTxt.add(name.replaceAll(RegExp(r'\.txt$'), ''));
          }
        } else if (low.endsWith('.mp3') ||
            low.endsWith('.wav') ||
            low.endsWith('.m4a')) {
          audio.add(f);
        }
      }
    } catch (_) {
      return out;
    }

    for (final f in audio) {
      final stem = f.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
      if (stem.length < 5) continue;
      if (withTxt.contains(stem)) continue;
      if (rssCanonical.contains(_canonicalize(stem))) continue;
      final alphaOnly =
          stem.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (alphaOnly.length >= 8 && rssCanonical.contains(alphaOnly)) continue;
      out.add(PodcastEpisode(title: stem, audioUrl: f.path));
    }

    return out;
  }

  static int _commonPrefixLen(String a, String b) {
    int i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  Future<void> _srtToTxt(String srtPath, String txtPath, {String? audioPath}) async {
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

      // Guard: 字幕品質檢查。舊版只有「<50 字」一道門檻，結果兩種壞資料
      // 都通過（2026-10-15 全庫稽核抓到 41 集）：
      //   a) YouTube 自動**翻譯**字幕 → 中文節目變英文全文（博音 EP130
      //      47KB 全英文、泛泛泛科學 合成生物學 EP60 全英文）
      //   b) YouTube **殘缺**字幕 → 只剩開頭結尾（博音 EP45 141 字、
      //      泛泛泛科學 失眠 EP79 304 字）
      // 兩種都該丟掉字幕、改走 Groq 轉錄，而不是寫進 RAG 當成完成。
      final strippedLen = text.replaceAll(RegExp(r'\s+'), '').length;
      final cjkLen = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
      final durSec =
          audioPath == null ? 0 : await _audioDurationSec(audioPath);

      var bad = strippedLen < 50;
      // ignore: unused_local_variable
      String why = '內容過少';
      // 中文節目的逐字稿應該以中文為主；全英文就是被自動翻譯了。
      if (!bad && durSec > 0 && cjkLen == 0 && strippedLen >= 50) {
        bad = true;
        why = '字幕疑似被自動翻譯成英文（中文節目卻沒有任何中文）';
      }
      // 長度合理性：中文語速最慢 1 字/秒。
      if (!bad && durSec > 0 && cjkLen < durSec) {
        bad = true;
        why = '字幕只覆蓋音訊開頭（$cjkLen 字 / 音訊 ${durSec.round()} 秒）';
      }

      if (bad) {
        // 字幕品質不合格（過短／被自動翻譯成英文）：丟棄改走 Groq 轉錄。
        try { await File(txtPath).delete(); } catch (_) {}
        try { await File(srtPath).delete(); } catch (_) {}
        return;
      }

      await File(txtPath).writeAsString(converted, flush: true);
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
          isCancelled: () => state.isCancelled,
        );
      } catch (e) {
        onLog('    ❌ 下載失敗');
      cache[t.key] = {
        'srt': false, 'txt': false,
        'yt_status': cache[t.key]?['yt_status'] ?? '',  // preserve 'not_found'
        'status': 'error',
      };
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
    // 用 title hash 而非全域 t.index：過濾後的 tasks 常同餘，會同時打 YT。
    await Future.delayed(Duration(milliseconds: (t.episode.title.hashCode % 4).abs() * 300));
    final subResult = await PodcastService.instance.downloadSubtitles(t.episode.title, podcastName,
      onLog: (msg) => onLog('      $msg'),
      isCancelled: () => state.isCancelled,
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

  /// 找出這集對應的本機音檔路徑（字幕品質檢查需要時長）。
static String? _firstAudio(String podDir, String stem) {
  for (final ext in const ['.mp3', '.wav', '.m4a']) {
    final p = '$podDir\\$stem$ext';
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// 用 ffprobe 取得音檔時長（秒）；取不到回 0。
  ///
  /// 逐字稿長度合理性檢查需要它：中文語速最慢 1 字/秒，
  /// N 秒的音訊至少該有 N 個字，不然就是轉寫只回了一小段。
  static Future<int> _audioDurationSec(String path) async {
    try {
      final r = await Process.run(_ffprobePath, [
        '-v', 'quiet', '-print_format', 'json', '-show_format', path,
      ]);
      if (r.exitCode != 0) return 0;
      final raw = r.stdout is String
          ? r.stdout as String
          : utf8.decode((r.stdout as List<int>?) ?? const [],
              allowMalformed: true);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final d = double.tryParse(
              ((j['format'] as Map<String, dynamic>?)?['duration'] as String?) ??
              '') ??
          0;
      return d.round();
    } catch (_) {
      return 0;
    }
  }

  static String get _ffprobePath =>
      ConfigService.instance.config.resolvedFfmpegPath.toLowerCase()
              .endsWith('ffmpeg.exe')
          ? '${ConfigService.instance.config.resolvedFfmpegPath.substring(0, ConfigService.instance.config.resolvedFfmpegPath.length - 10)}ffprobe.exe'
          : 'ffprobe';

  Future<void> _runGroq(
    _PodTask t,
    String podcastName,
    String podDir,
    String ext,
    Map<String, Map<String, dynamic>> cache,
    void Function(String) onLog,
    PipelineState state, {
    void Function()? onBudgetHit,
  }) async {
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
        onCorruptAudio: () async {
          // 音檔本身損毀（MP3 檔頭寫的時長大於實際資料，下載中斷會造成）：
          // 留著只會永遠重複失敗，直接刪掉讓下一輪從 RSS 重新下載。
          // 2026-10-15 實測：18 集因為這樣卡住，其中科技浪 EP27 檔頭寫
          // 49.1 分鐘但實際只有 2.9 分鐘，轉出 923 字就被當成成功。
          onLog('      🗑 音檔損毀，刪除以便重新下載');
          try { await File(audioPath).delete(); } catch (_) {}
          // 逐字稿一併清掉，避免殘留舊的半截內容。
          try { if (await File(txtPath).exists()) await File(txtPath).delete(); } catch (_) {}
          cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': ''};
        },
      );
      // Garbage guard: a transcript with almost no content means the audio
      // was bad/empty or ASR failed — do NOT mark done, retry next run.
      // 記 'error' 不是 'no_sub'：0 字通常代表「轉寫失敗」（例如上游 413
      // 段太大），記 no_sub 會被當成「這集本來就沒字幕」而永久跳過，
      // 等於每集都白燒一次音檔流量。
      //
      // 門檻要**依片長**算，不能用固定 50 字。實測（2026-10-15）：40 分鐘
      // 的集數只轉出「這集錄到這邊，下次再見，掰掰」這種結尾語，
      // 去掉空白還有 65 個字 → 剛好通過固定 50 字門檻 → 被當成成功。
      // 中文語速最慢也有 1 字/秒，所以 N 秒的音訊至少要有 N 個字。
      final strippedLen = text.replaceAll(RegExp(r'\s+'), '').length;
      final durSec = await _audioDurationSec(audioPath);
      final minChars = durSec > 0 ? durSec : 0;
      if (strippedLen < 50 || (minChars > 0 && strippedLen < minChars)) {
        try { if (await File(txtPath).exists()) await File(txtPath).delete(); } catch (_) {}
        cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'error'};
        onLog('      ⚠️ 逐字稿空/過短 ($strippedLen 字'
            '${minChars > 0 ? '，音訊 ${durSec.round()} 秒至少應有 $minChars 字' : ''}'
            ')：轉寫失敗，標記重試');
        return;
      }
      // Convert simplified Chinese to traditional.
      final converted = ChineseConverter.instance.isLoaded
          ? ChineseConverter.instance.toTraditional(text) : text;
      await File(txtPath).writeAsString(converted, flush: true);
      cache[t.key] = {'srt': false, 'txt': true, 'yt_status': 'not_found', 'status': 'ok'};
      onLog('      ✅ ($strippedLen 字)');
    } on UploadBudgetExceeded catch (e) {
      // 流量預算用盡：這集留待下批（status 保持未完成），不是錯誤、不重試。
      onLog('      ⏸ $e');
      onLog('      ${UploadBudget.describe()}');
      onBudgetHit?.call();
      cache[t.key] =
          {'srt': false, 'txt': false, 'yt_status': '', 'status': ''};
    } catch (e) {
      onLog('      ❌ $e');
      // Record failure so the episode is retried on next run instead of
      // being treated as done. Keep yt_status='' so YouTube (free) is
      // retried before spending Groq credits again.
      cache[t.key] = {'srt': false, 'txt': false, 'yt_status': '', 'status': 'error'};
    }
  }

  // ── Local directory helpers ────────────────────────────────────────

  /// Detect local directory paths (e.g. "C:\..." or "\\server\...").
  static bool _isLocalPath(String path) {
    if (path.isEmpty) return false;
    // Windows drive letter: C:\...
    if (RegExp(r'^[a-zA-Z]:\\').hasMatch(path)) return true;
    // UNC path: \\server\...
    if (path.startsWith('\\\\')) return true;
    // Relative path: .\ or ..\ or just a directory name
    if (path.startsWith('.') || path.contains('\\') || path.contains('/')) {
      // But not a URL
      if (!path.startsWith('http://') && !path.startsWith('https://')) return true;
    }
    return false;
  }

  /// Process a local directory of MP3+TXT files (no RSS, no YouTube).
  Future<void> _processLocalDir(
      String podcastName, String dirPath, Map<String, Map<String, dynamic>> cache) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      onLog('  ❌ 本地目錄不存在: $dirPath');
      return;
    }

    // Scan for .txt files — each is a transcription episode.
    final txtFiles = <String, String>{}; // stem -> full path
    await for (final f in dir.list()) {
      if (f is File && f.path.endsWith('.txt')) {
        final stem = f.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
        if (stem.length >= 3) txtFiles[stem] = f.path;
      }
    }

    if (txtFiles.isEmpty) {
      onLog('  📂 本地目錄: ${dir.path} (0 個逐字稿)');
      return;
    }

    int alreadyHave = 0;
    int newCount = 0;
    // Purge stale cache entries for files that no longer exist
    final prefix = '$podcastName|';
    final currentStems = txtFiles.keys.toSet();
    for (final key in cache.keys.where((k) => k.startsWith(prefix)).toList()) {
      final stem = key.substring(prefix.length);
      if (cache[key]?['txt'] == true && !currentStems.contains(stem)) {
        cache[key]!['txt'] = false;
        cache[key]!['status'] = '';
      }
    }
    for (final entry in txtFiles.entries) {
      final key = '$podcastName|${entry.key}';
      if (cache.containsKey(key) && cache[key]?['txt'] == true) {
        alreadyHave++;
      } else {
        cache[key] = {'srt': false, 'txt': true, 'yt_status': 'local', 'status': 'ok'};
        newCount++;
      }
    }
    await _saveCacheAsync(cache);

    final total = txtFiles.length;
    onLog('  📂 本地目錄: ${dir.path} ($total 集, 已處理 $alreadyHave, 新增 $newCount)');
  }
}

class _PodTask {
  final int index;
  final PodcastEpisode episode;
  final String key;
  _PodTask({required this.index, required this.episode, required this.key});
}
