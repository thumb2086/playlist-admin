import 'package:charset/charset.dart';

void main() {
  print('Testing charset package...');
  print('charset: $charset');
  
  // Check what's available
  print('charset keys: ${charset.keys}');
  
  // Try to get a codec
  try {
    final codec = codecForName('big5');
    print('codecForName big5: $codec');
  } catch (e) {
    print('codecForName error: $e');
  }
  
  try {
    final codec = codecForName('cp950');
    print('codecForName cp950: $codec');
  } catch (e) {
    print('codecForName cp950 error: $e');
  }
}