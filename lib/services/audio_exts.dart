/// 全站音訊副檔名正規集合（判重/索引/同步共用一處，免得四處各說各話）。
/// 目標是全 MP3（手機直連下載的 m4a/webm 是過渡，同步時強制換成 MP3），
/// 但「認得」必須全認，否則過渡檔會被誤判缺檔重下、播不到。
const kAudioExts = {'.mp3', '.m4a', '.webm', '.flac'};

/// 是否為可播放音訊（副檔名判斷，不讀檔）。
bool isAudioFile(String path) {
  final low = path.toLowerCase();
  for (final e in kAudioExts) {
    if (low.endsWith(e)) return true;
  }
  return false;
}
