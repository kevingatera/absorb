import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../widgets/absorb_title.dart';
import '../widgets/book_detail_sheet.dart';

// ─── Sort modes ──────────────────────────────────────────────
enum LibrarySort { recentlyAdded, alphabetical, duration, random }

// ─── Filter modes ────────────────────────────────────────────
enum LibraryFilter { none, inProgress, finished, notStarted, downloaded }

/// Show a bottom sheet with all books in a series, sorted by sequence.
/// Can be called from any screen.
void showSeriesBooksSheet(BuildContext context, {
  required String seriesName,
  String? seriesId,
  List<dynamic> books = const [],
  String? serverUrl,
  String? token,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollController) => _SeriesBooksSheet(
        seriesName: seriesName,
        seriesId: seriesId,
        books: books,
        serverUrl: serverUrl,
        token: token,
        scrollController: scrollController,
      ),
    ),
  );
}

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

  /// Whether the search bar has active text.
  bool get isSearchActive => _searchController.text.trim().isNotEmpty;

  /// Clear the search and return to the browse grid.
  void clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
    _focusNode.unfocus();
  }
  List<dynamic> _searchBookResults = [];
  List<dynamic> _searchSeriesResults = [];
  List<dynamic> _searchAuthorResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  bool get _isInSearchMode => _searchController.text.trim().isNotEmpty;

  // ── Browse state ──
  LibrarySort _sort = LibrarySort.recentlyAdded;
  bool _sortAsc = false; // false = desc (newest/longest first), true = asc
  LibraryFilter _filter = LibraryFilter.none;
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
        desc = _sortAsc ? 0 : 1;
        break;
      case LibrarySort.alphabetical:
        sort = 'media.metadata.title';
        desc = _sortAsc ? 0 : 1;
        break;
      case LibrarySort.duration:
        sort = 'media.duration';
        desc = _sortAsc ? 0 : 1;
        break;
      case LibrarySort.random:
        sort = 'addedAt';
        desc = 1;
        break;
    }

    // Server-side progress filter (ABS format: progress.<base64value>)
    String? filter;
    if (_filter == LibraryFilter.inProgress) {
      filter = 'progress.${base64Encode(utf8.encode('in-progress'))}';
    } else if (_filter == LibraryFilter.finished) {
      filter = 'progress.${base64Encode(utf8.encode('finished'))}';
    } else if (_filter == LibraryFilter.notStarted) {
      filter = 'progress.${base64Encode(utf8.encode('not-started'))}';
    }
    // Downloaded filter is client-side — handled after loading

    final useClientFilter = _filter == LibraryFilter.downloaded;
    final limit = (_sort == LibrarySort.random || useClientFilter) ? 1000 : _pageSize;

    final result = await api.getLibraryItems(
      lib.selectedLibraryId!,
      page: (_sort == LibrarySort.random || useClientFilter) ? 0 : _page,
      limit: limit,
      sort: sort,
      desc: desc,
      filter: filter,
    );

    if (result != null && mounted) {
      final results = (result['results'] as List<dynamic>?) ?? [];
      final total = (result['total'] as int?) ?? 0;
      setState(() {
        for (final r in results) {
          if (r is Map<String, dynamic>) {
            // Client-side downloaded filter
            if (useClientFilter) {
              final id = r['id'] as String? ?? '';
              if (!DownloadService().isDownloaded(id)) continue;
            }
            _items.add(r);
          }
        }
        if (_sort == LibrarySort.random) {
          _items.shuffle(Random(_randomSeed));
          _hasMore = false;
        } else if (useClientFilter) {
          _hasMore = false; // All loaded and filtered at once
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
    if (newSort == _sort) {
      // Tapping the same sort toggles direction (except Random)
      if (newSort == LibrarySort.random) return;
      setState(() {
        _sortAsc = !_sortAsc;
        _items.clear();
        _page = 0;
        _hasMore = true;
        _isLoadingPage = false;
      });
      _scrollController.jumpTo(0);
      _loadPage();
      return;
    }
    setState(() {
      _sort = newSort;
      // Smart defaults: A-Z and Length start ascending, others start descending
      _sortAsc = newSort == LibrarySort.alphabetical || newSort == LibrarySort.duration;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _isLoadingPage = false;
      if (newSort == LibrarySort.random) {
        _randomSeed = Random().nextInt(100000);
      }
    });
    _scrollController.jumpTo(0);
    _loadPage();
  }

  // ── Change filter and reload ──
  void _changeFilter(LibraryFilter newFilter) {
    // Tapping the active filter toggles it off
    final effective = newFilter == _filter ? LibraryFilter.none : newFilter;
    if (effective == _filter) return;
    setState(() {
      _filter = effective;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _isLoadingPage = false;
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
        _searchAuthorResults = [];
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
        _searchAuthorResults = (result['authors'] as List<dynamic>?) ?? [];
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
                hintText: 'Search books, series, and authors...',
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

            // ── Sort chips (hidden during search) ──
            if (!_isInSearchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _SortChip(
                              label: 'Recent',
                              icon: Icons.schedule_rounded,
                              selected: _sort == LibrarySort.recentlyAdded,
                              ascending: _sort == LibrarySort.recentlyAdded ? _sortAsc : null,
                              onTap: () => _changeSort(LibrarySort.recentlyAdded),
                            ),
                            const SizedBox(width: 8),
                            _SortChip(
                              label: 'A – Z',
                              icon: Icons.sort_by_alpha_rounded,
                              selected: _sort == LibrarySort.alphabetical,
                              ascending: _sort == LibrarySort.alphabetical ? _sortAsc : null,
                              onTap: () => _changeSort(LibrarySort.alphabetical),
                            ),
                            const SizedBox(width: 8),
                            _SortChip(
                              label: 'Length',
                              icon: Icons.timelapse_rounded,
                              selected: _sort == LibrarySort.duration,
                              ascending: _sort == LibrarySort.duration ? _sortAsc : null,
                              onTap: () => _changeSort(LibrarySort.duration),
                            ),
                            const SizedBox(width: 8),
                            _SortChip(
                              label: 'Random',
                              icon: Icons.shuffle_rounded,
                              selected: _sort == LibrarySort.random,
                              onTap: () => _changeSort(LibrarySort.random),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_hasMore ? "${_items.length}+" : _items.length} books',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),

            // ── Filter chips (hidden during search) ──
            if (!_isInSearchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChip(
                        label: 'In Progress',
                        icon: Icons.play_circle_outline_rounded,
                        selected: _filter == LibraryFilter.inProgress,
                        onTap: () => _changeFilter(LibraryFilter.inProgress),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Finished',
                        icon: Icons.check_circle_outline_rounded,
                        selected: _filter == LibraryFilter.finished,
                        onTap: () => _changeFilter(LibraryFilter.finished),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Not Started',
                        icon: Icons.circle_outlined,
                        selected: _filter == LibraryFilter.notStarted,
                        onTap: () => _changeFilter(LibraryFilter.notStarted),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Downloaded',
                        icon: Icons.download_done_rounded,
                        selected: _filter == LibraryFilter.downloaded,
                        onTap: () => _changeFilter(LibraryFilter.downloaded),
                      ),
                    ],
                  ),
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
      final filterMsg = switch (_filter) {
        LibraryFilter.inProgress => 'No books in progress',
        LibraryFilter.finished => 'No finished books',
        LibraryFilter.notStarted => 'All books have been started',
        LibraryFilter.downloaded => 'No downloaded books',
        LibraryFilter.none => 'No books found',
      };
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_books_outlined,
                size: 56, color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(filterMsg,
                style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
            if (_filter != LibraryFilter.none) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _changeFilter(LibraryFilter.none),
                child: Text('Clear filter',
                    style: tt.bodySmall?.copyWith(color: cs.primary)),
              ),
            ],
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
    if (_searchBookResults.isEmpty && _searchSeriesResults.isEmpty && _searchAuthorResults.isEmpty) {
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
        // ─── BOOKS (only title matches) ───
        if (_searchBookResults.isNotEmpty) ...[
          ...() {
            final query = _searchController.text.trim().toLowerCase();
            final titleMatches = _searchBookResults.where((result) {
              final item = result['libraryItem'] as Map<String, dynamic>? ?? {};
              final media = item['media'] as Map<String, dynamic>? ?? {};
              final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
              final title = (metadata['title'] as String? ?? '').toLowerCase();
              return title.contains(query);
            }).toList();
            if (titleMatches.isEmpty) return <Widget>[];
            return <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Text('Books',
                    style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600, color: cs.primary)),
              ),
              ...titleMatches.map((result) {
                final item =
                    result['libraryItem'] as Map<String, dynamic>? ?? {};
                return _BookResultTile(
                  item: item,
                  serverUrl: auth.serverUrl,
                  token: auth.token,
                );
              }),
            ];
          }(),
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

        // ─── AUTHORS ───
        if (_searchAuthorResults.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
                4, (_searchBookResults.isNotEmpty || _searchSeriesResults.isNotEmpty) ? 20 : 8, 4, 8),
            child: Text('Authors',
                style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: cs.primary)),
          ),
          ..._searchAuthorResults.map((result) {
            final authorData =
                result['author'] as Map<String, dynamic>? ?? result as Map<String, dynamic>;
            return _AuthorResultTile(
              author: authorData,
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
  final bool? ascending; // null = no arrow (e.g. Random), true = ↑, false = ↓
  final VoidCallback onTap;

  const _SortChip({
    required this.label,
    required this.icon,
    required this.selected,
    this.ascending,
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
              ? cs.primary.withValues(alpha: 0.15)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.4)
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
            if (selected && ascending != null) ...[
              const SizedBox(width: 2),
              Icon(
                ascending! ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 12,
                color: cs.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? cs.tertiary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? cs.tertiary.withValues(alpha: 0.4)
                : cs.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13,
                color: selected ? cs.tertiary : cs.onSurfaceVariant.withValues(alpha: 0.6)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? cs.tertiary : cs.onSurfaceVariant.withValues(alpha: 0.6),
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
                              Colors.black.withValues(alpha: 0.85),
                              Colors.black.withValues(alpha: 0.0),
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
            size: 24, color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Author result tile
// ═══════════════════════════════════════════════════════════════
class _AuthorResultTile extends StatelessWidget {
  final Map<String, dynamic> author;
  final String? serverUrl;
  final String? token;

  const _AuthorResultTile({
    required this.author,
    required this.serverUrl,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final name = author['name'] as String? ?? 'Unknown';
    final authorId = author['id'] as String? ?? '';
    final numBooks = author['numBooks'] as int?;

    String? imageUrl;
    if (authorId.isNotEmpty && serverUrl != null && token != null) {
      final cleanUrl = serverUrl!.endsWith('/')
          ? serverUrl!.substring(0, serverUrl!.length - 1)
          : serverUrl!;
      imageUrl =
          '$cleanUrl/api/authors/$authorId/image?width=200&token=$token';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showAuthorBooks(context, authorId, name),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Author avatar
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.secondaryContainer,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: imageUrl != null
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _ph(cs),
                          errorWidget: (_, __, ___) => _ph(cs),
                        )
                      : _ph(cs),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface)),
                      if (numBooks != null)
                        Text(
                            '$numBooks book${numBooks != 1 ? 's' : ''}',
                            style: tt.bodySmall
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
      ),
    );
  }

  Widget _ph(ColorScheme cs) {
    return Center(
      child: Icon(Icons.person_rounded,
          size: 22, color: cs.onSecondaryContainer.withValues(alpha: 0.5)),
    );
  }

  void _showAuthorBooks(
      BuildContext context, String authorId, String authorName) {
    FocusManager.instance.primaryFocus?.unfocus();
    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;
    if (api == null || lib.selectedLibraryId == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => _AuthorBooksSheet(
          libraryId: lib.selectedLibraryId!,
          authorId: authorId,
          authorName: authorName,
          serverUrl: auth.serverUrl,
          token: auth.token,
          scrollController: scrollController,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Author books bottom sheet
// ═══════════════════════════════════════════════════════════════
class _AuthorBooksSheet extends StatefulWidget {
  final String libraryId;
  final String authorId;
  final String authorName;
  final String? serverUrl;
  final String? token;
  final ScrollController scrollController;

  const _AuthorBooksSheet({
    required this.libraryId,
    required this.authorId,
    required this.authorName,
    required this.serverUrl,
    required this.token,
    required this.scrollController,
  });

  @override
  State<_AuthorBooksSheet> createState() => _AuthorBooksSheetState();
}

class _AuthorBooksSheetState extends State<_AuthorBooksSheet> {
  List<Map<String, dynamic>> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      // Use audiobookshelf filter: authors.<base64(authorId)>
      final filterValue = base64Encode(utf8.encode(widget.authorId));
      final cleanUrl = (auth.serverUrl ?? '').endsWith('/')
          ? auth.serverUrl!.substring(0, auth.serverUrl!.length - 1)
          : auth.serverUrl!;
      final url =
          '$cleanUrl/api/libraries/${widget.libraryId}/items'
          '?filter=authors.$filterValue&sort=media.metadata.title&limit=200&collapseseries=0';

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${auth.token}',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = (data['results'] as List<dynamic>?) ?? [];
        setState(() {
          _books = results.whereType<Map<String, dynamic>>().toList();
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Row(
            children: [
              Icon(Icons.person_rounded, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.authorName,
                    style: tt.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(
              child: Center(child: CircularProgressIndicator()))
        else if (_books.isEmpty)
          Expanded(
            child: Center(
              child: Text('No books found',
                  style: tt.bodyLarge
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
              itemCount: _books.length,
              itemBuilder: (context, index) {
                return _BookResultTile(
                  item: _books[index],
                  serverUrl: widget.serverUrl,
                  token: widget.token,
                );
              },
            ),
          ),
      ],
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
            FocusManager.instance.primaryFocus?.unfocus();
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
          size: 20, color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showSeriesBooks(context, seriesName),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Icon(Icons.auto_stories_rounded,
                        size: 22, color: cs.onSecondaryContainer.withValues(alpha: 0.7)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(seriesName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface)),
                      Text(
                          '${books.length} book${books.length != 1 ? 's' : ''}',
                          style: tt.bodySmall
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
      ),
    );
  }

  void _showSeriesBooks(BuildContext context, String seriesName) {
    showSeriesBooksSheet(
      context,
      seriesName: seriesName,
      seriesId: series['id'] as String?,
      books: books,
      serverUrl: serverUrl,
      token: token,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Series books bottom sheet
// ═══════════════════════════════════════════════════════════════
class _SeriesBooksSheet extends StatefulWidget {
  final String seriesName;
  final String? seriesId;
  final List<dynamic> books;
  final String? serverUrl;
  final String? token;
  final ScrollController scrollController;

  const _SeriesBooksSheet({
    required this.seriesName,
    this.seriesId,
    required this.books,
    required this.serverUrl,
    required this.token,
    required this.scrollController,
  });

  @override
  State<_SeriesBooksSheet> createState() => _SeriesBooksSheetState();
}

class _SeriesBooksSheetState extends State<_SeriesBooksSheet> {
  List<Map<String, dynamic>> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Use passed books as initial data
    _books = _unwrapBooks(widget.books);
    _sortBooks();
    if (_books.isNotEmpty) _isLoading = false;
    // Fetch full data from API for proper sequence info
    _fetchFromApi();
  }

  /// Unwrap ABS format: { libraryItem: {...}, sequence: "1" }
  /// Move sequence to top level of the item for consistent access.
  List<Map<String, dynamic>> _unwrapBooks(List<dynamic> raw) {
    final result = <Map<String, dynamic>>[];
    for (final b in raw) {
      if (b is! Map<String, dynamic>) continue;
      if (b.containsKey('libraryItem') && b['libraryItem'] is Map<String, dynamic>) {
        final item = Map<String, dynamic>.from(b['libraryItem'] as Map<String, dynamic>);
        if (b['sequence'] != null) item['sequence'] = b['sequence'];
        result.add(item);
      } else {
        result.add(Map<String, dynamic>.from(b));
      }
    }
    return result;
  }

  void _sortBooks() {
    _books.sort((a, b) {
      final seqA = _getSequence(a);
      final seqB = _getSequence(b);
      if (seqA == null && seqB == null) return 0;
      if (seqA == null) return 1;
      if (seqB == null) return -1;
      return seqA.compareTo(seqB);
    });
  }

  double? _getSequence(Map<String, dynamic> book) {
    // Top-level sequence (from unwrapping)
    final seq = book['sequence'];
    if (seq != null) {
      final v = double.tryParse(seq.toString());
      if (v != null) return v;
    }
    // Nested in metadata.series
    final media = book['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final seriesRaw = metadata['series'];
    if (seriesRaw is List) {
      for (final s in seriesRaw) {
        if (s is Map<String, dynamic>) {
          final v = s['sequence'];
          if (v != null) {
            final d = double.tryParse(v.toString());
            if (d != null) return d;
          }
        }
      }
    } else if (seriesRaw is Map<String, dynamic>) {
      final v = seriesRaw['sequence'];
      if (v != null) {
        final d = double.tryParse(v.toString());
        if (d != null) return d;
      }
    }
    final fallback = metadata['seriesSequence'];
    if (fallback != null) return double.tryParse(fallback.toString());
    return null;
  }

  String? _getSequenceString(Map<String, dynamic> book) {
    final v = _getSequence(book);
    if (v == null) return null;
    // Show as int if whole number, otherwise decimal
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }

  Future<void> _fetchFromApi() async {
    final seriesId = widget.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final lib = context.read<LibraryProvider>();
    final data = await api.getSeries(seriesId, libraryId: lib.selectedLibraryId);
    if (data != null && mounted) {
      final rawBooks = data['books'] ?? data['libraryItems'] ?? [];
      if (rawBooks is List && rawBooks.isNotEmpty) {
        final fetched = _unwrapBooks(rawBooks);
        setState(() {
          _books = fetched;
          _sortBooks();
          _isLoading = false;
        });
        return;
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Row(
            children: [
              Icon(Icons.auto_stories_rounded, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.seriesName,
                    style: tt.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            '${_books.length} book${_books.length != 1 ? 's' : ''} in this series',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        if (_isLoading && _books.isEmpty)
          const Expanded(
              child: Center(child: CircularProgressIndicator()))
        else if (_books.isEmpty)
          Expanded(
            child: Center(
              child: Text('No books found',
                  style: tt.bodyLarge
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
              itemCount: _books.length,
              itemBuilder: (context, index) {
                final book = _books[index];
                final bookId = book['id'] as String? ?? '';
                final media = book['media'] as Map<String, dynamic>? ?? {};
                final metadata =
                    media['metadata'] as Map<String, dynamic>? ?? {};
                final bookTitle = metadata['title'] as String? ?? 'Unknown';
                final authorName = metadata['authorName'] as String? ?? '';
                final sequence = _getSequenceString(book);
                final duration = (media['duration'] is num)
                    ? (media['duration'] as num).toDouble()
                    : 0.0;

                final lib = context.watch<LibraryProvider>();
                final progress = lib.getProgress(bookId);
                final isFinished = lib.getProgressData(bookId)?['isFinished'] == true;
                final isDownloaded = DownloadService().isDownloaded(bookId);

                String? coverUrl;
                if (bookId.isNotEmpty &&
                    widget.serverUrl != null &&
                    widget.token != null) {
                  final cleanUrl = widget.serverUrl!.endsWith('/')
                      ? widget.serverUrl!
                          .substring(0, widget.serverUrl!.length - 1)
                      : widget.serverUrl!;
                  coverUrl =
                      '$cleanUrl/api/items/$bookId/cover?width=400&token=${widget.token}';
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    elevation: 0,
                    color: cs.surfaceContainerHigh,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        if (bookId.isNotEmpty) {
                          showBookDetailSheet(context, bookId);
                        }
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Row(
                        children: [
                          // Square cover with sequence badge + status badges
                          SizedBox(
                            width: 80,
                            height: 80,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: coverUrl != null
                                      ? CachedNetworkImage(
                                          imageUrl: coverUrl,
                                          fit: BoxFit.cover,
                                          placeholder: (_, __) =>
                                              _placeholder(cs),
                                          errorWidget: (_, __, ___) =>
                                              _placeholder(cs),
                                        )
                                      : _placeholder(cs),
                                ),
                                if (sequence != null && sequence.isNotEmpty)
                                  Positioned(
                                    top: 4,
                                    left: 4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: cs.primary,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                        boxShadow: [
                                          BoxShadow(
                                              color: Colors.black
                                                  .withValues(alpha: 0.3),
                                              blurRadius: 4)
                                        ],
                                      ),
                                      child: Text('#$sequence',
                                          style: TextStyle(
                                              color: cs.onPrimary,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                // Downloaded badge (top-right)
                                if (isDownloaded)
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Icon(Icons.download_done_rounded,
                                          size: 12, color: cs.primary),
                                    ),
                                  ),
                                // Progress bar at bottom
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
                                // Finished overlay
                                if (isFinished)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: [
                                            Colors.black.withValues(alpha: 0.85),
                                            Colors.black.withValues(alpha: 0.0),
                                          ],
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.check_circle_rounded,
                                              size: 10, color: Colors.greenAccent[400]),
                                          const SizedBox(width: 3),
                                          Text('Done',
                                              style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.greenAccent[400])),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Info
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  if (sequence != null &&
                                      sequence.isNotEmpty)
                                    Text('Book $sequence',
                                        style: tt.labelSmall?.copyWith(
                                            color: cs.primary,
                                            fontWeight: FontWeight.w600)),
                                  Text(bookTitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: cs.onSurface)),
                                  if (authorName.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(authorName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: tt.bodySmall?.copyWith(
                                            color: cs.onSurfaceVariant)),
                                  ],
                                  if (duration > 0) ...[
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Text(_formatDuration(duration),
                                            style: tt.labelSmall?.copyWith(
                                                color: cs.onSurfaceVariant)),
                                        if (progress > 0 && !isFinished) ...[
                                          const SizedBox(width: 8),
                                          Text('${(progress * 100).round()}%',
                                              style: tt.labelSmall?.copyWith(
                                                  color: cs.primary,
                                                  fontWeight: FontWeight.w600)),
                                        ],
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Icon(Icons.chevron_right_rounded,
                                color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.headphones_rounded,
            size: 24, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
      ),
    );
  }

  String _formatDuration(double seconds) {
    final h = (seconds / 3600).floor();
    final m = ((seconds % 3600) / 60).floor();
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}
