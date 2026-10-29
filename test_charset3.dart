import 'package:charset/charset.dart';

void main() {
  print('Testing charset package...');
  
  // Try to use the library directly
  try {
    final codec = getCodec('big5');
    print('getCodec big5: $codec');
  } catch (e) {
    print('getCodec error: $e');
  }
  
  try {
    final codec = getCodec('cp950');
    print('getCodec cp950: $codec');
  } catch (e) {
    print('getCodec cp950 error: $e');
  }
}