import 'package:flutter/material.dart';
import '../services/player_controller.dart';
import 'dark_theme.dart';

/// 右側常駐佇列面板（Spotify 式三欄的右欄）：
/// 標題列（數量 / 清除 / 關閉）+ 佇列清單。桌機版由 MainShell.toggleQueue() 切換。
class QueuePanel extends StatefulWidget {
  final VoidCallback onClose;
  const QueuePanel({super.key, required this.onClose});

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
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
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(left: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(children: [
            const Icon(Icons.queue_music_rounded, color: AppColors.textMuted, size: 18),
            const SizedBox(width: 8),
            Text('播放佇列 (${_ctrl.queueTitles.length})',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (_ctrl.queueTitles.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error, size: 18),
                tooltip: '清除佇列',
                onPressed: _ctrl.clearQueue,
              ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 18),
              tooltip: '關閉面板',
              onPressed: widget.onClose,
            ),
          ]),
        ),
        const Expanded(child: QueueList()),
      ]),
    );
  }
}

/// 佇列清單本體：抽屜（手機）與右側面板（桌機）共用 — 可排序/點擊跳播/移除。
class QueueList extends StatefulWidget {
  const QueueList({super.key});

  @override
  State<QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<QueueList> {
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
    if (queue.isEmpty) {
      return const Center(
          child: Text('佇列是空的',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12)));
    }
    return ReorderableListView.builder(
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
            child: const Icon(Icons.drag_handle_rounded,
                color: AppColors.textMuted, size: 18),
          ),
          title: Text(queue[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: isCur ? AppColors.accent : AppColors.text,
                  fontWeight: isCur ? FontWeight.w600 : FontWeight.normal)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (!isCur)
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded,
                    color: AppColors.textMuted, size: 18),
                onPressed: () => _ctrl.jumpTo(i),
              ),
            IconButton(
              icon: const Icon(Icons.close_rounded,
                  color: AppColors.textMuted, size: 18),
              onPressed: () => _ctrl.removeFromQueue(i),
            ),
          ]),
          onTap: isCur ? null : () => _ctrl.jumpTo(i),
        );
      },
    );
  }
}
