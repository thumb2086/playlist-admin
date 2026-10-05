import 'dart:io';
import 'config_service.dart';
import 'playlist_parser.dart';
import 'fs_paths.dart';

/// 歌單整理：歌單內的歌曲留在原位（既有 m3u8 路徑全部不變），
/// 不在任何歌單的歌曲移入 `music\未分類\` 子資料夾，
/// 並重寫 `_Unsorted.m3u8`（路徑改指新位置，Echo/手機播放器相容）。
///
/// 「歌單內」定義：出現在任何**非 _unsorted** 的 m3u8（含 _favorites /
/// _single tracks — 使用者刻意收藏的也留原位）；`_unsorted` 自身不算，
/// 否則永遠沒有東西可移。重跑是冪等的（只處理 top-level，目標已存在就跳過）。
class LibraryOrganizer {
  static const unsortedDirName = '未分類';

  static Future<({int moved, int kept, int conflict})> organize(
      {void Function(String)? log}) async {
    final cfg = ConfigService.instance.config;
    final musicDir = Directory(cfg.musicPath);
    final plDir = Directory(cfg.playlistsPath);
    const audioExt = {'.mp3', '.m4a', '.flac', '.wav', '.mp4', '.ogg', '.aac'};

    // 1) 保留集合：非 _unsorted 的 m3u8 內所有曲目 stem。
    final keep = <String>{};
    if (await plDir.exists()) {
      await for (final e in plDir.list(followLinks: false)) {
        if (e is! File) continue;
        final fname = e.uri.pathSegments.last.toLowerCase();
        if (!fname.endsWith('.m3u8') && !fname.endsWith('.m3u')) continue;
        if (fname.contains('_unsorted')) continue;
        try {
          for (final name in PlaylistParser.parseTrackNames(e.path)) {
            final stem = name.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
            if (stem.isNotEmpty) keep.add(stem);
          }
        } catch (_) {}
      }
    }

    if (!await musicDir.exists()) return (moved: 0, kept: keep.length, conflict: 0);

    // 2) 只掃 top-level（子資料夾不動）：歌單內留原位，其餘移入 未分類。
    final unsortedDir =
        Directory(joinPath(cfg.musicPath, unsortedDirName));
    int moved = 0, kept = 0, conflict = 0;
    await for (final f in musicDir.list(followLinks: false)) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      final extIdx = name.lastIndexOf('.');
      if (extIdx <= 0) continue;
      if (!audioExt.contains(name.substring(extIdx).toLowerCase())) continue;
      final stem = name.substring(0, extIdx).toLowerCase();
      if (keep.contains(stem)) {
        kept++;
        continue;
      }
      await unsortedDir.create(recursive: true);
      final target = joinPath(unsortedDir.path, name);
      if (File(target).existsSync()) {
        conflict++; // 同名已在目標：跳過（不覆蓋）
        continue;
      }
      try {
        await f.rename(target);
        moved++;
      } catch (e) {
        log?.call('  ❌ 移動失敗 $name: $e');
        conflict++;
      }
    }

    // 3) 重寫 _Unsorted.m3u8 → 全部指向 未分類 子資料夾（與 Step4 同格式：
    //    #EXTINF + 相對路徑（正斜線、不編碼，Echo 直讀）。
    try {
      final files = <String>[];
      if (await unsortedDir.exists()) {
        await for (final f in unsortedDir.list(followLinks: false)) {
          if (f is File) files.add(f.uri.pathSegments.last);
        }
      }
      files.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final sb = StringBuffer('#EXTM3U\n');
      for (final name in files) {
        final stem = name.replaceAll(RegExp(r'\.\w+$'), '');
        sb.writeln('#EXTINF:-1,$stem');
        sb.writeln('../music/$unsortedDirName/$name');
      }
      final unsortedFile =
          File(joinPath(cfg.playlistsPath, '_Unsorted.m3u8'));
      await unsortedFile.writeAsString(sb.toString(), flush: true);
      log?.call('  📋 _Unsorted.m3u8 已重寫（${files.length} 首 → music\\$unsortedDirName\\）');
    } catch (e) {
      log?.call('  ❌ 重寫 _Unsorted.m3u8 失敗: $e');
    }

    // 4) 修復其他歌單中指向已移動檔案的路徑行。
    //    部分 m3u8 有「沒被 #EXTINF 包住的裸路徑行」，parseTrackNames 看不見、
    //    但 Echo 會讀 → 這些條目若指向已移動檔案會失效。只改路徑行，
    //    #EXTINF 標題行不動。冪等：值相同不寫。
    try {
      final movedMap = <String, String>{};
      if (await unsortedDir.exists()) {
        await for (final f in unsortedDir.list(followLinks: false)) {
          if (f is File) {
            final n = f.uri.pathSegments.last;
            final stem = n.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
            movedMap[stem] = n;
          }
        }
      }
      int repairedFiles = 0;
      await for (final e in plDir.list(followLinks: false)) {
        if (e is! File) continue;
        final fname = e.uri.pathSegments.last;
        final low = fname.toLowerCase();
        if ((!low.endsWith('.m3u8') && !low.endsWith('.m3u')) || low.contains('_unsorted')) {
          continue;
        }
        String content;
        try {
          content = await e.readAsString();
        } catch (_) {
          continue;
        }
        final lines = content.split('\n');
        bool changed = false;
        for (int i = 0; i < lines.length; i++) {
          final raw = lines[i].trim();
          if (raw.isEmpty || raw.startsWith('#')) continue;
          String decoded = raw;
          try { decoded = Uri.decodeComponent(raw); } catch (_) {}
          final base = decoded.split(RegExp(r'[\\/]')).last;
          final stem = base.replaceAll(RegExp(r'\.\w+$'), '').toLowerCase();
          final movedName = movedMap[stem];
          if (movedName == null) continue;
          final newline = '../music/$unsortedDirName/$movedName';
          if (raw != newline) {
            lines[i] = newline;
            changed = true;
          }
        }
        if (changed) {
          await e.writeAsString(lines.join('\n'), flush: true);
          repairedFiles++;
          log?.call('  🔧 修復歌單路徑: $fname');
        }
      }
      if (repairedFiles > 0) {
        log?.call('  🔧 共修復 $repairedFiles 份歌單的失效路徑');
      }
    } catch (e) {
      log?.call('  ❌ 修復歌單路徑失敗: $e');
    }

    log?.call('✅ 整理完成：歌單保留 $kept 首、移入未分類 $moved 首'
        '${conflict > 0 ? '、衝突跳過 $conflict' : ''}');
    return (moved: moved, kept: kept, conflict: conflict);
  }
}
