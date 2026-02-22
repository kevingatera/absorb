import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/bookmark_service.dart';
import '../services/sleep_timer_service.dart';
import 'absorb_slider.dart';
import 'sleep_timer_sheet.dart';

/// Show a toast when the user taps a button that requires active playback.
void showInactiveToast(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(const SnackBar(
      content: Text('Start playing a book first'),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
}

// ─── WIDE GLASS BUTTON (for 2-column grid) ─────────────────

class CardWideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final bool isActive;
  final bool alwaysEnabled;
  final VoidCallback? onTap;
  final Widget? child; // if provided, renders child instead (for stateful buttons)

  const CardWideButton({
    super.key,
    required this.icon, required this.label,
    required this.accent, required this.isActive,
    this.alwaysEnabled = false,
    this.onTap, this.child,
  });

  @override Widget build(BuildContext context) {
    if (child != null) return child!;
    final enabled = isActive || alwaysEnabled;
    return GestureDetector(
      onTap: enabled ? onTap : () => showInactiveToast(context),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: enabled ? Colors.white54 : Colors.white24),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
              color: enabled ? Colors.white54 : Colors.white24,
              fontSize: 11, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// Menu item for the More bottom sheet
class MoreMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  const MoreMenuItem({
    super.key,
    required this.icon, required this.label,
    required this.accent, required this.onTap,
    this.enabled = true,
  });

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : () => showInactiveToast(context),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: enabled ? accent.withValues(alpha: 0.7) : Colors.white24),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: TextStyle(
              color: enabled ? Colors.white.withValues(alpha: 0.8) : Colors.white24,
              fontSize: 14, fontWeight: FontWeight.w500))),
            Icon(Icons.chevron_right_rounded, size: 18, color: enabled ? Colors.white24 : Colors.white12),
          ],
        ),
      ),
    );
  }
}

/// Sleep button as wide card with countdown and fill bar
class CardSleepButtonInline extends StatelessWidget {
  final Color accent;
  final bool isActive;
  const CardSleepButtonInline({super.key, required this.accent, required this.isActive});

  @override Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SleepTimerService(),
      builder: (_, __) {
        final sleep = SleepTimerService();
        // Only show timer state on the card that's actually playing
        final active = isActive && sleep.isActive;
        final isTime = sleep.mode == SleepTimerMode.time;

        String label;
        if (active && isTime) {
          final r = sleep.timeRemaining;
          final m = r.inMinutes;
          final s = r.inSeconds % 60;
          label = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
        } else if (active) {
          label = '${sleep.chaptersRemaining} ch left';
        } else {
          label = 'Sleep Timer';
        }

        return GestureDetector(
          onTap: isActive ? () {
            showSleepTimerSheet(context, accent);
          } : () => showInactiveToast(context),
          child: Container(
            height: 36,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: active ? accent.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: active ? accent.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.08)),
            ),
            child: Stack(children: [
              if (active && isTime)
                FractionallySizedBox(
                  widthFactor: sleep.timeProgress.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
              Center(child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bedtime_outlined, size: 16,
                    color: active ? accent : (isActive ? Colors.white54 : Colors.white24)),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(
                    color: active ? accent : (isActive ? Colors.white54 : Colors.white24),
                    fontSize: active && isTime ? 13 : 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    fontFeatures: active && isTime ? const [FontFeature.tabularFigures()] : null,
                  )),
                ],
              )),
            ]),
          ),
        );
      },
    );
  }
}

/// Bookmark button as wide card
class CardBookmarkButtonInline extends StatefulWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  final String itemId;
  const CardBookmarkButtonInline({super.key, required this.player, required this.accent, required this.isActive, required this.itemId});
  @override State<CardBookmarkButtonInline> createState() => _CardBookmarkButtonInlineState();
}

class _CardBookmarkButtonInlineState extends State<CardBookmarkButtonInline> {
  int _count = 0;
  @override void initState() { super.initState(); _loadCount(); }
  Future<void> _loadCount() async {
    final c = await BookmarkService().getCount(widget.itemId);
    if (mounted) setState(() => _count = c);
  }

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isActive ? () => _showBookmarks(context) : () => showInactiveToast(context),
      onLongPress: widget.isActive ? () => _quickAdd(context) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bookmark_outline_rounded, size: 18,
              color: widget.isActive ? Colors.white54 : Colors.white24),
            const SizedBox(width: 8),
            Text(_count > 0 ? 'Bookmarks ($_count)' : 'Bookmark', style: TextStyle(
              color: widget.isActive ? Colors.white54 : Colors.white24,
              fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  void _quickAdd(BuildContext ctx) async {
    final pos = widget.player.position.inMilliseconds / 1000.0;
    String? chTitle;
    for (final ch in widget.player.chapters) {
      final m = ch as Map<String, dynamic>;
      final s = (m['start'] as num?)?.toDouble() ?? 0;
      final e = (m['end'] as num?)?.toDouble() ?? 0;
      if (pos >= s && pos < e) { chTitle = m['title'] as String?; break; }
    }
    await BookmarkService().addBookmark(itemId: widget.itemId, positionSeconds: pos, title: chTitle ?? 'Bookmark');
    _loadCount();
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: const Text('Bookmark added'), behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }

  void _showBookmarks(BuildContext context) {
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent, isScrollControlled: true, useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6, minChildSize: 0.3, maxChildSize: 0.9, expand: false,
        builder: (ctx, sc) => SimpleBookmarkSheet(itemId: widget.itemId, player: widget.player, accent: widget.accent, scrollController: sc, onChanged: _loadCount),
      ),
    );
  }
}

/// Speed button as wide card — opens the full speed sheet with slider
class CardSpeedButtonInline extends StatelessWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  const CardSpeedButtonInline({super.key, required this.player, required this.accent, required this.isActive});

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isActive ? () {
        showModalBottomSheet(context: context, backgroundColor: Colors.transparent,
          useSafeArea: true,
          builder: (ctx) => CardSpeedSheet(player: player, accent: accent));
      } : () => showInactiveToast(context),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.speed_rounded, size: 16,
              color: isActive ? accent : Colors.white24),
            const SizedBox(width: 8),
            Text('${player.speed.toStringAsFixed(2)}x', style: TextStyle(
              color: isActive ? accent : Colors.white24,
              fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

// ─── SPEED SHEET ─────────────────────────────────────────────

class CardSpeedSheet extends StatefulWidget {
  final AudioPlayerService player; final Color accent;
  const CardSpeedSheet({super.key, required this.player, required this.accent});
  @override State<CardSpeedSheet> createState() => _CardSpeedSheetState();
}

class _CardSpeedSheetState extends State<CardSpeedSheet> {
  late double _speed;
  static const _presets = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5];

  @override void initState() { super.initState(); _speed = (widget.player.speed * 20).round() / 20.0; }
  void _setSpeed(double v) { final s = (v * 20).round() / 20.0; setState(() => _speed = s.clamp(0.5, 3.0)); widget.player.setSpeed(_speed); }

  @override Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final navBarPad = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + navBarPad),
      decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: widget.accent.withValues(alpha: 0.2), width: 1))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 20),
        Text('Playback Speed', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
        const SizedBox(height: 4),
        Text('${_speed.toStringAsFixed(2)}x', style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: widget.accent)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: _presets.map((s) {
          final a = (_speed - s).abs() < 0.01;
          return GestureDetector(onTap: () => _setSpeed(s), child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: a ? widget.accent : Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(20),
              border: Border.all(color: a ? widget.accent : Colors.white.withValues(alpha: 0.12))),
            child: Text('${s}x', style: TextStyle(color: a ? Colors.black : Colors.white70, fontSize: 13, fontWeight: a ? FontWeight.w700 : FontWeight.w500)),
          ));
        }).toList()),
        const SizedBox(height: 16),
        AbsorbSlider(value: _speed, min: 0.5, max: 3.0, divisions: 50, activeColor: widget.accent, onChanged: _setSpeed),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Text('0.5x', style: TextStyle(color: Colors.white30, fontSize: 11)),
            Text('3.0x', style: TextStyle(color: Colors.white30, fontSize: 11)),
          ],
        )),
      ]),
    );
  }
}

// ─── BOOKMARK SHEET ──────────────────────────────────────────

class SimpleBookmarkSheet extends StatefulWidget {
  final String itemId; final AudioPlayerService player; final Color accent; final ScrollController scrollController; final VoidCallback onChanged;
  const SimpleBookmarkSheet({super.key, required this.itemId, required this.player, required this.accent, required this.scrollController, required this.onChanged});
  @override State<SimpleBookmarkSheet> createState() => _SimpleBookmarkSheetState();
}

class _SimpleBookmarkSheetState extends State<SimpleBookmarkSheet> {
  List<Bookmark>? _bookmarks;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final bm = await BookmarkService().getBookmarks(widget.itemId);
    if (mounted) setState(() => _bookmarks = bm);
    widget.onChanged();
  }

  @override Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: widget.accent.withValues(alpha: 0.2), width: 1)),
      ),
      child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
          const Spacer(),
          Text('Bookmarks', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
          const Spacer(),
          GestureDetector(onTap: () => _addBookmark(), child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: widget.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.add_rounded, color: widget.accent, size: 20),
          )),
        ])),
        const SizedBox(height: 8),
        Expanded(child: _bookmarks == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _bookmarks!.isEmpty
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.bookmark_outline_rounded, size: 48, color: Colors.white.withValues(alpha: 0.1)),
                    const SizedBox(height: 12),
                    Text('No bookmarks yet', style: tt.bodyMedium?.copyWith(color: Colors.white38)),
                    const SizedBox(height: 4),
                    Text('Long-press the bookmark button to quick save', style: tt.bodySmall?.copyWith(color: Colors.white24, fontSize: 11)),
                  ]))
                : ListView.builder(
                    controller: widget.scrollController, padding: const EdgeInsets.only(bottom: 24), itemCount: _bookmarks!.length,
                    itemBuilder: (ctx, i) {
                      final bm = _bookmarks![i];
                      final hasNote = bm.note != null && bm.note!.isNotEmpty;
                      return InkWell(
                        onTap: () { widget.player.seekTo(Duration(seconds: bm.positionSeconds.round())); Navigator.pop(ctx); },
                        onLongPress: () => _editBookmark(bm),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(Icons.bookmark_rounded, size: 20, color: widget.accent),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(bm.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: tt.bodyMedium?.copyWith(color: Colors.white70)),
                              const SizedBox(height: 2),
                              Text(bm.formattedPosition, style: tt.labelSmall?.copyWith(color: Colors.white38)),
                              if (hasNote) ...[
                                const SizedBox(height: 4),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(bm.note!, maxLines: 3, overflow: TextOverflow.ellipsis,
                                    style: tt.bodySmall?.copyWith(color: Colors.white38, fontSize: 11, height: 1.4)),
                                ),
                              ],
                            ])),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () async {
                                await BookmarkService().deleteBookmark(itemId: widget.itemId, bookmarkId: bm.id);
                                _load();
                              },
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close_rounded, size: 16, color: Colors.white24),
                              ),
                            ),
                          ]),
                        ),
                      );
                    })),
      ]),
    );
  }

  Future<void> _addBookmark() async {
    final pos = widget.player.position.inMilliseconds / 1000.0;
    final h = pos ~/ 3600; final m = (pos % 3600) ~/ 60; final s = pos.toInt() % 60;
    final posStr = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';

    // Find current chapter name for default title
    String defaultTitle = 'Bookmark at $posStr';
    for (final ch in widget.player.chapters) {
      final cm = ch as Map<String, dynamic>;
      final cs = (cm['start'] as num?)?.toDouble() ?? 0;
      final ce = (cm['end'] as num?)?.toDouble() ?? 0;
      if (pos >= cs && pos < ce) { defaultTitle = cm['title'] as String? ?? defaultTitle; break; }
    }

    final titleC = TextEditingController(text: defaultTitle);
    final noteC = TextEditingController();
    final result = await showDialog<Map<String, String>>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Add Bookmark'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: titleC, autofocus: true, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: noteC, maxLines: 3, decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder(), alignLabelWithHint: true)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, {'title': titleC.text, 'note': noteC.text}), child: const Text('Save')),
      ],
    ));
    if (result != null && result['title']!.isNotEmpty) {
      final note = result['note']?.isNotEmpty == true ? result['note'] : null;
      await BookmarkService().addBookmark(itemId: widget.itemId, positionSeconds: pos, title: result['title']!, note: note);
      _load();
    }
  }

  Future<void> _editBookmark(Bookmark bm) async {
    final titleC = TextEditingController(text: bm.title);
    final noteC = TextEditingController(text: bm.note ?? '');
    final result = await showDialog<Map<String, String>>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Edit Bookmark'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: titleC, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: noteC, maxLines: 3, decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder(), alignLabelWithHint: true)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, {'title': titleC.text, 'note': noteC.text}), child: const Text('Save')),
      ],
    ));
    if (result != null && result['title']!.isNotEmpty) {
      await BookmarkService().updateBookmark(
        itemId: widget.itemId, bookmarkId: bm.id,
        title: result['title']!, note: result['note']?.isNotEmpty == true ? result['note'] : null,
      );
      _load();
    }
  }
}
