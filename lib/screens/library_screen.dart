import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/download_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/book_detail_sheet.dart';

// ─── Sort modes ──────────────────────────────────────────────
enum LibrarySort { recentlyAdded, alphabetical, authorName, publishedYear, duration, random }

// ─── Filter modes ────────────────────────────────────────────
enum LibraryFilter { none, inProgress, finished, notStarted, downloaded, hasEbook, genre }

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
  String? _genreFilter;
  List<String> _availableGenres = [];
  bool _hideEbookOnly = false;
  final List<Map<String, dynamic>> _items = [];
  bool _isLoadingPage = false;
  bool _hasMore = true;
  int _page = 0;
  int _totalItems = 0;
  int? _randomSeed;
  int _loadGeneration = 0; // prevents stale async loads from corrupting state
  static const _pageSize = 20;

  final _scrollController = ScrollController();

  /// Called externally (e.g. from AppShell) to focus the search field.
  void requestSearchFocus() {
    _focusNode.requestFocus();
  }

  String? _lastLibraryId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Load initial page once the library is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryInitialLoad();
      final lib = context.read<LibraryProvider>();
      _lastLibraryId = lib.selectedLibraryId;
      lib.addListener(_onLibraryProviderChanged);
    });
  }

  void _onLibraryProviderChanged() {
    final lib = context.read<LibraryProvider>();
    if (lib.selectedLibraryId != _lastLibraryId && lib.selectedLibraryId != null) {
      _lastLibraryId = lib.selectedLibraryId;
      _loadGeneration++;
      setState(() {
        _items.clear();
        _page = 0;
        _hasMore = true;
        _isLoadingPage = false;
        _availableGenres = [];
        if (_filter == LibraryFilter.genre) {
          _filter = LibraryFilter.none;
          _genreFilter = null;
        }
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      _loadPage();
      _loadGenres();
    }
  }

  void _tryInitialLoad() {
    final lib = context.read<LibraryProvider>();
    PlayerSettings.getHideEbookOnly().then((v) {
      if (mounted) setState(() => _hideEbookOnly = v);
    });
    PlayerSettings.settingsChanged.addListener(_onSettingsChanged);
    if (lib.selectedLibraryId != null) {
      _loadPage();
      _loadGenres();
    } else {
      lib.addListener(_onLibraryChanged);
    }
  }

  void _onSettingsChanged() {
    PlayerSettings.getHideEbookOnly().then((v) {
      if (mounted && v != _hideEbookOnly) {
        _loadGeneration++;
        setState(() {
          _hideEbookOnly = v;
          _items.clear();
          _page = 0;
          _hasMore = true;
          _isLoadingPage = false;
        });
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        _loadPage();
      }
    });
  }

  void _onLibraryChanged() {
    final lib = context.read<LibraryProvider>();
    if (lib.selectedLibraryId != null && _items.isEmpty && !_isLoadingPage) {
      lib.removeListener(_onLibraryChanged);
      _loadPage();
      _loadGenres();
    }
  }

  Future<void> _loadGenres() async {
    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;
    if (api == null || lib.selectedLibraryId == null) return;
    final filterData = await api.getLibraryFilterData(lib.selectedLibraryId!);
    if (filterData != null && mounted) {
      final genres = filterData['genres'] as List<dynamic>? ?? [];
      setState(() {
        _availableGenres = genres.map((g) => g is Map ? (g['name'] as String? ?? '') : g.toString()).where((g) => g.isNotEmpty).toList()..sort();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    PlayerSettings.settingsChanged.removeListener(_onSettingsChanged);
    try {
      final lib = context.read<LibraryProvider>();
      lib.removeListener(_onLibraryChanged);
      lib.removeListener(_onLibraryProviderChanged);
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
    final gen = ++_loadGeneration;

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
        sort = 'addedAt'; desc = _sortAsc ? 0 : 1; break;
      case LibrarySort.alphabetical:
        sort = 'media.metadata.title'; desc = _sortAsc ? 0 : 1; break;
      case LibrarySort.authorName:
        sort = 'media.metadata.authorNameLF'; desc = _sortAsc ? 0 : 1; break;
      case LibrarySort.publishedYear:
        sort = 'media.metadata.publishedYear'; desc = _sortAsc ? 0 : 1; break;
      case LibrarySort.duration:
        sort = 'media.duration'; desc = _sortAsc ? 0 : 1; break;
      case LibrarySort.random:
        sort = 'addedAt'; desc = 1; break;
    }

    String? filter;
    if (_filter == LibraryFilter.inProgress) {
      filter = 'progress.${base64Encode(utf8.encode('in-progress'))}';
    } else if (_filter == LibraryFilter.finished) {
      filter = 'progress.${base64Encode(utf8.encode('finished'))}';
    } else if (_filter == LibraryFilter.notStarted) {
      filter = 'progress.${base64Encode(utf8.encode('not-started'))}';
    } else if (_filter == LibraryFilter.hasEbook) {
      filter = 'ebooks.${base64Encode(utf8.encode('ebook'))}';
    } else if (_filter == LibraryFilter.genre && _genreFilter != null) {
      filter = 'genres.${base64Encode(utf8.encode(_genreFilter!))}';
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

    if (result != null && mounted && gen == _loadGeneration) {
      final results = (result['results'] as List<dynamic>?) ?? [];
      final total = (result['total'] as int?) ?? 0;
      setState(() {
        _totalItems = total;
        for (final r in results) {
          if (r is Map<String, dynamic>) {
            // Client-side downloaded filter
            if (_filter == LibraryFilter.downloaded) {
              final id = r['id'] as String? ?? '';
              if (!DownloadService().isDownloaded(id)) continue;
            }
            if (_hideEbookOnly && PlayerSettings.isEbookOnly(r)) continue;
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
    } else if (mounted && gen == _loadGeneration) {
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
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      _loadPage();
      return;
    }
    setState(() {
      _sort = newSort;
      // Smart defaults: A-Z and Length start ascending, others start descending
      _sortAsc = newSort == LibrarySort.alphabetical || newSort == LibrarySort.authorName || newSort == LibrarySort.duration;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _isLoadingPage = false;
      if (newSort == LibrarySort.random) {
        _randomSeed = Random().nextInt(100000);
      }
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _loadPage();
  }

  // ── Change filter and reload ──
  void _changeFilter(LibraryFilter newFilter, {String? genre}) {
    final effective = (newFilter == _filter && genre == _genreFilter) ? LibraryFilter.none : newFilter;
    if (effective == _filter && genre == _genreFilter) return;
    _loadGeneration++;
    setState(() {
      _filter = effective;
      _genreFilter = effective == LibraryFilter.genre ? genre : null;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _isLoadingPage = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
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
        if (_hideEbookOnly) {
          _searchBookResults = _searchBookResults.where((r) {
            final item = r['libraryItem'] as Map<String, dynamic>? ?? r as Map<String, dynamic>;
            return !PlayerSettings.isEbookOnly(item);
          }).toList();
        }
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

  void _showLibraryPicker(BuildContext context, ColorScheme cs, TextTheme tt, List<dynamic> bookLibraries, LibraryProvider lib) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomPad = MediaQuery.of(ctx).viewPadding.bottom;
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: cs.onSurfaceVariant.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text('Select Library', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: bottomPad + 16),
                  itemCount: bookLibraries.length,
                  itemBuilder: (_, i) {
                    final library = bookLibraries[i] as Map<String, dynamic>;
                    final id = library['id'] as String;
                    final name = library['name'] as String? ?? 'Library';
                    final isSelected = id == lib.selectedLibraryId;
                    return ListTile(
                      leading: Icon(Icons.auto_stories_rounded,
                        color: isSelected ? cs.primary : cs.onSurfaceVariant),
                      title: Text(name),
                      trailing: isSelected
                          ? Icon(Icons.check_circle_rounded, color: cs.primary)
                          : null,
                      selected: isSelected,
                      onTap: () {
                        Navigator.pop(ctx);
                        if (!isSelected) lib.selectLibrary(id);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String get _sortLabel => switch (_sort) {
    LibrarySort.recentlyAdded => 'Date Added',
    LibrarySort.alphabetical => 'Title',
    LibrarySort.authorName => 'Author',
    LibrarySort.publishedYear => 'Year',
    LibrarySort.duration => 'Duration',
    LibrarySort.random => 'Random',
  };

  String get _filterLabel => switch (_filter) {
    LibraryFilter.inProgress => 'In Progress',
    LibraryFilter.finished => 'Finished',
    LibraryFilter.notStarted => 'Not Started',
    LibraryFilter.downloaded => 'Downloaded',
    LibraryFilter.hasEbook => 'eBooks',
    LibraryFilter.genre => _genreFilter ?? 'Genre',
    LibraryFilter.none => '',
  };

  void _showSortFilterSheet(BuildContext context, ColorScheme cs, TextTheme tt, {int initialTab = 0}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SortFilterSheet(
        currentSort: _sort,
        sortAsc: _sortAsc,
        currentFilter: _filter,
        genreFilter: _genreFilter,
        availableGenres: _availableGenres,
        initialTab: initialTab,
        cs: cs, tt: tt,
        onSortChanged: (sort) { Navigator.pop(ctx); _changeSort(sort); },
        onSortDirectionToggled: () {
          setState(() { _sortAsc = !_sortAsc; _items.clear(); _page = 0; _hasMore = true; _isLoadingPage = false; });
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
          _loadPage();
          Navigator.pop(ctx);
        },
        onFilterChanged: (filter, {String? genre}) { Navigator.pop(ctx); _changeFilter(filter, genre: genre); },
        onClearFilter: () { Navigator.pop(ctx); _changeFilter(LibraryFilter.none); },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final lib = context.watch<LibraryProvider>();
    final bookLibraries = lib.libraries.where((l) => (l['mediaType'] as String? ?? 'book') != 'podcast').toList();
    final hasMultipleLibraries = bookLibraries.length > 1;
    final libraryName = lib.selectedLibrary?['name'] as String? ?? 'Library';

    return Scaffold(
      floatingActionButton: _isInSearchMode ? null : ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: GestureDetector(
            onTap: () => _showSortFilterSheet(context, cs, tt),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_filter != LibraryFilter.none ? Icons.filter_list_rounded : Icons.tune_rounded, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Text(
                    _filter != LibraryFilter.none ? 'Sort & Filter ●' : 'Sort & Filter',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: SafeArea(
        child: Column(
          children: [
            AbsorbPageHeader(
              title: 'Library',
              actions: hasMultipleLibraries ? [
                GestureDetector(
                  onTap: () => _showLibraryPicker(context, cs, tt, bookLibraries, lib),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_stories_rounded, size: 14, color: cs.onSurfaceVariant),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 140),
                          child: Text(libraryName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis, maxLines: 1),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.unfold_more_rounded, size: 14, color: cs.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ] : null,
            ),
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
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
              ),
            ),

            if (!_isInSearchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => _showSortFilterSheet(context, cs, tt, initialTab: 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.sort_rounded, size: 14, color: cs.primary),
                            const SizedBox(width: 4),
                            Text(_sortLabel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
                            const SizedBox(width: 2),
                            if (_sort != LibrarySort.random)
                              Icon(_sortAsc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 12, color: cs.primary),
                          ],
                        ),
                      ),
                    ),
                    if (_filter != LibraryFilter.none) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: GestureDetector(
                          onTap: () => _showSortFilterSheet(context, cs, tt, initialTab: 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: cs.tertiary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.filter_list_rounded, size: 14, color: cs.tertiary),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(_filterLabel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.tertiary), overflow: TextOverflow.ellipsis, maxLines: 1),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () => _changeFilter(LibraryFilter.none),
                                  child: Icon(Icons.close_rounded, size: 14, color: cs.tertiary),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text('${_items.length}${_totalItems > 0 ? '/$_totalItems' : ''} books',
                      style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
                  ],
                ),
              ),

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
        LibraryFilter.hasEbook => 'No books with eBooks',
        LibraryFilter.genre => 'No books in "${_genreFilter ?? 'genre'}"',
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
// Sort & Filter bottom sheet with tabs
// ═══════════════════════════════════════════════════════════════
class _SortFilterSheet extends StatefulWidget {
  final LibrarySort currentSort;
  final bool sortAsc;
  final LibraryFilter currentFilter;
  final String? genreFilter;
  final List<String> availableGenres;
  final int initialTab;
  final ColorScheme cs;
  final TextTheme tt;
  final void Function(LibrarySort) onSortChanged;
  final VoidCallback onSortDirectionToggled;
  final void Function(LibraryFilter, {String? genre}) onFilterChanged;
  final VoidCallback onClearFilter;

  const _SortFilterSheet({
    required this.currentSort, required this.sortAsc,
    required this.currentFilter, this.genreFilter,
    required this.availableGenres, required this.initialTab,
    required this.cs, required this.tt,
    required this.onSortChanged, required this.onSortDirectionToggled,
    required this.onFilterChanged, required this.onClearFilter,
  });

  @override
  State<_SortFilterSheet> createState() => _SortFilterSheetState();
}

class _SortFilterSheetState extends State<_SortFilterSheet> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _genreExpanded = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
    if (widget.currentFilter == LibraryFilter.genre) _genreExpanded = true;
  }

  @override
  void dispose() { _tabCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: cs.onSurfaceVariant.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          TabBar(
            controller: _tabCtrl,
            labelColor: cs.primary, unselectedLabelColor: cs.onSurfaceVariant,
            indicatorColor: cs.primary, indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.sort_rounded, size: 18), const SizedBox(width: 6), const Text('Sort')])),
              Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.filter_list_rounded, size: 18), const SizedBox(width: 6),
                Text(widget.currentFilter != LibraryFilter.none ? 'Filter ●' : 'Filter')])),
            ],
          ),
          SizedBox(
            height: _genreExpanded ? 420 : 320,
            child: TabBarView(controller: _tabCtrl, children: [
              _buildSortTab(cs), _buildFilterTab(cs)]),
          ),
          SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 8),
        ],
      ),
    );
  }

  Widget _buildSortTab(ColorScheme cs) {
    final sorts = <(LibrarySort, String, IconData)>[
      (LibrarySort.recentlyAdded, 'Date Added', Icons.schedule_rounded),
      (LibrarySort.alphabetical, 'Title', Icons.sort_by_alpha_rounded),
      (LibrarySort.authorName, 'Author', Icons.person_rounded),
      (LibrarySort.publishedYear, 'Published Year', Icons.calendar_today_rounded),
      (LibrarySort.duration, 'Duration', Icons.timelapse_rounded),
      (LibrarySort.random, 'Random', Icons.shuffle_rounded),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: sorts.map((s) {
        final (sort, label, icon) = s;
        final selected = sort == widget.currentSort;
        return _SheetOption(
          icon: icon, label: label, selected: selected, selectedColor: cs.primary,
          trailing: selected && sort != LibrarySort.random
              ? GestureDetector(
                  onTap: widget.onSortDirectionToggled,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(widget.sortAsc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: cs.primary),
                      const SizedBox(width: 4),
                      Text(widget.sortAsc ? 'ASC' : 'DESC', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary)),
                    ]),
                  ),
                ) : null,
          onTap: () => widget.onSortChanged(sort),
        );
      }).toList(),
    );
  }

  Widget _buildFilterTab(ColorScheme cs) {
    final filters = <(LibraryFilter, String, IconData)>[
      (LibraryFilter.inProgress, 'In Progress', Icons.play_circle_outline_rounded),
      (LibraryFilter.finished, 'Finished', Icons.check_circle_outline_rounded),
      (LibraryFilter.notStarted, 'Not Started', Icons.circle_outlined),
      (LibraryFilter.downloaded, 'Downloaded', Icons.download_done_rounded),
      (LibraryFilter.hasEbook, 'eBooks', Icons.menu_book_rounded),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        if (widget.currentFilter != LibraryFilter.none)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: widget.onClearFilter,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: cs.errorContainer.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Icon(Icons.clear_rounded, size: 18, color: cs.error),
                  const SizedBox(width: 10),
                  Text('Clear Filter', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.error)),
                ]),
              ),
            ),
          ),
        ...filters.map((f) {
          final (filter, label, icon) = f;
          return _SheetOption(
            icon: icon, label: label,
            selected: filter == widget.currentFilter, selectedColor: cs.tertiary,
            onTap: () => widget.onFilterChanged(filter),
          );
        }),
        _SheetOption(
          icon: Icons.category_rounded,
          label: 'Genre',
          selected: widget.currentFilter == LibraryFilter.genre,
          selectedColor: cs.tertiary,
          trailing: Icon(_genreExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: cs.onSurfaceVariant),
          onTap: () => setState(() => _genreExpanded = !_genreExpanded),
        ),
        if (_genreExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: widget.availableGenres.isEmpty
                ? Padding(padding: const EdgeInsets.all(12),
                    child: Text('No genres found', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)))
                : Column(children: widget.availableGenres.map((genre) {
                    final selected = widget.currentFilter == LibraryFilter.genre && widget.genreFilter == genre;
                    return _SheetOption(
                      icon: Icons.label_outline_rounded, label: genre,
                      selected: selected, selectedColor: cs.tertiary,
                      compact: true, marquee: true,
                      onTap: () => widget.onFilterChanged(LibraryFilter.genre, genre: genre),
                    );
                  }).toList()),
          ),
      ],
    );
  }
}

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool compact;
  final bool marquee;

  const _SheetOption({
    required this.icon, required this.label, required this.selected,
    required this.selectedColor, this.trailing, required this.onTap,
    this.compact = false, this.marquee = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final vPad = compact ? 8.0 : 10.0;
    final fontSize = compact ? 13.0 : 14.0;
    final iconSize = compact ? 18.0 : 20.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: vPad),
        margin: EdgeInsets.only(bottom: compact ? 2 : 4),
        decoration: BoxDecoration(
          color: selected ? selectedColor.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Icon(icon, size: iconSize, color: selected ? selectedColor : cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: marquee
                ? _MarqueeText(text: label, style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? selectedColor : cs.onSurface))
                : Text(label, style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? selectedColor : cs.onSurface)),
          ),
          if (trailing != null) trailing!,
          if (selected && trailing == null)
            Icon(Icons.check_rounded, size: 18, color: selectedColor),
        ]),
      ),
    );
  }
}

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});
  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  late final ScrollController _sc;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sc = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndScroll());
  }

  void _checkAndScroll() {
    if (!_sc.hasClients || _sc.position.maxScrollExtent <= 0) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () {
      if (!mounted || !_sc.hasClients) return;
      final max = _sc.position.maxScrollExtent;
      _sc.animateTo(max, duration: Duration(milliseconds: (max * 30).round().clamp(1000, 5000)), curve: Curves.linear).then((_) {
        if (!mounted) return;
        Future.delayed(const Duration(seconds: 1), () {
          if (!mounted || !_sc.hasClients) return;
          _sc.animateTo(0, duration: const Duration(milliseconds: 500), curve: Curves.easeOut).then((_) {
            if (mounted) _checkAndScroll();
          });
        });
      });
    });
  }

  @override
  void dispose() { _timer?.cancel(); _sc.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _sc, scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, style: widget.style, maxLines: 1),
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
                          httpHeaders: lib.mediaHeaders,
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
                          httpHeaders: context.read<LibraryProvider>().mediaHeaders,
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
                        httpHeaders: context.read<LibraryProvider>().mediaHeaders,
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
    final lib = context.watch<LibraryProvider>();

    // Calculate time-weighted series progress across all books
    double totalDuration = 0;
    double listenedDuration = 0;
    for (final book in _books) {
      final bookId = book['id'] as String? ?? '';
      final media = book['media'] as Map<String, dynamic>? ?? {};
      final dur = (media['duration'] is num) ? (media['duration'] as num).toDouble() : 0.0;
      final prog = lib.getProgress(bookId);
      totalDuration += dur;
      listenedDuration += dur * prog;
    }
    final seriesProgress = totalDuration > 0 ? (listenedDuration / totalDuration).clamp(0.0, 1.0) : 0.0;
    final seriesPercent = (seriesProgress * 100).round();

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
          padding: EdgeInsets.fromLTRB(24, 0, 24, seriesProgress > 0 ? 4 : 12),
          child: Text(
            '${_books.length} book${_books.length != 1 ? 's' : ''} in this series',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        if (seriesProgress > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: seriesProgress,
                      minHeight: 4,
                      backgroundColor: cs.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(cs.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '$seriesPercent% complete',
                  style: tt.labelSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
                                          httpHeaders: context.read<LibraryProvider>().mediaHeaders,
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
