/// 可行性實驗：youtube_explode + Groq + Ollama + LRCLib
/// MediaKit 需要 libmpv（桌面 CI/手機自動打包），改用 Dart 單元直接測 API
library;
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

final log = Logger(printer: PrettyPrinter(methodCount: 0));

void main() {
  // ============================================================
  // 實驗 1: youtube_explode 搜尋 + 取串流 URL + 播放驗證
  // ============================================================
  test('YouTube: 搜尋 + 取音訊串流 URL + HEAD 驗證', () async {
    final ytdl = YoutubeExplode();
    try {
      final searchList = await ytdl.search.search('Never Gonna Give You Up');
      expect(searchList.isNotEmpty, true, reason: '搜尋有結果');
      final first = searchList.first;
      log.i('✅ 搜尋結果: "${first.title}" by ${first.author} (${first.id})');

      final manifest = await ytdl.videos.streams.getManifest(first.id);
      final audioOnly = manifest.audioOnly.sortByBitrate();
      expect(audioOnly.isNotEmpty, true, reason: '有音訊串流');

      final best = audioOnly.last;
      log.i('✅ 最佳音訊: bitrate=${best.bitrate}, '
          'container=${best.container}, url=${best.url.toString().substring(0, 80)}...');

      final resp = await http.head(best.url);
      expect(resp.statusCode, 200, reason: '音訊 URL 可達');
      log.i('✅ 音訊 URL HEAD 回應 200，串流可行');
    } finally {
      ytdl.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ============================================================
  // 實驗 2: Groq REST API（原生 Dart HTTP）
  // ============================================================
  test('Groq API: 原生 HTTP 呼叫', () async {
    const apiKey = String.fromEnvironment('GROQ_API_KEY', defaultValue: '');
    if (apiKey.isEmpty) {
      log.i('⚠️ 跳過：未提供 GROQ_API_KEY（-D GROQ_API_KEY=xxx）');
      return;
    }

    final resp = await http.post(
      Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'llama-3.1-8b-instant',
        'messages': [{'role': 'user', 'content': 'Say hello in 5 words'}],
        'max_tokens': 20,
      }),
    );

    log.i('Groq 回應: ${resp.statusCode} ${resp.body.substring(0, 200)}');
    expect(resp.statusCode, 200, reason: 'Groq API 回應正常');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ============================================================
  // 實驗 3: Ollama REST API（原生 Dart HTTP）
  // ============================================================
  test('Ollama API: 原生 HTTP 呼叫', () async {
    try {
      final resp = await http.get(
        Uri.parse('http://127.0.0.1:11434/api/tags'),
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final models = (data['models'] as List?) ?? [];
        log.i('✅ Ollama 已連線，模型數: ${models.length}');
        for (final m in models.take(5)) {
          log.i('  - ${m['name']}');
        }
      } else {
        log.i('⚠️ Ollama 回應非 200: ${resp.statusCode}');
      }
    } catch (e) {
      log.i('⚠️ Ollama 未運行或不可達: $e');
    }
  }, timeout: const Timeout(Duration(seconds: 10)));

  // ============================================================
  // 實驗 4: LRCLib.net 歌詞 API
  // ============================================================
  test('LRCLib: 歌詞 API（同步 + 非同步）', () async {
    final resp = await http.get(Uri.parse(
      'https://lrclib.net/api/get?artist_name=Rick+Astley'
      '&track_name=Never+Gonna+Give+You+Up'
      '&album_name=Whenever+You+Need+Somebody'
      '&duration=213',
    ));

    log.i('LRCLib 回應: ${resp.statusCode}');
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      final synced = data['syncedLyrics'] as String?;
      final plain = data['plainLyrics'] as String?;
      log.i('✅ 同步歌詞: ${synced != null ? "${synced.length} chars" : "無"}');
      log.i('✅ 非同步歌詞: ${plain != null ? "${plain.length} chars" : "無"}');
      expect(synced != null || plain != null, true, reason: '至少一種歌詞');
    } else {
      log.i('回應: ${resp.body.substring(0, 300)}');
      fail('LRCLib API 失敗: ${resp.statusCode}');
    }
  }, timeout: const Timeout(Duration(seconds: 15)));
}
