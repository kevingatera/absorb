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
import '../services/progress_sync_service.dart';
import '../services/bookmark_service.dart';
import '../services/sleep_timer_service.dart';
import '../services/playback_history_service.dart';
import '../widgets/absorb_slider.dart';
import '../widgets/absorb_title.dart';
import 'app_shell.dart';
import 'series_detail_screen.dart';
import 'settings_screen.dart'; // for PlayerSettings

class AbsorbingScreen extends StatefulWidget {
  const AbsorbingScreen({super.key});

  @override
  State<AbsorbingScreen> createState() => _AbsorbingScreenState();
}

class _AbsorbingScreenState extends State<AbsorbingScreen> {
  final _player = AudioPlayerService();
  final _pageController = PageController(viewportFraction: 0.93);

  @override
  void initState() {
    super.initState();
    _player.addListener(_rebuild);
  }

  @override
  void dispose() {
    _player.removeListener(_rebuild);
    _pageController.dispose();
    super.dispose();
  }

  String? _lastPlayingId;
  bool _isSyncing = false;
  bool _offlineMode = false;

  void _rebuild() {
    if (!mounted) return;
    setState(() {});
    // Auto-scroll to the newly active card if the playing book changed
    if (_player.currentItemId != _lastPlayingId) {
      _lastPlayingId = _player.currentItemId;
      if (_player.hasBook) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActiveCard());
      }
    }
  }

  void _scrollToActiveCard() {
    if (!_player.hasBook || !mounted) return;
    final lib = context.read<LibraryProvider>();
    final books = _getAbsorbingBooks(lib);
    final idx = books.indexWhere((b) => (b['id'] as String?) == _player.currentItemId);
    if (idx >= 0 && _pageController.hasClients) {
      _pageController.animateToPage(idx, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
  }

  Future<void> _stopAndRefresh(LibraryProvider lib) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    if (_player.hasBook) {
      await _player.pause();
      await _player.stop();
    }
    lib.refreshLocalProgress();
    await lib.refresh();
    if (mounted) setState(() => _isSyncing = false);
  }

  List<Map<String, dynamic>> _getAbsorbingBooks(LibraryProvider lib) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    
    for (final section in lib.personalizedSections) {
      final id = section['id'] as String? ?? '';
      if (id == 'continue-listening' || id == 'continue-series') {
        for (final e in (section['entities'] as List<dynamic>? ?? [])) {
          if (e is Map<String, dynamic>) {
            final itemId = e['id'] as String?;
            if (itemId != null && seen.add(itemId)) items.add(e);
          }
        }
      }
    }
    
    // If the currently playing book isn't in the list, add it at the front
    // (e.g. book was just started and server hasn't been refreshed yet)
    if (_player.hasBook && _player.currentItemId != null) {
      final playingId = _player.currentItemId!;
      if (!seen.contains(playingId)) {
        items.insert(0, {
          'id': playingId,
          'media': {
            'metadata': {
              'title': _player.currentTitle,
              'authorName': _player.currentAuthor,
            },
            'duration': _player.totalDuration,
            'chapters': _player.chapters,
          },
        });
      }
    }
    
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final lib = context.watch<LibraryProvider>();
    final dl = DownloadService();
    var books = _getAbsorbingBooks(lib);
    
    // Force offline mode when actually offline
    final effectiveOffline = _offlineMode || lib.isOffline;
    if (effectiveOffline) {
      books = books.where((b) => dl.isDownloaded(b['id'] as String? ?? '')).toList();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // ── Fixed Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  const AbsorbTitle(color: Colors.white38),
                  const Spacer(),
                  // Offline mode toggle
                  GestureDetector(
                    onTap: () {
                      setState(() => _offlineMode = !_offlineMode);
                      if (_offlineMode) _stopAndRefresh(lib);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: effectiveOffline ? Colors.orange.withOpacity(0.15) : Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: effectiveOffline ? Colors.orange.withOpacity(0.3) : Colors.white.withOpacity(0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            effectiveOffline ? Icons.airplanemode_active_rounded : Icons.airplanemode_inactive_rounded,
                            size: 14, color: effectiveOffline ? Colors.orange : Colors.white38,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            effectiveOffline ? 'Offline' : 'Online',
                            style: TextStyle(
                              color: effectiveOffline ? Colors.orange : Colors.white38,
                              fontSize: 11, fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Stop & Sync button
                  AnimatedOpacity(
                    opacity: _player.hasBook ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: !_player.hasBook,
                      child: GestureDetector(
                        onTap: () => _stopAndRefresh(lib),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withOpacity(0.08)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isSyncing) ...[
                                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38)),
                                const SizedBox(width: 6),
                                const Text('Syncing…', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                              ] else ...[
                                const Icon(Icons.stop_rounded, size: 14, color: Colors.white38),
                                const SizedBox(width: 4),
                                const Text('Stop & Sync', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ── Page Dots ──
            if (books.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: _PageDots(count: books.length, controller: _pageController),
              ),
            // ── Cards (refreshable) ──
            Expanded(
              child: lib.isLoading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24))
                  : books.isEmpty
                      ? _emptyState(cs, tt, effectiveOffline)
                      : PageView.builder(
                          controller: _pageController,
                          scrollDirection: Axis.horizontal,
                          itemCount: books.length,
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                            child: _AbsorbingCard(item: books[i], player: _player),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ColorScheme cs, TextTheme tt, bool isOffline) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isOffline ? Icons.cloud_off_rounded : Icons.headphones_rounded,
            size: 64, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          Text(isOffline ? 'No downloaded books' : 'Nothing absorbing yet',
            style: tt.titleMedium?.copyWith(color: Colors.white38)),
          const SizedBox(height: 8),
          Text(isOffline ? 'Download books to listen offline' : 'Start a book from the Library tab',
            style: tt.bodySmall?.copyWith(color: Colors.white24)),
        ],
      ),
    );
  }
}

// ─── PAGE DOTS ──────────────────────────────────────────────

class _PageDots extends StatelessWidget {
  final int count;
  final PageController controller;
  const _PageDots({required this.count, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (_, __) {
        final page = controller.hasClients ? (controller.page ?? 0).round() : 0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(count, (i) {
            final active = i == page;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: active ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: active ? Colors.white54 : Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        );
      },
    );
  }
}

// ─── ABSORBING CARD (full inline player) ────────────────────

class _AbsorbingCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final AudioPlayerService player;
  const _AbsorbingCard({required this.item, required this.player});

  @override
  State<_AbsorbingCard> createState() => _AbsorbingCardState();
}

class _AbsorbingCardState extends State<_AbsorbingCard> {
  ColorScheme? _coverScheme;
  bool _isStarting = false;
  List<dynamic>? _fetchedChapters;

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

  void _onCoverLoaded(ImageProvider provider) {
    if (_coverScheme != null) return;
    ColorScheme.fromImageProvider(provider: provider, brightness: Brightness.dark)
        .then((s) { if (mounted) setState(() => _coverScheme = s); })
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = _coverScheme ?? Theme.of(context).colorScheme;
    final accent = cs.primary;
    final bgDark = cs.surface;

    final lib = context.watch<LibraryProvider>();
    final progress = lib.getProgress(_itemId);
    final chapterIdx = _currentChapterIndex();
    final totalChapters = _isActive ? widget.player.chapters.length : _chapters.length;
    final bookProgress = _isActive && widget.player.totalDuration > 0
        ? (widget.player.position.inMilliseconds / 1000.0) / widget.player.totalDuration
        : progress;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withOpacity(0.15), width: 1),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Layer 1: Pre-blurred cover image (no BackdropFilter = no transition artifacts)
          if (_coverUrl != null)
            CachedNetworkImage(
              imageUrl: _coverUrl!,
              fit: BoxFit.cover,
              imageBuilder: (_, provider) {
                _onCoverLoaded(provider);
                return ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80, tileMode: TileMode.decal),
                  child: Image(image: provider, fit: BoxFit.cover),
                );
              },
              placeholder: (_, __) => Container(color: Colors.black),
              errorWidget: (_, __, ___) => Container(color: Colors.black),
            ),
          // Layer 2: Scrim
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.3),
                    bgDark.withOpacity(0.6),
                    Colors.black.withOpacity(0.85),
                  ],
                ),
              ),
            ),
          ),
          // Layer 3: Content — two halves
          Column(
            children: [
              // ═══ TOP HALF: Hero cover with overlay info ═══
              Expanded(
                flex: 5,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragEnd: (d) {
                    if (d.primaryVelocity != null && d.primaryVelocity! < -300) {
                      showBookDetailSheet(context, _itemId);
                    }
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Sharp cover image — fills the top area
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: _coverUrl != null
                              ? CachedNetworkImage(imageUrl: _coverUrl!, fit: BoxFit.cover,
                                  placeholder: (_, __) => _coverPlaceholder(),
                                  errorWidget: (_, __, ___) => _coverPlaceholder())
                              : _coverPlaceholder(),
                        ),
                      ),
                      // Top gradient overlay for stats
                      Positioned(
                        top: 8, left: 20, right: 20,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.black.withOpacity(0.85), Colors.black.withOpacity(0.3), Colors.transparent],
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${(bookProgress * 100).clamp(0, 100).toStringAsFixed(1)}%',
                                style: tt.labelSmall?.copyWith(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600, fontSize: 11)),
                              if (totalChapters > 0)
                                Text('Ch ${(chapterIdx + 1).clamp(1, totalChapters)} / $totalChapters',
                                  style: tt.labelSmall?.copyWith(color: Colors.white.withOpacity(0.6), fontSize: 11)),
                            ],
                          ),
                        ),
                      ),
                      // Bottom gradient overlay for title
                      Positioned(
                        bottom: 0, left: 20, right: 20,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 24, 14, 10),
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Colors.black.withOpacity(0.92), Colors.black.withOpacity(0.5), Colors.transparent],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.white, height: 1.2)),
                              const SizedBox(height: 2),
                              Text(_author, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(color: Colors.white70)),
                              if (_isActive && widget.player.currentChapter != null) ...[
                                const SizedBox(height: 3),
                                Container(
                                  height: 18,
                                  clipBehavior: Clip.hardEdge,
                                  decoration: BoxDecoration(
                                    color: accent.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    child: _MarqueeText(
                                      text: widget.player.currentChapter!['title'] ?? '',
                                      style: tt.labelSmall?.copyWith(color: accent.withOpacity(0.9), fontWeight: FontWeight.w500, fontSize: 10) ?? const TextStyle(fontSize: 10),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ═══ BOTTOM HALF: Fixed controls + scrollable buttons ═══
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    // Fixed: Progress bars
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _CardDualProgressBar(player: widget.player, accent: accent, isActive: _isActive, staticProgress: progress, staticDuration: _duration, chapters: _chapters),
                    ),
                    const SizedBox(height: 6),
                    // Fixed: Playback controls
                    _CardPlaybackControls(
                      player: widget.player,
                      accent: accent,
                      isActive: _isActive,
                      isStarting: _isStarting,
                      onStart: _startPlayback,
                    ),
                    const SizedBox(height: 10),
                    // Scrollable: Action button grid
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            children: [
                              // Row 1
                              Row(children: [
                                Expanded(child: _CardWideButton(
                                  icon: Icons.bedtime_outlined, label: 'Sleep Timer',
                                  accent: accent, isActive: _isActive,
                                  child: _CardSleepButtonInline(accent: accent, isActive: _isActive),
                                )),
                                const SizedBox(width: 10),
                                Expanded(child: _CardWideButton(
                                  icon: Icons.list_rounded, label: 'Chapters',
                                  accent: accent, isActive: _isActive,
                                  onTap: () => _showChapters(context, accent, tt),
                                )),
                              ]),
                              const SizedBox(height: 10),
                              // Row 2
                              Row(children: [
                                Expanded(child: _CardWideButton(
                                  icon: Icons.bookmark_outline_rounded, label: 'Bookmarks',
                                  accent: accent, isActive: _isActive,
                                  child: _CardBookmarkButtonInline(
                                    player: widget.player, accent: accent,
                                    isActive: _isActive, itemId: _itemId,
                                  ),
                                )),
                                const SizedBox(width: 10),
                                Expanded(child: _CardWideButton(
                                  icon: Icons.speed_rounded, label: 'Speed',
                                  accent: accent, isActive: _isActive,
                                  child: _CardSpeedButtonInline(player: widget.player, accent: accent, isActive: _isActive),
                                )),
                              ]),
                              const SizedBox(height: 10),
                              // Row 3
                              Row(children: [
                                Expanded(child: _CardWideButton(
                                  icon: Icons.history_rounded, label: 'History',
                                  accent: accent, isActive: _isActive,
                                  onTap: () => _showHistory(context, accent, tt),
                                )),
                                const SizedBox(width: 10),
                                Expanded(child: _DownloadWideButton(
                                  itemId: _itemId, coverUrl: _coverUrl,
                                  title: _title, author: _author, accent: accent,
                                )),
                              ]),
                              const SizedBox(height: 10),
                              // Details button — full width
                              GestureDetector(
                                onTap: () => showBookDetailSheet(context, _itemId),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.06),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: accent.withOpacity(0.15)),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.info_outline_rounded, size: 16, color: accent.withOpacity(0.7)),
                                      const SizedBox(width: 8),
                                      Text('Details', style: TextStyle(color: accent.withOpacity(0.7), fontSize: 13, fontWeight: FontWeight.w500)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _currentChapterIndex() {
    final chapters = _isActive ? widget.player.chapters : _chapters;
    if (chapters.isEmpty) return -1;
    final pos = _isActive ? widget.player.position.inMilliseconds / 1000.0 : 0.0;
    for (int i = 0; i < chapters.length; i++) {
      final ch = chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      if (pos >= start && pos < end) return i;
    }
    return 0;
  }

  Widget _coverPlaceholder() => Container(
    color: Colors.white.withOpacity(0.05),
    child: Center(child: Icon(Icons.headphones_rounded, size: 48, color: Colors.white.withOpacity(0.15))),
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
            border: Border(top: BorderSide(color: accent.withOpacity(0.2), width: 1)),
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
                  selectedTileColor: accent.withOpacity(0.1),
                  leading: SizedBox(width: 28, child: Text('${i + 1}', textAlign: TextAlign.center,
                    style: tt.labelMedium?.copyWith(fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400, color: isCurrent ? accent : Colors.white38))),
                  title: Text(chTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400, color: isCurrent ? Colors.white : Colors.white70)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('$pct%', style: tt.labelSmall?.copyWith(
                      color: isCurrent ? accent.withOpacity(0.7) : Colors.white24, fontSize: 10, fontWeight: FontWeight.w600)),
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
            border: Border(top: BorderSide(color: accent.withOpacity(0.2), width: 1)),
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
                      leading: Icon(_historyIcon(e.type), size: 18, color: accent.withOpacity(0.7)),
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
  const _CardDualProgressBar({required this.player, required this.accent, required this.isActive, required this.staticProgress, required this.staticDuration, required this.chapters});
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
    // Periodically reload settings (cheap SharedPreferences read)
    _settingsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _loadSettings());
  }

  Timer? _settingsTimer;

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
    // Reload settings in case user changed them on settings tab
    _loadSettings();
  }

  void _subscribePosition() {
    _posSub?.cancel();
    if (widget.isActive) {
      _posSub = widget.player.positionStream.listen((dur) {
        _lastKnownPos = dur.inMilliseconds / 1000.0;
        _lastPosTime = DateTime.now();
        _currentSpeed = widget.player.speed;
        _isPlaying = widget.player.isPlaying;
      });
      // Seed initial values
      _lastKnownPos = widget.player.position.inMilliseconds / 1000.0;
      _lastPosTime = DateTime.now();
      _currentSpeed = widget.player.speed;
      _isPlaying = widget.player.isPlaying;
    }
  }

  /// Smoothly interpolated position — predicts where playback is right now
  double get _smoothPos {
    if (!widget.isActive || !_isPlaying) return _lastKnownPos;
    final elapsed = DateTime.now().difference(_lastPosTime).inMilliseconds / 1000.0;
    return _lastKnownPos + elapsed * _currentSpeed;
  }

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsTimer?.cancel();
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
        final posS = active ? _smoothPos : widget.staticProgress * widget.staticDuration;
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
            if (_showBookSlider) ...[
              SizedBox(height: 32, child: LayoutBuilder(builder: (_, cons) {
                final w = cons.maxWidth;
                final p = _bookDragValue ?? bookProgress;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: active ? (d) { setState(() => _bookDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                  onHorizontalDragUpdate: active ? (d) { setState(() => _bookDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                  onHorizontalDragEnd: active ? (_) { if (_bookDragValue != null) player.seekTo(Duration(milliseconds: (_bookDragValue! * totalDur * 1000).round())); setState(() => _bookDragValue = null); } : null,
                  onTapUp: active ? (d) { final v = (d.localPosition.dx / w).clamp(0.0, 1.0); player.seekTo(Duration(milliseconds: (v * totalDur * 1000).round())); } : null,
                  child: CustomPaint(size: Size(w, 32), painter: AbsorbProgressPainter(progress: p, accent: widget.accent.withOpacity(0.5), isDragging: _bookDragValue != null)),
                );
              })),
              Padding(padding: const EdgeInsets.only(top: 2, bottom: 6), child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Book', style: tt.labelSmall?.copyWith(color: Colors.white24, fontSize: 9)),
                  Text('-${_fmt(bookRemaining)}', style: tt.labelSmall?.copyWith(color: Colors.white30, fontSize: 9)),
                ],
              )),
            ] else ...[
              Row(children: [
                Text('Book', style: tt.labelSmall?.copyWith(color: Colors.white24, fontSize: 9)),
                const SizedBox(width: 8),
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: bookProgress, minHeight: 3, backgroundColor: Colors.white.withOpacity(0.08), valueColor: AlwaysStoppedAnimation(widget.accent.withOpacity(0.5))))),
                const SizedBox(width: 8),
                Text('-${_fmt(bookRemaining)}', style: tt.labelSmall?.copyWith(color: Colors.white30, fontSize: 9)),
              ]),
              const SizedBox(height: 10),
            ],
            // Chapter bar
            SizedBox(height: 32, child: LayoutBuilder(builder: (_, cons) {
              final w = cons.maxWidth;
              final p = _chapterDragValue ?? chapterProgress;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: active ? (d) { setState(() => _chapterDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                onHorizontalDragUpdate: active ? (d) { setState(() => _chapterDragValue = (d.localPosition.dx / w).clamp(0.0, 1.0)); } : null,
                onHorizontalDragEnd: active ? (_) { if (_chapterDragValue != null) player.seekTo(Duration(milliseconds: ((chapterStart + _chapterDragValue! * chapterDur) * 1000).round())); setState(() => _chapterDragValue = null); } : null,
                onTapUp: active ? (d) { final v = (d.localPosition.dx / w).clamp(0.0, 1.0); player.seekTo(Duration(milliseconds: ((chapterStart + v * chapterDur) * 1000).round())); } : null,
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
                  style: tt.labelSmall?.copyWith(color: Colors.white38, fontSize: 10)),
                Text('-${_fmt(chapterRemaining)}', style: tt.labelSmall?.copyWith(color: Colors.white38, fontSize: 10)),
              ],
            )),
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
    PlayerSettings.getBackSkip().then((v) { if (mounted) setState(() => _backSkip = v); });
    PlayerSettings.getForwardSkip().then((v) { if (mounted) setState(() => _forwardSkip = v); });
  }

  @override void dispose() {
    _playPauseController.dispose();
    super.dispose();
  }

  Widget _skipIcon(int seconds, bool isForward) {
    final hasBuiltIn = [5, 10, 30].contains(seconds);
    if (hasBuiltIn) {
      IconData icon;
      if (isForward) { icon = seconds == 5 ? Icons.forward_5_rounded : seconds == 10 ? Icons.forward_10_rounded : Icons.forward_30_rounded; }
      else { icon = seconds == 5 ? Icons.replay_5_rounded : seconds == 10 ? Icons.replay_10_rounded : Icons.replay_30_rounded; }
      return Icon(icon, size: 32, color: widget.isActive ? Colors.white70 : Colors.white24);
    }
    return Stack(alignment: Alignment.center, children: [
      Icon(isForward ? Icons.rotate_right_rounded : Icons.rotate_left_rounded, size: 32, color: widget.isActive ? Colors.white70 : Colors.white24),
      Padding(padding: const EdgeInsets.only(top: 2), child: Text('$seconds', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: widget.isActive ? Colors.white : Colors.white24))),
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
              boxShadow: [BoxShadow(color: widget.accent.withOpacity(0.4), blurRadius: 25, spreadRadius: -5)],
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
            GestureDetector(
              onTap: widget.isActive ? () => widget.player.skipBackward(_backSkip) : null,
              child: SizedBox(width: 48, height: 48, child: Center(child: _skipIcon(_backSkip, false))),
            ),
            const SizedBox(width: 20),
            GestureDetector(
              onTap: widget.isActive ? widget.player.togglePlayPause : widget.onStart,
              child: SizedBox(
                width: 80, height: 80,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Waveform visualizer rings behind button
                    if (isPlaying) ...[
                      _WaveRing(accent: widget.accent, delay: 0),
                      _WaveRing(accent: widget.accent, delay: 0.33),
                      _WaveRing(accent: widget.accent, delay: 0.66),
                    ],
                    // Main button
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [BoxShadow(color: widget.accent.withOpacity(0.4), blurRadius: 25, spreadRadius: -5)],
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
            const SizedBox(width: 20),
            GestureDetector(
              onTap: widget.isActive ? () => widget.player.skipForward(_forwardSkip) : null,
              child: SizedBox(width: 48, height: 48, child: Center(child: _skipIcon(_forwardSkip, true))),
            ),
          ],
        );
      },
    );
  }
}

/// Pulsing ring that radiates outward from the play button while playing
class _WaveRing extends StatefulWidget {
  final Color accent;
  final double delay;
  const _WaveRing({required this.accent, required this.delay});
  @override State<_WaveRing> createState() => _WaveRingState();
}

class _WaveRingState extends State<_WaveRing> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    Future.delayed(Duration(milliseconds: (widget.delay * 2000).round()), () {
      if (mounted) _controller.repeat();
    });
  }

  @override void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final t = _controller.value;
        final scale = 1.0 + t * 0.4;
        final opacity = (1.0 - t).clamp(0.0, 0.25);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.accent.withOpacity(opacity),
                width: 2,
              ),
            ),
          ),
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
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
          ),
          child: Icon(icon, color: isActive ? Colors.white60 : Colors.white24, size: 20)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: isActive ? Colors.white38 : Colors.white.withOpacity(0.2), fontSize: 9, fontWeight: FontWeight.w500)),
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
            if (timerActive) {
              sleep.cancel();
            } else {
              _showSetSheet(context);
            }
          } : null,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 44, height: 44,
              decoration: BoxDecoration(
                color: timerActive ? accent.withOpacity(0.2) : Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: timerActive ? accent.withOpacity(0.4) : Colors.white.withOpacity(0.1), width: 1),
              ),
              child: timerActive
                  ? Center(child: Text(sleep.displayLabel, style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.w700)))
                  : Icon(Icons.bedtime_outlined, color: isActive ? Colors.white60 : Colors.white24, size: 20)),
            const SizedBox(height: 4),
            Text('Sleep', style: TextStyle(color: timerActive ? accent : (isActive ? Colors.white38 : Colors.white.withOpacity(0.2)), fontSize: 9, fontWeight: FontWeight.w500)),
          ]),
        );
      },
    );
  }

  void _showSetSheet(BuildContext context) {
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          const Text('Sleep Timer', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
            for (final mins in [5, 10, 15, 30, 45, 60])
              _timerChip(ctx, '${mins}m', () {
                SleepTimerService().setTimeSleep(Duration(minutes: mins));
                Navigator.pop(ctx);
              }),
            _timerChip(ctx, '1 Ch', () {
              SleepTimerService().setChapterSleep(1);
              Navigator.pop(ctx);
            }),
            _timerChip(ctx, '2 Ch', () {
              SleepTimerService().setChapterSleep(2);
              Navigator.pop(ctx);
            }),
          ]),
        ]),
      ),
    );
  }

  Widget _timerChip(BuildContext ctx, String label, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.12))),
      child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
    ));
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
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
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
        Text('Bookmarks', style: TextStyle(color: widget.isActive ? Colors.white38 : Colors.white.withOpacity(0.2), fontSize: 9, fontWeight: FontWeight.w500)),
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
        border: Border(top: BorderSide(color: widget.accent.withOpacity(0.2), width: 1)),
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
            decoration: BoxDecoration(color: widget.accent.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.add_rounded, color: widget.accent, size: 20),
          )),
        ])),
        const SizedBox(height: 8),
        Expanded(child: _bookmarks == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _bookmarks!.isEmpty
                ? Center(child: Text('No bookmarks yet', style: tt.bodyMedium?.copyWith(color: Colors.white38)))
                : ListView.builder(
                    controller: widget.scrollController, padding: const EdgeInsets.only(bottom: 24), itemCount: _bookmarks!.length,
                    itemBuilder: (ctx, i) {
                      final bm = _bookmarks![i];
                      return ListTile(
                        leading: Icon(Icons.bookmark_rounded, size: 20, color: widget.accent),
                        title: Text(bm.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium?.copyWith(color: Colors.white70)),
                        subtitle: Text(bm.formattedPosition, style: tt.labelSmall?.copyWith(color: Colors.white38)),
                        trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white24),
                          onPressed: () async { await BookmarkService().deleteBookmark(itemId: widget.itemId, bookmarkId: bm.id); _load(); }),
                        onTap: () { widget.player.seekTo(Duration(seconds: bm.positionSeconds.round())); Navigator.pop(ctx); },
                      );
                    })),
      ]),
    );
  }

  Future<void> _addBookmark() async {
    final pos = widget.player.position.inMilliseconds / 1000.0;
    final h = pos ~/ 3600; final m = (pos % 3600) ~/ 60; final s = pos.toInt() % 60;
    final posStr = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
    final tc = TextEditingController(text: 'Bookmark at $posStr');
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Add Bookmark'),
      content: TextField(controller: tc, autofocus: true, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, tc.text), child: const Text('Save')),
      ],
    ));
    if (result != null && result.isNotEmpty) {
      await BookmarkService().addBookmark(itemId: widget.itemId, positionSeconds: pos, title: result);
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
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
          ),
          child: Center(child: Text(isActive ? '${player.speed}x' : '1.0x',
            style: TextStyle(color: isActive ? accent : Colors.white24, fontSize: 12, fontWeight: FontWeight.w700)))),
        const SizedBox(height: 4),
        Text('Speed', style: TextStyle(color: isActive ? Colors.white38 : Colors.white.withOpacity(0.2), fontSize: 9, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  void _showSpeedSheet(BuildContext context) {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent,
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
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: widget.accent.withOpacity(0.2), width: 1))),
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
            decoration: BoxDecoration(color: a ? widget.accent : Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(20),
              border: Border.all(color: a ? widget.accent : Colors.white.withOpacity(0.12))),
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
      iconColor = Colors.greenAccent.withOpacity(0.8);
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
                color: Colors.white.withOpacity(0.08),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            if (downloading)
              SizedBox(width: 44, height: 44,
                child: CircularProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  strokeWidth: 2,
                  color: Colors.white38,
                  backgroundColor: Colors.white.withOpacity(0.05),
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
  final VoidCallback? onTap;
  final Widget? child; // if provided, renders child instead (for stateful buttons)

  const _CardWideButton({
    required this.icon, required this.label,
    required this.accent, required this.isActive,
    this.onTap, this.child,
  });

  @override Widget build(BuildContext context) {
    if (child != null) return child!;
    return GestureDetector(
      onTap: isActive ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: isActive ? Colors.white54 : Colors.white24),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(
              color: isActive ? Colors.white54 : Colors.white24,
              fontSize: 12, fontWeight: FontWeight.w500)),
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
            if (active) { sleep.cancel(); } else { _showSleepPicker(context); }
          } : null,
          child: Container(
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: active ? accent.withOpacity(0.1) : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: active ? accent.withOpacity(0.3) : Colors.white.withOpacity(0.08)),
            ),
            child: Stack(children: [
              if (active && isTime)
                FractionallySizedBox(
                  widthFactor: sleep.timeProgress.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.15),
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
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        decoration: const BoxDecoration(color: Color(0xFF1A1A1A), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          const Text('Sleep Timer', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
            for (final mins in [5, 10, 15, 30, 45, 60])
              _timerChip(ctx, '${mins}m', () { SleepTimerService().setTimeSleep(Duration(minutes: mins)); Navigator.pop(ctx); }),
            _timerChip(ctx, '1 Ch', () { SleepTimerService().setChapterSleep(1); Navigator.pop(ctx); }),
            _timerChip(ctx, '2 Ch', () { SleepTimerService().setChapterSleep(2); Navigator.pop(ctx); }),
          ]),
        ]),
      ),
    );
  }

  Widget _timerChip(BuildContext ctx, String label, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.12))),
      child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
    ));
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
  @override Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isActive ? _addBookmark : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bookmark_outline_rounded, size: 18,
              color: widget.isActive ? Colors.white54 : Colors.white24),
            const SizedBox(width: 8),
            Text('Bookmark', style: TextStyle(
              color: widget.isActive ? Colors.white54 : Colors.white24,
              fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  void _addBookmark() {
    final pos = widget.player.position;
    BookmarkService().addBookmark(itemId: widget.itemId, positionSeconds: pos.inMilliseconds / 1000.0, title: 'Bookmark');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: const Text('Bookmark added'),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
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
          builder: (ctx) => _CardSpeedSheet(player: player, accent: accent));
      } : null,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
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

/// Download button as wide card
class _DownloadWideButton extends StatefulWidget {
  final String itemId;
  final String? coverUrl;
  final String title;
  final String? author;
  final Color accent;
  const _DownloadWideButton({required this.itemId, this.coverUrl, required this.title, this.author, required this.accent});
  @override State<_DownloadWideButton> createState() => _DownloadWideButtonState();
}

class _DownloadWideButtonState extends State<_DownloadWideButton> {
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
    final Color color;
    if (downloaded) {
      icon = Icons.download_done_rounded;
      label = 'Saved';
      color = Colors.greenAccent.withOpacity(0.7);
    } else if (downloading) {
      icon = Icons.downloading_rounded;
      label = '${(progress * 100).toStringAsFixed(0)}%';
      color = widget.accent;
    } else {
      icon = Icons.download_outlined;
      label = 'Download';
      color = Colors.white54;
    }

    return GestureDetector(
      onTap: () => _handleTap(context),
      child: Container(
        height: 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: downloaded ? Colors.greenAccent.withOpacity(0.06) : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: downloaded ? Colors.greenAccent.withOpacity(0.15) : Colors.white.withOpacity(0.08)),
        ),
        child: Stack(children: [
          if (downloading)
            FractionallySizedBox(
              widthFactor: progress.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: widget.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          Center(child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          )),
        ]),
      ),
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

// ─── BOOK DETAIL BOTTOM SHEET ───────────────────────────────

void showBookDetailSheet(BuildContext context, String itemId) {
  showModalBottomSheet(
    context: context, isScrollControlled: true, useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false, initialChildSize: 0.85, minChildSize: 0.5, maxChildSize: 0.95,
      builder: (ctx, sc) => _BookDetailSheetContent(itemId: itemId, scrollController: sc),
    ),
  );
}

class _BookDetailSheetContent extends StatefulWidget {
  final String itemId;
  final ScrollController scrollController;
  const _BookDetailSheetContent({required this.itemId, required this.scrollController});
  @override State<_BookDetailSheetContent> createState() => _BookDetailSheetContentState();
}

class _BookDetailSheetContentState extends State<_BookDetailSheetContent> {
  Map<String, dynamic>? _item;
  bool _isLoading = true;
  bool _chaptersExpanded = false;

  @override void initState() { super.initState(); _loadItem(); }

  Future<void> _loadItem() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    try {
      final item = await api.getLibraryItem(widget.itemId);
      if (mounted) setState(() { _item = item; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String? get _coverUrl {
    final auth = context.read<AuthProvider>();
    return auth.apiService?.getCoverUrl(widget.itemId, width: 800);
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(color: Color(0xFF111111), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Stack(children: [
        if (_coverUrl != null)
          Positioned.fill(child: CachedNetworkImage(
            imageUrl: _coverUrl!, fit: BoxFit.cover,
            imageBuilder: (_, p) => ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80, tileMode: TileMode.decal),
              child: Image(image: p, fit: BoxFit.cover)),
            placeholder: (_, __) => const SizedBox(),
            errorWidget: (_, __, ___) => const SizedBox(),
          )),
        Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [const Color(0xFF111111).withOpacity(0.6), const Color(0xFF111111).withOpacity(0.85), const Color(0xFF111111)],
        )))),
        _isLoading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24))
            : _item == null
                ? Center(child: Text('Failed to load', style: tt.bodyMedium?.copyWith(color: Colors.white38)))
                : AnimatedOpacity(
                    opacity: 1.0, duration: const Duration(milliseconds: 300),
                    child: _buildContent(context, cs, tt)),
      ]),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme cs, TextTheme tt) {
    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];
    final title = metadata['title'] as String? ?? 'Unknown';
    final authorName = metadata['authorName'] as String? ?? '';
    final narrator = metadata['narratorName'] as String? ?? '';
    final descRaw = metadata['description'] as String? ?? '';
    final desc = descRaw.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&nbsp;', ' ').trim();
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final seriesEntries = metadata['series'] as List<dynamic>? ?? [];
    final genres = (metadata['genres'] as List<dynamic>?)?.cast<String>() ?? [];
    final publisher = metadata['publisher'] as String? ?? '';
    final year = metadata['publishedYear'] as String? ?? '';
    final lib = context.watch<LibraryProvider>();
    final progress = lib.getProgress(widget.itemId);
    final auth = context.read<AuthProvider>();

    final progressData = lib.getProgressData(widget.itemId);
    final isFinished = progressData?['isFinished'] == true;
    final currentTime = (progressData?['currentTime'] as num?)?.toDouble() ?? 0;

    return ListView(controller: widget.scrollController, padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
      Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
      Text(title, textAlign: TextAlign.center, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
      const SizedBox(height: 4),
      Text(authorName, textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: Colors.white60)),
      if (narrator.isNotEmpty) ...[const SizedBox(height: 2),
        Text('Narrated by $narrator', textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: Colors.white38))],
      const SizedBox(height: 12),
      if (progress > 0) ...[
        ClipRRect(borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 4,
            backgroundColor: Colors.white.withOpacity(0.1), valueColor: AlwaysStoppedAnimation(cs.primary))),
        const SizedBox(height: 4),
        Text('${(progress * 100).toStringAsFixed(1)}% complete', textAlign: TextAlign.center,
          style: tt.labelSmall?.copyWith(color: Colors.white38)),
        const SizedBox(height: 12),
      ],
      SizedBox(height: 52, child: FilledButton.icon(
        onPressed: () => _startAbsorb(context, auth: auth, title: title, author: authorName,
          coverUrl: _coverUrl, duration: duration, chapters: chapters),
        icon: const Icon(Icons.waves_rounded, size: 24),
        label: Text('Absorb', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onPrimary)),
        style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      )),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _DownloadButton(itemId: widget.itemId, coverUrl: _coverUrl, title: title, author: authorName)),
        const SizedBox(width: 10),
        if (isFinished)
          Expanded(child: _sheetBtn(icon: Icons.replay_rounded,
            label: 'Listen Again', onTap: () => _markNotFinished(context, auth, currentTime, duration)))
        else
          Expanded(child: _sheetBtn(icon: Icons.check_circle_outline_rounded,
            label: 'Mark Finished', onTap: () => _markFinished(context, auth, duration))),
      ]),
      if (progress > 0 || isFinished) ...[
        const SizedBox(height: 8),
        _sheetBtn(icon: Icons.restart_alt_rounded,
          label: 'Reset Progress', onTap: () => _resetProgress(context, auth, duration)),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (year.isNotEmpty) _chip(Icons.calendar_today_rounded, year),
        _chip(Icons.schedule_rounded, _fmtDur(duration)),
        if (chapters.isNotEmpty) _chip(Icons.list_rounded, '${chapters.length} chapters'),
        if (publisher.isNotEmpty) _chip(Icons.business_rounded, publisher),
        ...genres.take(3).map((g) => _chip(Icons.tag_rounded, g)),
      ]),
      if (seriesEntries.isNotEmpty) ...[const SizedBox(height: 16),
        ...seriesEntries.map((s) {
          final name = s['name'] as String? ?? '';
          final seq = s['sequence'] as String? ?? '';
          final seriesId = s['id'] as String?;
          return Padding(padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              onTap: () => _openSeries(context, seriesId, name),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.primary.withOpacity(0.15)),
                ),
                child: Row(children: [
                  Icon(Icons.auto_stories_rounded, size: 16, color: cs.primary.withOpacity(0.7)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('$name${seq.isNotEmpty ? ' #$seq' : ''}',
                    style: tt.bodySmall?.copyWith(color: cs.primary.withOpacity(0.9), fontWeight: FontWeight.w500))),
                  Icon(Icons.chevron_right_rounded, size: 18, color: cs.primary.withOpacity(0.5)),
                ]),
              ),
            ));
        })],
      if (desc.isNotEmpty) ...[const SizedBox(height: 16),
        Text('About', style: tt.titleSmall?.copyWith(color: Colors.white54, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(desc, style: tt.bodySmall?.copyWith(color: Colors.white70, height: 1.5))],
      if (chapters.isNotEmpty) ...[const SizedBox(height: 16),
        GestureDetector(onTap: () => setState(() => _chaptersExpanded = !_chaptersExpanded),
          child: Row(children: [
            Text('Chapters (${chapters.length})', style: tt.titleSmall?.copyWith(color: Colors.white54, fontWeight: FontWeight.w600)),
            const Spacer(), Icon(_chaptersExpanded ? Icons.expand_less : Icons.expand_more, color: Colors.white38, size: 20)])),
        if (_chaptersExpanded) ...[const SizedBox(height: 8),
          ...chapters.asMap().entries.map((e) {
            final ch = e.value as Map<String, dynamic>;
            return Padding(padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 28, child: Text('${e.key + 1}', style: tt.labelSmall?.copyWith(color: Colors.white30))),
                Expanded(child: Text(ch['title'] as String? ?? 'Chapter ${e.key + 1}', maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: Colors.white60))),
                Text(_fmtDur(((ch['end'] as num?)?.toDouble() ?? 0) - ((ch['start'] as num?)?.toDouble() ?? 0)), style: tt.labelSmall?.copyWith(color: Colors.white30)),
              ]));
          })]],
    ]);
  }

  Widget _sheetBtn({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(onTap: onTap, child: Container(height: 40,
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.1))),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 16, color: Colors.white54), const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500))])));
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: Colors.white38), const SizedBox(width: 4),
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis, maxLines: 1,
          style: const TextStyle(color: Colors.white54, fontSize: 11)))]));
  }

  String _fmtDur(double s) {
    final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor();
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  Future<void> _openSeries(BuildContext context, String? seriesId, String seriesName) async {
    if (seriesId == null) return;
    final seriesMap = <String, dynamic>{
      'id': seriesId,
      'name': seriesName,
    };
    Navigator.pop(context); // close sheet
    Navigator.push(context, MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: seriesMap)));
  }

  Future<void> _startAbsorb(BuildContext context, {required AuthProvider auth, required String title, required String author, required String? coverUrl, required double duration, required List<dynamic> chapters}) async {
    final player = AudioPlayerService();
    // Grab the root navigator before we pop the sheet
    final rootNav = Navigator.of(context, rootNavigator: true);
    
    if (player.currentItemId == widget.itemId) {
      if (!player.isPlaying) player.play();
      // Close the sheet, then go to absorbing
      rootNav.pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) return; // sheet is gone, use the app shell context instead
        // Find app shell from the navigator's context
      });
      // Use a slight delay to let the sheet close
      Future.delayed(const Duration(milliseconds: 100), () {
        AppShell.goToAbsorbingGlobal();
      });
      return;
    }
    final api = auth.apiService;
    if (api == null) return;
    
    // Start playback
    await player.playItem(api: api, itemId: widget.itemId, title: title, author: author, coverUrl: coverUrl, totalDuration: duration, chapters: chapters);
    
    // Refresh library so the absorbing screen picks up the new book
    if (context.mounted) {
      final lib = context.read<LibraryProvider>();
      lib.refreshLocalProgress();
      lib.refresh();
    }
    
    // Close sheet and navigate
    rootNav.pop();
    Future.delayed(const Duration(milliseconds: 100), () {
      AppShell.goToAbsorbingGlobal();
    });
  }

  Future<void> _markFinished(BuildContext context, AuthProvider auth, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Finished?'),
        content: const Text('This will set your progress to 100% and stop playback if this book is playing.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark Finished')),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    final player = AudioPlayerService();
    if (player.currentItemId == widget.itemId) await player.stop();
    try {
      await api.markFinished(widget.itemId, duration);
      await ProgressSyncService().deleteLocal(widget.itemId);
      if (context.mounted) {
        context.read<LibraryProvider>().clearProgressFor(widget.itemId);
        await _loadItem();
        context.read<LibraryProvider>().refresh();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 3), content: const Text('Marked as finished — nice work!'),
          behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      }
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3), content: const Text('Failed to update — check your connection'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }

  Future<void> _markNotFinished(BuildContext context, AuthProvider auth, double currentTime, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Not Finished?'),
        content: const Text('This will clear the finished status but keep your current position.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unmark')),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    try {
      await api.markNotFinished(widget.itemId, currentTime: currentTime, duration: duration);
      await ProgressSyncService().deleteLocal(widget.itemId);
      if (context.mounted) {
        context.read<LibraryProvider>().clearProgressFor(widget.itemId);
        await _loadItem();
        context.read<LibraryProvider>().refresh();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 3), content: const Text('Marked as not finished — back at it!'),
          behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      }
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3), content: const Text('Failed to update — check your connection'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }

  Future<void> _resetProgress(BuildContext context, AuthProvider auth, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Progress?'),
        content: const Text('This will erase all progress for this book and set it back to the beginning. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    final player = AudioPlayerService();
    if (player.currentItemId == widget.itemId) await player.stop();
    await ProgressSyncService().deleteLocal(widget.itemId);
    if (context.mounted) context.read<LibraryProvider>().clearProgressFor(widget.itemId);
    final serverSuccess = await api.resetProgress(widget.itemId, duration);
    if (context.mounted) {
      await _loadItem();
      await context.read<LibraryProvider>().refresh();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(serverSuccess ? 'Progress reset — fresh start!' : 'Reset may not have synced — check your server'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }
}

// ─── MARQUEE TEXT (scrolls if content overflows) ─────────────

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
