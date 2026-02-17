import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../widgets/home_section.dart';
import '../widgets/library_selector.dart';
import '../widgets/absorb_title.dart';
import '../widgets/shimmer.dart';
import 'absorbing_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _player = AudioPlayerService();

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayerChanged);
    Future.microtask(() {
      final lib = context.read<LibraryProvider>();
      if (lib.libraries.isEmpty) lib.loadLibraries();
      lib.refreshLocalProgress();
    });
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    if (mounted) {
      context.read<LibraryProvider>().refreshLocalProgress();
      setState(() {});
    }
  }

  static const _prioritySections = [
    'continue-listening',
    'continue-series',
    'recently-added',
    'listen-again',
    'discover',
  ];

  static const _hiddenSections = {'newest-authors', 'recent-series'};

  static const _sectionLabels = {
    'continue-listening': 'Continue Listening',
    'continue-series': 'Continue Series',
    'recently-added': 'Recently Added',
    'listen-again': 'Listen Again',
    'discover': 'Discover',
    'episodes-recently-added': 'New Episodes',
    'downloaded-books': 'Downloaded Books',
  };

  static const _sectionIcons = {
    'continue-listening': Icons.play_circle_outline_rounded,
    'continue-series': Icons.auto_stories_rounded,
    'recently-added': Icons.new_releases_outlined,
    'listen-again': Icons.replay_rounded,
    'discover': Icons.explore_outlined,
    'episodes-recently-added': Icons.podcasts_rounded,
    'downloaded-books': Icons.download_done_rounded,
  };

  List<dynamic> _sortSections(List<dynamic> sections) {
    final sorted = List<dynamic>.from(sections);
    sorted.sort((a, b) {
      final aIdx = _prioritySections.indexOf(a['id'] ?? '');
      final bIdx = _prioritySections.indexOf(b['id'] ?? '');
      return (aIdx == -1 ? 999 : aIdx).compareTo(bIdx == -1 ? 999 : bIdx);
    });
    return sorted;
  }

  List<dynamic> _continueListeningItems(LibraryProvider lib) {
    for (final section in lib.personalizedSections) {
      if (section['id'] == 'continue-listening') {
        return (section['entities'] as List<dynamic>?) ?? [];
      }
    }
    return [];
  }

  String _titleCase(String s) {
    return s.replaceAll('-', ' ').split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final lib = context.watch<LibraryProvider>();

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await lib.refresh();
          },
          child: CustomScrollView(
            slivers: [
              // ── Top bar: ABSORB title + offline toggle + library selector ──
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                  child: Row(
                    children: [
                      const AbsorbTitle(),
                      const Spacer(),
                      if (!lib.isOffline && lib.libraries.length > 1)
                        const LibrarySelectorButton(),
                    ],
                  ),
                ),
              ),

              // ── Loading shimmer ──
              if (lib.isLoading)
                ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  const SliverToBoxAdapter(child: ShimmerHeroCard()),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  const SliverToBoxAdapter(child: ShimmerBookRow()),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  const SliverToBoxAdapter(child: ShimmerBookRow()),
                ],

              // ── Error ──
              if (!lib.isLoading && lib.errorMessage != null &&
                  lib.personalizedSections.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off_rounded, size: 48, color: cs.error),
                        const SizedBox(height: 12),
                        Text(lib.errorMessage!,
                          style: tt.bodyLarge?.copyWith(color: cs.error)),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: lib.refresh,
                          child: const Text('Retry')),
                      ],
                    ),
                  ),
                ),

              // ── Empty ──
              if (!lib.isLoading && lib.errorMessage == null &&
                  lib.personalizedSections.isEmpty && (lib.libraries.isNotEmpty || lib.isOffline))
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          lib.isOffline
                              ? Icons.download_for_offline_outlined
                              : Icons.library_music_outlined,
                          size: 48,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          lib.isOffline
                              ? 'No downloaded books'
                              : 'Your library is empty',
                          style: tt.bodyLarge?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        if (lib.isOffline) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Download books while online to listen offline',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              // ── Other sections ──
              if (!lib.isLoading)
                ..._sortSections(lib.personalizedSections).map((section) {
                  final id = section['id'] ?? '';
                  if (id == 'continue-listening' ||
                      _hiddenSections.contains(id)) {
                    return const SliverToBoxAdapter();
                  }
                  final label = section['label'] ??
                      _sectionLabels[id] ?? _titleCase(id);
                  final entities =
                      (section['entities'] as List<dynamic>?) ?? [];
                  final type = section['type'] ?? 'book';
                  if (entities.isEmpty) return const SliverToBoxAdapter();

                  return SliverToBoxAdapter(
                    child: HomeSection(
                      title: label,
                      icon: _sectionIcons[id] ?? Icons.album_outlined,
                      entities: entities,
                      sectionType: type,
                      sectionId: id,
                    ),
                  );
                }),

              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Absorb Card — blurred-cover card for continue listening
// ══════════════════════════════════════════════════════════════

class _AbsorbCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final double progress;
  final String? coverUrl;

  const _AbsorbCard({
    required this.item,
    required this.progress,
    this.coverUrl,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];

    final title = metadata['title'] as String? ?? 'Unknown';
    final author = metadata['authorName'] as String? ?? '';
    final itemId = item['id'] as String?;

    final duration = (media['duration'] is num)
        ? (media['duration'] as num).toDouble() : 0.0;
    final currentTime = progress * duration;

    // Try to get chapter count from various sources
    final numChapters = chapters.isNotEmpty
        ? chapters.length
        : (media['numChapters'] is num)
            ? (media['numChapters'] as num).toInt()
            : (metadata['chapters'] is List)
                ? (metadata['chapters'] as List).length
                : 0;

    // Try to find current chapter from chapter timing data
    String chapterLabel = '';
    if (chapters.isNotEmpty) {
      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        if (ch is! Map) continue;
        final start =
            (ch['start'] is num) ? (ch['start'] as num).toDouble() : 0.0;
        final end =
            (ch['end'] is num) ? (ch['end'] as num).toDouble() : 0.0;
        if (currentTime >= start && currentTime < end) {
          chapterLabel = 'Ch. ${i + 1} of $numChapters';
          break;
        }
      }
    }
    // Fallback: if we have numChapters but no timing, estimate chapter
    if (chapterLabel.isEmpty && numChapters > 0 && duration > 0) {
      final estChapter = ((currentTime / duration) * numChapters).floor() + 1;
      chapterLabel = 'Ch. ~$estChapter of $numChapters';
    }

    final remaining = duration - currentTime;
    final hoursLeft = (remaining / 3600).floor();
    final minsLeft = ((remaining % 3600) / 60).floor();
    final timeLeft = hoursLeft > 0
        ? '${hoursLeft}h ${minsLeft}m left'
        : '${minsLeft}m left';

    return GestureDetector(
      onTap: () {
        if (itemId != null) {
          showBookDetailSheet(context, itemId);
        }
      },
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 20,
              spreadRadius: -4,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Cover image — scaled up to avoid blur edge artifacts
            if (coverUrl != null)
              Positioned.fill(
                child: Transform.scale(
                  scale: 1.15,
                  child: CachedNetworkImage(
                    imageUrl: coverUrl!,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) =>
                        Container(color: cs.surfaceContainerHigh),
                  ),
                ),
              )
            else
              Container(color: cs.surfaceContainerHigh),

            // Blur + dark overlay — no separate ClipRRect needed,
            // outer container's clipBehavior handles it
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(color: Colors.black.withOpacity(0.5)),
              ),
            ),

            // Content
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // ── Square cover ──
                  AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 16,
                            spreadRadius: -2,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: coverUrl != null
                            ? CachedNetworkImage(
                                imageUrl: coverUrl!,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => Container(
                                  color: cs.surfaceContainerHighest),
                              )
                            : Container(
                                color: cs.surfaceContainerHighest,
                                child: const Icon(Icons.headphones_rounded,
                                    color: Colors.white24, size: 32)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // ── Info ──
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.2,
                          ),
                        ),
                        if (author.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.bodySmall?.copyWith(
                              color: Colors.white60, fontSize: 13)),
                        ],
                        const SizedBox(height: 14),
                        // Progress bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            minHeight: 4,
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation(cs.primary),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Stats row
                        Row(
                          children: [
                            Text(
                              '${(progress * 100).round()}%',
                              style: tt.labelMedium?.copyWith(
                                color: cs.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (chapterLabel.isNotEmpty) ...[
                              Text('·',
                                style: tt.labelSmall?.copyWith(
                                  color: Colors.white30)),
                              const SizedBox(width: 6),
                              Text(chapterLabel,
                                style: tt.labelSmall?.copyWith(
                                  color: Colors.white60, fontSize: 11)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(timeLeft,
                          style: tt.labelSmall?.copyWith(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Listening Stats Strip
// ══════════════════════════════════════════════════════════════


