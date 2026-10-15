import 'dart:convert';
import 'dart:io';

import 'config_service.dart';
import 'groq_service.dart';

/// 逐字稿／音訊庫健康檢查（`playlist-admin doctor`）。
///
/// 為什麼需要這個工具：2026-10-15 一整天修掉 12 個 bug，其中 **8 個是
/// pipeline 回報「✅ 成功」但資料其實是壞的**：
///
///   - 83 個音檔本身損毀（MP3 檔頭宣稱 49 分鐘，實際只有 2.9 分鐘）
///   - 分段檔名互相覆蓋 → 逐字稿只剩結尾語（「這集錄到這邊，下次再見」）
///   - YouTube 字幕被自動翻譯成英文 → 中文節目變英文全文
///   - 字幕只覆蓋開頭 → 141 字的「逐字稿」
///
/// 「檔案存在」完全不等於「資料正確」。這個工具用**獨立的標準**重新驗：
///   1. 覆蓋率      —— 每個音檔是否有有效逐字稿（> 200 bytes）
///   2. 音訊完整性  —— 實際可解碼長度 vs 檔頭宣稱長度
///   3. 內容密度    —— 中文字數 ÷ 音訊秒數（語速最慢 1 字/秒）
///   4. 語言一致性  —— 中文為主的節目，逐字稿是否以中文為主
///   5. STT 額度    —— 探一下中轉現在還能不能轉錄
class DoctorReport {
  int totalAudio = 0;
  int withTranscript = 0;
  int missingTranscript = 0;
  int corruptAudio = 0;
  int truncatedTranscript = 0;
  int wrongLanguage = 0;

  final List<String> corruptFiles = [];
  final List<String> truncatedFiles = [];
  final List<String> wrongLangFiles = [];
  final Map<String, int> perPodcast = {};

  /// 中文語速（字/秒）中位數。
  double medianRate = 0;

  /// 有問題、需要重做的集數總計。
  int get needsWork => missingTranscript + corruptAudio +
      truncatedTranscript + wrongLanguage;

  bool get isHealthy => needsWork == 0;
}

class LibraryDoctor {
  LibraryDoctor._();

  static const _audioExts = ['.mp3', '.wav', '.m4a'];
  static const _minTxtBytes = 200;
  /// 實際可解碼長度低於宣稱長度的這個比例 → 判定音檔損毀。
  static const _corruptRatio = 0.90;

  static final _cjk = RegExp(r'[\u4e00-\u9fff]');
  static final _enWords =
      RegExp(r'\b(the|and|of|to|in|is|that|for|with|this|you|we|it)\b',
          caseSensitive: false);

  /// 跑完整檢查。[onProgress] 回報 (已完成, 總數)。
  static Future<DoctorReport> run({
    required String podcastsDir,
    int workers = 6,
    bool skipAudioProbe = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final report = DoctorReport();
    final files = <File>[];
    final podcasts = Directory(podcastsDir);
    if (!podcasts.existsSync()) {
      stderr.writeln('找不到目錄: $podcastsDir');
      return report;
    }

    for (final d in podcasts.listSync()) {
      if (d is! Directory) continue;
      for (final f in d.listSync()) {
        if (f is! File) continue;
        final p = f.path.toLowerCase();
        if (_audioExts.any(p.endsWith)) files.add(f);
      }
    }
    report.totalAudio = files.length;

    var done = 0;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= files.length) return;
        final f = files[i];
        final stem = f.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
        final dir = f.parent.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;

        // 1) 覆蓋率
        final txt = File('${f.parent.path}${Platform.pathSeparator}$stem.txt');
        var hasTxt = false;
        String? body;
        if (txt.existsSync() && txt.lengthSync() > _minTxtBytes) {
          hasTxt = true;
          report.withTranscript++;
          try {
            body = txt.readAsStringSync();
          } catch (_) {
            body = null;
          }
        } else {
          report.missingTranscript++;
        }
        report.perPodcast[dir] = (report.perPodcast[dir] ?? 0) + (hasTxt ? 1 : 0);

        // 2) 音訊完整性 + 3) 內容密度
        final dur = skipAudioProbe
            ? (hdr: 0.0, real: 0.0)
            : await _probeDuration(f.path, false);
        if (dur.hdr > 0 && dur.real > 0 &&
            dur.real < dur.hdr * _corruptRatio) {
          report.corruptAudio++;
          report.corruptFiles.add('$dir / ${f.uri.pathSegments.last}');
        }

        if (body != null && dur.hdr > 0) {
          final cjk = _cjk.allMatches(body).length;
          if (cjk < dur.hdr) {
            report.truncatedTranscript++;
            report.truncatedFiles
                .add('$dir / ${f.uri.pathSegments.last}  ($cjk 字 / ${dur.hdr.round()} 秒)');
          }
          // 4) 語言一致性：中文為主的節目卻整份英文 = 被自動翻譯
          if (cjk == 0) {
            final en = _enWords.allMatches(body).length;
            if (en > 20) {
              report.wrongLanguage++;
              report.wrongLangFiles
                  .add('$dir / ${f.uri.pathSegments.last}  ($en 英文詞, 0 中文)');
            }
          }
        }

        done++;
        if (onProgress != null && done % 200 == 0) {
          onProgress(done, files.length);
        }
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    onProgress?.call(files.length, files.length);
    return report;
  }

  /// 回傳 (宣稱時長, 實際可解碼到哪)。用 packet 時間戳（不解碼）→ 快很多。
  static Future<({double hdr, double real})> _probeDuration(
      String path, bool skipProbe) async {
    final ffprobe = _ffprobePath();
    try {
      final r = await Process.run(ffprobe, [
        '-v', 'error',
        '-select_streams', 'a:0',
        '-show_entries', 'format=duration',
        '-show_entries', 'packet=pts_time',
        '-of', 'json',
        path,
      ], runInShell: false);
      final raw = r.stdout is String
          ? r.stdout as String
          : utf8.decode((r.stdout as List<int>?) ?? const [],
              allowMalformed: true);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final hdr = double.tryParse(
              ((j['format'] as Map<String, dynamic>?)?['duration'] as String?) ??
              '') ??
          0;
      if (skipProbe) return (hdr: hdr, real: hdr.toDouble());
      final pkts = (j['packets'] as List?) ?? const [];
      var real = 0.0;
      if (pkts.isNotEmpty) {
        final last = pkts.last as Map<String, dynamic>;
        real = double.tryParse(last['pts_time'] as String? ?? '') ?? 0;
      }
      return (hdr: hdr, real: real == 0 ? hdr : real);
    } catch (_) {
      return (hdr: 0.0, real: 0.0);
    }
  }

  static String _ffprobePath() {
    final f = ConfigService.instance.config.resolvedFfmpegPath;
    if (f.toLowerCase().endsWith('ffmpeg.exe')) {
      return '${f.substring(0, f.length - 10)}ffprobe.exe';
    }
    return 'ffprobe';
  }

  /// 探一下 STT 中轉現在能不能轉錄（1 秒音訊，幾乎不花額度）。
  ///
  /// 教訓：2026-10-15 我從 log 推論「所有 Groq key 都撞上限」就停掉整個
  /// pipeline，後來實測中轉 6/6 成功——推論代替實測害我誤停。
  /// 所以「額度夠不夠」永遠要實際探，不要猜。
  static Future<String> probeStt({Duration timeout = const Duration(seconds: 90)}) async {
    final svc = GroqService.instance;
    try {
      await svc.loadFromEnv();
      if (ConfigService.instance.config.groqApiKey.isNotEmpty) {
        svc.setApiKey(ConfigService.instance.config.groqApiKey);
      }
      final f = File('${Directory.systemTemp.path}\\doctor_probe.mp3');
      if (!f.existsSync()) {
        final r = await Process.run(
            ConfigService.instance.config.resolvedFfmpegPath, [
          '-y', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono',
          '-t', '1', '-c:a', 'libmp3lame', '-b:a', '32k', f.path,
        ]);
        if (r.exitCode != 0) return '無法產生探針音訊（ffmpeg 不可用）';
      }
      final t0 = DateTime.now();
      final text = await svc.transcribeFile(
        filePath: f.path,
        model: 'whisper-large-v3-turbo',
        language: 'zh',
      );
      final ms = DateTime.now().difference(t0).inMilliseconds;
      try { f.deleteSync(); } catch (_) {}
      return '可用（${text.trim().length} 字, ${ms}ms）';
    } catch (e) {
      return '不可用：${e.toString().split('\n').first.substring(0, e.toString().length > 140 ? 140 : e.toString().length)}';
    }
  }

  /// 人類可讀的報告。
  static String format(DoctorReport r, {bool verbose = false}) {
    final b = StringBuffer();
    final pct = r.totalAudio == 0 ? 0.0 : 100.0 * r.withTranscript / r.totalAudio;
    b.writeln('=== 音訊庫健康檢查 ===');
    b.writeln('');
    b.writeln('音檔總數        = ${r.totalAudio}');
    b.writeln('有逐字稿        = ${r.withTranscript}  '
        '(${(pct).toStringAsFixed(2)}%)');
    b.writeln('缺逐字稿        = ${r.missingTranscript}');
    b.writeln('');
    b.writeln('音訊完整性（實際可解碼 vs 檔頭宣稱）');
    b.writeln('  損毀          = ${r.corruptAudio}');
    b.writeln('');
    b.writeln('逐字稿品質（中文字數 vs 音訊秒數，門檻 1 字/秒）');
    b.writeln('  疑似截斷      = ${r.truncatedTranscript}');
    b.writeln('');
    b.writeln('語言一致性');
    b.writeln('  疑似被翻譯   = ${r.wrongLanguage}');
    b.writeln('');

    if (verbose) {
      if (r.corruptFiles.isNotEmpty) {
        b.writeln('--- 損毀音檔 ---');
        for (final f in r.corruptFiles.take(30)) {
          b.writeln('  $f');
        }
        if (r.corruptFiles.length > 30) {
          b.writeln('  ... 另 ${r.corruptFiles.length - 30} 個');
        }
        b.writeln('');
      }
      if (r.truncatedFiles.isNotEmpty) {
        b.writeln('--- 疑似截斷的逐字稿 ---');
        for (final f in r.truncatedFiles.take(30)) {
          b.writeln('  $f');
        }
        if (r.truncatedFiles.length > 30) {
          b.writeln('  ... 另 ${r.truncatedFiles.length - 30} 個');
        }
        b.writeln('');
      }
      if (r.wrongLangFiles.isNotEmpty) {
        b.writeln('--- 被自動翻譯成英文 ---');
        for (final f in r.wrongLangFiles.take(30)) {
          b.writeln('  $f');
        }
        b.writeln('');
      }
    }

    b.writeln(r.isHealthy
        ? '✅ 全部通過'
        : '⚠️  有 ${r.needsWork} 個項目需要處理');
    return b.toString();
  }
}

