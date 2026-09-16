import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/jam_service.dart';
import '../services/player_controller.dart';
import '../widgets/dark_theme.dart';

/// 「一起聽」— Cloudflare Relay 版 Spotify Jam。
/// 不需輸入 IP，任何網路都能加入。
class JamPage extends StatefulWidget {
  const JamPage({super.key});
  @override
  State<JamPage> createState() => _JamPageState();
}

class _JamPageState extends State<JamPage> {
  final _nameCtrl = TextEditingController(text: '我');
  final _codeCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();
  final _chatScroll = ScrollController();
  Timer? _searchDebounce;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    JamService.instance.addListener(_onChanged);
    PlayerController.instance.addListener(_onChanged);
    _nameCtrl.text = '我';
  }

  @override
  void dispose() {
    JamService.instance.removeListener(_onChanged);
    PlayerController.instance.removeListener(_onChanged);
    _searchDebounce?.cancel();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _searchCtrl.dispose();
    _chatCtrl.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      JamService.instance.search(q);
    });
  }

  @override
  Widget build(BuildContext context) {
    final jam = JamService.instance;
    final active = jam.mode != 'idle';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: active ? _buildRoom(context, jam) : _buildLanding(context, jam),
    );
  }

  // ===================================================================
  //  尚未加入房間
  // ===================================================================

  Widget _buildLanding(BuildContext context, JamService jam) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.groups_rounded, size: 64, color: AppColors.accent),
              const SizedBox(height: 12),
              const Text('一起聽',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('免費版 Spotify Jam — 任何網路、不用輸入 IP',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 24),
              _field('你的暱稱', _nameCtrl, hint: '例如：小拇哥'),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  await JamService.instance.startHost(name: _nameCtrl.text.trim());
                },
                icon: const Icon(Icons.add_box_rounded, size: 18),
                label: const Text('建立新房間（我是房主）'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Row(children: [
                  Expanded(child: Divider()),
                  Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('或', style: TextStyle(color: AppColors.textMuted, fontSize: 12))),
                  Expanded(child: Divider()),
                ]),
              ),
              _field('輸入房間代碼', _codeCtrl, hint: '6 位碼', maxLength: 6),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _joining
                    ? null
                    : () async {
                        setState(() => _joining = true);
                        await JamService.instance.connect(
                          code: _codeCtrl.text.trim(),
                          name: _nameCtrl.text.trim(),
                        );
                        if (mounted) setState(() => _joining = false);
                      },
                icon: const Icon(Icons.login_rounded, size: 18),
                label: Text(_joining ? '加入中…' : '加入房間'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              if (jam.lastError.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(jam.lastError,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.error, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              const Text('🔒 免費・免註冊・免 IP — 只要同個代碼就能一起聽',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {String? hint, int? maxLength}) {
    return TextField(
      controller: ctrl,
      maxLength: maxLength,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        counterText: '',
        filled: true,
        fillColor: AppColors.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  // ===================================================================
  //  房間內
  // ===================================================================

  Widget _buildRoom(BuildContext context, JamService jam) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final wide = constraints.maxWidth > 820;
      final left = _buildLeft(jam);
      final right = _buildRight(jam);
      return Column(children: [
        _roomHeader(jam),
        const SizedBox(height: 12),
        Expanded(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: left),
                  const SizedBox(width: 12),
                  Expanded(child: right),
                ])
              : ListView(children: [left, const SizedBox(height: 12), right]),
        ),
      ]);
    });
  }

  Widget _roomHeader(JamService jam) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        // QR Code
        QrImageView(
          data: jam.roomCode,
          version: QrVersions.auto,
          size: 64,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(color: Colors.black),
          dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
        ),
        const SizedBox(width: 12),
        // Code + info
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(jam.isHost ? '我是房主' : '我是成員',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
            const SizedBox(height: 2),
            Text(jam.roomCode,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 4)),
          ]),
        ),
        // 成員 chips
        Wrap(spacing: 6, children: [
          for (final m in jam.members)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: m['isHost'] == true ? AppColors.accentDim : AppColors.bg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${m['isHost'] == true ? '👑 ' : ''}${m['name']}',
                style: TextStyle(
                    fontSize: 11,
                    color: m['isHost'] == true ? AppColors.accent : AppColors.text),
              ),
            ),
        ]),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '複製代碼',
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: jam.roomCode));
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已複製'), duration: Duration(seconds: 1)));
          },
        ),
        IconButton(
          tooltip: '離開房間',
          icon: const Icon(Icons.logout_rounded, size: 18),
          onPressed: () => JamService.instance.leaveRoom(),
        ),
      ]),
    );
  }

  Widget _buildLeft(JamService jam) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _nowPlayingCard(jam),
      const SizedBox(height: 12),
      _searchCard(jam),
    ]);
  }

  Widget _nowPlayingCard(JamService jam) {
    final pc = PlayerController.instance;
    final t = jam.current;
    final dur = pc.duration.inMilliseconds;
    final pos = pc.position.inMilliseconds;
    final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
    final skipActive = jam.mySkip;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t == null ? '尚未播放' : '現在播放',
                  style: const TextStyle(fontSize: 10, color: AppColors.textMuted, letterSpacing: 1)),
              const SizedBox(height: 4),
              Text(
                t == null ? '—' : (t['title'] as String? ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                t == null ? '' : (t['artist'] as String? ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ]),
          ),
          IconButton(
            tooltip: '播放 / 暫停',
            iconSize: 44,
            icon: Icon(
              pc.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
              color: AppColors.accent,
            ),
            onPressed: () => JamService.instance.togglePlay(),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '投票跳過',
            icon: Icon(
              skipActive ? Icons.fast_forward_rounded : Icons.fast_forward_outlined,
              color: skipActive ? AppColors.accent : AppColors.textMuted,
            ),
            onPressed: t == null ? null : () => JamService.instance.toggleSkip(),
          ),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: AppColors.bg,
            valueColor: const AlwaysStoppedAnimation(AppColors.accent),
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Text(_fmt(pos), style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          const Spacer(),
          if (jam.skipNeeded > 0)
            Text('跳過 ${jam.skipVotes}/${jam.skipNeeded}',
                style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          const Spacer(),
          Text(_fmt(dur), style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ]),
      ]),
    );
  }

  Widget _searchCard(JamService jam) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.search_rounded, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 6),
          const Text('加歌', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (jam.searchError.isNotEmpty)
            Expanded(
              child: Text(jam.searchError,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: AppColors.error)),
            ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _searchCtrl,
          onChanged: (_) => _onSearchChanged(),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: '搜尋歌曲、歌手…（房主需先登入 Spotify）',
            isDense: true,
            filled: true,
            fillColor: AppColors.bg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (jam.searching)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(8), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
        else if (jam.searchResults.isNotEmpty)
          ...jam.searchResults.map((r) => _searchResultTile(jam, r)),
      ]),
    );
  }

  Widget _searchResultTile(JamService jam, Map<String, dynamic> r) {
    final name = r['name'] as String? ?? '';
    final artists = (r['artists'] as List? ?? []).join(', ');
    final cover = r['coverUrl'] as String?;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: cover != null && cover.isNotEmpty
            ? Image.network(cover, width: 34, height: 34, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _coverPlaceholder())
            : _coverPlaceholder(),
      ),
      title: Text(name,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12)),
      subtitle: Text(artists,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
      trailing: IconButton(
        tooltip: '加入佇列',
        icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.accent, size: 20),
        onPressed: () {
          JamService.instance.addTrackFromSearch(r);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已加入：$name'), duration: const Duration(seconds: 1)));
        },
      ),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      width: 34, height: 34,
      color: AppColors.bg,
      child: const Icon(Icons.music_note_rounded, size: 16, color: AppColors.textMuted),
    );
  }

  Widget _buildRight(JamService jam) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _queueCard(jam),
      const SizedBox(height: 12),
      _chatCard(jam),
    ]);
  }

  Widget _queueCard(JamService jam) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.queue_music_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 6),
          Text('播放佇列（${jam.queue.length}）',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        if (jam.queue.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('歌單空空的，用上面「加歌」搜尋加入吧！',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
          )
        else
          ...jam.queue.asMap().entries.map((e) {
            final t = e.value;
            final isCurrent = jam.current?['id'] == t['id'];
            final title = t['title'] as String? ?? '';
            final artist = t['artist'] as String? ?? '';
            final addedBy = t['addedBy'] as String? ?? '';
            final votes = t['votes'] as int? ?? 0;
            final myVote = jam.myVote(t['id'] as String? ?? '');
            final kind = t['kind'] == 'local' ? '本機' : '串流';
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isCurrent ? AppColors.accentDim : AppColors.bg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(
                  isCurrent ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                  color: isCurrent ? AppColors.accent : AppColors.textMuted,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal)),
                    Text('$artist · $addedBy · $kind',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                  ]),
                ),
                Column(children: [
                  InkWell(
                    onTap: () => JamService.instance.vote(t['id'] as String?, 1),
                    child: Icon(Icons.arrow_upward_rounded,
                        size: 16,
                        color: myVote == 1 ? AppColors.accent : AppColors.textMuted),
                  ),
                  Text('$votes',
                      style: TextStyle(
                          fontSize: 10,
                          color: myVote != 0 ? AppColors.accent : AppColors.textMuted)),
                  InkWell(
                    onTap: () => JamService.instance.vote(t['id'] as String?, -1),
                    child: Icon(Icons.arrow_downward_rounded,
                        size: 16,
                        color: myVote == -1 ? AppColors.accent : AppColors.textMuted),
                  ),
                ]),
                if (jam.isHost)
                  IconButton(
                    tooltip: '移除',
                    icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.textMuted),
                    onPressed: () => JamService.instance.removeTrack(t['id'] as String? ?? ''),
                  ),
              ]),
            );
          }),
      ]),
    );
  }

  Widget _chatCard(JamService jam) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.chat_rounded, size: 18, color: AppColors.accent),
          SizedBox(width: 6),
          Text('聊天室', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView.builder(
            controller: _chatScroll,
            shrinkWrap: true,
            itemCount: jam.chat.length,
            itemBuilder: (ctx, i) {
              final c = jam.chat[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${c['text']}',
                    style: const TextStyle(fontSize: 11, height: 1.3)),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _chatCtrl,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: '說點什麼…',
                isDense: true,
                filled: true,
                fillColor: AppColors.bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _sendChat(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '送出',
            icon: const Icon(Icons.send_rounded, color: AppColors.accent, size: 20),
            onPressed: _sendChat,
          ),
        ]),
      ]),
    );
  }

  void _sendChat() {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty) return;
    JamService.instance.sendChat(text);
    _chatCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(_chatScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  String _fmt(int ms) {
    if (ms <= 0) return '0:00';
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}