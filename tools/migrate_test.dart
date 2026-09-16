import 'dart:io';
import 'package:playlist_admin/services/app_data_dir.dart';

Future<void> main() async {
  print('new dir : ${AppDataDir.dir}');
  print('legacy  : ${AppDataDir.legacyDir}');
  print('new exists before: ${Directory(AppDataDir.dir).existsSync()}');
  print('legacy exists    : ${Directory(AppDataDir.legacyDir).existsSync()}');
  await AppDataDir.ensureMigrated();
  print('new exists after : ${Directory(AppDataDir.dir).existsSync()}');
  if (Directory(AppDataDir.dir).existsSync()) {
    final entries = Directory(AppDataDir.dir).listSync();
    print('entries in new dir: ${entries.length}');
    for (final e in entries.take(10)) {
      print('  ${e.uri.pathSegments.last}');
    }
  }
}