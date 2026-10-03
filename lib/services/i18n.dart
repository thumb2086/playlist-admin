import 'package:flutter/foundation.dart';
import '../version.dart';

class I18N extends ChangeNotifier {
  I18N._();
  static final I18N instance = I18N._();

  String _lang = 'zh-TW';
  String get currentLang => _lang;
  bool get isZh => _lang == 'zh-TW';

  void setLanguage(String lang) {
    if (_lang == lang) return;
    _lang = lang;
    notifyListeners();
  }

  String t(String key, [List<dynamic>? args]) {
    final map = _lang == 'en' ? _en : _zh;
    String text = map[key] ?? key;
    if (args != null && args.isNotEmpty) {
      for (int i = 0; i < args.length; i++) {
        text = text.replaceFirst('{$i}', args[i].toString());
      }
    }
    return text;
  }

  static final Map<String, String> _zh = {
    // App
    'app.title': 'playlist-admin',
    'app.sidebar.library': '歌單庫',
    'app.sidebar.player': '播放器',
    'app.sidebar.pipeline': 'Pipeline',
    'app.sidebar.stats': '統計',
    'app.sidebar.playlist': 'playlist',
    'app.sidebar.admin': 'admin',
    'app.sidebar.spotube': 'Spotube',
    'app.sidebar.download': '下載',
    'app.sidebar.settings': '設定',
    'app.version': 'v$appVersion',
    'app.header.badge': 'PLAYLIST ADMIN',

    // Library
    'library.url_hint': '貼上 Spotify 播放清單 URL…',
    'library.add_btn': '加入',
    'library.refresh': '重新整理',
    'library.empty_title': '尚未加入歌單',
    'library.empty_subtitle': '貼上 Spotify URL 開始',
    'library.stats_playlists': '歌單',
    'library.stats_songs': '歌曲',
    'library.stats_matched': '已匹配',
    'library.stats_completion': '完成率',
    'library.song_count': '{0}/{1} 首',

    // Pipeline
    'pipeline.step_convert': '轉檔',
    'pipeline.step_scrape': '爬取',
    'pipeline.step_prune': '清理',
    'pipeline.step_unsorted': '分類',
    'pipeline.step_metadata': '元資料',
    'pipeline.step_lufs': 'LUFS',
    'pipeline.step_rag': 'RAG 索引',
    'pipeline.run_rag': 'RAG 索引',
    'pipeline.run_opencode': '開 opencode 問 podcast',
    'pipeline.step_srt': 'SRT',
    'pipeline.run_all': '完整流程',
    'pipeline.run_convert': '只轉檔',
    'pipeline.run_scrape': '只爬取',
    'pipeline.run_prune': '只清理',
    'pipeline.run_podcast': 'Podcast 流程',
    'pipeline.pause': '暫停',
    'pipeline.cancel': '取消',
    'pipeline.clear_log': '清除日誌',
    'pipeline.starting': 'Pipeline 啟動中…',
    'pipeline.log_placeholder': '日誌將顯示在這裡',
    'pipeline.cancelled': 'Pipeline 已取消',
    'pipeline.complete': 'Pipeline 完成',

    // Stats
    'stats.total_files': '總檔案',
    'stats.mp3': 'MP3',
    'stats.flac': 'FLAC',
    'stats.txt': 'TXT',
    'stats.podcast': 'Podcast',
    'stats.format_breakdown': '格式明細',
    'stats.storage': '容量',
    'stats.saved': '節省空間',
    'stats.duplicates': '重複檔案',
    'stats.cross_dup': '跨歌單重複',
    'stats.playlists': '播放清單',
    'stats.entries': '歌曲條目',
    'stats.format_distribution': '格式分布',
    'stats.refresh': '重新整理資料',

    // Spotube

    // Settings
    'settings.general': '一般設定',
    'settings.library_path': '音樂庫路徑',
    'settings.thread_count': '轉檔執行緒數',
    'settings.ffmpeg_path': 'FFmpeg 路徑',
    'settings.language': '語言',
    'settings.theme': '主題',
    'settings.debug_mode': '除錯模式',
    'settings.metadata_enrich': 'Metadata 增強',
    'settings.auto_update_check': '自動檢查更新',
    'settings.spotube': 'Spotube 自動化',
    'settings.spotube_dl_path': '下載路徑',
    'settings.exact_match': '精確檔名比對',
    'settings.convert_matched_only': '只轉換有匹配的歌',
    'settings.lyrics_section': '歌詞設定',
    'settings.lyrics_folder': '歌詞資料夾',
    'settings.save': '儲存設定',
    'settings.saved': '設定已儲存',

    // Player
    'player.select_playlist': '請選擇播放清單',
    'player.no_lyrics': '(無同步歌詞)',
    'player.lyric_offset': '歌詞偏移',
    'player.fave_add': '加入我的最愛',
    'player.fave_remove': '移除我的最愛',
    'player.fave_added': '已加入我的最愛',
    'player.fave_removed': '已移除我的最愛',

    // Download
    'download.tab_podcast': 'Podcast',
    'download.tab_song': '歌曲下載',
    'download.tab_stt': '語音轉文字',
    'download.podcast_history_hint': '最近選過的 Podcast…',
    'download.podcast_search_hint': '搜尋 Podcast 名稱…',
    'download.search': '搜尋',
    'download.use_rss_url': '或貼上 RSS / YouTube 頻道網址',
    'download.hide_url_input': '隱藏 RSS 輸入',
    'download.podcast_hint': '貼上 Podcast RSS Feed URL…',
    'download.fetch': '讀取',
    'download.podcast_empty': '輸入 RSS URL 讀取節目列表',
    'download.podcast_search_empty': '搜尋 Podcast 名稱開始，或貼上 RSS URL',
    'download.select_all': '全選',
    'download.deselect_all': '取消全選',
    'download.dl_selected': '下載選取',
    'download.downloading': '下載中:',
    'download.song_hint': '輸入歌曲名稱或 YouTube URL…',
    'download.dl_song': '下載歌曲',
    'download.dl_yt_url': '下載 YouTube 音檔',
    'download.or_enter_yt': '或直接貼上 YouTube / 歌曲名稱，然後點擊上方按鈕',
    'download.log': '日誌',
    'download.log_empty': '日誌將顯示在這裡',
    'download.groq_key_hint': '輸入 Groq API Key…',
    'download.groq_api_key': 'Groq API Key',
    'download.audio_url_hint': '或輸入音檔 URL（可選）…',
    'download.select_audio_file': '選擇音檔',
    'download.select_file': '選擇檔案',
    'download.no_audio_files': '資料庫中沒有音檔',
    'download.transcribe': '開始辨識',
    'download.transcription_result': '辨識結果',
    'download.copy': '複製',
    'download.auto_detect': '自動偵測',
    'download.language': '語言',
    'download.save_key': '儲存',

    // Common
    'common.loading': '載入中…',
    'common.error': '錯誤',
    'common.success': '成功',
    'common.skip': '跳過',
    'common.done': '完成',
    'common.failed': '失敗',
    'common.cancelled': '取消',
  };

  static final Map<String, String> _en = {
    'app.title': 'playlist-admin',
    'app.sidebar.library': 'Library',
    'app.sidebar.player': 'Player',
    'app.sidebar.pipeline': 'Pipeline',
    'app.sidebar.stats': 'Stats',
    'app.sidebar.spotube': 'Spotube',
    'app.sidebar.download': 'Download',
    'app.sidebar.settings': 'Settings',
    'app.sidebar.playlist': 'playlist',
    'app.sidebar.admin': 'admin',
    'app.version': 'v$appVersion',
    'app.header.badge': 'PLAYLIST ADMIN',

    'library.url_hint': 'Paste Spotify playlist URL…',
    'library.add_btn': 'Add',
    'library.refresh': 'Refresh',
    'library.empty_title': 'No playlists yet',
    'library.empty_subtitle': 'Paste a Spotify URL to get started',
    'library.stats_playlists': 'Playlists',
    'library.stats_songs': 'Songs',
    'library.stats_matched': 'Matched',
    'library.stats_completion': 'Complete',
    'library.song_count': '{0}/{1} songs',

    'pipeline.step_convert': 'Convert',
    'pipeline.step_scrape': 'Scrape',
    'pipeline.step_prune': 'Prune',
    'pipeline.step_unsorted': 'Sort',
    'pipeline.step_metadata': 'Metadata',
    'pipeline.step_lufs': 'LUFS',
    'pipeline.step_rag': 'RAG index',
    'pipeline.run_rag': 'RAG Index',
    'pipeline.run_opencode': 'Ask podcast via opencode',
    'pipeline.step_srt': 'SRT',
    'pipeline.run_all': 'Full Pipeline',
    'pipeline.run_convert': 'Convert Only',
    'pipeline.run_scrape': 'Scrape Only',
    'pipeline.run_prune': 'Prune Only',
    'pipeline.run_podcast': 'Podcast Pipeline',
    'pipeline.pause': 'Pause',
    'pipeline.cancel': 'Cancel',
    'pipeline.clear_log': 'Clear Log',
    'pipeline.starting': 'Pipeline starting…',
    'pipeline.log_placeholder': 'Log will appear here',
    'pipeline.cancelled': 'Pipeline cancelled',
    'pipeline.complete': 'Pipeline complete',

    'stats.total_files': 'Total Files',
    'stats.mp3': 'MP3',
    'stats.flac': 'FLAC',
    'stats.txt': 'TXT',
    'stats.podcast': 'Podcast',
    'stats.format_breakdown': 'Format Breakdown',
    'stats.storage': 'Storage',
    'stats.saved': 'Space Saved',
    'stats.duplicates': 'Duplicate Files',
    'stats.cross_dup': 'Cross-Playlist Dup',
    'stats.playlists': 'Playlists',
    'stats.entries': 'Entries',
    'stats.format_distribution': 'Format Distribution',
    'stats.refresh': 'Refresh Data',


    'settings.general': 'General',
    'settings.library_path': 'Library Path',
    'settings.thread_count': 'Converter Threads',
    'settings.ffmpeg_path': 'FFmpeg Path',
    'settings.language': 'Language',
    'settings.theme': 'Theme',
    'settings.debug_mode': 'Debug Mode',
    'settings.metadata_enrich': 'Metadata Enrichment',
    'settings.auto_update_check': 'Auto Update Check',
    'settings.spotube': 'Spotube Automation',
    'settings.spotube_exe': 'Executable Path',
    'settings.spotube_dl_path': 'Download Path',
    'settings.exact_match': 'Exact Filename Match',
    'settings.convert_matched_only': 'Convert Matched Only',
    'settings.lyrics_section': 'Lyrics',
    'settings.lyrics_folder': 'Lyrics Folder',
    'settings.save': 'Save',
    'settings.saved': 'Settings saved',


    // Player
    'player.select_playlist': 'Select a playlist',
    'player.no_lyrics': '(No synced lyrics)',
    'player.lyric_offset': 'Lyric Offset',
    'player.fave_add': 'Add to Favorites',
    'player.fave_remove': 'Remove from Favorites',
    'player.fave_added': 'Added to Favorites',
    'player.fave_removed': 'Removed from Favorites',

    // Download
    'download.tab_podcast': 'Podcast',
    'download.tab_song': 'Song Download',
    'download.tab_stt': 'Speech-to-Text',
    'download.podcast_history_hint': 'Recent podcasts…',
    'download.podcast_search_hint': 'Search podcast name…',
    'download.search': 'Search',
    'download.use_rss_url': 'Or paste RSS / YouTube channel URL',
    'download.hide_url_input': 'Hide RSS input',
    'download.podcast_hint': 'Paste Podcast RSS Feed URL…',
    'download.fetch': 'Fetch',
    'download.podcast_empty': 'Enter an RSS URL to load episodes',
    'download.podcast_search_empty': 'Search a podcast to get started, or paste an RSS URL',
    'download.select_all': 'Select All',
    'download.deselect_all': 'Deselect All',
    'download.dl_selected': 'Download Selected',
    'download.downloading': 'Downloading:',
    'download.song_hint': 'Enter song name or YouTube URL…',
    'download.dl_song': 'Download Song',
    'download.dl_yt_url': 'Download YouTube Audio',
    'download.or_enter_yt': 'Or paste a YouTube/Song URL, then click button above',
    'download.log': 'Log',
    'download.log_empty': 'Log will appear here',
    'download.groq_key_hint': 'Enter Groq API Key…',
    'download.groq_api_key': 'Groq API Key',
    'download.audio_url_hint': 'Or enter audio URL (optional)…',
    'download.select_audio_file': 'Select Audio File',
    'download.select_file': 'Select File',
    'download.no_audio_files': 'No audio files in library',
    'download.transcribe': 'Transcribe',
    'download.transcription_result': 'Transcription Result',
    'download.copy': 'Copy',
    'download.auto_detect': 'Auto Detect',
    'download.language': 'Language',
    'download.save_key': 'Save',

    'common.loading': 'Loading…',
    'common.error': 'Error',
    'common.success': 'Success',
    'common.skip': 'Skip',
    'common.done': 'Done',
    'common.failed': 'Failed',
    'common.cancelled': 'Cancelled',
  };
}

String t(String key, [List<dynamic>? args]) => I18N.instance.t(key, args);
