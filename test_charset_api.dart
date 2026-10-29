import 'package:charset/charset.dart';

void main() {
  // Test the charset package API
  print('Testing charset package...');
  
  // Try to get a charset
  try {
    final cs = Charset.forName('big5');
    print('Charset.forName works: $cs');
    final bytes = [0xA4, 0x40]; // Big5 for '一'
    final decoded = cs.decode(bytes);
    print('Decoded: $decoded');
  } catch (e) {
    print('Charset.forName error: $e');
  }
  
  try {
    final cs = Charset.forName('cp950');
    print('Charset.forName cp950 works: $cs');
  } catch (e) {
    print('Charset.forName cp950 error: $e');
  }
  
  try {
    final cs = getCharset('big5');
    print('getCharset works: $cs');
  } catch (e) {
    print('getCharset error: $e');
  }
}