import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  final testCases = [
    {'artist': 'BTS', 'track': '2.0'},
    {'artist': 'AKB48 Team TP', 'track': '24_7 Shining'},
    {'artist': 'Jung Kook', 'track': '3D (feat. Jack Harlow)'},
  ];

  for (var test in testCases) {
    final artist = test['artist']!;
    final track = test['track']!;
    final start = DateTime.now();
    
    final params = {
      'artist_name': artist,
      'track_name': track,
    };
    final uri = Uri.https('lrclib.net', '/api/get', params);
    
    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final hasSynced = data['syncedLyrics'] != null;
        final hasPlain = data['plainLyrics'] != null;
        print('$artist - $track: ${DateTime.now().difference(start).inMilliseconds}ms, synced=${hasSynced}, plain=${hasPlain}');
      } else {
        print('$artist - $track: HTTP ${resp.statusCode}');
      }
    } catch (e) {
      print('$artist - $track: Error $e');
    }
    
    await Future.delayed(Duration(milliseconds: 200));
  }
}