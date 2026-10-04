import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../app.dart';
import '../models/config_model.dart';
import '../services/config_service.dart';
import '../services/i18n.dart';
import '../services/sync_server.dart';
import '../services/version_checker.dart';
import '../widgets/dark_theme.dart';
import '../widgets/update_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _basePathCtrl, _workersCtrl, _ffmpegCtrl,
      _lyricsFolderCtrl, _discordAppIdCtrl, _groqApiKeyCtrl, _groqBaseUrlCtrl;

  void _onConfigChanged() { if (mounted) setState(() {}); }

  @override
  void initState() {
    super.initState();
    final c = ConfigService.instance.config;
    _basePathCtrl = TextEditingController(text: c.basePath);
    _workersCtrl = TextEditingController(text: c.maxThreads.toString());
    _ffmpegCtrl = TextEditingController(text: c.ffmpegPath);
    _lyricsFolderCtrl = TextEditingController(text: c.lyricsFolderName);
    _discordAppIdCtrl = TextEditingController(text: c.discordApplicationId);
    _groqApiKeyCtrl = TextEditingController(text: c.groqApiKey);
    _groqBaseUrlCtrl = TextEditingController(text: c.groqBaseUrl);
    I18N.instance.addListener(_onConfigChanged);
    ConfigService.instance.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    I18N.instance.removeListener(_onConfigChanged);
    ConfigService.instance.removeListener(_onConfigChanged);
    _basePathCtrl.dispose(); _workersCtrl.dispose(); _ffmpegCtrl.dispose();
    _lyricsFolderCtrl.dispose(); _discordAppIdCtrl.dispose(); _groqApiKeyCtrl.dispose();
    _groqBaseUrlCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final c = ConfigService.instance.config;
    c.basePath = _basePathCtrl.text;
    c.maxThreads = int.tryParse(_workersCtrl.text) ?? 4;
    c.ffmpegPath = _ffmpegCtrl.text;
    c.lyricsFolderName = _lyricsFolderCtrl.text.trim().isEmpty ? 'Lyrics' : _lyricsFolderCtrl.text.trim();
    c.discordApplicationId = _discordAppIdCtrl.text.trim();
    c.groqApiKey = _groqApiKeyCtrl.text.trim();
    c.groqBaseUrl = _groqBaseUrlCtrl.text.trim();
    ConfigService.instance.save();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('settings.saved')), duration: const Duration(seconds: 1)));
  }

  /// Toggle專用：只存當前config，不收割文字框。
  /// 舊寫法每個toggle都調_save()，打一半的路徑會被順手存掉。
  void _saveQuiet() {
    ConfigService.instance.save();
  }

  /// 內附 opencode skill → 全域目錄（~/.config/opencode/skills/<name>/）。
  /// 來源是打包進 app 的 assets（CI 從 .opencode/skills 同步，見 flutter-release.yml）。
  Future<void> _installSkill() async {
    const name = 'podcast-knowledge';
    try {
      final data = await rootBundle
          .loadString('assets/skills/$name/SKILL.md');
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      if (home.isEmpty) throw Exception('找不到家目錄');
      final sep = Platform.pathSeparator;
      final dest = Directory('$home$sep.config${sep}opencode${sep}skills$sep$name');
      await dest.create(recursive: true);
      await File('${dest.path}${sep}SKILL.md')
          .writeAsString(data, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已安裝 $name（opencode 重啟後生效）'),
          duration: Duration(seconds: 3)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('安裝 Skill 失敗：$e'),
          duration: const Duration(seconds: 3)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ConfigService.instance.config;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: ListView(children: [
        _Section(t('settings.general'), [
          _Field(t('settings.library_path'), _basePathCtrl, 'C:\\Users\\CPXru\\Music\\playlist-admin'),
          _Field(t('settings.thread_count'), _workersCtrl, '4'),
          _Field(t('settings.ffmpeg_path'), _ffmpegCtrl, 'bin/ffmpeg.exe'),
          // Language
          _DropdownLabel(t('settings.language')),
          _Dropdown(
            value: I18N.instance.currentLang,
            items: const [DropdownMenuItem(value: 'zh-TW', child: Text('繁體中文')), DropdownMenuItem(value: 'en', child: Text('English'))],
            onChanged: (v) { I18N.instance.setLanguage(v); c.language = v; ConfigService.instance.save(); },
          ),
          const SizedBox(height: 8),
          // Theme
          _DropdownLabel(t('settings.theme')),
          _Dropdown(
            value: c.theme,
            items: const [DropdownMenuItem(value: 'dark', child: Text('深色 / Dark')), DropdownMenuItem(value: 'light', child: Text('淺色 / Light'))],
            onChanged: (v) { c.theme = v; ConfigService.instance.save(); setState(() {}); },
          ),
          const SizedBox(height: 4),
          _Toggle(t('settings.debug_mode'), c.debugMode, (v) { c.debugMode = v; _saveQuiet(); setState(() {}); }),
          _Toggle(t('settings.metadata_enrich'), c.enableMetadataEnrichment, (v) { c.enableMetadataEnrichment = v; _saveQuiet(); setState(() {}); }),
          _Toggle(t('settings.auto_update_check'), c.autoUpdateCheck, (v) { c.autoUpdateCheck = v; _saveQuiet(); setState(() {}); }),
          _Toggle('自動下載更新', c.autoDownloadUpdate, (v) { c.autoDownloadUpdate = v; _saveQuiet(); setState(() {}); }),
          _Toggle('接收 Beta 更新', c.receiveBetaUpdates, (v) { c.receiveBetaUpdates = v; _saveQuiet(); setState(() {}); }),
          const SizedBox(height: 4),
          const _DropdownLabel('串流音質'),
          _Dropdown(
            value: c.streamQuality,
            items: const [
              DropdownMenuItem(value: 'low', child: Text('省流量（≤96 kbps）')),
              DropdownMenuItem(value: 'standard', child: Text('標準')),
              DropdownMenuItem(value: 'high', child: Text('高音質（優先 opus ≥160k）')),
            ],
            onChanged: (v) { c.streamQuality = v; _saveQuiet(); setState(() {}); },
          ),
          const SizedBox(height: 4),
          const _UpdateCheckRow(),
          const SizedBox(height: 4),
          Row(children: [
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('新手導引', style: TextStyle(fontSize: 13)),
                Text('重看首次啟動的介紹與環境檢查',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ]),
            ),
            OutlinedButton.icon(
              onPressed: MainShell.startTour, // 逐頁導覽（每頁浮卡講功能）
              icon: const Icon(Icons.school_outlined, size: 16),
              label: const Text('開啟導引'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('opencode Skill（RAG 知識檢索）', style: TextStyle(fontSize: 13)),
                Text('安裝 podcast-knowledge 到全域 ~/.config/opencode/skills',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ]),
            ),
            OutlinedButton.icon(
              onPressed: _installSkill, // 內附 skill → opencode v2 全域目錄
              icon: const Icon(Icons.terminal_rounded, size: 16),
              label: const Text('安裝 Skill'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          // 電腦端開關：手機走區網一鍵同步（手機上不顯示，沒東西可服）。
          if (!kIsWeb &&
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
            const _SyncServerRow(),
        ]),
        const SizedBox(height: 12),
        _Section(t('settings.lyrics_section'), [
          _Field(t('settings.lyrics_folder'), _lyricsFolderCtrl, 'Lyrics'),
        ]),
        const SizedBox(height: 12),
        _Section('Groq API (Podcast 轉錄)', [
          _Field('API Key (多個用逗號分隔)', _groqApiKeyCtrl, 'gsk_xxx,gsk_yyy'),
          const SizedBox(height: 4),
          const _DropdownLabel('Groq Base URL（轉錄與 RAG 問答端點）'),
          // 下拉兩個預設 + 自訂；自訂值在下方欄位輸入（按「儲存」生效）。
          _Dropdown(
            value: c.groqBaseUrl == AppConfig.defaultGroqBaseUrl
                ? 'router'
                : c.groqBaseUrl.isEmpty
                    ? 'official'
                    : 'custom',
            items: const [
              DropdownMenuItem(
                  value: 'router',
                  child: Text('推薦 router — vercel-router-khaki.vercel.app')),
              DropdownMenuItem(
                  value: 'official', child: Text('官方 api.groq.com')),
              DropdownMenuItem(
                  value: 'custom', child: Text('自訂…（用下方欄位輸入）')),
            ],
            onChanged: (v) {
              final cfg = ConfigService.instance.config;
              if (v == 'router') {
                cfg.groqBaseUrl = AppConfig.defaultGroqBaseUrl;
                _groqBaseUrlCtrl.text = AppConfig.defaultGroqBaseUrl;
              } else if (v == 'official') {
                cfg.groqBaseUrl = '';
                _groqBaseUrlCtrl.text = '';
              }
              // custom：維持現值，等下方欄位輸入後按儲存。
              _saveQuiet();
              if (mounted) setState(() {});
            },
          ),
          _Field('自訂 Base URL', _groqBaseUrlCtrl,
              '貼你的 router 網址，如 https://my-router.example.com（留空 = 官方）'),
          const SizedBox(height: 4),
          const Text(
            '用推薦 router 時，上面的 Key 填 router 給的 ak_ 開頭金鑰（或 ROUTER_TOKEN）；'
            '上游多把 Groq key 的輪替/冷卻由 router 負責，官方模式則用一般 gsk_ key。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 4),
          const Text(
            '沒有 key 也能用，Podcast 會改用 YouTube 字幕',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ]),
        const SizedBox(height: 12),
        _Section('Discord Rich Presence', [
          _Field('Discord Application ID', _discordAppIdCtrl, '到 discord.com/developers 申請'),
          _Toggle('Discord Presence', c.discordPresenceEnabled, (v) {
            c.discordPresenceEnabled = v;
            _saveQuiet();
            setState(() {});
          }),
        ]),
        const SizedBox(height: 20),
        Center(
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.accent, Color(0xFF169C46)]),
              borderRadius: BorderRadius.circular(10),
            ),
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent, shadowColor: Colors.transparent,
                foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
              ),
              child: Text(t('settings.save'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _DropdownLabel extends StatelessWidget {
  final String text;
  const _DropdownLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 4), child:
      Text(text, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)));
  }
}

class _Dropdown extends StatelessWidget {
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String> onChanged;
  const _Dropdown({required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          dropdownColor: AppColors.surfaceLight,
          isExpanded: true,
          items: items,
          onChanged: (v) { if (v != null) { onChanged(v); } },
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title; final List<Widget> children;
  const _Section(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14), ...children,
      ]),
    );
  }
}

class _Field extends StatelessWidget {
  final String label; final TextEditingController controller; final String hint;
  const _Field(this.label, this.controller, this.hint);

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 10), child:
      TextField(controller: controller,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        style: const TextStyle(fontSize: 13),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String label; final bool value; final ValueChanged<bool> onChanged;
  const _Toggle(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(fontSize: 13)),
      value: value, onChanged: onChanged, dense: true, contentPadding: EdgeInsets.zero,
      activeTrackColor: AppColors.accent,
    );
  }
}

/// 手動檢查更新（自動檢查之外的按鈕）：
/// 有新版 → UpdateDialog（用戶主動按的，不理会 skippedVersion）；
/// 已最新 / 連線失敗 → snackbar 回報。
class _UpdateCheckRow extends StatefulWidget {
  const _UpdateCheckRow();

  @override
  State<_UpdateCheckRow> createState() => _UpdateCheckRowState();
}

class _UpdateCheckRowState extends State<_UpdateCheckRow> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    if (VersionChecker.isDevBuild) {
      // 開發版不打 GitHub（版本號是本地隨便填的，比新舊沒意義）。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '開發版不檢查更新（目前版本 ${VersionChecker.currentVersion}）'),
            duration: const Duration(seconds: 2)));
      }
      return;
    }
    setState(() => _checking = true);
    try {
      final info = await VersionChecker.checkForUpdate();
      if (!mounted) return;
      if (info.hasUpdate) {
        showDialog(context: context, builder: (_) => UpdateDialog(info: info));
      } else if (info.htmlUrl.isEmpty) {
        // checkForUpdate 失敗時回 htmlUrl='' 的空 VersionInfo。
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('檢查更新失敗：無法連線 GitHub'),
            duration: Duration(seconds: 2)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已是最新版本（${VersionChecker.currentVersion}）'),
            duration: const Duration(seconds: 2)));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('檢查更新', style: TextStyle(fontSize: 13)),
            Text('目前版本 ${VersionChecker.currentVersion}',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ]),
        ),
        OutlinedButton.icon(
          onPressed: _checking ? null : _check,
          icon: _checking
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.system_update_rounded, size: 16),
          label: Text(_checking ? '檢查中…' : '檢查更新'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            side: const BorderSide(color: AppColors.border),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
      ]),
    );
  }
}

/// 電腦端區網同步開關：打開後手機「音樂庫 → 從電腦同步」可一鍵拉歌。
/// 只在桌面顯示；開關持久化到 config（下次啟動自動接著服）。
class _SyncServerRow extends StatefulWidget {
  const _SyncServerRow();
  @override
  State<_SyncServerRow> createState() => _SyncServerRowState();
}

class _SyncServerRowState extends State<_SyncServerRow> {
  bool _toggling = false;
  String _url = '';
  bool _failed = false;

  bool get _on =>
      SyncServer.instance.isRunning ||
      ConfigService.instance.config.syncServerEnabled;

  Future<void> _refreshUrl() async {
    if (!SyncServer.instance.isRunning) {
      if (mounted) setState(() => _url = '');
      return;
    }
    final ip = await SyncServer.lanIp();
    if (mounted) {
      setState(
          () => _url = 'http://$ip:${SyncServer.instance.port}');
    }
  }

  Future<void> _toggle(bool v) async {
    if (_toggling) return;
    setState(() {
      _toggling = true;
      _failed = false;
    });
    try {
      if (v) {
        await SyncServer.instance.start();
      } else {
        await SyncServer.instance.stop();
      }
      ConfigService.instance.config.syncServerEnabled = v;
      await ConfigService.instance.save();
      await _refreshUrl();
    } catch (e) {
      if (mounted) {
        setState(() => _failed = true);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('啟動失敗：$e')));
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _refreshUrl();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('手機同步（區網）', style: TextStyle(fontSize: 13)),
                  Text('手機掃 QR 一鍵拉歌，只走 Wi-Fi 不耗流量',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textMuted)),
                ]),
          ),
          if (_toggling)
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            Switch(
              value: _on,
              activeTrackColor: AppColors.accent,
              onChanged: _toggle,
            ),
        ]),
        if (_failed)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('啟動失敗（port 可能被佔用），重開 app 再試',
                style: TextStyle(fontSize: 11, color: Colors.redAccent)),
          ),
        if (_url.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            QrImageView(
              data: _url,
              version: QrVersions.auto,
              size: 120,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(color: Colors.black),
              dataModuleStyle:
                  const QrDataModuleStyle(color: Colors.black),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('手機掃這個 QR（或手輸下面網址）：',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textMuted)),
                    const SizedBox(height: 4),
                    Text(_url,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent)),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _url));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('已複製'),
                                duration: Duration(seconds: 1)));
                      },
                      icon: const Icon(Icons.copy_rounded, size: 14),
                      label: const Text('複製網址',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ]),
            ),
          ]),
        ],
      ]),
    );
  }
}
