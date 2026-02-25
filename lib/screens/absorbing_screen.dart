import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/absorbing_card.dart';

class AbsorbingScreen extends StatefulWidget {
  const AbsorbingScreen({super.key});

  /// Global key for accessing the absorbing screen state
  static final globalKey = GlobalKey<_AbsorbingScreenState>();

  /// Scroll to the currently playing book card
  static void scrollToActive() {
    globalKey.currentState?._scrollToActiveCard();
  }

  @override
  State<AbsorbingScreen> createState() => _AbsorbingScreenState();
}

class _AbsorbingScreenState extends State<AbsorbingScreen> {
  final _player = AudioPlayerService();
  final _pageController = PageController(viewportFraction: 0.92);

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
  String? _lastFinishedId;
  bool _isSyncing = false;

  void _rebuild() {
    if (!mounted) return;
    if (_player.currentItemId != _lastPlayingId) {
      final wasPlayingId = _lastPlayingId;
      _lastPlayingId = _player.currentItemId;
      if (_player.hasBook) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActiveCard());
      } else if (wasPlayingId != null && !_isSyncing) {
        // Book just stopped (natural completion or session end)
        _lastFinishedId = wasPlayingId;
        final lib = context.read<LibraryProvider>();
        lib.markFinishedLocally(wasPlayingId);
      }
    }
    setState(() {});
  }

  void _scrollToActiveCard({int retries = 2}) {
    if (!_player.hasBook || !mounted) return;
    final lib = context.read<LibraryProvider>();
    final books = _getAbsorbingBooks(lib);
    final idx = books.indexWhere((b) => (b['id'] as String?) == _player.currentItemId);
    if (idx >= 0 && _pageController.hasClients) {
      _pageController.animateToPage(idx, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    } else if (retries > 0) {
      // Book might not be in the list yet — retry after a rebuild
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _scrollToActiveCard(retries: retries - 1);
      });
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

  /// Pull-to-refresh: sync progress to/from server without stopping playback.
  Future<void> _pullRefresh() async {
    final lib = context.read<LibraryProvider>();
    if (lib.isOffline) return;
    await lib.refresh();
  }

  List<Map<String, dynamic>> _getAbsorbingBooks(LibraryProvider lib) {
    final removes = lib.manualAbsorbRemoves;
    final cache = lib.absorbingItemCache;

    // Quick lookup of fresh data from the current server sections
    final sectionLookup = <String, Map<String, dynamic>>{};
    for (final section in lib.personalizedSections) {
      for (final e in (section['entities'] as List<dynamic>? ?? [])) {
        if (e is Map<String, dynamic>) {
          final itemId = e['id'] as String?;
          if (itemId != null) sectionLookup[itemId] = e;
        }
      }
    }

    // Build list from the persisted local absorbing set.
    // Books stay here even after the server removes them from continue-listening
    // (e.g. when marked finished). Only removed when the user explicitly removes.
    final items = <Map<String, dynamic>>[];
    for (final itemId in lib.absorbingBookIds) {
      if (removes.contains(itemId)) continue;
      final itemData = sectionLookup[itemId] ?? cache[itemId];
      if (itemData != null) items.add(itemData);
    }

    // If the currently playing book isn't in the list, add it at the front.
    // If it IS in the list, move it to the front.
    if (_player.hasBook && _player.currentItemId != null) {
      final playingId = _player.currentItemId!;
      if (!removes.contains(playingId)) {
        final existingIdx = items.indexWhere((b) => (b['id'] as String?) == playingId);
        if (existingIdx > 0) {
          final item = items.removeAt(existingIdx);
          items.insert(0, item);
        } else if (existingIdx < 0) {
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
    }

    // When nothing is playing, keep the last-finished book at the front
    if (!_player.hasBook && _lastFinishedId != null && !removes.contains(_lastFinishedId)) {
      final finishedIdx = items.indexWhere((b) => (b['id'] as String?) == _lastFinishedId);
      if (finishedIdx > 0) {
        final item = items.removeAt(finishedIdx);
        items.insert(0, item);
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
    final effectiveOffline = lib.isOffline;
    if (effectiveOffline) {
      books = books.where((b) => dl.isDownloaded(b['id'] as String? ?? '')).toList();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            AbsorbPageHeader(
              title: 'Absorbing',
              brandingColor: Colors.white38,
              titleColor: Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
              actions: [
                // Offline mode toggle
                GestureDetector(
                  onTap: () {
                    final newVal = !lib.isManualOffline;
                    lib.setManualOffline(newVal);
                    if (newVal) _stopAndRefresh(lib);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: effectiveOffline ? Colors.orange.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: effectiveOffline ? Colors.orange.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.08)),
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
                // Unified button: "Sync" when idle, "Stop & Sync" when playing
                if (!effectiveOffline)
                  GestureDetector(
                    onTap: _isSyncing ? null : () {
                      if (_player.hasBook) {
                        _stopAndRefresh(lib);
                      } else {
                        () async {
                          setState(() => _isSyncing = true);
                          await _pullRefresh();
                          if (mounted) setState(() => _isSyncing = false);
                        }();
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isSyncing) ...[
                            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38)),
                            const SizedBox(width: 6),
                            const Text('Syncing…', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                          ] else if (_player.hasBook) ...[
                            const Icon(Icons.stop_rounded, size: 14, color: Colors.white38),
                            const SizedBox(width: 4),
                            const Text('Stop & Sync', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                          ] else ...[
                            const Icon(Icons.sync_rounded, size: 14, color: Colors.white38),
                            const SizedBox(width: 4),
                            const Text('Sync', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  // Offline: just stop button (no sync)
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
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.stop_rounded, size: 14, color: Colors.white38),
                              SizedBox(width: 4),
                              Text('Stop', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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
                          clipBehavior: Clip.none,
                          physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
                          itemCount: books.length,
                          itemBuilder: (_, i) => LayoutBuilder(
                            builder: (context, constraints) {
                              final cardWidth = constraints.maxWidth;
                              final vPad = (constraints.maxHeight * 0.04).clamp(12.0, 40.0);
                              return AnimatedBuilder(
                                animation: _pageController,
                                builder: (context, child) {
                                  double distFromCenter = 0.0;
                                  double rawDist = 0.0;
                                  if (_pageController.position.haveDimensions) {
                                    final page = _pageController.page ?? _pageController.initialPage.toDouble();
                                    rawDist = page - i; // negative = card is to the right
                                    distFromCenter = rawDist.abs();
                                  }
                                  final double scaleX;
                                  if (distFromCenter >= 1.0) {
                                    scaleX = 0.85;
                                  } else {
                                    // Use easeOut curve for smoother transition
                                    final t = Curves.easeOut.transform(1.0 - distFromCenter);
                                    scaleX = 0.85 + (t * 0.15); // 0.85 → 1.0
                                  }
                                  // Calculate how much space the squeeze frees up, then translate toward center
                                  final squeezedWidth = cardWidth * scaleX;
                                  final freedSpace = cardWidth - squeezedWidth;
                                  // Pull card toward center by half the freed space
                                  final direction = rawDist > 0 ? 1.0 : (rawDist < 0 ? -1.0 : 0.0);
                                  final translateX = direction * freedSpace * 0.45;

                                  return Transform(
                                    alignment: Alignment.center,
                                    transform: Matrix4.identity()
                                      ..translate(translateX, 0.0, 0.0)
                                      ..scale(scaleX, 1.0, 1.0),
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: vPad),
                                      child: child,
                                    ),
                                  );
                                },
                                child: RepaintBoundary(child: AbsorbingCard(key: ValueKey(books[i]['id'] as String? ?? '$i'), item: books[i], player: _player)),
                              );
                            },
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
            size: 64, color: Colors.white.withValues(alpha: 0.15)),
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
                color: active ? Colors.white54 : Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        );
      },
    );
  }
}
