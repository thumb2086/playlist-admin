import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;

class ChineseConverter {
  static ChineseConverter? _instance;
  Map<String, String>? _s2t;  // simplified -> traditional
  Map<String, String>? _t2s;  // traditional -> simplified
  List<String>? _sKeys;
  List<String>? _tKeys;

  ChineseConverter._();

  static ChineseConverter get instance => _instance ??= ChineseConverter._();

  bool get isLoaded => _s2t != null;

  Future<void> load() async {
    if (_s2t != null) return;
    String data;
    try {
      data = await rootBundle.loadString('assets/s2t_opencc.json');
    } catch (_) {
      try {
        final file = File('assets/s2t_opencc.json');
        data = await file.readAsString();
      } catch (_) {
        final file = File('${Directory.current.path}\\assets\\s2t_opencc.json');
        data = await file.readAsString();
      }
    }
    // 扁平 { 簡: 繁 }（由 tools/gen_s2t.py 以 OpenCC s2tw 產生：
    // 2772 單字 + 1522 詞組，詞組層處理 头发→頭髮 這類逐字轉會錯的個案）。
    // 舊版讀 zhcdict.json 只撈到 SIMPONLY/TRADONLY 兩個字串，等於沒轉。
    final map = jsonDecode(data) as Map<String, dynamic>;

    _s2t = {};
    _t2s = {};
    for (final e in map.entries) {
      if (e.value is! String) continue;
      _s2t![e.key] = e.value as String;
      _t2s![e.value as String] = e.key;
    }

    // Sort keys by length descending for longest-prefix-match
    _sKeys = _s2t!.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    _tKeys = _t2s!.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  String _convert(String text, Map<String, String> dict, List<String> sortedKeys) {
    if (text.isEmpty) return text;
    final buf = StringBuffer();
    int i = 0;
    while (i < text.length) {
      bool matched = false;
      for (final key in sortedKeys) {
        if (i + key.length <= text.length && text.substring(i, i + key.length) == key) {
          buf.write(dict[key]!);
          i += key.length;
          matched = true;
          break;
        }
      }
      if (!matched) {
        buf.write(text[i]);
        i++;
      }
    }
    return buf.toString();
  }

  String toSimplified(String text) {
    if (_t2s == null || _tKeys == null) return text;
    return _convert(text, _t2s!, _tKeys!);
  }

  String toTraditional(String text) {
    if (_s2t == null || _sKeys == null) return text;
    return _convert(text, _s2t!, _sKeys!);
  }
}
