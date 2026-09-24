/// Generic track/episode item for PlaylistDetailPage.
/// Works for both music playlists (GQL) and podcast shows (RSS).
class PlaylistItem {
  final String name;
  final String artist;
  final int durationMs;
  final String? coverUrl;
  final String audioQuery;  // Music: "Title - Artist"; Podcast: episode title
  final String? audioUrl;   // Podcast: direct RSS mp3 URL (null for music)
  final String? isrc;       // Spotify ISRC for accurate matching
  final String? album;      // Spotify album name (detail panel 顯示用)

  const PlaylistItem({
    required this.name,
    this.artist = '',
    this.durationMs = 0,
    this.coverUrl,
    required this.audioQuery,
    this.audioUrl,
    this.isrc,
    this.album,
  });

  String get durationText {
    final m = (durationMs ~/ 60000).toString();
    final s = ((durationMs ~/ 1000) % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
