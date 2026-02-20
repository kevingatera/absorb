import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/download_service.dart';
import '../widgets/absorb_title.dart';
import 'absorbing_screen.dart';
import 'series_detail_screen.dart';

// ─── Sort modes ──────────────────────────────────────────────
enum LibrarySort { recentlyAdded, alphabetical, random }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends State<LibraryScreen> {
  // ── Search state ──
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  List<dynamic> _searchBookResults = [];
  List<dynamic> _searchSeriesResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  bool get _isInSearchMode => _searchController.text.trim().isNotEmpty;

  // ── Browse state ──
  LibrarySort _sort = LibrarySort.recentlyAdded;
  final List<Map<String, dynamic>> _items = [];
  bool _isLoadingPage = false;
  bool _hasMore = true;
  int _page = 0;
  int? _randomSeed;
  static const _pageSize = 20;

  final _scrollController = ScrollController();

  /// Called externally (e.g. from AppShell) to focus the search field.
  void requestSearchFocus() {
    _focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Load initial page once the library is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryInitialLoad();
    });
  }

  void _tryInitialLoad() {
    final lib = context.read<LibraryProvider>();
    if (lib.selectedLibraryId != null) {
      _loadPage();
    } else {
      // Library not ready yet — listen for changes
      lib.addListener(_onLibraryChanged);
    }
  }

  void _onLibraryChanged() {
    final lib = context.read<LibraryProvider>();
    if (lib.selectedLibraryId != null && _items.isEmpty && !_isLoadingPage) {
      lib.removeListener(_onLibraryChanged);
      _loadPage();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    try {
      context.read<LibraryProvider>().removeListener(_onLibraryChanged);
    } catch (_) {}
    super.dispose();
  }

  // ── Scroll-based pagination ──
  void _onScroll() {
    if (_isInSearchMode) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadPage();
    }
  }

  // ── Load a page of items ──
  Future<void> _loadPage() async {
    if (_isLoadingPage || !_hasMore) return;
    setState(() => _isLoadingPage = true);

    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;
    if (api == null || lib.selectedLibraryId == null) {
      setState(() => _isLoadingPage = false);
      return;
    }

    String sort;
    int desc;
    switch (_sort) {
      case LibrarySort.recentlyAdded:
        sort = 'addedAt';
        desc = 1;
        break;
      case LibrarySort.alphabetical:
        sort = 'media.metadata.title';
        desc = 0;
        break;
      case LibrarySort.random:
        // Fetch a big batch and shuffle client-side
        sort = 'addedAt';
        desc = 1;
        break;
    }

    final limit = _sort == LibrarySort.random ? 1000 : _pageSize;

    final result = await api.getLibraryItems(
      lib.selectedLibraryId!,
      page: _sort == LibrarySort.random ? 0 : _page,
      limit: limit,
      sort: sort,
      desc: desc,
    );

    if (result != null && mounted) {
      final results = (result['results'] as List<dynamic>?) ?? [];
      final total = (result['total'] as int?) ?? 0;
      setState(() {
        for (final r in results) {
          if (r is Map<String, dynamic>) _items.add(r);
        }
        if (_sort == LibrarySort.random) {
          _items.shuffle(Random(_randomSeed));
          _hasMore = false; // All loaded at once
        } else {
          _page++;
          _hasMore = _items.length < total;
        }
        _isLoadingPage = false;
      });
    } else if (mounted) {
      setState(() => _isLoadingPage = false);
    }
  }

  // ── Change sort and reload ──
  void _changeSort(LibrarySort newSort) {
    if (newSort == _sort) return;
    setState(() {
      _sort = newSort;
      _items.clear();
      _page = 0;
      _hasMore = true;
      if (newSort == LibrarySort.random) {
        _randomSeed = Random().nextInt(100000);
      }
    });
    _scrollController.jumpTo(0);
    _loadPage();
  }

  // ── Search ──
  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchBookResults = [];
        _searchSeriesResults = [];
        _hasSearched = false;
        _isSearching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(query.trim());
    });
  }

  Future<void> _performSearch(String query) async {
    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;
    if (api == null || lib.selectedLibraryId == null) return;

    setState(() => _isSearching = true);

    final result = await api.searchLibrary(lib.selectedLibraryId!, query);
    if (result != null && mounted) {
      setState(() {
        _searchBookResults = (result['book'] as List<dynamic>?) ?? [];
        _searchSeriesResults = (result['series'] as List<dynamic>?) ?? [];
        _isSearching = false;
        _hasSearched = true;
      });
    } else if (mounted) {
      setState(() {
        _isSearching = false;
        _hasSearched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 4),
              child: AbsorbTitle(),
            ),
            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SearchBar(
                controller: _searchController,
                focusNode: _focusNode,
                hintText: 'Search books and series...',
                leading: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.search_rounded),
                ),
                trailing: [
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                        _focusNode.unfocus();
                      },
                    ),
                ],
                onChanged: _onSearchChanged,
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),

            // ── Filter chips (hidden during search) ──
            if (!_isInSearchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    _SortChip(
                      label: 'Recent',
                      icon: Icons.schedule_rounded,
                      selected: _sort == LibrarySort.recentlyAdded,
                      onTap: () => _changeSort(LibrarySort.recentlyAdded),
                    ),
                    const SizedBox(width: 8),
                    _SortChip(
                      label: 'A – Z',
                      icon: Icons.sort_by_alpha_rounded,
                      selected: _sort == LibrarySort.alphabetical,
                      onTap: () => _changeSort(LibrarySort.alphabetical),
                    ),
                    const SizedBox(width: 8),
                    _SortChip(
                      label: 'Random',
                      icon: Icons.shuffle_rounded,
                      selected: _sort == LibrarySort.random,
                      onTap: () => _changeSort(LibrarySort.random),
                    ),
                    const Spacer(),
                    Text(
                      '${_hasMore ? "${_items.length}+" : _items.length} books',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),

            // ── Content ──
            Expanded(
              child: _isInSearchMode
                  ? _buildSearchResults(cs, tt)
                  : _buildGrid(cs, tt),
            ),
          ],
        ),
      ),
    );
  }

  // ── Pull-to-refresh ──
  Future<void> _refreshAll() async {
    final lib = context.read<LibraryProvider>();
    await lib.refresh();
    setState(() {
      _items.clear();
      _page = 0;
      _hasMore = true;
      if (_sort == LibrarySort.random) {
        _randomSeed = Random(_randomSeed).nextInt(100000);
      }
    });
    await _loadPage();
  }

  // ═══════════════════════════════════════════════════════════════
  // BROWSE GRID
  // ═══════════════════════════════════════════════════════════════
  Widget _buildGrid(ColorScheme cs, TextTheme tt) {
    if (_items.isEmpty && _isLoadingPage) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && !_isLoadingPage) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_books_outlined,
                size: 56, color: cs.onSurfaceVariant.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text('No books found',
                style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: GridView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.68,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          // Loading indicator at the end
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return _GridBookTile(item: _items[index]);
      },
    ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // SEARCH RESULTS
  // ═══════════════════════════════════════════════════════════════
  Widget _buildSearchResults(ColorScheme cs, TextTheme tt) {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasSearched) {
      return const SizedBox.shrink();
    }
    if (_searchBookResults.isEmpty && _searchSeriesResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No results found',
                style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    final auth = context.read<AuthProvider>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      children: [
        // ─── BOOKS ───
        if (_searchBookResults.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text('Books',
                style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: cs.primary)),
          ),
          ..._searchBookResults.map((result) {
            final item =
                result['libraryItem'] as Map<String, dynamic>? ?? {};
            return _BookResultTile(
              item: item,
              serverUrl: auth.serverUrl,
              token: auth.token,
            );
          }),
        ],

        // ─── SERIES ───
        if (_searchSeriesResults.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
                4, _searchBookResults.isNotEmpty ? 20 : 8, 4, 8),
            child: Text('Series',
                style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: cs.primary)),
          ),
          ..._searchSeriesResults.map((result) {
            final seriesData =
                result['series'] as Map<String, dynamic>? ?? {};
            final books = result['books'] as List<dynamic>? ?? [];
            return _SeriesResultCard(
              series: seriesData,
              books: books,
              serverUrl: auth.serverUrl,
              token: auth.token,
            );
          }),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Sort chip
// ═══════════════════════════════════════════════════════════════
class _SortChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SortChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withOpacity(0.15)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? cs.primary.withOpacity(0.4)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: selected ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Grid book tile (cover + title + author)
// ═══════════════════════════════════════════════════════════════
class _GridBookTile extends StatefulWidget {
  final Map<String, dynamic> item;

  const _GridBookTile({required this.item});

  @override
  State<_GridBookTile> createState() => _GridBookTileState();
}

class _GridBookTileState extends State<_GridBookTile> {
  final _dl = DownloadService();

  @override
  void initState() {
    super.initState();
    _dl.addListener(_rebuild);
  }

  @override
  void dispose() {
    _dl.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final lib = context.watch<LibraryProvider>();

    final itemId = widget.item['id'] as String? ?? '';
    final media = widget.item['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = metadata['title'] as String? ?? 'Unknown';
    final author = metadata['authorName'] as String? ?? '';
    final coverUrl = lib.getCoverUrl(itemId);
    final progress = lib.getProgress(itemId);
    final isDownloaded = _dl.isDownloaded(itemId);
    final isFinished = lib.getProgressData(itemId)?['isFinished'] == true;

    return GestureDetector(
      onTap: () {
        if (itemId.isNotEmpty) showBookDetailSheet(context, itemId);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cover — 1:1 square
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Cover image
                  coverUrl != null
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _placeholder(cs),
                          errorWidget: (_, __, ___) => _placeholder(cs),
                        )
                      : _placeholder(cs),

                  // Progress bar at bottom of cover
                  if (progress > 0 && !isFinished)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: Colors.black38,
                        valueColor: AlwaysStoppedAnimation(cs.primary),
                      ),
                    ),

                  // ── Banners ──
                  if (isFinished || isDownloaded)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.85),
                              Colors.black.withOpacity(0.0),
                            ],
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isFinished) ...[
                              Icon(Icons.check_circle_rounded,
                                  size: 10, color: Colors.greenAccent[400]),
                              const SizedBox(width: 3),
                              Text('Done',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.greenAccent[400])),
                            ],
                            if (isFinished && isDownloaded)
                              const SizedBox(width: 6),
                            if (isDownloaded) ...[
                              Icon(Icons.download_done_rounded,
                                  size: 10, color: cs.primary),
                              const SizedBox(width: 3),
                              Text('Saved',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: cs.primary)),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          // Title
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
              fontSize: 11,
            ),
          ),
          // Author
          if (author.isNotEmpty)
            Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.headphones_rounded,
            size: 24, color: cs.onSurfaceVariant.withOpacity(0.3)),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Search result tiles (carried over from old search_screen)
// ═══════════════════════════════════════════════════════════════
class _BookResultTile extends StatelessWidget {
  final Map<String, dynamic> item;
  final String? serverUrl;
  final String? token;

  const _BookResultTile({
    required this.item,
    required this.serverUrl,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final itemId = item['id'] as String?;
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = metadata['title'] as String? ?? 'Unknown';
    final authorName = metadata['authorName'] as String? ?? '';

    String? coverUrl;
    if (itemId != null && serverUrl != null && token != null) {
      final cleanUrl = serverUrl!.endsWith('/')
          ? serverUrl!.substring(0, serverUrl!.length - 1)
          : serverUrl!;
      coverUrl = '$cleanUrl/api/items/$itemId/cover?width=200&token=$token';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (itemId != null) showBookDetailSheet(context, itemId);
          },
          borderRadius: BorderRadius.circular(12),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: coverUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _ph(cs),
                        errorWidget: (_, __, ___) => _ph(cs),
                      )
                    : _ph(cs),
              ),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface)),
                      if (authorName.isNotEmpty)
                        Text(authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.chevron_right_rounded,
                    color: cs.onSurfaceVariant, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ph(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Icon(Icons.headphones_rounded,
          size: 20, color: cs.onSurfaceVariant.withOpacity(0.3)),
    );
  }
}

class _SeriesResultCard extends StatelessWidget {
  final Map<String, dynamic> series;
  final List<dynamic> books;
  final String? serverUrl;
  final String? token;

  const _SeriesResultCard({
    required this.series,
    required this.books,
    required this.serverUrl,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final seriesName = series['name'] as String? ?? 'Unknown Series';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Series header
            InkWell(
              onTap: () {
                final seriesWithBooks = {...series, 'books': books};
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        SeriesDetailScreen(series: seriesWithBooks),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: Row(
                  children: [
                    Icon(Icons.library_books_rounded,
                        size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(seriesName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface)),
                          Text(
                              '${books.length} book${books.length != 1 ? 's' : ''}',
                              style: tt.labelSmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        color: cs.onSurfaceVariant, size: 20),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            // Books in series
            ...books.asMap().entries.map((entry) {
              final raw = entry.value as Map<String, dynamic>? ?? {};
              final book = raw.containsKey('libraryItem')
                  ? (raw['libraryItem'] as Map<String, dynamic>? ?? raw)
                  : raw;
              final bookId = book['id'] as String?;
              final media = book['media'] as Map<String, dynamic>? ?? {};
              final metadata =
                  media['metadata'] as Map<String, dynamic>? ?? {};
              final bookTitle = metadata['title'] as String? ?? 'Unknown';
              final sequence = metadata['seriesSequence'] as String?;

              String? coverUrl;
              if (bookId != null && serverUrl != null && token != null) {
                final cleanUrl = serverUrl!.endsWith('/')
                    ? serverUrl!.substring(0, serverUrl!.length - 1)
                    : serverUrl!;
                coverUrl =
                    '$cleanUrl/api/items/$bookId/cover?width=200&token=$token';
              }

              return InkWell(
                onTap: () {
                  if (bookId != null) showBookDetailSheet(context, bookId);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: coverUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: coverUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => Container(
                                      color: cs.surfaceContainerHighest),
                                  errorWidget: (_, __, ___) => Container(
                                      color: cs.surfaceContainerHighest),
                                )
                              : Container(
                                  color: cs.surfaceContainerHighest),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (sequence != null && sequence.isNotEmpty)
                              Text('Book $sequence',
                                  style: tt.labelSmall?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w500)),
                            Text(bookTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: cs.onSurface)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          color: cs.onSurfaceVariant, size: 18),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}
