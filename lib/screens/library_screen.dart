import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/download_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/library_grid_tiles.dart';
import '../widgets/library_search_results.dart';
import '../widgets/library_sort_filter_sheet.dart';

// ─── Sort modes ──────────────────────────────────────────────
enum LibrarySort { recentlyAdded, alphabetical, authorName, publishedYear, duration, random }

// ─── Filter modes ────────────────────────────────────────────
enum LibraryFilter { none, inProgress, finished, notStarted, downloaded, hasEbook, genre }

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
  bool _collapseSeries = false;
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
        // Reset filter on library switch — genre filters don't carry across libraries
        _filter = LibraryFilter.none;
        _genreFilter = null;
      });
      PlayerSettings.setLibraryFilter('none');
      PlayerSettings.setLibraryGenreFilter(null);
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
    PlayerSettings.getCollapseSeries().then((v) {
      if (mounted) setState(() => _collapseSeries = v);
    });
    _restoreSortFilter().then((_) {
      if (!mounted) return;
      _lastLibraryId = lib.selectedLibraryId;
      lib.addListener(_onLibraryProviderChanged);
      if (lib.selectedLibraryId != null) {
        _loadPage();
        _loadGenres();
      } else {
        lib.addListener(_onLibraryChanged);
      }
    });
    PlayerSettings.settingsChanged.addListener(_onSettingsChanged);
  }

  Future<void> _restoreSortFilter() async {
    final results = await Future.wait([
      PlayerSettings.getLibrarySort(),
      PlayerSettings.getLibrarySortAsc(),
      PlayerSettings.getLibraryFilter(),
      PlayerSettings.getLibraryGenreFilter(),
    ]);
    if (!mounted) return;
    final sortName = results[0] as String;
    final sortAsc = results[1] as bool;
    final filterName = results[2] as String;
    final genreFilter = results[3] as String;
    setState(() {
      _sort = LibrarySort.values.firstWhere(
        (s) => s.name == sortName,
        orElse: () => LibrarySort.recentlyAdded,
      );
      _sortAsc = sortAsc;
      if (_sort == LibrarySort.random) _randomSeed = Random().nextInt(100000);
      _filter = LibraryFilter.values.firstWhere(
        (f) => f.name == filterName,
        orElse: () => LibraryFilter.none,
      );
      _genreFilter = genreFilter.isNotEmpty ? genreFilter : null;
    });
  }

  void _onSettingsChanged() {
    Future.wait([
      PlayerSettings.getHideEbookOnly(),
      PlayerSettings.getCollapseSeries(),
    ]).then((values) {
      final newHideEbook = values[0];
      final newCollapse = values[1];
      if (!mounted) return;
      if (newHideEbook != _hideEbookOnly || newCollapse != _collapseSeries) {
        _loadGeneration++;
        setState(() {
          _hideEbookOnly = newHideEbook;
          _collapseSeries = newCollapse;
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
      collapseSeries: _collapseSeries && !useClientFilter && !lib.isPodcastLibrary,
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
      PlayerSettings.setLibrarySortAsc(_sortAsc);
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
    PlayerSettings.setLibrarySort(_sort.name);
    PlayerSettings.setLibrarySortAsc(_sortAsc);
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
    PlayerSettings.setLibraryFilter(_filter.name);
    PlayerSettings.setLibraryGenreFilter(_genreFilter);
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

  void _showLibraryPicker(BuildContext context, ColorScheme cs, TextTheme tt, List<dynamic> allLibraries, LibraryProvider lib) {
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
                  itemCount: allLibraries.length,
                  itemBuilder: (_, i) {
                    final library = allLibraries[i] as Map<String, dynamic>;
                    final id = library['id'] as String;
                    final name = library['name'] as String? ?? 'Library';
                    final mediaType = library['mediaType'] as String? ?? 'book';
                    final isSelected = id == lib.selectedLibraryId;
                    return ListTile(
                      leading: Icon(mediaType == 'podcast' ? Icons.podcasts_rounded : Icons.auto_stories_rounded,
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
      builder: (ctx) => SortFilterSheet(
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
        collapseSeries: _collapseSeries,
        onCollapseSeriesChanged: (value) {
          Navigator.pop(ctx);
          PlayerSettings.setCollapseSeries(value);
        },
        isPodcastLibrary: context.read<LibraryProvider>().isPodcastLibrary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final lib = context.watch<LibraryProvider>();
    final allLibraries = lib.libraries;
    final hasMultipleLibraries = allLibraries.length > 1;
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
                  onTap: () => _showLibraryPicker(context, cs, tt, allLibraries, lib),
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
                        Icon(lib.isPodcastLibrary ? Icons.podcasts_rounded : Icons.auto_stories_rounded, size: 14, color: cs.onSurfaceVariant),
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
                    if (_collapseSeries) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => PlayerSettings.setCollapseSeries(false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: cs.secondary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.auto_stories_rounded, size: 14, color: cs.secondary),
                              const SizedBox(width: 4),
                              Text('Series', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.secondary)),
                              const SizedBox(width: 4),
                              Icon(Icons.close_rounded, size: 14, color: cs.secondary),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text('${_items.length}${_totalItems > 0 ? '/$_totalItems' : ''} ${_collapseSeries ? 'items' : 'books'}',
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
      return RefreshIndicator(
        onRefresh: _refreshAll,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              child: Center(
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
              ),
            ),
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
        final item = _items[index];
        if (item.containsKey('collapsedSeries')) {
          return GridSeriesTile(item: item);
        }
        return GridBookTile(item: item);
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
                return BookResultTile(
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
            return SeriesResultCard(
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
            return AuthorResultTile(
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
