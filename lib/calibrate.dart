import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'services/app_data_dir.dart';

int? _foundHwnd;

int _enumFindSpotube(int h, int param) {
  final len = GetWindowTextLength(h) + 1;
  final buf = calloc<Uint16>(len);
  GetWindowText(h, buf.cast<Utf16>(), len);
  final title = buf.cast<Utf16>().toDartString();
  calloc.free(buf);
  if (title.toLowerCase().contains('spotube')) {
    _foundHwnd = h;
    return FALSE;
  }
  return TRUE;
}

void main() {
  _foundHwnd = null;
  final cb = Pointer.fromFunction<WNDENUMPROC>(_enumFindSpotube, FALSE);
  EnumWindows(cb, 0);

  if (_foundHwnd == null) {
    print('Error: Spotube not found. Please start Spotube first.');
    return;
  }

  final hwnd = _foundHwnd!;
  final rect = calloc<RECT>();
  GetWindowRect(hwnd, rect);
  print('Spotube window: (${rect.ref.left}, ${rect.ref.top}) '
      '${rect.ref.right - rect.ref.left}x${rect.ref.bottom - rect.ref.top}');
  calloc.free(rect);

  final targets = [
    'sidebar_library', 'Sidebar Library icon',
    'library_filter', 'Library search/filter field',
    'first_playlist_card', 'First playlist card (after filter)',
    'three_dot_menu', 'Three-dot menu on playlist page',
    'confirm_button', 'Confirm dialog button',
    'skip_detect', 'White detection point on skip dialog',
    'skip', 'Skip button on dialog',
    'skip_all', 'Skip All button on dialog',
  ];

  final results = <String, List<int>>{};
  final origin = _clientOrigin(hwnd);

  for (int i = 0; i < targets.length; i += 2) {
    final key = targets[i];
    final desc = targets[i + 1];
    print('\n--- $desc ---');
    print('Move mouse over [$key] and press Enter...');
    stdin.readLineSync();
    _wait(200);

    final pos = calloc<POINT>();
    GetCursorPos(pos);
    final dx = pos.ref.x - origin[0];
    final dy = pos.ref.y - origin[1];
    results[key] = [dx, dy];
    print('  Recorded: ($dx, $dy) (screen: ${pos.ref.x}, ${pos.ref.y})');
    calloc.free(pos);
  }

  print('\n--- Download All (relative to three_dot_menu) ---');
  print('Click the three-dot menu, then move mouse to "Download All" and press Enter...');
  stdin.readLineSync();
  _wait(200);
  final pos = calloc<POINT>();
  GetCursorPos(pos);
  final base = results['three_dot_menu']!;
  final dx = pos.ref.x - (base[0] + origin[0]);
  final dy = pos.ref.y - (base[1] + origin[1]);
  results['download_all_offset'] = [dx, dy];
  print('  Offset from three_dot_menu: ($dx, $dy)');
  calloc.free(pos);

  print('\n=== Results ===');
  print('{');
  for (final e in results.entries) {
    print("  '${e.key}': [${e.value[0]}, ${e.value[1]}],");
  }
  print('}');

  // Auto-save to config
  try {
    // Write directly to config.json
    final pointerFile = File('${AppDataDir.dir}\\config.json');
    if (pointerFile.existsSync()) {
      final data = jsonDecode(pointerFile.readAsStringSync()) as Map<String, dynamic>;
      data['spotube_coords'] = results.map((k, v) => MapEntry(k, v));
      pointerFile.writeAsStringSync(jsonEncode(data), flush: true);
      print('\n✅ Auto-saved to config.json');
    }
  } catch (e) {
    print('\n⚠️ Could not auto-save: $e');
    print('Manually copy the results above into config.json under "spotube_coords".');
  }
}

List<int> _clientOrigin(int hwnd) {
  final rect = calloc<RECT>();
  GetWindowRect(hwnd, rect);
  final origin = [rect.ref.left, rect.ref.top];
  calloc.free(rect);
  return origin;
}

void _wait(int ms) {
  // 舊寫法 Stopwatch 空轉吃滿一個 CPU 核心：Sleep 讓出時間片。
  Sleep(ms);
}
