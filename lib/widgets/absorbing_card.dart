import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../services/playback_history_service.dart';
import 'book_detail_sheet.dart';
import 'equalizer_sheet.dart';
import 'card_progress_bar.dart';
import 'card_playback_controls.dart';
import 'card_buttons.dart';

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
  ui.Image? _blurredCover; // Precached blurred background

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
      _blurredCover?.dispose();
      _blurredCover = null;
      _fetchedChapters = null;
      _lastChapterIdx = -1;
      _fetchChaptersIfNeeded();
    }
    if (old.player != widget.player) _startChapterTracking();
  }

  @override
  void dispose() {
    _chapterTrackSub?.cancel();
    _blurredCover?.dispose();
    super.dispose();
  }

  void _onCoverLoaded(ImageProvider provider) {
    if (_coverScheme != null) return;
    ColorScheme.fromImageProvider(provider: provider, brightness: Brightness.dark)
        .then((s) {
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _coverScheme = s);
            });
          }
        })
        .catchError((_) {});
    // Precache the blurred version of the cover
    if (_blurredCover == null) {
      _precacheBlur(provider);
    }
  }

  /// Resolve the image, render it blurred to an offscreen canvas, cache the result.
  Future<void> _precacheBlur(ImageProvider provider) async {
    try {
      final completer = Completer<ui.Image>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      }, onError: (e, _) {
        if (!completer.isCompleted) completer.completeError(e);
        stream.removeListener(listener);
      });
      stream.addListener(listener);

      final srcImage = await completer.future;
      // Render at reduced size for performance (blur hides detail anyway)
      const targetWidth = 200;
      final aspect = srcImage.height / srcImage.width;
      final targetHeight = (targetWidth * aspect).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()));
      final paint = Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30, tileMode: TileMode.decal);
      canvas.drawImageRect(
        srcImage,
        Rect.fromLTWH(0, 0, srcImage.width.toDouble(), srcImage.height.toDouble()),
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        paint,
      );
      final picture = recorder.endRecording();
      final blurred = await picture.toImage(targetWidth, targetHeight);
      picture.dispose();

      if (mounted) {
        setState(() => _blurredCover = blurred);
      } else {
        blurred.dispose();
      }
    } catch (_) {
      // Fallback: card will show without blurred background, which is fine
    }
  }

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
          // Layer 1: Pre-blurred cover background (cached bitmap — no per-frame blur)
          if (_blurredCover != null)
            RepaintBoundary(
              child: RawImage(
                image: _blurredCover,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
            )
          else if (_coverUrl != null)
            // Fallback while blur is being computed: show unblurred cover dimmed
            RepaintBoundary(
              child: CachedNetworkImage(
                imageUrl: _coverUrl!,
                fit: BoxFit.cover,
                imageBuilder: (_, provider) {
                  _onCoverLoaded(provider);
                  return Opacity(
                    opacity: 0.3,
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
                child: CardDualProgressBar(player: widget.player, accent: accent, isActive: _isActive, staticProgress: progress, staticDuration: _duration, chapters: _chapters, showBookBar: true, showChapterBar: false),
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
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ),
                ),
                const SizedBox(height: 20),
                // ── Chapter pill-scrubber (same width as book bar) ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: CardDualProgressBar(player: widget.player, accent: accent, isActive: _isActive, staticProgress: progress, staticDuration: _duration, chapters: _chapters, showBookBar: false, showChapterBar: true, chapterName: _chapterName(chapterIdx), chapterIndex: chapterIdx, totalChapters: totalChapters),
                ),
                // ── Controls + buttons ──
                Expanded(
                  child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      const Spacer(flex: 2),
                      CardPlaybackControls(
                        player: widget.player,
                        accent: accent,
                        isActive: _isActive,
                        isStarting: _isStarting,
                        onStart: _startPlayback,
                      ),
                      const Spacer(flex: 3),
                      // ── Button grid (hugs bottom) ──
                      Row(children: [
                        Expanded(child: CardWideButton(
                          icon: Icons.list_rounded, label: 'Chapters',
                          accent: accent, isActive: _isActive,
                          onTap: () => _showChapters(context, accent, tt),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: CardWideButton(
                          icon: Icons.speed_rounded, label: 'Speed',
                          accent: accent, isActive: _isActive,
                          child: CardSpeedButtonInline(player: widget.player, accent: accent, isActive: _isActive),
                        )),
                      ]),
                      const SizedBox(height: 8),
                      // Secondary actions: Sleep Timer + Bookmarks
                      Row(children: [
                        Expanded(child: CardWideButton(
                          icon: Icons.bedtime_outlined, label: 'Sleep Timer',
                          accent: accent, isActive: _isActive,
                          child: CardSleepButtonInline(accent: accent, isActive: _isActive),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: CardWideButton(
                          icon: Icons.bookmark_outline_rounded, label: 'Bookmarks',
                          accent: accent, isActive: _isActive,
                          child: CardBookmarkButtonInline(
                            player: widget.player, accent: accent,
                            isActive: _isActive, itemId: _itemId,
                          ),
                        )),
                      ]),
                      const SizedBox(height: 8),
                      // More menu: Details + History (centered below buttons)
                      Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showMoreMenu(context, accent, tt),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.more_horiz_rounded, size: 18, color: Colors.white54),
                                const SizedBox(width: 4),
                                Text('More', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white54)),
                              ],
                            ),
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

  String _fmtTime(double s) {
    if (s < 0) s = 0;
    final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor(); final sec = (s % 60).floor();
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
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
                MoreMenuItem(
                  icon: Icons.info_outline_rounded,
                  label: 'Book Details',
                  accent: accent,
                  onTap: () { Navigator.pop(ctx); showBookDetailSheet(context, _itemId); },
                ),
                const SizedBox(height: 6),
                // Equalizer / Audio Enhancements
                MoreMenuItem(
                  icon: Icons.equalizer_rounded,
                  label: 'Audio Enhancements',
                  accent: accent,
                  onTap: () { Navigator.pop(ctx); showEqualizerSheet(context, accent); },
                ),
                const SizedBox(height: 6),
                // History option
                MoreMenuItem(
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
