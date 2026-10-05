import 'dart:convert';
import 'dart:io';
import 'config_service.dart';

/// 封面/時長/專輯磁碟快取（cache/spotify/cover_cache.json）。
/// 詳情頁 enrichment 寫入；播放器讀取（播放列/SMTC 不再全靠呼叫端帶圖）。
class CoverCache {
  static Map<String, dynamic>? _mem;

  /// 封面快取 key：ISRC 優先（統一小寫，防大小寫分叉），否則正規化「曲名 - 歌手」。
  static String key(String? isrc, String name, String artist) {
    if (isrc != null && isrc.isNotEmpty) {
      return 'isrc:${isrc.toLowerCase()}';
    }
    return 't:${norm('$name - $artist')}';
  }

  /// 正規化：小寫，只留英數 + CJK（檔名 sanitizer 換掉的標點兩邊一起消掉）。
  static String norm(String s) => s.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fff\u3400-\u4dbf㐀-䶿豈-﫿]'), '');

  static Future<Map<String, dynamic>> load() async {
    if (_mem != null) return _mem!;
    try {
      final f = File('${ConfigService.instance.config.spotifyCachePath}'
          '${Platform.pathSeparator}cover_cache.json');
      if (await f.exists()) {
        _mem = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        // 一次性遷移：舊 key `isrc:大寫` 改小寫（key() 已統一小寫，
        // 不遷則舊條目永遠 miss、白白重抓一次 GQL）。
        var dirty = false;
        for (final k in _mem!.keys.toList()) {
          if (k.startsWith('isrc:') && k != k.toLowerCase()) {
            if (!_mem!.containsKey(k.toLowerCase())) {
              _mem![k.toLowerCase()] = _mem![k];
            }
            _mem!.remove(k);
            dirty = true;
          }
        }
        if (dirty) {
          try {
            await f.writeAsString(jsonEncode(_mem));
          } catch (_) {}
        }
        return _mem!;
      }
    } catch (_) {}
    _mem = {};
    return _mem!;
  }

  static Future<void> save(Map<String, dynamic> cache) async {
    _mem = cache;
    try {
      final dir = Directory(ConfigService.instance.config.spotifyCachePath);
      await dir.create(recursive: true);
      await File('${dir.path}${Platform.pathSeparator}cover_cache.json')
          .writeAsString(jsonEncode(cache));
    } catch (_) {}
  }
}
