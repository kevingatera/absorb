import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:just_audio/just_audio.dart' hide PlaybackEvent;
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../services/bookmark_service.dart';
import '../services/sleep_timer_service.dart';
import '../services/playback_history_service.dart';
import '../widgets/absorb_slider.dart';
import 'absorbing_shared.dart';
import 'sleep_timer_sheet.dart';
import 'book_detail_sheet.dart';

class AbsorbingCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final AudioPlayerService player;
  const AbsorbingCard({super.key, required this.item, required this.player});

  @override
  State<AbsorbingCard> createState() => AbsorbingCardState();
}

class AbsorbingCardState extends State<AbsorbingCard> with AutomaticKeepAliveClientMixin {
  ColorScheme? _coverScheme;
  bool _isStarting = false;
  List<dynamic>? _fetchedChapters;
  StreamSubscription<Duration>? _chapterTrackSub;
  int _lastChapterIdx = -1;

  @override
  bool get wantKeepAlive => true;

  String get _itemId => widget.item['id'] as String? ?? '';
  Map<String, dynamic> get _media => widget.item['media'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _metadata => _media['metadata'] as Map<String, dynamic>? ?? {};
  String get _title => _metadata['title'] as String? ?? 'Unknown';
  String get _author => _metadata['authorName'] as String? ?? '';
  double get _duration => (_media['duration'] as num?)?.toDouble() ?? 0;
  List<dynamic> get _chapters {
    // Prefer fetched chapters (from full item), fall back to inline data
    if (_fetchedChapters != null && _fetchedChapters!.isNotEmpty) return _fetchedChapters!;
    return _media['chapters'] as List<dynamic>? ?? [];
  }
  bool get _isActive => widget.player.currentItemId == _itemId;

  String? get _coverUrl {
    final auth = context.read<AuthProvider>();
    return auth.apiService?.getCoverUrl(_itemId, width: 800);
  }

  @override
  void initState() {
    super.initState();
    _fetchChaptersIfNeeded();
    _startChapterTracking();
  }

  Future<void> _fetchChaptersIfNeeded() async {
    // If chapters are already in the item data, skip
    final inline = _media['chapters'] as List<dynamic>? ?? [];
    if (inline.isNotEmpty) return;
    // Fetch full item to get chapters
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    try {
      final fullItem = await api.getLibraryItem(_itemId);
      if (fullItem != null && mounted) {
        final media = fullItem['media'] as Map<String, dynamic>? ?? {};
        final chapters = media['chapters'] as List<dynamic>? ?? [];
        if (chapters.isNotEmpty) {
          setState(() => _fetchedChapters = chapters);
          // If this is the active book and player has no chapters, update them
          if (_isActive && widget.player.chapters.isEmpty) {
            widget.player.updateChapters(chapters);
          }
        }
      }
    } catch (_) {}
  }

  void _startChapterTracking() {
    _chapterTrackSub?.cancel();
    _chapterTrackSub = widget.player.absolutePositionStream.listen((pos) {
      if (!_isActive) return;
      final posS = pos.inMilliseconds / 1000.0;
      final chapters = widget.player.chapters.isNotEmpty ? widget.player.chapters : _chapters;
      int idx = 0;
      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i] as Map<String, dynamic>;
        final start = (ch['start'] as num?)?.toDouble() ?? 0;
        final end = (ch['end'] as num?)?.toDouble() ?? 0;
        if (posS >= start && posS < end) { idx = i; break; }
      }
      if (idx != _lastChapterIdx) {
        _lastChapterIdx = idx;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(AbsorbingCard old) {
    super.didUpdateWidget(old);
    final oldId = old.item['id'] as String? ?? '';
    if (oldId != _itemId) {
      // Item changed — reset all stale state
      _coverScheme = null;
      _fetchedChapters = null;
      _lastChapterIdx = -1;
      _fetchChaptersIfNeeded();
    }
    if (old.player != widget.player) _startChapterTracking();
  }

  @override
  void dispose() {
    _chapterTrackSub?.cancel();
    super.dispose();
  }

  void _onCoverLoaded(ImageProvider provider) {
    if (_coverScheme != null) return;
    ColorScheme.fromImageProvider(provider: provider, brightness: Brightness.dark)
        .then((s) {
          if (mounted) {
            // Delay scheme application to avoid mid-swipe rebuilds
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _coverScheme = s);
            });
          }
        })
        .catchError((_) {});
  }

  // Cache the blur filter to avoid recreating it every build
  static final _blurFilter = ImageFilter.blur(sigmaX: 40, sigmaY: 40, tileMode: TileMode.decal);

  @override
  Widget build(BuildContext context) {
    super.build(context); // required for AutomaticKeepAliveClientMixin
    final tt = Theme.of(context).textTheme;
    final cs = _coverScheme ?? Theme.of(context).colorScheme;
    final accent = cs.primary;
    final bgDark = cs.surface;

    final lib = context.watch<LibraryProvider>();
    final progress = lib.getProgress(_itemId);
    final chapterIdx = _currentChapterIndex();
    final totalChapters = _isActive ? widget.player.chapters.length : _chapters.length;
    final double bookProgress;
    if (_isActive && widget.player.totalDuration > 0) {
      final playerPos = widget.player.position.inMilliseconds / 1000.0;
      // Don't use player position if it's near zero while we have real progress
      // (means the player is still loading/seeking to resume point)
      if (playerPos < 1.0 && progress > 0.01) {
        bookProgress = progress; // Keep showing stored progress during load
      } else {
        bookProgress = (playerPos / widget.player.totalDuration).clamp(0.0, 1.0);
      }
    } else {
      bookProgress = progress;
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withValues(alpha: 0.15), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Stack(
          fit: StackFit.expand,
          children: [
          // Layer 1: Pre-blurred cover image (isolated for performance)
          if (_coverUrl != null)
            RepaintBoundary(
              child: CachedNetworkImage(
                imageUrl: _coverUrl!,
                fit: BoxFit.cover,
                imageBuilder: (_, provider) {
                  _onCoverLoaded(provider);
                  return ImageFiltered(
                    imageFilter: _blurFilter,
                    child: Image(image: provider, fit: BoxFit.cover),
                  );
                },
                placeholder: (_, __) => Container(color: Colors.black),
                errorWidget: (_, __, ___) => Container(color: Colors.black),
              ),
            ),
          // Layer 2: Scrim
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.6),
                    Colors.black.withValues(alpha: 0.85),
                  ],
                ),
              ),
            ),
          ),
          // Layer 3: Content
          Column(
            children: [
              // ── Stats row ──
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${(bookProgress * 100).clamp(0, 100).toStringAsFixed(1)}%',
                      style: tt.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontWeight: FontWeight.w800, fontSize: 15,
                        shadows: [Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 4)],
                      )),
                    if (totalChapters > 0)
                      Text('Ch ${(chapterIdx + 1).clamp(1, totalChapters)} / $totalChapters',
                        style: tt.labelMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w700, fontSize: 14,
                          shadows: [Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 4)],
                        )),
                  ],
                ),
              ),
              // ── Book progress bar ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _CardDualProgressBar(player: widget.player, accent: accent, isActive: _isActive, staticProgress: progress, staticDuration: _duration, chapters: _chapters, showBookBar: true, showChapterBar: false),
              ),
                const SizedBox(height: 10),
                // ── Cover with title/author/chapter overlaid + download badge ──
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: LayoutBuilder(
                    builder: (context, constraints) {
                      final coverWidth = constraints.maxWidth * 0.85;
                      // Use the smaller of desired width or available height to prevent squishing
                      final coverSize = coverWidth < constraints.maxHeight
                          ? coverWidth
                          : constraints.maxHeight;
                      final isDownloaded = DownloadService().isDownloaded(_itemId);
                      return Container(
                          width: coverSize,
                          height: coverSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, spreadRadius: -2, offset: const Offset(0, 6)),
                              BoxShadow(color: accent.withValues(alpha: 0.15), blurRadius: 30, spreadRadius: -5),
                            ],
                          ),
                          child: RepaintBoundary(
                            child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // Cover image
                                _coverUrl != null
                                    ? CachedNetworkImage(imageUrl: _coverUrl!, fit: BoxFit.cover,
                                          placeholder: (_, __) => _coverPlaceholder(),
                                          errorWidget: (_, __, ___) => _coverPlaceholder())
                                    : _coverPlaceholder(),
                                // Downloaded badge (top-right)
                                if (isDownloaded)
                                  Positioned(
                                    top: 8, right: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.6),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.download_done_rounded, size: 13, color: accent.withValues(alpha: 0.9)),
                                          const SizedBox(width: 4),
                                          Text('Downloaded', style: TextStyle(color: accent.withValues(alpha: 0.9), fontSize: 10, fontWeight: FontWeight.w600)),
                                        ],
                                      ),
                                    ),
                                  ),
                                // Subtle bottom gradient for chapter pill legibility
                                Positioned(
                                  left: 0, right: 0, bottom: 0,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: [
                                          Colors.black.withValues(alpha: 0.7),
                                          Colors.black.withValues(alpha: 0.3),
                                          Colors.black.withValues(alpha: 0.0),
                                        ],
                                        stops: const [0.0, 0.5, 1.0],
                                      ),
                                    ),
                                    child: const SizedBox(height: 70, width: double.infinity),
                                  ),
                                ),
                                // Chapter pill overlaid at bottom center
                                if (_chapterName(chapterIdx) != null)
                                  Positioned(
                                    left: 10, right: 10, bottom: 10,
                                    child: Center(
                                      child: Container(
                                        height: 30,
                                        clipBehavior: Clip.hardEdge,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.55),
                                          borderRadius: BorderRadius.circular(15),
                                          border: Border.all(color: accent.withValues(alpha: 0.3), width: 0.5),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 14),
                                          child: _MarqueeText(
                                            text: _chapterName(chapterIdx)!,
                                            style: tt.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.95), fontWeight: FontWeight.w600, fontSize: 13) ?? const TextStyle(fontSize: 13),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ),
                ),
                const SizedBox(height: 6),
                // ── Chapter bar + controls + buttons ──
                Expanded(
                  child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _CardDualProgressBar(player: widget.player, accent: accent, isActive: _isActive, staticProgress: progress, staticDuration: _duration, chapters: _chapters, showBookBar: false, showChapterBar: true),
                      // Flex 2:3 biases controls slightly upward to visually center
                      // (compensates for chapter time labels adding weight above)
                      const Spacer(flex: 2),
                      _CardPlaybackControls(
                        player: widget.player,
                        accent: accent,
                        isActive: _isActive,
                        isStarting: _isStarting,
                        onStart: _startPlayback,
                      ),
                      const Spacer(flex: 3),
                      // ── Button grid (hugs bottom) ──
                      // Primary actions: Chapters + Speed (larger, more prominent)
                      Row(children: [
                        Expanded(child: _CardWideButton(
                          icon: Icons.list_rounded, label: 'Chapters',
                          accent: accent, isActive: _isActive,
                          onTap: () => _showChapters(context, accent, tt),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: _CardWideButton(
                          icon: Icons.speed_rounded, label: 'Speed',
                          accent: accent, isActive: _isActive,
                          child: _CardSpeedButtonInline(player: widget.player, accent: accent, isActive: _isActive),
                        )),
                      ]),
                      const SizedBox(height: 8),
                      // Secondary actions: Sleep Timer + Bookmarks
                      Row(children: [
                        Expanded(child: _CardWideButton(
                          icon: Icons.bedtime_outlined, label: 'Sleep Timer',
                          accent: accent, isActive: _isActive,
                          child: _CardSleepButtonInline(accent: accent, isActive: _isActive),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: _CardWideButton(
                          icon: Icons.bookmark_outline_rounded, label: 'Bookmarks',
                          accent: accent, isActive: _isActive,
                          child: _CardBookmarkButtonInline(
                            player: widget.player, accent: accent,
                            isActive: _isActive, itemId: _itemId,
                          ),
                        )),
                      ]),
                      // More menu: Details + History (centered below buttons)
                      Center(
                        child: GestureDetector(
                          onTap: () => _showMoreMenu(context, accent, tt),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Icon(Icons.more_horiz_rounded, size: 22, color: Colors.white38),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                  ),
                ),
              ],
            ),
        ],
      ),
      ),
    );
  }

  int _currentChapterIndex() {
    final chapters = _isActive ? widget.player.chapters : _chapters;
    if (chapters.isEmpty) return -1;
    double pos;
    if (_isActive) {
      pos = widget.player.position.inMilliseconds / 1000.0;
    } else {
      // Use stored progress to calculate position when not actively playing
      final lib = context.read<LibraryProvider>();
      final progress = lib.getProgress(_itemId);
      pos = progress * _duration;
    }
    for (int i = 0; i < chapters.length; i++) {
      final ch = chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      if (pos >= start && pos < end) return i;
    }
    // If past the last chapter end, return last chapter
    if (pos > 0 && chapters.isNotEmpty) return chapters.length - 1;
    return 0;
  }

  String? _chapterName(int chapterIdx) {
    if (_isActive && widget.player.currentChapter != null) {
      return widget.player.currentChapter!['title'] as String?;
    }
    if (chapterIdx >= 0 && chapterIdx < _chapters.length) {
      final ch = _chapters[chapterIdx] as Map<String, dynamic>;
      return ch['title'] as String?;
    }
    return null;
  }

  Widget _coverPlaceholder() => Container(
    color: Colors.white.withValues(alpha: 0.05),
    child: Center(child: Icon(Icons.headphones_rounded, size: 48, color: Colors.white.withValues(alpha: 0.15))),
  );

  Future<void> _startPlayback() async {
    if (_isStarting) return;
    setState(() => _isStarting = true);
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) { setState(() => _isStarting = false); return; }
    await widget.player.playItem(
      api: api, itemId: _itemId, title: _title, author: _author,
      coverUrl: _coverUrl, totalDuration: _duration, chapters: _chapters,
    );
    if (mounted) setState(() => _isStarting = false);
  }

  void _showChapters(BuildContext context, Color accent, TextTheme tt) {
    final chapters = _isActive ? widget.player.chapters : _chapters;
    if (chapters.isEmpty) return;
    // Get total duration for percentage calc
    final totalDur = _isActive ? widget.player.totalDuration : _duration;

    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.6, maxChildSize: 0.9,
        builder: (_, sc) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: accent.withValues(alpha: 0.2), width: 1)),
          ),
          child: Column(children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
            Text('Chapters', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 8),
            Expanded(child: ListView.builder(
              controller: sc, itemCount: chapters.length,
              itemBuilder: (_, i) {
                final ch = chapters[i] as Map<String, dynamic>;
                final chTitle = ch['title'] as String? ?? 'Chapter ${i + 1}';
                final start = (ch['start'] as num?)?.toDouble() ?? 0;
                final end = (ch['end'] as num?)?.toDouble() ?? 0;
                final pos = _isActive ? widget.player.position.inMilliseconds / 1000.0 : 0.0;
                final isCurrent = _isActive && pos >= start && pos < end;
                // Percentage of book at end of this chapter
                final pct = totalDur > 0 ? (end / totalDur * 100).round() : 0;
                return ListTile(
                  dense: true, selected: isCurrent,
                  selectedTileColor: accent.withValues(alpha: 0.1),
                  leading: SizedBox(width: 28, child: Text('${i + 1}', textAlign: TextAlign.center,
                    style: tt.labelMedium?.copyWith(fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400, color: isCurrent ? accent : Colors.white38))),
                  title: Text(chTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400, color: isCurrent ? Colors.white : Colors.white70)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('$pct%', style: tt.labelSmall?.copyWith(
                      color: isCurrent ? accent.withValues(alpha: 0.7) : Colors.white24, fontSize: 10, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text(_fmtDur(end - start), style: tt.labelSmall?.copyWith(color: Colors.white38)),
                  ]),
                  onTap: _isActive ? () {
                    debugPrint('[MFDBG-UI] chapterList tap: chapter $i start=${start.toStringAsFixed(1)}s');
                    widget.player.seekTo(Duration(seconds: start.round()));
                    Navigator.pop(ctx);
                  } : null,
                );
              },
            )),
          ]),
        ),
      ),
    );
  }

  void _showHistory(BuildContext context, Color accent, TextTheme tt) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.6, maxChildSize: 0.9,
        builder: (_, sc) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: accent.withValues(alpha: 0.2), width: 1)),
          ),
          child: Column(children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Spacer(),
                Text('Playback History', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.white38),
                  onPressed: () async {
                    await PlaybackHistoryService().clearHistory(_itemId);
                    Navigator.pop(ctx);
                  },
                  tooltip: 'Clear history',
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Expanded(child: FutureBuilder<List<PlaybackEvent>>(
              future: PlaybackHistoryService().getHistory(_itemId),
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                final events = snap.data!;
                if (events.isEmpty) return Center(child: Text('No history yet', style: tt.bodyMedium?.copyWith(color: Colors.white38)));
                return ListView.builder(
                  controller: sc, itemCount: events.length,
                  itemBuilder: (_, i) {
                    final e = events[i]; // already newest-first from getHistory
                    final posLabel = _fmtTime(e.positionSeconds);
                    final timeAgo = _timeAgo(e.timestamp);
                    return ListTile(
                      dense: true,
                      leading: Icon(_historyIcon(e.type), size: 18, color: accent.withValues(alpha: 0.7)),
                      title: Text(e.label, style: tt.bodySmall?.copyWith(color: Colors.white70)),
                      subtitle: Text('at $posLabel', style: tt.labelSmall?.copyWith(color: Colors.white38)),
                      trailing: Text(timeAgo, style: tt.labelSmall?.copyWith(color: Colors.white30)),
                      onTap: _isActive ? () {
                        widget.player.seekTo(Duration(seconds: e.positionSeconds.round()));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(seconds: 3), content: Text('Jumped to $posLabel')));
                      } : null,
                    );
                  },
                );
              },
            )),
          ]),
        ),
      ),
    );
  }

  void _showMoreMenu(BuildContext context, Color accent, TextTheme tt) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: accent.withValues(alpha: 0.2), width: 1)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                // Details option
                _MoreMenuItem(
                  icon: Icons.info_outline_rounded,
                  label: 'Book Details',
                  accent: accent,
                  onTap: () { Navigator.pop(ctx); showBookDetailSheet(context, _itemId); },
                ),
                const SizedBox(height: 6),
                // History option
                _MoreMenuItem(
                  icon: Icons.history_rounded,
                  label: 'Playback History',
                  accent: accent,
                  enabled: _isActive,
                  onTap: () { Navigator.pop(ctx); _showHistory(context, accent, tt); },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _historyIcon(PlaybackEventType type) {
    switch (type) {
      case PlaybackEventType.play: return Icons.play_arrow_rounded;
      case PlaybackEventType.pause: return Icons.pause_rounded;
      case PlaybackEventType.seek: return Icons.swap_horiz_rounded;
      case PlaybackEventType.syncLocal: return Icons.save_rounded;
      case PlaybackEventType.syncServer: return Icons.cloud_done_rounded;
      case PlaybackEventType.autoRewind: return Icons.replay_rounded;
      case PlaybackEventType.skipForward: return Icons.forward_30_rounded;
      case PlaybackEventType.skipBackward: return Icons.replay_10_rounded;
      case PlaybackEventType.speedChange: return Icons.speed_rounded;
    }
  }

  String _fmtTime(double s) {
    if (s < 0) s = 0;
    final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor(); final sec = (s % 60).floor();
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _fmtDur(double s) {
    final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor(); final sec = (s % 60).floor();
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${sec}s';
  }
}

// ─── DUAL PROGRESS BAR (card version) ───────────────────────

class _CardDualProgressBar extends StatefulWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  final double staticProgress;
  final double staticDuration;
  final List<dynamic> chapters;
  final bool showBookBar;
  final bool showChapterBar;
  const _CardDualProgressBar({required this.player, required this.accent, required this.isActive, required this.staticProgress, required this.staticDuration, required this.chapters, this.showBookBar = true, this.showChapterBar = true});
  @override State<_CardDualProgressBar> createState() => _CardDualProgressBarState();
}

class _CardDualProgressBarState extends State<_CardDualProgressBar> with TickerProviderStateMixin, WidgetsBindingObserver {
  double? _chapterDragValue;
  double? _bookDragValue;
  bool _showBookSlider = false;
  bool _speedAdjustedTime = true;
  late AnimationController _waveController;
  late AnimationController _smoothTicker;

  // Smooth position tracking
  double _lastKnownPos = 0;
  DateTime _lastPosTime = DateTime.now();
  double _currentSpeed = 1.0;
  bool _isPlaying = false;
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _waveController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500))..repeat();
    _smoothTicker = AnimationController(vsync: this, duration: const Duration(days: 999))..repeat();
    _loadSettings();
    _subscribePosition();
    // Listen for settings changes instead of polling
    PlayerSettings.settingsChanged.addListener(_loadSettings);
  }

  void _loadSettings() {
    PlayerSettings.getShowBookSlider().then((v) { if (mounted && v != _showBookSlider) setState(() => _showBookSlider = v); });
    PlayerSettings.getSpeedAdjustedTime().then((v) { if (mounted && v != _speedAdjustedTime) setState(() => _speedAdjustedTime = v); });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadSettings();
  }

  @override
  void didUpdateWidget(_CardDualProgressBar old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) _subscribePosition();
  }

  void _subscribePosition() {
    _posSub?.cancel();
    if (widget.isActive) {
      // Always seed from the known static position — this is truth until the player proves otherwise
      final seedPos = widget.staticProgress * widget.staticDuration;
      _lastKnownPos = seedPos > 0 ? seedPos : _lastKnownPos;
      _lastPosTime = DateTime.now();
      debugPrint('[MFDBG-UI] subscribePosition: seedPos=${seedPos.toStringAsFixed(1)}s '
          '_lastKnownPos=${_lastKnownPos.toStringAsFixed(1)}s');

      _posSub = widget.player.absolutePositionStream.listen((dur) {
        final posSeconds = dur.inMilliseconds / 1000.0;

        // If a seek just happened, check if this position event is the real
        // post-seek value or a transient glitch. Accept values near the seek
        // target; reject obvious transitional near-zero values.
        final seekTarget = widget.player.activeSeekTarget;
        if (seekTarget != null) {
          // Accept if close to the seek target (within 5s tolerance)
          if ((posSeconds - seekTarget).abs() < 5.0) {
            debugPrint('[MFDBG-UI] ACCEPT (near seekTarget): pos=${posSeconds.toStringAsFixed(1)}s '
                'seekTarget=${seekTarget.toStringAsFixed(1)}s diff=${((posSeconds - seekTarget).abs()).toStringAsFixed(1)}s');
            _lastKnownPos = posSeconds;
            _lastPosTime = DateTime.now();
            _currentSpeed = widget.player.speed;
            _isPlaying = widget.player.isPlaying;
            return;
          }
          // Reject transient values far from the seek target
          debugPrint('[MFDBG-UI] REJECT (far from seekTarget): pos=${posSeconds.toStringAsFixed(1)}s '
              'seekTarget=${seekTarget.toStringAsFixed(1)}s diff=${((posSeconds - seekTarget).abs()).toStringAsFixed(1)}s '
              '_lastKnownPos=${_lastKnownPos.toStringAsFixed(1)}s');
          return;
        }

        // Normal playback: reject transient near-zero during track changes
        if (_lastKnownPos > 10.0 && posSeconds < 2.0) {
          debugPrint('[MFDBG-UI] REJECT (near-zero transient): pos=${posSeconds.toStringAsFixed(1)}s '
              '_lastKnownPos=${_lastKnownPos.toStringAsFixed(1)}s');
          return;
        }

        // Log significant position changes
        final delta = posSeconds - _lastKnownPos;
        if (delta.abs() > 5.0 || posSeconds.toInt() % 5 == 0) {
          debugPrint('[MFDBG-UI] ACCEPT (normal): pos=${posSeconds.toStringAsFixed(1)}s '
              'prev=${_lastKnownPos.toStringAsFixed(1)}s delta=${delta.toStringAsFixed(1)}s');
        }
        _lastKnownPos = posSeconds;
        _lastPosTime = DateTime.now();
        _currentSpeed = widget.player.speed;
        _isPlaying = widget.player.isPlaying;
      });
      _currentSpeed = widget.player.speed;
      _isPlaying = widget.player.isPlaying;
    }
  }

  /// Smoothly interpolated position — predicts where playback is right now.
  /// Snaps immediately to seek target when a seek is in progress.
  double get _smoothPos {
    // If a seek just happened, snap to the target immediately
    final seekTarget = widget.player.activeSeekTarget;
    if (seekTarget != null && (seekTarget - _lastKnownPos).abs() > 2.0) {
      // Don't log every frame — only when it changes significantly
      return seekTarget;
    }
    if (!widget.isActive || !_isPlaying) return _lastKnownPos;
    final elapsed = DateTime.now().difference(_lastPosTime).inMilliseconds / 1000.0;
    return _lastKnownPos + elapsed * _currentSpeed;
  }

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PlayerSettings.settingsChanged.removeListener(_loadSettings);
    _posSub?.cancel();
    _waveController.dispose();
    _smoothTicker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final player = widget.player;
    final active = widget.isActive;

    return ListenableBuilder(
      listenable: _smoothTicker,
      builder: (context, _) {
        final staticPos = widget.staticProgress * widget.staticDuration;
        final posS = active ? _smoothPos : staticPos;
        final totalDur = active ? player.totalDuration : widget.staticDuration;
        final speed = active ? _currentSpeed : 1.0;
        final isPlaying = active && _isPlaying;
        final bookProgress = totalDur > 0 ? (posS / totalDur).clamp(0.0, 1.0) : 0.0;

        double chapterStart = 0, chapterEnd = totalDur;
        if (active) {
          final chapter = player.currentChapter;
          if (chapter != null) {
            chapterStart = (chapter['start'] as num?)?.toDouble() ?? 0;
            chapterEnd = (chapter['end'] as num?)?.toDouble() ?? totalDur;
          } else if (player.chapters.isNotEmpty) {
            for (final ch in player.chapters) {
              final m = ch as Map<String, dynamic>;
              final s = (m['start'] as num?)?.toDouble() ?? 0;
              final e = (m['end'] as num?)?.toDouble() ?? 0;
              if (posS >= s && posS < e) {
                chapterStart = s;
                chapterEnd = e;
                break;
              }
            }
          }
        } else if (widget.chapters.isNotEmpty) {
          // Inactive card: find chapter from stored chapters list using static position
          for (final ch in widget.chapters) {
            final m = ch as Map<String, dynamic>;
            final s = (m['start'] as num?)?.toDouble() ?? 0;
            final e = (m['end'] as num?)?.toDouble() ?? 0;
            if (posS >= s && posS < e) {
              chapterStart = s;
              chapterEnd = e;
              break;
            }
          }
        }
        final chapterDur = chapterEnd - chapterStart;
        final chapterPos = (posS - chapterStart).clamp(0.0, chapterDur);
        final chapterProgress = chapterDur > 0 ? chapterPos / chapterDur : 0.0;
        final speedDiv = _speedAdjustedTime ? speed : 1.0;
        final bookRemaining = (totalDur - posS) / speedDiv;
        final chapterRemaining = (chapterDur - chapterPos) / speedDiv;
        final chapterElapsed = chapterPos / speedDiv;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            // Book bar
            if (widget.showBookBar) ...[
            if (_showBookSlider) ...[
              SizedBox(height: 32, child: LayoutBuilder(builder: (_, cons) {
                final w = cons.maxWidth;
                final p = _bookDragValue ?? bookProgress;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: active ? (d) { setState(() => _bookDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                  onHorizontalDragUpdate: active ? (d) { setState(() => _bookDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                  onHorizontalDragEnd: active ? (_) { if (_bookDragValue != null) { final seekMs = (_bookDragValue! * totalDur * 1000).round(); debugPrint('[MFDBG-UI] bookBar dragEnd: dragValue=${_bookDragValue!.toStringAsFixed(3)} totalDur=$totalDur seekMs=$seekMs (${(seekMs/1000.0).toStringAsFixed(1)}s)'); player.seekTo(Duration(milliseconds: seekMs)); } setState(() => _bookDragValue = null); } : null,
                  onTapUp: active ? (d) { final v = (d.localPosition.dx / w).clamp(0.0, 1.0); final seekMs = (v * totalDur * 1000).round(); debugPrint('[MFDBG-UI] bookBar tap: value=${v.toStringAsFixed(3)} totalDur=$totalDur seekMs=$seekMs (${(seekMs/1000.0).toStringAsFixed(1)}s)'); player.seekTo(Duration(milliseconds: seekMs)); } : null,
                  child: CustomPaint(size: Size(w, 32), painter: AbsorbProgressPainter(progress: p, accent: widget.accent.withValues(alpha: 0.5), isDragging: _bookDragValue != null)),
                );
              })),
              Padding(padding: const EdgeInsets.only(top: 2, bottom: 6), child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(_bookDragValue != null ? _bookDragValue! * totalDur : posS), style: tt.labelSmall?.copyWith(color: _bookDragValue != null ? Colors.white70 : Colors.white54, fontSize: 12, fontWeight: FontWeight.w600, shadows: [Shadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 3)])),
                  Text('-${_fmt(_bookDragValue != null ? (1.0 - _bookDragValue!) * totalDur : bookRemaining)}', style: tt.labelSmall?.copyWith(color: _bookDragValue != null ? Colors.white70 : Colors.white54, fontSize: 12, fontWeight: FontWeight.w600, shadows: [Shadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 3)])),
                ],
              )),
            ] else ...[
              Row(children: [
                Text(_fmt(_bookDragValue != null ? _bookDragValue! * totalDur : posS), style: tt.labelSmall?.copyWith(color: _bookDragValue != null ? Colors.white60 : Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: bookProgress, minHeight: 3, backgroundColor: Colors.white.withValues(alpha: 0.08), valueColor: AlwaysStoppedAnimation(widget.accent.withValues(alpha: 0.5))))),
                const SizedBox(width: 8),
                Text('-${_fmt(_bookDragValue != null ? (1.0 - _bookDragValue!) * totalDur : bookRemaining)}', style: tt.labelSmall?.copyWith(color: _bookDragValue != null ? Colors.white60 : Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
              ]),
              const SizedBox(height: 10),
            ],
            ], // end showBookBar
            // Chapter bar
            if (widget.showChapterBar) ...[
            SizedBox(height: 32, child: LayoutBuilder(builder: (_, cons) {
              final w = cons.maxWidth;
              final p = _chapterDragValue ?? chapterProgress;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: active ? (d) { setState(() => _chapterDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                onHorizontalDragUpdate: active ? (d) { setState(() => _chapterDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                onHorizontalDragEnd: active ? (_) { if (_chapterDragValue != null) { final seekMs = ((chapterStart + _chapterDragValue! * chapterDur) * 1000).round(); debugPrint('[MFDBG-UI] chapterBar dragEnd: chapterStart=$chapterStart chapterDur=$chapterDur dragValue=${_chapterDragValue!.toStringAsFixed(3)} seekMs=$seekMs (${(seekMs/1000.0).toStringAsFixed(1)}s)'); player.seekTo(Duration(milliseconds: seekMs)); } setState(() => _chapterDragValue = null); } : null,
                onTapUp: active ? (d) { final v = (d.localPosition.dx / w).clamp(0.0, 1.0); final seekMs = ((chapterStart + v * chapterDur) * 1000).round(); debugPrint('[MFDBG-UI] chapterBar tap: chapterStart=$chapterStart chapterDur=$chapterDur v=${v.toStringAsFixed(3)} seekMs=$seekMs (${(seekMs/1000.0).toStringAsFixed(1)}s)'); player.seekTo(Duration(milliseconds: seekMs)); } : null,
                child: ListenableBuilder(
                  listenable: _waveController,
                  builder: (_, __) => CustomPaint(
                    size: Size(w, 32),
                    painter: AbsorbProgressPainter(progress: p, accent: widget.accent, isDragging: _chapterDragValue != null, squiggly: true, isPlaying: isPlaying, wavePhase: _waveController.value),
                  ),
                ),
              );
            })),
            Padding(padding: const EdgeInsets.only(top: 3), child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(_chapterDragValue != null ? (_chapterDragValue! * chapterDur) / speedDiv : chapterElapsed),
                  style: tt.labelSmall?.copyWith(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
                Text('-${_fmt(chapterRemaining)}', style: tt.labelSmall?.copyWith(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            )),
            ], // end showChapterBar
          ]),
        );
      },
    );
  }

  String _fmt(double s) {
    if (s < 0) s = 0;
    final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor(); final sec = (s % 60).floor();
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

// ─── PLAYBACK CONTROLS (card version) ───────────────────────

class _CardPlaybackControls extends StatefulWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  final bool isStarting;
  final VoidCallback onStart;
  const _CardPlaybackControls({required this.player, required this.accent, required this.isActive, required this.isStarting, required this.onStart});
  @override State<_CardPlaybackControls> createState() => _CardPlaybackControlsState();
}

class _CardPlaybackControlsState extends State<_CardPlaybackControls> with SingleTickerProviderStateMixin {
  int _backSkip = 10;
  int _forwardSkip = 30;
  late AnimationController _playPauseController;

  @override void initState() {
    super.initState();
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0, // 0 = play icon, 1 = pause icon
    );
    _loadSkipSettings();
    PlayerSettings.settingsChanged.addListener(_loadSkipSettings);
  }

  @override void didUpdateWidget(covariant _CardPlaybackControls old) {
    super.didUpdateWidget(old);
  }

  void _loadSkipSettings() {
    PlayerSettings.getBackSkip().then((v) { if (mounted && v != _backSkip) setState(() => _backSkip = v); });
    PlayerSettings.getForwardSkip().then((v) { if (mounted && v != _forwardSkip) setState(() => _forwardSkip = v); });
  }

  @override void dispose() {
    PlayerSettings.settingsChanged.removeListener(_loadSkipSettings);
    _playPauseController.dispose();
    super.dispose();
  }

  Widget _skipIcon(int seconds, bool isForward) {
    final hasBuiltIn = [5, 10, 30].contains(seconds);
    if (hasBuiltIn) {
      IconData icon;
      if (isForward) { icon = seconds == 5 ? Icons.forward_5_rounded : seconds == 10 ? Icons.forward_10_rounded : Icons.forward_30_rounded; }
      else { icon = seconds == 5 ? Icons.replay_5_rounded : seconds == 10 ? Icons.replay_10_rounded : Icons.replay_30_rounded; }
      return Icon(icon, size: 38, color: widget.isActive ? Colors.white70 : Colors.white24);
    }
    return Stack(alignment: Alignment.center, children: [
      Icon(isForward ? Icons.rotate_right_rounded : Icons.rotate_left_rounded, size: 38, color: widget.isActive ? Colors.white70 : Colors.white24),
      Padding(padding: const EdgeInsets.only(top: 2), child: Text('$seconds', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: widget.isActive ? Colors.white : Colors.white24))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isStarting) {
      return SizedBox(height: 64,
        child: Center(child: SizedBox(width: 64, height: 64,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.4), blurRadius: 25, spreadRadius: -5)],
            ),
            child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: widget.accent))),
          ),
        )),
      );
    }

    return StreamBuilder<PlayerState>(
      stream: widget.isActive ? widget.player.playerStateStream : const Stream.empty(),
      builder: (_, snapshot) {
        final isPlaying = widget.isActive && (snapshot.data?.playing ?? false);
        final isLoading = widget.isActive && (snapshot.data?.processingState == ProcessingState.loading || snapshot.data?.processingState == ProcessingState.buffering);

        // Animate play/pause icon
        if (isPlaying) {
          _playPauseController.forward();
        } else {
          _playPauseController.reverse();
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Previous chapter
            GestureDetector(
              onTap: widget.isActive ? widget.player.skipToPreviousChapter : null,
              child: SizedBox(width: 40, height: 40, child: Center(
                child: Icon(Icons.skip_previous_rounded, size: 24, color: widget.isActive ? Colors.white38 : Colors.white12),
              )),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: widget.isActive ? () => widget.player.skipBackward(_backSkip) : null,
              child: SizedBox(width: 52, height: 52, child: Center(child: _skipIcon(_backSkip, false))),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: widget.isActive ? widget.player.togglePlayPause : widget.onStart,
              child: SizedBox(
                width: 80, height: 80,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Main button
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.4), blurRadius: 25, spreadRadius: -5)],
                      ),
                      child: isLoading
                          ? Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: widget.accent)))
                          : Center(
                              child: AnimatedIcon(
                                icon: AnimatedIcons.play_pause,
                                progress: _playPauseController,
                                size: 34,
                                color: Colors.black87,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: widget.isActive ? () => widget.player.skipForward(_forwardSkip) : null,
              child: SizedBox(width: 52, height: 52, child: Center(child: _skipIcon(_forwardSkip, true))),
            ),
            const SizedBox(width: 4),
            // Next chapter
            GestureDetector(
              onTap: widget.isActive ? widget.player.skipToNextChapter : null,
              child: SizedBox(width: 40, height: 40, child: Center(
                child: Icon(Icons.skip_next_rounded, size: 24, color: widget.isActive ? Colors.white38 : Colors.white12),
              )),
            ),
          ],
        );
      },
    );
  }
}

// ─── GLASS BUTTONS (card versions) ──────────────────────────

class _CardGlassButton extends StatelessWidget {
  final IconData icon; final String label; final Color accent; final bool isActive; final VoidCallback onTap;
  const _CardGlassButton({required this.icon, required this.label, required this.accent, required this.isActive, required this.onTap});

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
          ),
          child: Icon(icon, color: isActive ? Colors.white60 : Colors.white24, size: 20)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: isActive ? Colors.white38 : Colors.white.withValues(alpha: 0.2), fontSize: 9, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class _CardSleepButton extends StatelessWidget {
  final Color accent; final bool isActive;
  const _CardSleepButton({required this.accent, required this.isActive});

  @override Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SleepTimerService(),
      builder: (_, __) {
        final sleep = SleepTimerService();
        final timerActive = sleep.isActive;
        return GestureDetector(
          onTap: isActive ? () {
            showSleepTimerSheet(context, accent);
          } : null,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 44, height: 44,
              decoration: BoxDecoration(
                color: timerActive ? accent.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: timerActive ? accent.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.1), width: 1),
              ),
              child: timerActive
                  ? Center(child: Text(sleep.displayLabel, style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.w700)))
                  : Icon(Icons.bedtime_outlined, color: isActive ? Colors.white60 : Colors.white24, size: 20)),
            const SizedBox(height: 4),
            Text('Sleep', style: TextStyle(color: timerActive ? accent : (isActive ? Colors.white38 : Colors.white.withValues(alpha: 0.2)), fontSize: 9, fontWeight: FontWeight.w500)),
          ]),
        );
      },
    );
  }
}


class _CardBookmarkButton extends StatefulWidget {
  final AudioPlayerService player; final Color accent; final bool isActive; final String itemId;
  const _CardBookmarkButton({required this.player, required this.accent, required this.isActive, required this.itemId});
  @override State<_CardBookmarkButton> createState() => _CardBookmarkButtonState();
}

class _CardBookmarkButtonState extends State<_CardBookmarkButton> {
  int _count = 0;
  @override void initState() { super.initState(); _loadCount(); }
  Future<void> _loadCount() async {
    final c = await BookmarkService().getCount(widget.itemId);
    if (mounted) setState(() => _count = c);
  }

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isActive ? () => _showBookmarks(context) : null,
      onLongPress: widget.isActive ? () => _quickAdd(context) : null,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Icon(Icons.bookmark_border_rounded, color: widget.isActive ? Colors.white60 : Colors.white24, size: 20),
            if (_count > 0) Positioned(top: 4, right: 4, child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: widget.accent, shape: BoxShape.circle),
              child: Text('$_count', style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
            )),
          ])),
        const SizedBox(height: 4),
        Text('Bookmarks', style: TextStyle(color: widget.isActive ? Colors.white38 : Colors.white.withValues(alpha: 0.2), fontSize: 9, fontWeight: FontWeight.w500)),
      ]),
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
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(duration: const Duration(seconds: 3), content: Text('Bookmark added'), behavior: SnackBarBehavior.floating));
    }
  }

  void _showBookmarks(BuildContext context) {
    // Reuse the player screen's bookmark sheet pattern
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent, isScrollControlled: true, useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6, minChildSize: 0.3, maxChildSize: 0.9, expand: false,
        builder: (ctx, sc) => _SimpleBookmarkSheet(itemId: widget.itemId, player: widget.player, accent: widget.accent, scrollController: sc, onChanged: _loadCount),
      ),
    );
  }
}

class _SimpleBookmarkSheet extends StatefulWidget {
  final String itemId; final AudioPlayerService player; final Color accent; final ScrollController scrollController; final VoidCallback onChanged;
  const _SimpleBookmarkSheet({required this.itemId, required this.player, required this.accent, required this.scrollController, required this.onChanged});
  @override State<_SimpleBookmarkSheet> createState() => _SimpleBookmarkSheetState();
}

class _SimpleBookmarkSheetState extends State<_SimpleBookmarkSheet> {
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

class _CardSpeedButton extends StatelessWidget {
  final AudioPlayerService player; final Color accent; final bool isActive;
  const _CardSpeedButton({required this.player, required this.accent, required this.isActive});

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isActive ? () => _showSpeedSheet(context) : null,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
          ),
          child: Center(child: Text(isActive ? '${player.speed}x' : '1.0x',
            style: TextStyle(color: isActive ? accent : Colors.white24, fontSize: 12, fontWeight: FontWeight.w700)))),
        const SizedBox(height: 4),
        Text('Speed', style: TextStyle(color: isActive ? Colors.white38 : Colors.white.withValues(alpha: 0.2), fontSize: 9, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  void _showSpeedSheet(BuildContext context) {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (ctx) => _CardSpeedSheet(player: player, accent: accent));
  }
}

class _CardSpeedSheet extends StatefulWidget {
  final AudioPlayerService player; final Color accent;
  const _CardSpeedSheet({required this.player, required this.accent});
  @override State<_CardSpeedSheet> createState() => _CardSpeedSheetState();
}

class _CardSpeedSheetState extends State<_CardSpeedSheet> {
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

// ─── DOWNLOAD BUTTON WITH PROGRESS ──────────────────────────

class _DownloadButton extends StatefulWidget {
  final String itemId;
  final String? coverUrl;
  final String title;
  final String? author;
  const _DownloadButton({required this.itemId, this.coverUrl, required this.title, this.author});
  @override State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  final _dl = DownloadService();

  @override void initState() { super.initState(); _dl.addListener(_rebuild); }
  @override void dispose() { _dl.removeListener(_rebuild); super.dispose(); }
  void _rebuild() { if (mounted) setState(() {}); }

  @override Widget build(BuildContext context) {
    final downloading = _dl.isDownloading(widget.itemId);
    final downloaded = _dl.isDownloaded(widget.itemId);
    final progress = _dl.downloadProgress(widget.itemId);

    final IconData icon;
    final String label;
    final Color iconColor;
    if (downloaded) {
      icon = Icons.download_done_rounded;
      label = 'Saved';
      iconColor = Colors.greenAccent.withValues(alpha: 0.8);
    } else if (downloading) {
      icon = Icons.close_rounded;
      label = '${(progress * 100).toStringAsFixed(0)}%';
      iconColor = Colors.white70;
    } else {
      icon = Icons.download_outlined;
      label = 'Download';
      iconColor = Colors.white54;
    }

    return GestureDetector(
      onTap: () => _handleTap(context),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            if (downloading)
              SizedBox(width: 44, height: 44,
                child: CircularProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  strokeWidth: 2,
                  color: Colors.white38,
                  backgroundColor: Colors.white.withValues(alpha: 0.05),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: iconColor, fontSize: 9)),
      ]),
    );
  }

  void _handleTap(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    if (_dl.isDownloaded(widget.itemId)) {
      showDialog(context: context, builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Remove download?', style: TextStyle(color: Colors.white)),
        content: const Text('The audiobook will be removed from your device.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () { _dl.deleteDownload(widget.itemId); Navigator.pop(ctx); },
            child: const Text('Remove', style: TextStyle(color: Colors.redAccent))),
        ],
      ));
    } else if (_dl.isDownloading(widget.itemId)) {
      _dl.cancelDownload(widget.itemId);
    } else {
      _dl.downloadItem(api: api, itemId: widget.itemId, title: widget.title, author: widget.author, coverUrl: widget.coverUrl);
    }
  }
}


// ─── WIDE GLASS BUTTON (for 2-column grid) ─────────────────

class _CardWideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final bool isActive;
  final bool alwaysEnabled;
  final VoidCallback? onTap;
  final Widget? child; // if provided, renders child instead (for stateful buttons)

  const _CardWideButton({
    required this.icon, required this.label,
    required this.accent, required this.isActive,
    this.alwaysEnabled = false,
    this.onTap, this.child,
  });

  @override Widget build(BuildContext context) {
    if (child != null) return child!;
    final enabled = isActive || alwaysEnabled;
    return GestureDetector(
      onTap: enabled ? onTap : null,
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
class _MoreMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  const _MoreMenuItem({
    required this.icon, required this.label,
    required this.accent, required this.onTap,
    this.enabled = true,
  });

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
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
class _CardSleepButtonInline extends StatelessWidget {
  final Color accent;
  final bool isActive;
  const _CardSleepButtonInline({required this.accent, required this.isActive});

  @override Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SleepTimerService(),
      builder: (_, __) {
        final sleep = SleepTimerService();
        final active = sleep.isActive;
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
            _showSleepPicker(context);
          } : null,
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

  void _showSleepPicker(BuildContext context) {
    showSleepTimerSheet(context, accent);
  }
}

/// Bookmark button as wide card
class _CardBookmarkButtonInline extends StatefulWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  final String itemId;
  const _CardBookmarkButtonInline({required this.player, required this.accent, required this.isActive, required this.itemId});
  @override State<_CardBookmarkButtonInline> createState() => _CardBookmarkButtonInlineState();
}

class _CardBookmarkButtonInlineState extends State<_CardBookmarkButtonInline> {
  int _count = 0;
  @override void initState() { super.initState(); _loadCount(); }
  Future<void> _loadCount() async {
    final c = await BookmarkService().getCount(widget.itemId);
    if (mounted) setState(() => _count = c);
  }

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isActive ? () => _showBookmarks(context) : null,
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
        builder: (ctx, sc) => _SimpleBookmarkSheet(itemId: widget.itemId, player: widget.player, accent: widget.accent, scrollController: sc, onChanged: _loadCount),
      ),
    );
  }
}

/// Speed button as wide card — opens the full speed sheet with slider
class _CardSpeedButtonInline extends StatelessWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  const _CardSpeedButtonInline({required this.player, required this.accent, required this.isActive});

  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isActive ? () {
        showModalBottomSheet(context: context, backgroundColor: Colors.transparent,
          useSafeArea: true,
          builder: (ctx) => _CardSpeedSheet(player: player, accent: accent));
      } : null,
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



class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});
  @override State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animController;
  double _maxScroll = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animController = AnimationController(vsync: this, duration: const Duration(seconds: 6));
    _animController.addListener(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void didUpdateWidget(covariant _MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _animController.stop();
      _animController.reset();
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  void _onTick() {
    if (_scrollController.hasClients && _maxScroll > 0) {
      _scrollController.jumpTo(_animController.value * _maxScroll);
    }
  }

  void _checkOverflow() {
    if (!mounted || !_scrollController.hasClients) return;
    _maxScroll = _scrollController.position.maxScrollExtent;
    if (_maxScroll > 0) {
      final dur = Duration(milliseconds: (_maxScroll * 25).round().clamp(2000, 15000));
      _animController.duration = dur;
      _startLoop();
    }
  }

  void _startLoop() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    await _animController.forward(from: 0);
    if (!mounted) return;
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _startLoop();
  }

  @override
  void dispose() {
    _animController.removeListener(_onTick);
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(widget.text, style: widget.style, maxLines: 1, softWrap: false),
      ),
    );
  }
}
