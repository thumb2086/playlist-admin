import 'package:flutter/material.dart';
import '../services/i18n.dart';
import '../services/update_service.dart';
import '../services/version_checker.dart';
import 'dark_theme.dart';

class UpdateDialog extends StatefulWidget {
  final VersionInfo info;
  const UpdateDialog({super.key, required this.info});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  final _svc = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDownloading = _svc.state == UpdateState.downloading;
    final isReady = _svc.state == UpdateState.ready;
    final isError = _svc.state == UpdateState.error;
    final progress = _svc.progress;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          VersionChecker.markSkipped(widget.info.latestVersion);
          Navigator.of(context).pop();
        }
      },
      child: AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Column(children: [
          Icon(
            isReady ? Icons.check_circle : (isError ? Icons.error : Icons.new_releases_rounded),
            color: isReady ? AppColors.accent : (isError ? AppColors.error : AppColors.accent),
            size: 40,
          ),
          const SizedBox(height: 8),
          Text(
            isReady ? '下載完成！' : (isError ? '下載失敗' : '🎉 新版本可用！'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('目前版本: ', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              Text(t('app.version'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Text('最新版本: ', style: TextStyle(color: AppColors.accent, fontSize: 12)),
              Text(widget.info.latestVersion, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.accent)),
            ]),
            if (isDownloading) ...[
              const SizedBox(height: 14),
              // 普通進度條：Tween 每次都 begin:0 重播會閃爍。
              ClipRRect(borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: progress, backgroundColor: AppColors.surfaceLight,
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent), minHeight: 6)),
              const SizedBox(height: 6),
              Text('${(progress * 100).toStringAsFixed(0)}% 下載中…',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ],
            if (!isReady && !isError && widget.info.releaseNotes != null && widget.info.releaseNotes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('更新內容', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Container(
                height: 120, padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppColors.surfaceLight, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(
                  child: Text(widget.info.releaseNotes!, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4)),
                ),
              ),
            ],
          ]),
        ),
        actions: [
          if (!isReady) ...[
            TextButton(
              onPressed: isDownloading ? null : () {
                VersionChecker.markSkipped(widget.info.latestVersion);
                Navigator.of(context).pop();
              },
              child: Text(t('common.skip'), style: TextStyle(color: isDownloading ? AppColors.textMuted : AppColors.textMuted)),
            ),
            TextButton(
              onPressed: isDownloading ? null : () {
                VersionChecker.markSkipped(widget.info.latestVersion);
                Navigator.of(context).pop();
              },
              child: Text('稍後提醒', style: TextStyle(color: isDownloading ? AppColors.textMuted : AppColors.textSecondary)),
            ),
          ],
          Container(
            decoration: isReady
                ? BoxDecoration(gradient: const LinearGradient(colors: [AppColors.accent, Color(0xFF169C46)]), borderRadius: BorderRadius.circular(8))
                : null,
            child: ElevatedButton(
              onPressed: isDownloading ? null : (isReady ? _svc.launchInstaller : () { _svc.startDownload(widget.info); Navigator.of(context).pop(); }),
              style: ElevatedButton.styleFrom(
                backgroundColor: isReady ? Colors.transparent : (isDownloading ? AppColors.surfaceLight : AppColors.accent),
                shadowColor: Colors.transparent,
                foregroundColor: isDownloading ? AppColors.textMuted : Colors.black,
              ),
              child: Text(
                isDownloading ? '下載中…' : (isReady ? '執行安裝' : '背景下載'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
