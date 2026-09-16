import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Ollama REST API 原生 Dart 客戶端（取代 Python bridge）。
/// 直接呼叫本地 Ollama API，不需要 Python。
class OllamaNativeService {
  OllamaNativeService._();
  static final instance = OllamaNativeService._();

  String baseUrl = 'http://127.0.0.1:11434';
  bool _connected = false;
  bool get isConnected => _connected;

  /// 檢查 Ollama 是否運行中。
  Future<bool> checkConnection() async {
    try {
      final resp = await http.get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
      _connected = resp.statusCode == 200;
      return _connected;
    } catch (_) {
      _connected = false;
      return false;
    }
  }

  /// 取得已安裝的模型列表。
  Future<List<String>> listModels() async {
    try {
      final resp = await http.get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final models = (data['models'] as List?) ?? [];
      return models.map<String>((m) => m['name'] as String).toList();
    } catch (_) {
      return [];
    }
  }
  /// 串流式問答（逐 token 回傳）：streamed request + NDJSON 逐行 parse。
  /// 舊寫法 stream:false + http.post，要等整段生完（最長 300s）才吐一次。
  Stream<String> chatStream(String prompt, {String? model, List<Map<String, String>>? history}) async* {
    final chosenModel = model ?? await _pickModel();
    if (chosenModel == null) throw Exception('無可用模型');

    final msgs = <Map<String, String>>[];
    if (history != null) msgs.addAll(history);
    msgs.add({'role': 'user', 'content': prompt});

    final client = http.Client();
    try {
      final req = http.Request('POST', Uri.parse('$baseUrl/api/chat'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'model': chosenModel,
          'messages': msgs,
          'stream': true,
        });
      // connect 30s（TTFT 含冷啟動載模型放寬到 120s），之後每行 120s。
      final resp = await client.send(req).timeout(const Duration(seconds: 120));
      if (resp.statusCode != 200) {
        throw Exception('Ollama 回應 ${resp.statusCode}');
      }
      await for (final line in resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 120))) {
        final t = line.trim();
        if (t.isEmpty) continue;
        try {
          final data = jsonDecode(t) as Map<String, dynamic>;
          final content = (data['message'] as Map?)?['content'] as String?;
          if (content != null && content.isNotEmpty) yield content;
          if (data['done'] == true) break;
        } catch (_) {}
      }
    } finally {
      client.close();
    }
  }

  /// 非串流式問答。
  Future<String> chat(String prompt, {String? model, List<Map<String, String>>? history}) async {
    final sb = StringBuffer();
    await for (final token in chatStream(prompt, model: model, history: history)) {
      sb.write(token);
    }
    return sb.toString();
  }

  /// 產生 embeddings（用於 RAG）。
  Future<List<double>> embed(String text, {String? model}) async {
    final chosenModel = model ?? 'nomic-embed-text';
    final resp = await http.post(
      Uri.parse('$baseUrl/api/embeddings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': chosenModel,
        'prompt': text,
      }),
    ).timeout(const Duration(seconds: 60));

    if (resp.statusCode != 200) {
      throw Exception('Ollama embed 失敗: ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body);
    // embedding 可能是 int list（小模型量化輸出）：逐個轉 double，
    // cast<double>() 遇到 int 直接拋。
    final raw = data['embedding'] as List?;
    if (raw == null) return [];
    return raw.map((e) => (e as num).toDouble()).toList();
  }

  Future<String?> _pickModel() async {
    final models = await listModels();
    if (models.isEmpty) return null;
    // 偏好通用對話模型。
    const preferred = ['llama3.1', 'llama3', 'qwen2.5', 'gemma2', 'mistral'];
    for (final p in preferred) {
      final match = models.where((m) => m.toLowerCase().contains(p));
      if (match.isNotEmpty) return match.first;
    }
    return models.first;
  }
}
