import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/services/config_service.dart';
import 'package:playlist_admin/services/groq_service.dart';

/// Groq router 真實轉錄 E2E（app 全鏈：config → GroqService → native → router → Groq）。
/// 需先設定 groq_base_url；跑法：set GROQ_E2E=1 後 flutter test。
void main() {
  test('app 轉錄走自建 router', () async {
    // 不建 TestWidgetsFlutterBinding：它會把 HttpClient 擋成 400（全 mock）。
    await ConfigService.instance.load();
    final cfg = ConfigService.instance.config;
    expect(cfg.groqBaseUrl, contains('vercel.app'),
        reason: 'config.groq_base_url 需指向 router');
    expect(cfg.groqApiKey, isNotEmpty, reason: 'config.groq_api_key 需填 router token');

    // 挑最小 mp3 當測資。
    final podDir = Directory('${cfg.basePath}${Platform.pathSeparator}podcasts');
    File? best;
    if (podDir.existsSync()) {
      for (final f in podDir.listSync(recursive: true)) {
        if (f is File && f.path.toLowerCase().endsWith('.mp3')) {
          if (best == null || f.lengthSync() < best.lengthSync()) best = f;
        }
      }
    }
    expect(best, isNotNull, reason: 'podcasts 下要有 mp3');
    final sw = Stopwatch()..start();

    GroqService.instance.setApiKey(cfg.groqApiKey);
    final text = await GroqService.instance.transcribeFile(
      filePath: best!.path,
      model: GroqService.instance.defaultModel,
    );
    // ignore: avoid_print
    print('transcribed ${best.lengthSync()} bytes in ${sw.elapsedMilliseconds}ms, '
        '${text.length} chars, head: ${text.substring(0, text.length.clamp(0, 60))}');
    expect(text, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)),
      skip: Platform.environment['GROQ_E2E'] == '1'
          ? false
          : '網路探針（會打 router/Groq）：set GROQ_E2E=1 再跑');
}
