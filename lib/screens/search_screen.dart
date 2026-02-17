import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../widgets/absorb_title.dart';
import 'absorbing_screen.dart';
import 'series_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> with RouteAware {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<dynamic> _bookResults = [];
  List<dynamic> _seriesResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;

  /// Call this to focus the search field (e.g. when tab is selected)
  void requestSearchFocus() {
    _focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _bookResults = [];
        _seriesResults = [];
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
        _bookResults = (result['book'] as List<dynamic>?) ?? [];
        _seriesResults = (result['series'] as List<dynamic>?) ?? [];
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
            // Absorb brand
            const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 4),
              child: AbsorbTitle(),
            ),
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                      },
                    ),
                ],
                onChanged: _onSearchChanged,
                padding: WidgetStatePropertyAll(
                  const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),

            // Results
            Expanded(
              child: _isSearching
                  ? const Center(child: CircularProgressIndicator())
                  : !_hasSearched
                      ? _buildEmptyHint(cs, tt)
                      : (_bookResults.isEmpty && _seriesResults.isEmpty)
                          ? _buildNoResults(cs, tt)
                          : _buildResults(context, cs, tt),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyHint(ColorScheme cs, TextTheme tt) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, size: 56, color: cs.onSurfaceVariant.withOpacity(0.3)),
          const SizedBox(height: 12),
          Text(
            'Search your library',
            style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildNoResults(ColorScheme cs, TextTheme tt) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'No results found',
            style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context, ColorScheme cs, TextTheme tt) {
    final auth = context.read<AuthProvider>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
      children: [
        // ─── BOOKS ───────────────────────────────────
        if (_bookResults.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              'Books',
              style: tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
          ..._bookResults.map((result) {
            final item = result['libraryItem'] as Map<String, dynamic>? ?? {};
            return _BookResultTile(
              item: item,
              serverUrl: auth.serverUrl,
              token: auth.token,
            );
          }),
        ],

        // ─── SERIES ──────────────────────────────────
        if (_seriesResults.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(4, _bookResults.isNotEmpty ? 20 : 8, 4, 8),
            child: Text(
              'Series',
              style: tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
          ..._seriesResults.map((result) {
            final seriesData = result['series'] as Map<String, dynamic>? ?? {};
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

// ─── BOOK RESULT TILE ────────────────────────────────────────
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

    final bookId = item['id'] as String?;
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};

    final title = metadata['title'] as String? ?? 'Unknown';
    final authorName = metadata['authorName'] as String? ?? '';

    String? coverUrl;
    if (bookId != null && serverUrl != null && token != null) {
      final cleanUrl = serverUrl!.endsWith('/')
          ? serverUrl!.substring(0, serverUrl!.length - 1)
          : serverUrl!;
      coverUrl = '$cleanUrl/api/items/$bookId/cover?width=200&token=$token';
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
            if (bookId != null) {
              showBookDetailSheet(context, bookId);
            }
          },
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      if (authorName.isNotEmpty)
                        Text(
                          authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
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

// ─── SERIES RESULT CARD ──────────────────────────────────────
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
            // Series header — tappable, goes to series detail
            InkWell(
              onTap: () {
                final seriesWithBooks = {
                  ...series,
                  'books': books,
                };
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
                          Text(
                            seriesName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          Text(
                            '${books.length} book${books.length != 1 ? 's' : ''}',
                            style: tt.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
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
            // Book list within the series
            ...books.asMap().entries.map((entry) {
              final raw = entry.value as Map<String, dynamic>? ?? {};
              // Unwrap search result format
              final book = raw.containsKey('libraryItem')
                  ? (raw['libraryItem'] as Map<String, dynamic>? ?? raw)
                  : raw;
              final bookId = book['id'] as String?;
              final media = book['media'] as Map<String, dynamic>? ?? {};
              final metadata =
                  media['metadata'] as Map<String, dynamic>? ?? {};
              final bookTitle =
                  metadata['title'] as String? ?? 'Unknown';
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
                  if (bookId != null) {
                    showBookDetailSheet(context, bookId);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  child: Row(
                    children: [
                      // Small cover
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
                                    color: cs.surfaceContainerHighest,
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    color: cs.surfaceContainerHighest,
                                  ),
                                )
                              : Container(
                                  color: cs.surfaceContainerHighest,
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (sequence != null && sequence.isNotEmpty)
                              Text(
                                'Book $sequence',
                                style: tt.labelSmall?.copyWith(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            Text(
                              bookTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodySmall?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: cs.onSurface,
                              ),
                            ),
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
