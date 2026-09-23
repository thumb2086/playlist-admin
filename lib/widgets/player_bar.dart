import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/config_service.dart';
import '../services/player_controller.dart';
import 'dark_theme.dart';

/// Spotube-style persistent bottom player bar: cover + title/artist +
/// seek bar + controls (shuffle/prev/play/next/repeat) + volume + queue.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key});
  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  final _ctrl = PlayerController.instance;
  bool _seeking = false;
  double _seekValue = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onState);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onState);
    super.dispose();
  }

  void _onState() => setState(() {});

  Widget _buildCover() {
    final cp = _ctrl.coverPath;
    if (cp == null) return const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24);
    final bytes = _ctrl.getArtworkBytes();
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24));
    }
    if (cp.startsWith('http')) {
      return CachedNetworkImage(imageUrl: cp, fit: BoxFit.cover,
          placeholder: (_, __) => const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24),
          errorWidget: (_, __, ___) => const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24));
    }
    if (File(cp).existsSync()) {
      return Image.file(File(cp), fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24));
    }
    return const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = _ctrl.hasTrack;
    // 直接點歌（首頁卡片）不設 queue：title 已載入就該能控制播放，
    // 否則暫停/seek/循環全部停用 =「播放控制失效」。
    final canPlay = hasTrack || _ctrl.title.isNotEmpty;
    final statusText = _ctrl.statusText;
    final dur = _ctrl.duration;
    final pos = _seeking ? Duration(seconds: _seekValue.toInt()) : _ctrl.position;
    final maxDur = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;

    return Container(
      height: 72,
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        // --- Cover + Title/Artist ---
        // 顯示也用 canPlay：直接播放（首頁卡/show▶）沒設 queue，舊的 hasTrack
        // 分支會掉進「無封面槽＋灰字」的 else（診斷已證 art URL 有送到）。
        if (canPlay) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 48, height: 48,
              color: AppColors.surfaceLight,
              child: _buildCover(),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 140,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_ctrl.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                Text(_ctrl.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ] else ...[
          const SizedBox(width: 58, height: 48),
          const SizedBox(width: 10),
          SizedBox(
            width: 140,
            child: Text(
              statusText.isNotEmpty ? statusText : (_ctrl.title.isNotEmpty ? _ctrl.title : '未播放'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: statusText.isNotEmpty ? Colors.orange : (canPlay ? AppColors.text : AppColors.textMuted.withValues(alpha: 0.5)),
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],

        // --- Previous ---
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded, size: 22),
          onPressed: hasTrack ? _ctrl.previous : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28),
        ),

        // --- Play/Pause ---
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: canPlay ? Colors.white : AppColors.surfaceLight,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(_ctrl.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 24, color: Colors.black),
            onPressed: canPlay ? _ctrl.togglePlay : null,
            padding: EdgeInsets.zero,
          ),
        ),

        // --- Next ---
        IconButton(
          icon: const Icon(Icons.skip_next_rounded, size: 22),
          onPressed: hasTrack ? _ctrl.next : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28),
        ),

        // --- Shuffle + Loop ---
        IconButton(
          icon: Icon(Icons.shuffle_rounded, size: 16,
              color: _ctrl.shuffle ? AppColors.accent : AppColors.textMuted),
          onPressed: canPlay ? _ctrl.toggleShuffle : null,
          tooltip: _ctrl.shuffle ? '隨機播放 (開)' : '隨機播放 (關)',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24),
        ),
        IconButton(
          icon: Icon(_ctrl.loop ? Icons.repeat_rounded : Icons.repeat_one_rounded, size: 16,
              color: _ctrl.loop ? AppColors.accent : AppColors.textMuted),
          onPressed: canPlay ? _ctrl.toggleLoop : null,
          tooltip: _ctrl.loop ? '循環播放' : '單曲循環',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24),
        ),

        // --- Seek bar ---
        Expanded(
          child: Row(children: [
            Text(_fmt(pos), style: const TextStyle(fontSize: 10, fontFamily: 'Consolas', color: AppColors.textMuted)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                  activeTrackColor: AppColors.accent, inactiveTrackColor: AppColors.surfaceLight,
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: _seeking ? _seekValue : pos.inMilliseconds.toDouble().clamp(0, maxDur),
                  max: maxDur,
                  onChanged: canPlay ? (v) => setState(() { _seeking = true; _seekValue = v; }) : null,
                  onChangeEnd: (v) {
                    _seeking = false;
                    _ctrl.seek(Duration(milliseconds: v.toInt()));
                  },
                ),
              ),
            ),
            Text(_fmt(dur), style: const TextStyle(fontSize: 10, fontFamily: 'Consolas', color: AppColors.textMuted)),
          ]),
        ),

        // --- Volume ---
        const SizedBox(width: 4),
        const Icon(Icons.volume_up_rounded, size: 16, color: AppColors.textMuted),
        SizedBox(
          width: 80,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
              activeTrackColor: AppColors.textSecondary, inactiveTrackColor: AppColors.surfaceLight,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: _ctrl.volume,
              onChanged: _ctrl.setVolume,
            ),
          ),
        ),

        // --- Queue button ---
        IconButton(
          icon: const Icon(Icons.queue_music_rounded, size: 18),
          onPressed: hasTrack ? () => _showQueueDrawer(context) : null,
          tooltip: '播放佇列',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28),
        ),
        // --- Sleep timer ---
        IconButton(
          icon: Icon(Icons.bedtime_outlined, size: 18,
              color: _ctrl.sleepEndsAt != null ? Colors.orange : AppColors.textMuted),
          onPressed: canPlay ? () => _showSleepMenu(context) : null,
          tooltip: _ctrl.sleepEndsAt != null ? '睡眠定時器 (${_ctrl.sleepRemainingText})' : '睡眠定時器',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28),
        ),
        // --- Crossfade toggle ---
        IconButton(
          icon: Icon(Icons.linear_scale_rounded, size: 18,
              color: ConfigService.instance.config.crossfadeEnabled ? AppColors.accent : AppColors.textMuted),
          onPressed: () {
            final c = ConfigService.instance.config;
            c.crossfadeEnabled = !c.crossfadeEnabled;
            ConfigService.instance.save();
            setState(() {});
          },
          tooltip: ConfigService.instance.config.crossfadeEnabled ? 'Crossfade 開' : 'Crossfade 關',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28),
        ),
      ]),
    );
  }

  void _showQueueDrawer(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      isScrollControlled: true,
      builder: (_) => const _QueueDrawer(),
    );
  }

  void _showSleepMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(14), child: Text('睡眠定時器', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
        ...const [15, 30, 60, 120].map((m) => ListTile(
          dense: true,
          leading: const Icon(Icons.timer_outlined, color: AppColors.textMuted, size: 18),
          title: Text('$m 分鐘', style: const TextStyle(fontSize: 13)),
          onTap: () { Navigator.pop(ctx); _ctrl.setSleepTimer(Duration(minutes: m)); },
        )),
        ListTile(
          dense: true,
          leading: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 18),
          title: const Text('取消定時器', style: TextStyle(fontSize: 13)),
          onTap: () { Navigator.pop(ctx); _ctrl.setSleepTimer(null); },
        ),
      ])),
    );
  }
}

class _QueueDrawer extends StatefulWidget {
  const _QueueDrawer();
  @override
  State<_QueueDrawer> createState() => _QueueDrawerState();
}

class _QueueDrawerState extends State<_QueueDrawer> {
  final _ctrl = PlayerController.instance;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onState);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onState);
    super.dispose();
  }

  void _onState() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final queue = _ctrl.queueTitles;
    final cur = _ctrl.index;
    return SizedBox(
      height: (queue.length * 48.0 + 70).clamp(200.0, 560.0),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
          child: Row(children: [
            const Icon(Icons.queue_music_rounded, color: AppColors.textMuted, size: 18),
            const SizedBox(width: 8),
            Text('播放佇列 (${queue.length})', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (queue.isNotEmpty) IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error, size: 18),
              tooltip: '清除佇列',
              onPressed: () {
                _ctrl.clearQueue();
                Navigator.of(context).pop();
              },
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 18),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ]),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: queue.length,
            onReorderItem: (oldIndex, newIndex) {
              _ctrl.moveInQueue(oldIndex, newIndex);
            },
            itemBuilder: (ctx, i) {
              final isCur = i == cur;
              return ListTile(
                key: ValueKey('$i-${queue[i]}'),
                dense: true,
                leading: ReorderableDragStartListener(
                  index: i,
                  child: const Icon(Icons.drag_handle_rounded, color: AppColors.textMuted, size: 18),
                ),
                title: Text(queue[i],
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: isCur ? AppColors.accent : AppColors.text,
                        fontWeight: isCur ? FontWeight.w600 : FontWeight.normal)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!isCur) IconButton(
                    icon: const Icon(Icons.play_arrow_rounded, color: AppColors.textMuted, size: 18),
                    onPressed: () => _ctrl.jumpTo(i),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 18),
                    onPressed: () => _ctrl.removeFromQueue(i),
                  ),
                ]),
                onTap: isCur ? null : () => _ctrl.jumpTo(i),
              );
            },
          ),
        ),
      ]),
    );
  }
}
