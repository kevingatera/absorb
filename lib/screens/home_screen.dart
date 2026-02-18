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
import 'app_shell.dart';

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
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.3, 1.0],
            colors: [
              cs.primary.withOpacity(0.06),
              cs.surface,
              cs.surface,
            ],
          ),
        ),
        child: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await lib.refresh();
          },
          child: CustomScrollView(
            slivers: [
              // ── Top bar: ABSORB title + library selector ──
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

              // ── Currently Absorbing section ──
              if (!lib.isLoading)
                ...() {
                  // Find continue-listening entities
                  List<dynamic> clItems = [];
                  for (final section in lib.personalizedSections) {
                    if (section['id'] == 'continue-listening') {
                      clItems = (section['entities'] as List<dynamic>?) ?? [];
                      break;
                    }
                  }
                  if (clItems.isEmpty) return <Widget>[];
                  return <Widget>[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                        child: Row(
                          children: [
                            Icon(Icons.play_circle_outline_rounded, size: 16,
                              color: cs.primary.withOpacity(0.7)),
                            const SizedBox(width: 8),
                            Text('Continue Listening',
                              style: tt.titleSmall?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: cs.onSurface.withOpacity(0.8),
                                letterSpacing: 0.3,
                              )),
                            const SizedBox(width: 12),
                            Expanded(child: Container(height: 0.5,
                              color: cs.outlineVariant.withOpacity(0.2))),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SizedBox(
                          height: 72,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            physics: const BouncingScrollPhysics(),
                            itemCount: clItems.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 10),
                            itemBuilder: (context, i) {
                              final item = clItems[i] as Map<String, dynamic>;
                              return _ContinueListeningCard(
                                item: item,
                                lib: lib,
                                player: _player,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ];
                }(),

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
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Continue Listening Card — compact card with play button
// ══════════════════════════════════════════════════════════════

class _ContinueListeningCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final LibraryProvider lib;
  final AudioPlayerService player;

  const _ContinueListeningCard({
    required this.item,
    required this.lib,
    required this.player,
  });

  @override
  State<_ContinueListeningCard> createState() => _ContinueListeningCardState();
}

class _ContinueListeningCardState extends State<_ContinueListeningCard> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final item = widget.item;
    final lib = widget.lib;
    final player = widget.player;

    final itemId = item['id'] as String? ?? '';
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = metadata['title'] as String? ?? 'Unknown';
    final author = metadata['authorName'] as String? ?? '';
    final coverUrl = lib.getCoverUrl(itemId);
    final progress = lib.getProgress(itemId);
    final isCurrentItem = player.currentItemId == itemId;

    return GestureDetector(
      onTap: () => showBookDetailSheet(context, itemId),
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isCurrentItem
              ? cs.primary.withOpacity(0.08)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: isCurrentItem
              ? Border.all(color: cs.primary.withOpacity(0.2))
              : null,
        ),
        child: Row(
          children: [
            // Cover
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48, height: 48,
                child: coverUrl != null
                    ? CachedNetworkImage(imageUrl: coverUrl, fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(Icons.headphones_rounded, size: 18, color: cs.onSurfaceVariant)))
                    : Container(
                        color: cs.surfaceContainerHighest,
                        child: Icon(Icons.headphones_rounded, size: 18, color: cs.onSurfaceVariant)),
              ),
            ),
            const SizedBox(width: 10),
            // Title + author + progress
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600, color: cs.onSurface)),
                  if (author.isNotEmpty)
                    Text(author, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: tt.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant, fontSize: 11)),
                  const SizedBox(height: 4),
                  // Thin progress bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: cs.outlineVariant.withOpacity(0.2),
                      valueColor: AlwaysStoppedAnimation(cs.primary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Play button
            GestureDetector(
              onTap: _isLoading ? null : () {
                if (isCurrentItem) {
                  player.togglePlayPause();
                } else {
                  _startBook(context, itemId);
                }
              },
              child: Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(isCurrentItem ? 1.0 : 0.15),
                  shape: BoxShape.circle,
                ),
                child: _isLoading
                    ? Padding(
                        padding: const EdgeInsets.all(9),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isCurrentItem ? cs.onPrimary : cs.primary,
                        ),
                      )
                    : Icon(
                        isCurrentItem && player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 18,
                        color: isCurrentItem ? cs.onPrimary : cs.primary,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startBook(BuildContext context, String itemId) async {
    setState(() => _isLoading = true);
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) { setState(() => _isLoading = false); return; }

    // Fetch full item data to get chapters
    final fullItem = await api.getLibraryItem(itemId);
    if (fullItem == null) { if (mounted) setState(() => _isLoading = false); return; }

    final media = fullItem['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = metadata['title'] as String? ?? '';
    final author = metadata['authorName'] as String? ?? '';
    final coverUrl = widget.lib.getCoverUrl(itemId);
    final duration = (media['duration'] is num)
        ? (media['duration'] as num).toDouble() : 0.0;
    final chapters = (media['chapters'] as List<dynamic>?) ?? [];

    // Start playback
    await widget.player.playItem(
      api: api, itemId: itemId, title: title, author: author,
      coverUrl: coverUrl, totalDuration: duration, chapters: chapters,
    );

    if (mounted) setState(() => _isLoading = false);
    // Navigate to absorbing screen
    if (context.mounted) AppShell.goToAbsorbing(context);
  }
}
