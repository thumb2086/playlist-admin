import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/groq_native_service.dart';

/// Groq 端點選擇回歸：留空走官方、有值走自建 router（OpenAI 相容 /v1）。
void main() {
  test('apiUrl：官方基底', () {
    expect(GroqNativeService.apiUrl('/audio/transcriptions', ''),
        'https://api.groq.com/openai/v1/audio/transcriptions');
    expect(GroqNativeService.apiUrl('/chat/completions', '   '),
        'https://api.groq.com/openai/v1/chat/completions');
  });

  test('apiUrl：自建 router（尾斜線正規化）', () {
    expect(GroqNativeService.apiUrl('/audio/transcriptions', 'https://x.vercel.app'),
        'https://x.vercel.app/v1/audio/transcriptions');
    expect(GroqNativeService.apiUrl('/audio/transcriptions', 'https://x.vercel.app/'),
        'https://x.vercel.app/v1/audio/transcriptions');
    expect(GroqNativeService.apiUrl('/chat/completions', 'https://x.vercel.app//'),
        'https://x.vercel.app/v1/chat/completions');
  });
}
