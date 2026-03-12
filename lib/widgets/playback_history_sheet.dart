import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/playback_history_service.dart';
import 'status_message_view.dart';

void showPlaybackHistorySheet(
  BuildContext context, {
  required String itemId,
  required Color accent,
  required bool canSeek,
  required void Function(Duration position) onSeek,
  double? livePositionSeconds,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.05,
      snap: true,
      maxChildSize: 0.9,
      builder: (_, sc) => PlaybackHistorySheet(
        itemId: itemId,
        accent: accent,
        scrollController: sc,
        canSeek: canSeek,
        onSeek: onSeek,
        livePositionSeconds: livePositionSeconds,
      ),
    ),
  );
}

class PlaybackHistorySheet extends StatefulWidget {
  final String itemId;
  final Color accent;
  final ScrollController scrollController;
  final bool canSeek;
  final void Function(Duration position) onSeek;
  final double? livePositionSeconds;

  const PlaybackHistorySheet({
    super.key,
    required this.itemId,
    required this.accent,
    required this.scrollController,
    required this.canSeek,
    required this.onSeek,
    this.livePositionSeconds,
  });

  @override
  State<PlaybackHistorySheet> createState() => _PlaybackHistorySheetState();
}

class _PlaybackHistorySheetState extends State<PlaybackHistorySheet> {
  late Future<List<PlaybackEvent>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = _loadHistory();
  }

  Future<List<PlaybackEvent>> _loadHistory() {
    final api = context.read<AuthProvider>().apiService;
    return PlaybackHistoryService().getMergedHistory(
      widget.itemId,
      api: api,
      syncWithServer: widget.livePositionSeconds == null,
      livePositionSeconds: widget.livePositionSeconds,
    );
  }

  Future<void> _clearHistory() async {
    await PlaybackHistoryService().clearHistory(widget.itemId);
    if (!mounted) return;
    setState(() {
      _historyFuture = _loadHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).bottomSheetTheme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top:
              BorderSide(color: widget.accent.withValues(alpha: 0.2), width: 1),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Spacer(),
                Text(
                  'Playback History',
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  onPressed: _clearHistory,
                  tooltip: 'Clear local history',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              widget.canSeek
                  ? 'Tap an event to jump to that position'
                  : 'Local and server state are merged here when available',
              style: tt.bodySmall?.copyWith(
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<PlaybackEvent>>(
              future: _historyFuture,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }

                final events = snap.data!;
                if (events.isEmpty) {
                  return const StatusMessageView(
                    icon: Icons.history_rounded,
                    title: 'No playback history yet',
                    message:
                        'Your recent play, pause, seek, and progress snapshots for this item will appear here.',
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  );
                }

                final items = <Widget>[];
                String? lastDateLabel;
                for (final event in events) {
                  final dateLabel = _dateLabel(event.timestamp);
                  if (dateLabel != lastDateLabel) {
                    lastDateLabel = dateLabel;
                    items.add(
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          dateLabel,
                          style: tt.labelSmall?.copyWith(
                            color: widget.accent.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    );
                  }

                  final posLabel = _fmtTime(event.positionSeconds);
                  final timeStr = _timeOfDay(event.timestamp);

                  items.add(
                    ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -2),
                      leading: Icon(
                        _historyIcon(event.type),
                        size: 18,
                        color: widget.accent.withValues(alpha: 0.7),
                      ),
                      title: Text(
                        event.label,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      subtitle: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'at $posLabel',
                            style: tt.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          if (event.synthetic ||
                              event.source != PlaybackEventSource.local)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _sourceColor(event.source, cs)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: _sourceColor(event.source, cs)
                                        .withValues(alpha: 0.2),
                                  ),
                                ),
                                child: Text(
                                  event.sourceLabel,
                                  style: tt.labelSmall?.copyWith(
                                    color: _sourceColor(event.source, cs)
                                        .withValues(alpha: 0.9),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      trailing: Text(
                        timeStr,
                        style: tt.labelSmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.3),
                        ),
                      ),
                      onTap: widget.canSeek
                          ? () {
                              widget.onSeek(
                                Duration(
                                    seconds: event.positionSeconds.round()),
                              );
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(seconds: 3),
                                  content: Text('Jumped to $posLabel'),
                                ),
                              );
                            }
                          : null,
                    ),
                  );
                }

                return ListView(
                  controller: widget.scrollController,
                  children: items,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _sourceColor(PlaybackEventSource source, ColorScheme cs) {
    switch (source) {
      case PlaybackEventSource.local:
        return cs.primary;
      case PlaybackEventSource.server:
        return Colors.teal;
      case PlaybackEventSource.both:
        return Colors.indigo;
    }
  }

  IconData _historyIcon(PlaybackEventType type) {
    switch (type) {
      case PlaybackEventType.play:
        return Icons.play_arrow_rounded;
      case PlaybackEventType.pause:
        return Icons.pause_rounded;
      case PlaybackEventType.seek:
        return Icons.swap_horiz_rounded;
      case PlaybackEventType.syncLocal:
        return Icons.save_alt_rounded;
      case PlaybackEventType.syncServer:
        return Icons.cloud_done_rounded;
      case PlaybackEventType.autoRewind:
        return Icons.replay_10_rounded;
      case PlaybackEventType.skipForward:
        return Icons.forward_10_rounded;
      case PlaybackEventType.skipBackward:
        return Icons.replay_10_rounded;
      case PlaybackEventType.speedChange:
        return Icons.speed_rounded;
    }
  }

  String _fmtTime(double seconds) {
    var s = seconds;
    if (s < 0) s = 0;
    final h = (s / 3600).floor();
    final m = ((s % 3600) / 60).floor();
    final sec = (s % 60).floor();
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _dateLabel(DateTime dt) {
    final now = DateTime.now();
    final d = DateTime(dt.year, dt.month, dt.day);
    final n = DateTime(now.year, now.month, now.day);
    final diff = n.difference(d).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _timeOfDay(DateTime dt) {
    var h = dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    if (h == 0) h = 12;
    return '$h:$m $ampm';
  }
}
