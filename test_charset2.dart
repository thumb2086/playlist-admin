import 'package:charset/charset.dart';

void main() {
  print('Testing charset package...');
  
  // Check what's available
  print('Charset class: $Charset');
  
  // Try to see what static methods are available
  print('Charset methods: ${Charset.toString()}');
  
  // Try to use the codec directly
  try {
    final codec = const Utf8Codec();
    print('Utf8Codec works');
  } catch (e) {
    print('Utf8Codec error: $e');
  }
  
  // Try to see what's exported
  print('Testing charset package exports...');
}