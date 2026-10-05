import 'dart:io';

/// 平台路徑拼接（手機/桌面共用）：Android/iOS 上硬編碼 `\\` 會變成
/// 檔名的一部分（目錄建在奇怪位置、檔案永遠找不到）。
/// 全站新代碼走這裡；舊 `\\` 按「手機是否走得到」逐步替換。
String joinPath(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final sep = Platform.pathSeparator;
  final left = a.endsWith(sep) ? a.substring(0, a.length - 1) : a;
  final right = b.startsWith(sep) ? b.substring(1) : b;
  return '$left$sep$right';
}
