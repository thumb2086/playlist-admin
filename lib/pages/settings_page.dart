import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../services/i18n.dart';
import '../widgets/dark_theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _basePathCtrl, _workersCtrl, _ffmpegCtrl,
      _lyricsFolderCtrl, _discordAppIdCtrl, _groqApiKeyCtrl;

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
    I18N.instance.addListener(_onConfigChanged);
    ConfigService.instance.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    I18N.instance.removeListener(_onConfigChanged);
    ConfigService.instance.removeListener(_onConfigChanged);
    _basePathCtrl.dispose(); _workersCtrl.dispose(); _ffmpegCtrl.dispose();
    _lyricsFolderCtrl.dispose(); _discordAppIdCtrl.dispose(); _groqApiKeyCtrl.dispose();
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
    ConfigService.instance.save();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('settings.saved')), duration: const Duration(seconds: 1)));
  }

  /// Toggle專用：只存當前config，不收割文字框。
  /// 舊寫法每個toggle都調_save()，打一半的路徑會被順手存掉。
  void _saveQuiet() {
    ConfigService.instance.save();
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
        ]),
        const SizedBox(height: 12),
        _Section(t('settings.lyrics_section'), [
          _Field(t('settings.lyrics_folder'), _lyricsFolderCtrl, 'Lyrics'),
        ]),
        const SizedBox(height: 12),
        _Section('Groq API (Podcast 轉錄)', [
          _Field('API Key (多個用逗號分隔)', _groqApiKeyCtrl, 'gsk_xxx,gsk_yyy'),
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
