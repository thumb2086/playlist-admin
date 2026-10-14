import 'dart:convert';
import 'dart:io';
import 'config_service.dart';
import 'cover_cache.dart';
import 'metadata_reader.dart';
import 'artist_names.dart';
import 'spotify_gql_client.dart';
import 'spotify_session.dart';

/// ffmpeg / ffprobe 實際路徑：優先用設定裡的（desktop 的 bin/ffmpeg.exe
  /// 不在 PATH），退回 PATH 名稱。舊寫法直接用裸 'ffmpeg' → 找不到就是
  /// 每次寫入都失敗（年份/專輯一直補不進 ID3 的真正原因）。
String _ffmpegPath() {
  try {
    final p = ConfigService.instance.config.resolvedFfmpegPath;
    if (p.isNotEmpty) return p;
  } catch (_) {}
  return 'ffmpeg';
}

String _ffprobePath() {
  final f = _ffmpegPath();
  if (f == 'ffmpeg') return 'ffprobe';
  // ...\bin\ffmpeg.exe → ...\bin\ffprobe.exe
  final i = f.lastIndexOf('ffmpeg');
  if (i > 0) return '${f.substring(0, i)}ffprobe${f.substring(i + 6)}';
  return 'ffprobe';
}

/// 檔名 stem（不含副檔名）——cache key 兜底用。
String fileNameFor(String path) =>
    File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');

class MetadataEnricher {
  final void Function(String) log;
  final String libraryPath;

  MetadataEnricher({required this.log, required this.libraryPath});

  Future<void> enrichAll({void Function(int, int)? onProgress}) async {
    log('🔍 掃描缺少 metadata 的檔案…');
    final files = await _scanMissingMetadata();
    if (files.isEmpty) {
      log('✅ 所有檔案都有完整 metadata');
      return;
    }

    log('🎵 找到 ${files.length} 個檔案缺少 metadata，開始補充…');
    int success = 0;

    // spotify_cache 索引只建一次：原本每首歌都 listSync + 全讀全 parse，
    // O(歌×快取檔) 的同步 IO 全卡在主 thread 上。
    final cacheIndex = await _loadSpotifyCacheIndex();

    for (int i = 0; i < files.length; i++) {
      final path = files[i];
      try {
        final ok = await _enrichFile(path, cacheIndex);
        if (ok) success++;
      } catch (e) {
        log('  ❌ ${path.split('\\').last}: $e');
      }
      if (onProgress != null) onProgress(i + 1, files.length);
      if (i % 10 == 9 || i == files.length - 1) {
        log('  進度: ${i + 1}/${files.length} (成功: $success)');
      }
    }
    log('🎉 Metadata 補充完成: $success/${files.length}');
  }

  /// 把 ID3 裡的英文歌手名轉成中文（ArtistNames 對照表有的才轉）。
  ///
  /// 為什麼要獨立流程：enrichAll 只補「缺的值」，而這批檔案的 artist
  /// 早就寫了英文（非空）→ 不會被覆寫。這個流程專治「值存在但語言錯」。
  /// 只改 artist tag，title/album/date/封面一律不動（音訊 copy）。
  Future<int> localizeArtists({void Function(int done, int total)? onProgress}) async {
    log('🌏 掃描 artist 英文名（轉中文）…');
    final files = <String>[];
    try {
      final dir = Directory(libraryPath);
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.mp3')) {
            files.add(e.path);
          }
        }
      }
    } catch (_) {}
    files.sort();
    final total = files.length;
    if (total == 0) {
      log('沒有 mp3 可處理');
      return 0;
    }
    var changed = 0;
    for (int i = 0; i < files.length; i++) {
      final p = files[i];
      try {
        final meta = await MetadataReader.read(p);
        final cur = (meta.artist ?? '').trim();
        // 空 → 不處理（enrichAll 負責）；已是中文 → 跳過。
        if (cur.isEmpty ||
            RegExp(r'[\u4e00-\u9fff]').hasMatch(cur)) {
          onProgress?.call(i + 1, total);
          continue;
        }
        final zh = ArtistNames.toDisplayList(cur);
        if (zh == cur || zh.isEmpty) {
          onProgress?.call(i + 1, total);
          continue;
        }
        if (await _applyMetadata(p, meta.title, zh, meta.album, null, null)) {
          changed++;
          log('  ✅ ${File(p).uri.pathSegments.last}: $cur → $zh');
        }
      } catch (_) {}
      onProgress?.call(i + 1, total);
      if (i % 50 == 0) {
        log('  進度: ${i + 1}/$total（已轉 $changed）');
        await Future<void>.delayed(Duration.zero);
      }
    }
    log('🎉 artist 中文化完成：$changed/$total');
    return changed;
  }

  /// 全庫 Spotify 校正：title/artist/album/year 全部以 Spotify 為準重寫。
  ///
  /// 解決兩類問題：
  /// 1. album 被填成曲名（早期 fallback 寫的假專輯）
  /// 2. album/date 缺（spotify_cache 沒這首歌，或當時是外來音檔）
  ///
  /// 每首 searchTracks（找 trackId）→ getTrack（拿專輯與年份）共 2 個請求，
  /// 4 路並行 + 延遲。曲名必須與搜尋結果相符才套用，避免貼錯歌。
  /// [onlyProblems] true = 只處理有問題的（album 空 / album==title / 無 year），
  /// false = 全庫重寫（最慢但最乾淨）。
  Future<int> correctFromSpotify({
    bool onlyProblems = true,
    int limit = 0,
    void Function(int done, int total, String file)? onProgress,
  }) async {
    log('🎵 Spotify 全庫校正（onlyProblems=$onlyProblems）…');
    try {
      await SpotifySession.instance.load();
    } catch (_) {}
    if (!SpotifySession.instance.isLoggedIn) {
      log('⚠️ Spotify 未登入：先在 app 重登（搜尋頁有「重登」鈕）');
      return 0;
    }
    final gql = SpotifyGqlClient();
    final yearRe = RegExp(r'^(1\d{3}|2\d{3})$');

    final files = <String>[];
    try {
      final dir = Directory(libraryPath);
      if (await dir.exists()) {
        await for (final e
            in dir.list(recursive: true, followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.mp3')) {
            files.add(e.path);
          }
        }
      }
    } catch (_) {}
    files.sort();

    // 先篩出真正要處理的（讀 ID3 只為判斷，不寫）
    final targets = <String>[];
    for (final p in files) {
      if (onlyProblems) {
        final t = tagsOf(p);
        final title = t['title'] ?? '';
        final album = t['album'] ?? '';
        final date = t['date'] ?? '';
        final badAlbum = album.trim().isEmpty ||
            album.trim() == _unknownAlbum ||
            // 假專輯：album 就是曲名（或曲名前綴）
            album.trim() == title.trim();
        final badDate = date.trim().isEmpty ||
            !yearRe.hasMatch(date.trim()) ||
            date.trim() == '1970';
        if (!badAlbum && !badDate) continue;
      }
      targets.add(p);
    }
    final total = limit > 0 && limit < targets.length ? limit : targets.length;
    if (total == 0) {
      log('✅ 沒有需要校正的檔案');
      return 0;
    }
    log('  需校正 $total / ${files.length}');

    // 並行查詢 → 收集結果，最後序列寫檔（ffmpeg 同時跑太多會 IO 打架）
    final picked = <String, Map<String, String?>>{};
    var cursor = 0;
    var hits = 0, miss = 0;
    Future<void> worker() async {
      while (cursor < total) {
        final path = targets[cursor++];
        final name = fileNameFor(path);
        final parts = name.split(' - ');
        final title = parts.first.trim();
        final artist =
            parts.length > 1 ? parts.sublist(1).join(' - ').trim() : '';
        final q = artist.isEmpty ? title : '$title $artist';
        if (q.isEmpty) {
          miss++;
          continue;
        }
        try {
          final s = await gql.searchTracks(q, limit: 1);
          final tracks = SpotifyTrackItem.parseSearchTracks(s);
          if (tracks.isEmpty) {
            miss++;
            continue;
          }
          final pick = tracks.first;
          // 曲名必須相符（全等或一方包含另一方），否則寧可不套
          final pn = CoverCache.norm(pick.name);
          final ln = CoverCache.norm(title);
          if (ln.isEmpty ||
              (pn != ln && !pn.contains(ln) && !ln.contains(pn))) {
            miss++;
            continue;
          }
          // 歌手要對得上（任一段有交集即可，協演/Feat. 常只列部分）
          final pa = pick.artists.isEmpty
              ? ''
              : CoverCache.norm(pick.artists.join(''));
          final la = artist.isEmpty ? '' : CoverCache.norm(artist);
          if (pa.isNotEmpty &&
              la.isNotEmpty &&
              !pa.contains(la) &&
              !la.contains(pa)) {
            miss++;
            continue;
          }
          // getTrack 才有日期（searchTracks 的 albumOfTrack 沒有 date 欄位）
          String? year;
          try {
            final t = await gql.getTrack(pick.id);
            year = SpotifyTrackItem.yearFromResponse(t,
                expectAlbumName: pick.album);
          } catch (_) {}
          picked[path] = {
            'title': pick.name,
            'artist': pick.artists.join(', '),
            'album': pick.album,
            'year': year ?? '',
          };
          hits++;
        } catch (_) {
          miss++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        onProgress?.call(cursor, total, name);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    log('  Spotify 命中 $hits / 未匹配 $miss');

    // 寫 ID3
    var wrote = 0, writeFail = 0;
    for (final e in picked.entries) {
      final v = e.value;
      final okw = await _applyMetadata(
          e.key, v['title'], v['artist'], v['album'], v['year'], null);
      if (okw) {
        wrote++;
      } else {
        writeFail++;
      }
      if ((wrote + writeFail) % 50 == 0) {
        log('  寫入進度 ${wrote + writeFail}/$picked.length（成功 $wrote）');
        await Future<void>.delayed(Duration.zero);
      }
    }
    log('🎉 Spotify 校正完成：寫入 $wrote / 查詢命中 $hits'
        '（寫入失敗 $writeFail、未匹配 $miss）');
    return wrote;
  }

  /// 讀 ID3（純讀，失敗回空 map）——校正前的篩選用。
  static Map<String, String> tagsOf(String path) {
    try {
      final r = Process.runSync(_ffprobePath(), [
        '-v', 'quiet', '-print_format', 'json', '-show_format', path,
      ], stdoutEncoding: null);
      final d = jsonDecode((r.stdout is String
              ? r.stdout as String
              : utf8.decode(r.stdout as List<int>, allowMalformed: true))) as
          Map<String, dynamic>;
      final tags = (d['format'] as Map?)?['tags'] as Map? ?? {};
      return {
        'title': (tags['title'] ?? '').toString(),
        'artist': (tags['artist'] ?? '').toString(),
        'album': (tags['album'] ?? '').toString(),
        'date': (tags['date'] ?? '').toString(),
      };
    } catch (_) {
      return {'title': '', 'artist': '', 'album': '', 'date': ''};
    }
  }

  /// 補年份：唯一會回 albumOfTrack.date 的查詢是 getTrack
  ///（searchTracks / fetchPlaylist 的 albumOfTrack 只有 coverArt/id/name/uri）。
  /// 流程：本機檔名 → searchTracks 取 trackId → getTrack 取 year → 寫 ID3。
  /// 每首一次 Spotify 請求（1.2s 間隔避免 429），結果寫進 CoverCache 快取，
  /// 重跑會跳過已補的。
  Future<int> fillYearsFromSpotify({
    int limit = 0,
    void Function(int done, int total, String file)? onProgress,
  }) async {
    log('📅 補年份（Spotify getTrack）…');
    try {
      await SpotifySession.instance.load();
    } catch (_) {}
    if (!SpotifySession.instance.isLoggedIn) {
      log('⚠️ Spotify 未登入：先在 app 重登再跑（搜尋頁有「重登」鈕）');
      return 0;
    }
    final cache = await CoverCache.load();
    final gql = SpotifyGqlClient();

    final targets = <String>[];
    try {
      final dir = Directory(libraryPath);
      if (await dir.exists()) {
        await for (final e
            in dir.list(recursive: true, followLinks: false)) {
          if (e is! File || !e.path.toLowerCase().endsWith('.mp3')) continue;
          targets.add(e.path);
        }
      }
    } catch (_) {}
    targets.sort();
    final total = limit > 0 && limit < targets.length ? limit : targets.length;

    var done = 0, ok = 0, skip = 0, fail = 0;
    final yearRe = RegExp(r'^(1\d{3}|2\d{3})$');

    // ── 速度：原本每首 2 個請求 + 1.2s 硬等待 → 3 首/分鐘（全庫 26 小時）。
    // 改成 4 路並行 + 400ms 間隔 → 約 12~15 首/分鐘（全庫 ~5 小時 → 實際更快）。
    // 另外：cache 已有 trackId 的直接 getTrack，省掉 searchTracks 那一次請求。
    final pending = <String>[];
    for (int i = 0; i < total; i++) {
      final name = fileNameFor(targets[i]);
      final parts = name.split(' - ');
      final title = parts.first.trim();
      final artist = parts.length > 1 ? parts.sublist(1).join(' - ').trim() : '';
      pending.add(targets[i]);
      // 已有年份 → 直接寫 ID3，不打 Spotify
      final key = CoverCache.key(null, title, artist);
      final y = (cache[key] is Map) ? ((cache[key] as Map)['y'] as String?) : null;
      if (y != null && yearRe.hasMatch(y)) {
        // 稍後批次寫（避免阻塞 Spotify 查詢）
        skip++;
      }
    }

    // 批次查詢年份（並行），結果寫 cache
    final results = <String, String?>{}; // path -> year
    var cursor = 0;
    var dirtyCache = false;
    Future<void> worker() async {
      while (cursor < pending.length) {
        final path = pending[cursor++];
        final name = fileNameFor(path);
        final parts = name.split(' - ');
        final title = parts.first.trim();
        final artist = parts.length > 1 ? parts.sublist(1).join(' - ').trim() : '';
        final key = CoverCache.key(null, title, artist);
        var year = (cache[key] is Map)
            ? ((cache[key] as Map)['y'] as String?)
            : null;
        if (year != null && yearRe.hasMatch(year)) {
          results[path] = year;
          continue;
        }
        try {
          final q = artist.isEmpty ? title : '$title $artist';
          final s = await gql.searchTracks(q, limit: 1);
          final tracks = SpotifyTrackItem.parseSearchTracks(s);
          if (tracks.isEmpty) {
            fail++;
            continue;
          }
          final pick = tracks.first;
          final pn = CoverCache.norm(pick.name);
          final ln = CoverCache.norm(title);
          if (ln.isEmpty || pn != ln) {
            fail++;
            continue;
          }
          final t = await gql.getTrack(pick.id);
          year = SpotifyTrackItem.yearFromResponse(t,
              expectAlbumName: pick.album);
          if (year != null && yearRe.hasMatch(year)) {
            cache[key] = {
              ...(cache[key] is Map
                  ? cache[key] as Map
                  : <String, dynamic>{}),
              'y': year,
            };
            dirtyCache = true;
          }
        } catch (_) {
          fail++;
        }
        // 400ms 間隔（4 路並行 → 整體約 10 req/s，仍遠低於 Spotify 限制）
        await Future<void>.delayed(const Duration(milliseconds: 400));
        done++;
        if (done % 100 == 0) {
          try {
            await CoverCache.save(cache);
          } catch (_) {}
          log('  查詢進度 $done/$total（失敗 $fail）');
          onProgress?.call(done, total, name);
        }
      }
    }
    // 4 路並行查詢（原本序列 → 3 首/分鐘；並行後 ~15 首/分鐘）
    await Future.wait(List.generate(4, (_) => worker()));
    if (dirtyCache) {
      try {
        await CoverCache.save(cache);
      } catch (_) {}
    }

    // ── 階段二：寫 ID3（序列執行：ffmpeg 同時跑太多會 IO 打架）──
    for (final path in results.keys.toList()) {
      final year = results[path]!;
      final name = fileNameFor(path);
      final parts = name.split(' - ');
      final title = parts.first.trim();
      final artist =
          parts.length > 1 ? parts.sublist(1).join(' - ').trim() : '';
      final wrote = await _applyMetadata(path, title, artist, null, year, null);
      if (wrote) {
        ok++;
      } else {
        fail++;
      }
      final w = ok + fail;
      if (w % 50 == 0) {
        log('  寫入進度 $w/${results.length}（成功 $ok／失敗 $fail）');
        await Future<void>.delayed(Duration.zero);
      }
    }
    log('🎉 年份補齊：$ok（略過 $skip、失敗 $fail，共 $total）');
    return ok;
  }

  Future<List<String>> _scanMissingMetadata() async {
    final missing = <String>[];
    final dir = Directory(libraryPath);
    if (!await dir.exists()) return missing;

    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final low = e.path.toLowerCase();
      if (!low.endsWith('.mp3') && !low.endsWith('.m4a') && !low.endsWith('.flac')) continue;

      final meta = await MetadataReader.read(e.path);
      // 判定「缺什麼」不只是 title/artist：album 與 date 缺也要補。
      // 舊邏輯只看 title/artist → 「未分類」裡那批有 title/artist（從檔名來的）
      // 但 album/date 全空的檔案永遠不會被處理，RAG 就顯示「未知的專輯」。
      final t = (meta.title ?? '').trim();
      final a = (meta.artist ?? '').trim();
      final al = (meta.album ?? '').trim();
      final badTitle = t.isEmpty || t == _unknownTitle;
      final badArtist = a.isEmpty || a == _unknownArtist;
      final badAlbum = al.isEmpty || al == _unknownAlbum;
      // date 不在 TrackMetadata（ffprobe 沒讀），靠 year 流程補，
      // 這裡只挑 title/artist/album 缺任一者。
      if (badTitle || badArtist || badAlbum) missing.add(e.path);
    }
    return missing;
  }

  /// 佔位值（補 metadata 時可能寫進去的「未知的…」不算有效資料）。
  static const _unknownTitle = '未知的標題';
  static const _unknownArtist = '未知的演出者';
  static const _unknownAlbum = '未知的專輯';

  Future<bool> _enrichFile(String filePath, Map<String, Map<String, dynamic>> cacheIndex) async {
    final stem = File(filePath).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
    final meta = await MetadataReader.read(filePath);

    String? title = meta.title;
    String? artist = meta.artist;
    String? album;
    String? year;
    String? coverUrl;

// 佔位值視為「沒有」，要能被 cache / 檔名覆蓋。
    bool bad(String? v, String ph) =>
        v == null || v.trim().isEmpty || v.trim() == ph;
    if (bad(title, _unknownTitle)) title = null;
    if (bad(artist, _unknownArtist)) artist = null;

    // 1. Try Spotify cache (in-memory index, no IO here)
    final cached = _lookupSpotifyCache(stem, cacheIndex);
    if (cached != null) {
      title ??= cached['title'] as String?;
      artist ??= cached['artist'] as String?;
      album ??= cached['album'] as String?;
      coverUrl ??= cached['cover_url'] as String?;
      // 年份來源依序：release_date → CoverCache 的 'y'（artwork embedder 從
      // Spotify GQL albumOfTrack.date 寫入）。只認 4 位數。
      final rd = cached['release_date'] as String?;
      if (rd != null && rd.length >= 4) {
        year = rd.substring(0, 4);
      } else {
        try {
          final cc = await CoverCache.load();
          final key = CoverCache.key(null, title ?? fileNameFor(filePath),
              artist ?? '');
          final e = cc[key];
          if (e is Map) year = e['y'] as String?;
        } catch (_) {}
      }
    }

    // 2. If still no title/artist, try to extract from filename.
    // 檔名慣例是「曲名 - 歌手」（下載時 `${name} - ${artist}`），
    // 與 _titleFromPath/_artistFromPath 一致：第一段=曲名。
    final fileName = File(filePath).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
    if ((title == null || title.isEmpty) && fileName.contains(' - ')) {
      final parts = fileName.split(' - ');
      if (parts.length >= 2) {
        title = parts.first.trim();
        artist = parts.sublist(1).join(' - ').trim();
      }
    }

if (title == null || title.isEmpty) {
      title = fileName;
    }
    // album / artist 仍缺或還是佔位值 → 留空不要寫回去
    // （寫進去 RAG 又會顯示「未知的專輯」）
    if (album != null && album.trim() == _unknownAlbum) album = null;
    if (artist != null && artist.trim() == _unknownArtist) artist = null;

    // Apply metadata via ffmpeg
    return _applyMetadata(filePath, title, artist, album, year, coverUrl);
  }

  /// 一次把 spotify_cache 讀進記憶體（檔名 stem → 內容），之後全是記憶體比對。
  Future<Map<String, Map<String, dynamic>>> _loadSpotifyCacheIndex() async {
    final index = <String, Map<String, dynamic>>{};
    try {
      final base = ConfigService.instance.config.basePath;
      if (base.isEmpty) return index;
      final cacheDir = Directory('$base\\spotify_cache');
      if (!await cacheDir.exists()) return index;
      await for (final f in cacheDir.list()) {
        if (f is File && f.path.endsWith('.json')) {
          try {
            final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
            final key = File(f.path).uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
            index[key] = data;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return index;
  }

  Map<String, dynamic>? _lookupSpotifyCache(String stem, Map<String, Map<String, dynamic>> index) {
    if (index.isEmpty) return null;
    final hit = index[stem.toLowerCase()];
    if (hit != null) return hit;
    // Fuzzy fallback：只允許「長的那個包含短的」，且短的至少 6 字。
    // 舊寫法是雙向 contains 且無長度下限 → "BTS" 命中 ARIRANG、
    // "Body to Body - BTS" 配到 BTS 舊專輯 album，album 全錯。
    final stemKey = fuzzyKey(stem);
    if (stemKey.length < 6) return null;
    // 檔名「曲名 - 歌手」：曲名段拿來驗證命中，防止 artist's 短 token
    // 反向命中別的歌（Everything - BIDO 曾愷妤 曾被整筆 cache 覆蓋成
    // title=Everything/artist=BIDO，標籤錯置）。
    final stemTitle = fuzzyKey(
        stem.contains(' - ') ? stem.split(' - ').first : stem);
    for (final data in index.values) {
      final cacheKey = fuzzyKey(data['title'] as String? ?? '');
      if (cacheKey.length < 6) continue;
      final bool hit2 = stemKey.length >= cacheKey.length
          ? stemKey.contains(cacheKey)
          : cacheKey.contains(stemKey);
      if (!hit2) continue;
      // 曲名必須也相符（雙向包含，>=2 字才算），否則跳過這筆。
      if (stemTitle.length >= 2 && cacheKey.length >= 2 &&
          !stemTitle.contains(cacheKey) && !cacheKey.contains(stemTitle)) {
        continue;
      }
      return data;
    }
    return null;
  }

  /// 模糊比對用正規化 key：小寫、去空白與標點，只留字母數字。
  /// 公開是為了測試（純函式，無副作用）。
  static final _fuzzyStrip = RegExp(
      "[\\s\\-_·、,，.。!！?？:：;；\"'（）()\\[\\]【】]");
  static String fuzzyKey(String s) =>
      s.toLowerCase().replaceAll(_fuzzyStrip, '');

  /// 組 `-metadata k=v` 參數（帶封面失敗時的退回路徑也用同一份）。
  ///
  /// 規則：
  /// - artist 過 ArtistNames 轉中文（對照表有才轉，不臆測日本/歐美藝人）
  /// - date 必須 4 位數：其他值寧可不寫（空 date 會讓播放器顯示 1970）
  static List<String> _tagArgs(
      String? title, String? artist, String? album, String? year) {
    final out = <String>[];
    if (title != null && title.isNotEmpty) {
      out.addAll(['-metadata', 'title=$title']);
    }
    final artistOut = (artist != null && artist.isNotEmpty)
        ? ArtistNames.toDisplayList(artist)
        : artist;
    if (artistOut != null && artistOut.isNotEmpty) {
      out.addAll(['-metadata', 'artist=$artistOut']);
    }
    if (album != null && album.isNotEmpty) {
      out.addAll(['-metadata', 'album=$album']);
    }
    final y = year?.trim() ?? '';
    if (RegExp(r'^(1\d{3}|2\d{3})$').hasMatch(y)) {
      out.addAll(['-metadata', 'date=$y']);
    }
    return out;
  }

  Future<bool> _applyMetadata(
    String filePath,
    String? title,
    String? artist,
    String? album,
    String? year,
    String? coverUrl,
  ) async {
    try {
      // 組參數：先決定 map/codec，再加 metadata，最後才放輸出路徑。
      // 舊寫法用 removeLast() 想移除「還沒加進去的輸出路徑」→ 命令結構壞掉，
      // ffmpeg 報 "Output same as Input"，每次寫入都失敗。
      final hadArt = await _hasArtwork(filePath);
      final tmpPath = '$filePath.meta_tmp.mp3';

      final args = <String>['-y', '-i', filePath];
      if (hadArt) {
        // 有封面：音訊+視訊都帶過去（只 map 0:a 會把封面洗掉）。
        // `-c:v copy` 而非 mjpeg：有些封面 stream 解碼會失敗
        // （exit=69 "Terminating thread ... Invalid data"），copy 直接搬位元組不碰編碼。
        args.addAll([
          '-map', '0:a', '-map', '0:v',
          '-c:a', 'copy', '-c:v', 'copy', '-id3v2_version', '3',
          '-metadata:s:v', 'title=Album cover',
          '-metadata:s:v', 'comment=Cover (front)',
        ]);
      } else {
        args.addAll(['-map', '0:a', '-c:a', 'copy']);
      }
      args.addAll(_tagArgs(title, artist, album, year));
      args.add(tmpPath);

      // runInShell: false：中文 artist 經 cmd.exe 會被引號吃掉
      final r = await Process.run(_ffmpegPath(), args,
          runInShell: false, stdoutEncoding: null);

      if (r.exitCode != 0 || !await File(tmpPath).exists()) {
        // 帶封面失敗最常見是「dimensions not set」（PNG 封面或缺尺寸資訊的
        // JPEG），音訊本身沒事 → 退回只寫音訊：metadata 優先於封面。
        if (hadArt) {
          final out2 = File('$filePath.meta_tmp2.mp3');
          final retry = await Process.run(
            _ffmpegPath(),
            [
              '-y', '-i', filePath, '-map', '0:a', '-c:a', 'copy',
              ..._tagArgs(title, artist, album, year),
              out2.path,
            ],
            runInShell: false,
            stdoutEncoding: null,
          );
          if (retry.exitCode == 0 && await out2.exists()) {
            await File(filePath).delete();
            await out2.rename(filePath);
            log('  ✅ 已更新 metadata（封面保留失敗，僅寫標籤）: '
                '${File(filePath).uri.pathSegments.last}');
            return true;
          }
          if (await out2.exists()) await out2.delete();
        }
        final lines = (r.stderr is String
                ? r.stderr as String
                : utf8.decode(r.stderr as List<int>, allowMalformed: true))
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        // 真錯誤在最後（開頭是 ffmpeg 版權 banner）
        final tail = lines.length <= 4
            ? lines.join(' | ')
            : lines.sublist(lines.length - 4).join(' | ');
        log('  ⚠️ ffmpeg 失敗 exit=${r.exitCode}: $tail');
        if (await File(tmpPath).exists()) await File(tmpPath).delete();
        return false;
      }
      await File(filePath).delete();
      await File(tmpPath).rename(filePath);
      log('  ✅ 已更新 metadata: ${File(filePath).uri.pathSegments.last}');
      return true;
    } catch (e) {
      log('  ⚠️ Metadata 寫入錯誤: $e');
      return false;
    }
  }

  /// 有沒有內嵌封面（ffprobe 找 image stream）。
  Future<bool> _hasArtwork(String path) async {
    try {
      final r = await Process.run(_ffprobePath(), [
        '-v', 'quiet', '-print_format', 'json', '-show_streams', path,
      ], runInShell: false);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final streams = j['streams'] as List<dynamic>? ?? [];
      return streams.any((s) =>
          (s is Map) &&
          (s['codec_type'] == 'video' || s['codec_type'] == 'image'));
    } catch (_) {
      return false;
    }
  }
}
