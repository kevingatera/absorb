import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../widgets/absorb_title.dart';
import 'series_detail_screen.dart';

enum SeriesSort { recent, alphabetical }

class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key});

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  SeriesSort _sort = SeriesSort.recent;
  bool _hasTriedLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasTriedLoad) {
      final lib = context.read<LibraryProvider>();
      if (lib.selectedLibraryId != null && lib.series.isEmpty) {
        _hasTriedLoad = true;
        _loadSeries();
      }
    }
  }

  void _loadSeries() {
    final lib = context.read<LibraryProvider>();
    if (lib.selectedLibraryId == null) return;
    lib.loadSeries(
      sort: _sort == SeriesSort.recent ? 'addedAt' : 'name',
      desc: _sort == SeriesSort.recent ? 1 : 0,
    );
  }

  void _toggleSort() {
    setState(() {
      _sort = _sort == SeriesSort.recent
          ? SeriesSort.alphabetical
          : SeriesSort.recent;
    });
    _loadSeries();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final lib = context.watch<LibraryProvider>();
    final auth = context.read<AuthProvider>();

    if (!_hasTriedLoad && lib.selectedLibraryId != null) {
      _hasTriedLoad = true;
      Future.microtask(() => _loadSeries());
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => _loadSeries(),
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AbsorbTitle(),
                  const SizedBox(height: 8),
                  Text(
                    'Series',
                    style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    avatar: Icon(
                      _sort == SeriesSort.recent
                          ? Icons.schedule_rounded
                          : Icons.sort_by_alpha_rounded,
                      size: 18,
                    ),
                    label: Text(_sort == SeriesSort.recent ? 'Recent' : 'A–Z'),
                    selected: false,
                    onSelected: (_) => _toggleSort(),
                    showCheckmark: false,
                  ),
                ),
              ],
            ),
            if (lib.isLoadingSeries && lib.series.isEmpty)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!lib.isLoadingSeries && lib.series.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.library_books_outlined,
                          size: 48, color: cs.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text('No series found',
                          style: tt.bodyLarge
                              ?.copyWith(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed: _loadSeries,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            if (lib.series.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.65,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final series = lib.series[index] as Map<String, dynamic>;
                      return _SeriesGridCard(
                        series: series,
                        serverUrl: auth.serverUrl,
                        token: auth.token,
                      );
                    },
                    childCount: lib.series.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SeriesGridCard extends StatelessWidget {
  final Map<String, dynamic> series;
  final String? serverUrl;
  final String? token;

  const _SeriesGridCard({
    required this.series,
    required this.serverUrl,
    required this.token,
  });

  String _coverUrl(String bookId) {
    final cleanUrl = serverUrl!.endsWith('/')
        ? serverUrl!.substring(0, serverUrl!.length - 1)
        : serverUrl!;
    return '$cleanUrl/api/items/$bookId/cover?width=400&token=$token';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final name = series['name'] as String? ?? 'Unknown Series';
    final books = series['books'] as List<dynamic>? ?? [];
    final bookCount = books.length;

    // Collect cover URLs for up to 5 books
    final List<String> coverUrls = [];
    if (serverUrl != null && token != null) {
      for (int i = 0; i < books.length && i < 5; i++) {
        final book = books[i] as Map<String, dynamic>? ?? {};
        final bookId = book['id'] as String?;
        if (bookId != null) coverUrls.add(_coverUrl(bookId));
      }
    }

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SeriesDetailScreen(series: series),
            ),
          );
        },
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stacked covers area
            AspectRatio(
              aspectRatio: 1,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _StackedCovers(
                  coverUrls: coverUrls,
                  cs: cs,
                ),
              ),
            ),
            // Info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$bookCount book${bookCount != 1 ? 's' : ''}',
                    style: tt.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
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

/// Stacked book covers — shows up to 5 covers offset like a tight fan.
class _StackedCovers extends StatelessWidget {
  final List<String> coverUrls;
  final ColorScheme cs;

  const _StackedCovers({required this.coverUrls, required this.cs});

  @override
  Widget build(BuildContext context) {
    if (coverUrls.isEmpty) {
      return _placeholder();
    }
    if (coverUrls.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: coverUrls.first,
          fit: BoxFit.cover,
          placeholder: (_, __) => _placeholder(),
          errorWidget: (_, __, ___) => _placeholder(),
        ),
      );
    }

    // Stack multiple covers with tight horizontal offset
    final count = coverUrls.length;
    // Each subsequent cover shifts right by this much
    const double shiftPerCover = 12.0;
    final totalShift = shiftPerCover * (count - 1);

    return LayoutBuilder(builder: (context, constraints) {
      final availW = constraints.maxWidth;
      final availH = constraints.maxHeight;
      // Cover width shrinks to fit the stack in the space
      final coverW = availW - totalShift;
      final coverH = availH;

      return Stack(
        children: List.generate(count, (i) {
          // Render back to front: index 0 is the back
          final reverseI = count - 1 - i;
          final left = reverseI * shiftPerCover;

          return Positioned(
            left: left,
            top: 0,
            width: coverW,
            height: coverH,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 4,
                    offset: const Offset(2, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: coverUrls[reverseI],
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: cs.surfaceContainerHighest,
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: cs.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
          );
        }),
      );
    });
  }

  Widget _placeholder() {
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Icon(
          Icons.library_books_rounded,
          size: 36,
          color: cs.onSurfaceVariant.withOpacity(0.35),
        ),
      ),
    );
  }
}
