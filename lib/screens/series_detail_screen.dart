import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/api_service.dart';
import 'absorbing_screen.dart';

class SeriesDetailScreen extends StatefulWidget {
  final Map<String, dynamic> series;

  const SeriesDetailScreen({super.key, required this.series});

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  late String _name;
  List<Map<String, dynamic>> _books = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _name = widget.series['name'] as String? ?? 'Unknown Series';
    _books = _unwrapBooks(widget.series['books'] ?? widget.series['libraryItems'] ?? []);
    _sortBooksBySequence();
    // Always fetch from API to get the full book list with sequence data
    _fetchSeries();
  }

  /// ABS wraps books as {libraryItem: {...}, sequence: "1"} in some responses.
  /// Unwrap them and move sequence to top level for consistent access.
  List<Map<String, dynamic>> _unwrapBooks(List<dynamic> raw) {
    final result = <Map<String, dynamic>>[];
    for (final b in raw) {
      if (b is! Map<String, dynamic>) continue;
      if (b.containsKey('libraryItem') && b['libraryItem'] is Map<String, dynamic>) {
        final item = Map<String, dynamic>.from(b['libraryItem'] as Map<String, dynamic>);
        // Preserve sequence at top level
        if (b['sequence'] != null) item['sequence'] = b['sequence'];
        result.add(item);
      } else {
        result.add(Map<String, dynamic>.from(b));
      }
    }
    return result;
  }

  void _sortBooksBySequence() {
    _books.sort((a, b) {
      final seqA = _getSequence(a);
      final seqB = _getSequence(b);
      if (seqA == null && seqB == null) return 0;
      if (seqA == null) return 1;
      if (seqB == null) return -1;
      return seqA.compareTo(seqB);
    });
  }

  double? _getSequence(dynamic book) {
    if (book is! Map<String, dynamic>) return null;
    // Top-level sequence (from unwrapping or ABS format)
    final seq = book['sequence'];
    if (seq != null) { final v = double.tryParse(seq.toString()); if (v != null) return v; }
    // Nested in metadata.series
    final media = book['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final seriesRaw = metadata['series'];
    if (seriesRaw is List) {
      for (final s in seriesRaw) {
        if (s is Map<String, dynamic>) {
          final v = s['sequence'];
          if (v != null) { final d = double.tryParse(v.toString()); if (d != null) return d; }
        }
      }
    } else if (seriesRaw is Map<String, dynamic>) {
      final v = seriesRaw['sequence'];
      if (v != null) { final d = double.tryParse(v.toString()); if (d != null) return d; }
    }
    final fallback = metadata['seriesSequence'];
    if (fallback != null) return double.tryParse(fallback.toString());
    return null;
  }

  Future<void> _fetchSeries() async {
    final seriesId = widget.series['id'] as String?;
    if (seriesId == null) return;
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    final lib = context.read<LibraryProvider>();
    final libraryId = lib.selectedLibraryId;

    if (_books.isEmpty) setState(() => _isLoading = true);
    final data = await api.getSeries(seriesId, libraryId: libraryId);
    if (data != null && mounted) {
      final rawBooks = data['books'] ?? data['libraryItems'] ?? [];
      if (rawBooks.isNotEmpty) {
      }
      final fetched = _unwrapBooks(rawBooks);
      setState(() {
        _name = data['name'] as String? ?? _name;
        if (fetched.isNotEmpty) _books = fetched;
        _sortBooksBySequence();
        _isLoading = false;
      });
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final auth = context.read<AuthProvider>();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(
              _name,
              style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),

          // Book count
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                _isLoading
                    ? 'Loading...'
                    : '${_books.length} book${_books.length != 1 ? 's' : ''} in this series',
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),

          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),

          // Book list
          if (!_isLoading && _books.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'No books found',
                  style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),

          if (!_isLoading && _books.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final book = _books[index] as Map<String, dynamic>? ?? {};
                    return _SeriesBookTile(
                      book: book,
                      index: index,
                      serverUrl: auth.serverUrl,
                      token: auth.token,
                    );
                  },
                  childCount: _books.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SeriesBookTile extends StatelessWidget {
  final Map<String, dynamic> book;
  final int index;
  final String? serverUrl;
  final String? token;

  const _SeriesBookTile({
    required this.book,
    required this.index,
    required this.serverUrl,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final bookId = book['id'] as String?;
    final media = (book['media'] is Map<String, dynamic>)
        ? book['media'] as Map<String, dynamic>
        : <String, dynamic>{};
    final metadata = (media['metadata'] is Map<String, dynamic>)
        ? media['metadata'] as Map<String, dynamic>
        : <String, dynamic>{};

    final title = metadata['title'] as String? ?? 'Unknown Title';
    final authorName = metadata['authorName'] as String? ?? '';
    final duration = (media['duration'] is num) ? (media['duration'] as num).toDouble() : 0.0;

    // Try to get sequence number — check top level first (from unwrapping), then metadata
    String? sequence = book['sequence']?.toString();
    if (sequence == null) {
      final seriesRaw = metadata['series'];
      if (seriesRaw is Map<String, dynamic>) {
        sequence = seriesRaw['sequence'] as String?;
      } else if (seriesRaw is List && seriesRaw.isNotEmpty) {
        for (final s in seriesRaw) {
          if (s is Map<String, dynamic>) {
            sequence = s['sequence'] as String?;
            if (sequence != null) break;
          }
        }
      }
      sequence ??= metadata['seriesSequence'] as String?;
    }

    String? coverUrl;
    if (bookId != null && serverUrl != null && token != null) {
      final cleanUrl = serverUrl!.endsWith('/')
          ? serverUrl!.substring(0, serverUrl!.length - 1)
          : serverUrl!;
      coverUrl = '$cleanUrl/api/items/$bookId/cover?width=400&token=$token';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (bookId != null) {
              showBookDetailSheet(context, bookId);
            }
          },
          borderRadius: BorderRadius.circular(14),
          child: Row(
            children: [
              // Square cover
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
                              placeholder: (_, __) => _placeholder(cs),
                              errorWidget: (_, __, ___) => _placeholder(cs),
                            )
                          : _placeholder(cs),
                    ),
                    if (sequence != null && sequence.isNotEmpty)
                      Positioned(
                        top: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.primary,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)],
                          ),
                          child: Text('#$sequence',
                            style: TextStyle(color: cs.onPrimary, fontSize: 10, fontWeight: FontWeight.w800)),
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (sequence != null && sequence.isNotEmpty)
                        Text(
                          'Book $sequence',
                          style: tt.labelSmall?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      if (authorName.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (duration > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          _formatDuration(duration),
                          style: tt.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Chevron
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: 24,
          color: cs.onSurfaceVariant.withOpacity(0.4),
        ),
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
