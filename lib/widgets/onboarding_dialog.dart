import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../app.dart';
import '../services/config_service.dart';
import '../services/spotify_session.dart';
import '../services/youtube_service.dart';
import 'dark_theme.dart';

/// 新手導引：首次啟動自動顯示（config.setupCompleted 旗標，複用既有死欄位），
/// 設定 → 新手導引 可隨時重看。四頁：歡迎 → 環境檢查 → 功能地圖 → 完成。
class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({super.key});
  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  int _page = 0;
  bool _ytdlp = false;
  bool _checking = true;
  late final bool _mobile;

  @override
  void initState() {
    super.initState();
    _mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    _check();
  }

  Future<void> _check() async {
    var ytdlp = false;
    if (!_mobile) {
      // 與 pipeline orchestrator 相同的檢查法。
      try {
        final r = await Process.run('yt-dlp', ['--version'], runInShell: false);
        ytdlp = r.exitCode == 0;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _ytdlp = ytdlp;
      _checking = false;
    });
  }

  void _finish() async {
    final c = ConfigService.instance.config;
    c.setupCompleted = true;
    // 手機首次啟動 basePath 是空的（還沒同步過）：save() 會靜默不寫，
    // 旗標只活在記憶體 → 下次冷啟動導引又跳出來。先給預設路徑再存。
    try {
      await ConfigService.instance.ensureBasePath();
    } catch (_) {}
    try {
      await ConfigService.instance.save();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceLight,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            [
              _welcomePage(),
              _envPage(),
              _mapPage(),
              _donePage(),
            ][_page],
            const SizedBox(height: 16),
            Row(children: [
              if (_page > 0)
                TextButton(
                  onPressed: () => setState(() => _page--),
                  child: const Text('上一頁'),
                )
              else
                TextButton(
                  onPressed: _finish,
                  child: const Text('跳過', style: TextStyle(color: AppColors.textMuted)),
                ),
              const Spacer(),
              Text('${_page + 1} / 4',
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
              const SizedBox(width: 8),
              if (_page == 3)
                TextButton(
                  onPressed: () {
                    _finish();
                    MainShell.startTour(); // 逐頁導覽：每頁浮卡講該頁功能
                  },
                  child: const Text('逐頁導覽',
                      style: TextStyle(fontSize: 11, color: AppColors.accent)),
                ),
              ElevatedButton(
                onPressed: () {
                  if (_page == 3) {
                    _finish();
                  } else {
                    setState(() => _page++);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                ),
                child: Text(_page == 3 ? '開始使用' : '下一步'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── P1 歡迎 ──────────────────────────────────────────
  Widget _welcomePage() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.queue_music_rounded, color: AppColors.accent, size: 28),
        SizedBox(width: 8),
        Text('歡迎使用 Playlist Administrator',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 12),
      _bullet('音樂庫管理 — 歌單同步、統計、歌詞、USB 匯出'),
      _bullet('串流播放 — 搜尋直接聽，批次下載到本機'),
      _bullet('Podcast — 訂閱、自動抓新集、逐字稿'),
      _bullet('一起聽 — 開房間，朋友跨網路加入同步聽'),
    ]);
  }

  // ── P2 環境檢查 ──────────────────────────────────────
  Widget _envPage() {
    if (_mobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('環境檢查', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _infoRow('手機免設定', '搜尋自動走 YouTube；一起聽音訊由房主電腦解析'),
        _infoRow('Spotify 登入', '僅桌面版可登入，手機加入房間照樣加歌/聊天/投票'),
      ]);
    }
    final cookies = YoutubeService.cookiesPathForDiag;
    final spotify = SpotifySession.instance.isLoggedIn;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('環境檢查', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      _checking
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          : Column(children: [
              _statusRow('yt-dlp', _ytdlp,
                  _ytdlp ? '串流/下載可用' : '未安裝：winget install yt-dlp'),
              _statusRow('YouTube cookies', cookies != null,
                  cookies ?? '未找到 yt_cookies.txt（放桌面/Documents，否則易被 YouTube 擋）'),
              _statusRow('Spotify 登入', spotify,
                  spotify ? '搜尋完整可用' : '未登入：可到「搜尋」頁登入；一起聽未登入會自動改用 YouTube 搜尋'),
            ]),
    ]);
  }

  // ── P3 功能地圖 ──────────────────────────────────────
  Widget _mapPage() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('功能地圖', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      _bullet('搜尋 — 找歌 → 直接播或下載'),
      _bullet('一起聽 — 6 位代碼/QR 開房，加歌、投票、聊天、同步'),
      _bullet('音樂庫 — 統計、USB 匯出、「整理」把歌單外歌曲移入未分類\\'),
      _bullet('Pipeline — 同步歌單＋批次下載；「下載與訂閱」貼 RSS / YT 頻道網址（桌面版）'),
      _bullet('設定 — 路徑、串流音質、更新、本頁導引'),
    ]);
  }

  // ── P4 完成 ──────────────────────────────────────────
  Widget _donePage() {
    return const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 34),
      SizedBox(height: 8),
      Text('就這樣，可以開始了！', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      SizedBox(height: 8),
      Text('按下方「逐頁導覽」會逐頁切換、帶你看每個頁面的功能重點；之後在設定或首頁隨時重看。',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5)),
    ]);
  }

  // ── 小元件 ───────────────────────────────────────────
  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 5, color: AppColors.accent),
          ),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 12, height: 1.4))),
        ]),
      );

  Widget _statusRow(String label, bool ok, String hint) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              size: 16, color: ok ? const Color(0xFF2ECC71) : AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              Text(hint,
                  style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted, height: 1.3)),
            ]),
          ),
        ]),
      );

  Widget _infoRow(String label, String hint) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              Text(hint,
                  style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted, height: 1.3)),
            ]),
          ),
        ]),
      );
}
