import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/absorb_page_header.dart';

class AdminPodcastsScreen extends StatefulWidget {
  final Map<String, dynamic> library;
  const AdminPodcastsScreen({super.key, required this.library});
  @override State<AdminPodcastsScreen> createState() => _AdminPodcastsScreenState();
}

class _AdminPodcastsScreenState extends State<AdminPodcastsScreen> {
  bool _loading = true;
  bool _checkingEpisodes = false;
  List<dynamic> _shows = [];

  String get _libraryId => widget.library['id'] as String? ?? '';
  String get _folderId {
    final folders = widget.library['folders'] as List?;
    if (folders != null && folders.isNotEmpty) return folders[0]['id'] as String? ?? '';
    return '';
  }

  @override
  void initState() { super.initState(); _loadShows(); }

  Future<void> _loadShows() async {
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    setState(() => _loading = true);
    try {
      final r = await api.getLibraryItems(_libraryId, limit: 100);
      if (r != null && r['results'] is List) {
        _shows = (r['results'] as List).map((item) {
          if (item is Map<String, dynamic>) return item['libraryItem'] ?? item;
          return item;
        }).toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _checkNewEpisodes() async {
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    setState(() => _checkingEpisodes = true);
    final ok = await api.checkNewEpisodes(_libraryId);
    if (mounted) {
      setState(() => _checkingEpisodes = false);
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(
        content: Text(ok ? 'Checking for new episodes…' : 'Failed to check episodes'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      if (ok) Future.delayed(const Duration(seconds: 3), _loadShows);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      floatingActionButton: FloatingActionButton.small(
        backgroundColor: cs.primary,
        onPressed: () => _showSearchSheet(),
        child: Icon(Icons.add_rounded, color: cs.onPrimary),
      ),
      body: SafeArea(child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(children: [
            const Expanded(child: AbsorbPageHeader(title: 'Podcasts', padding: EdgeInsets.zero)),
            _checkingEpisodes
                ? const Padding(padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38)))
                : IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.white38, size: 22),
                    tooltip: 'Check for new episodes',
                    onPressed: _checkNewEpisodes),
            IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white38), onPressed: () => Navigator.pop(context)),
          ]),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : RefreshIndicator(onRefresh: _loadShows, child: _buildShowList(cs, tt)),
        ),
      ])),
    );
  }

  // ─── Show List ──────────────────────────────────────────────

  Widget _buildShowList(ColorScheme cs, TextTheme tt) {
    if (_shows.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.podcasts_rounded, size: 48, color: Colors.white.withValues(alpha: 0.1)),
        const SizedBox(height: 12),
        Text('No podcasts yet', style: tt.bodyMedium?.copyWith(color: Colors.white30)),
        const SizedBox(height: 4),
        Text('Tap + to search and add shows', style: tt.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.2))),
      ]));
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      itemCount: _shows.length,
      itemBuilder: (_, i) {
        final item = _shows[i] as Map<String, dynamic>;
        final media = item['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? 'Unknown';
        final author = metadata['author'] as String? ?? '';
        final numEps = media['numEpisodes'] as int?
            ?? (media['episodes'] as List?)?.length
            ?? item['numEpisodes'] as int?
            ?? 0;
        final itemId = item['id'] as String? ?? '';

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => _openShowDetail(item),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(10), child: _coverImg(cs, itemId)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (author.isNotEmpty) ...[const SizedBox(height: 2),
                    Text(author, style: tt.bodySmall?.copyWith(color: Colors.white38), maxLines: 1, overflow: TextOverflow.ellipsis)],
                  const SizedBox(height: 4),
                  Text('$numEps episodes', style: tt.labelSmall?.copyWith(color: cs.primary.withValues(alpha: 0.7), fontSize: 11)),
                ])),
                Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.15)),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _coverImg(ColorScheme cs, String itemId) {
    final auth = context.read<AuthProvider>();
    final url = '${auth.serverUrl}/api/items/$itemId/cover?token=${auth.token}';
    return Image.network(url, width: 56, height: 56, fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _coverPlaceholder(cs));
  }

  Widget _coverPlaceholder(ColorScheme cs) => Container(width: 56, height: 56,
    decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
    child: Icon(Icons.podcasts_rounded, color: cs.primary.withValues(alpha: 0.4)));

  // ─── Search Sheet ───────────────────────────────────────────

  void _showSearchSheet() {
    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true, backgroundColor: Colors.transparent,
      builder: (_) => _PodcastSearchSheet(libraryId: _libraryId, folderId: _folderId, onAdded: _loadShows));
  }

  // ─── Show Detail ────────────────────────────────────────────

  void _openShowDetail(Map<String, dynamic> item) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _PodcastDetailScreen(item: item, libraryId: _libraryId, onChanged: _loadShows)));
  }

  void _msg(String s) => ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
    SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
}


// ═══════════════════════════════════════════════════════════════
//  Search & Add Podcast Sheet
// ═══════════════════════════════════════════════════════════════

class _PodcastSearchSheet extends StatefulWidget {
  final String libraryId;
  final String folderId;
  final VoidCallback onAdded;
  const _PodcastSearchSheet({required this.libraryId, required this.folderId, required this.onAdded});
  @override State<_PodcastSearchSheet> createState() => _PodcastSearchSheetState();
}

class _PodcastSearchSheetState extends State<_PodcastSearchSheet> {
  final _ctrl = TextEditingController();
  bool _searching = false;
  List<dynamic> _results = [];

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _search() async {
    final q = _ctrl.text.trim(); if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    final api = context.read<AuthProvider>().apiService;
    if (api != null) _results = await api.searchPodcasts(q);
    if (mounted) setState(() => _searching = false);
  }

  /// Extract the podcast map from a search result item
  Map<String, dynamic> _extractPod(dynamic item) {
    if (item is Map<String, dynamic>) {
      if (item.containsKey('podcast')) return item['podcast'] as Map<String, dynamic>;
      return item;
    }
    return {};
  }

  String _getImageUrl(Map<String, dynamic> pod) {
    return pod['cover'] as String?
        ?? pod['imageUrl'] as String?
        ?? pod['artworkUrl600'] as String?
        ?? pod['artworkUrl100'] as String?
        ?? '';
  }

  void _openPreview(Map<String, dynamic> pod) {
    Navigator.pop(context); // close search sheet
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PodcastPreviewScreen(
          podcast: pod,
          libraryId: widget.libraryId,
          folderId: widget.folderId,
          onAdded: widget.onAdded,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, sc) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Add Podcast', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              _buildSearchBar(cs, tt),
              const Divider(height: 1, color: Colors.white10),
              Expanded(
                child: _searching
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : _results.isEmpty
                        ? Center(child: Text('Search iTunes to find podcasts', style: tt.bodySmall?.copyWith(color: Colors.white24)))
                        : _buildResultsList(cs, tt, sc),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchBar(ColorScheme cs, TextTheme tt) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _ctrl,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          hintText: 'Search for podcasts…',
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25)),
          prefixIcon: Icon(Icons.search_rounded, color: Colors.white.withValues(alpha: 0.3)),
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38)),
                )
              : IconButton(icon: Icon(Icons.arrow_forward_rounded, color: cs.primary), onPressed: _search),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildResultsList(ColorScheme cs, TextTheme tt, ScrollController sc) {
    return ListView.builder(
      controller: sc,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final pod = _extractPod(_results[i]);
        final title = pod['title'] as String? ?? pod['trackName'] as String? ?? pod['collectionName'] as String? ?? 'Unknown';
        final author = pod['artistName'] as String? ?? pod['author'] as String? ?? '';
        final imageUrl = _getImageUrl(pod);

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => _openPreview(pod),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: imageUrl.isNotEmpty
                        ? Image.network(
                            imageUrl,
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _ph(cs),
                          )
                        : _ph(cs),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (author.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(author, style: tt.bodySmall?.copyWith(color: Colors.white38), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.15)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _ph(ColorScheme cs) => Container(
    width: 50, height: 50,
    decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
    child: Icon(Icons.podcasts_rounded, color: cs.primary.withValues(alpha: 0.4), size: 22),
  );

  void _snk(String s) => ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
    SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
}


// ═══════════════════════════════════════════════════════════════
//  Podcast Preview / Confirmation Screen
// ═══════════════════════════════════════════════════════════════

class _PodcastPreviewScreen extends StatefulWidget {
  final Map<String, dynamic> podcast;
  final String libraryId;
  final String folderId;
  final VoidCallback onAdded;
  const _PodcastPreviewScreen({
    required this.podcast,
    required this.libraryId,
    required this.folderId,
    required this.onAdded,
  });
  @override State<_PodcastPreviewScreen> createState() => _PodcastPreviewScreenState();
}

class _PodcastPreviewScreenState extends State<_PodcastPreviewScreen> {
  bool _loadingFeed = false;
  bool _adding = false;
  Map<String, dynamic>? _feedData;
  List<dynamic> _feedEpisodes = [];

  Map<String, dynamic> get _pod => widget.podcast;
  String get _title => _pod['title'] as String? ?? _pod['trackName'] as String? ?? _pod['collectionName'] as String? ?? 'Podcast';
  String get _author => _pod['artistName'] as String? ?? _pod['author'] as String? ?? '';
  String get _feedUrl => _pod['feedUrl'] as String? ?? '';
  String get _imageUrl =>
      _pod['cover'] as String? ??
      _pod['imageUrl'] as String? ??
      _pod['artworkUrl600'] as String? ?? '';
  String get _description => _feedData?['metadata']?['description'] as String? ??
      _pod['description'] as String? ?? '';
  List<dynamic> get _genres => _pod['genres'] as List? ?? [];

  @override
  void initState() {
    super.initState();
    if (_feedUrl.isNotEmpty) _loadFeed();
  }

  Future<void> _loadFeed() async {
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    setState(() => _loadingFeed = true);
    final result = await api.getPodcastFeed(_feedUrl);
    if (result != null && mounted) {
      setState(() {
        _feedData = result['podcast'] as Map<String, dynamic>? ?? result;
        _feedEpisodes = _feedData?['episodes'] as List? ?? [];
        _loadingFeed = false;
      });
    } else if (mounted) {
      setState(() => _loadingFeed = false);
    }
  }

  Future<void> _addPodcast() async {
    if (_feedUrl.isEmpty) { _msg('No feed URL found'); return; }
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    setState(() => _adding = true);
    final result = await api.createPodcast(
      libraryId: widget.libraryId,
      folderId: widget.folderId,
      feedUrl: _feedUrl,
      podcastData: _pod,
    );
    if (mounted) {
      setState(() => _adding = false);
      if (result != null) {
        widget.onAdded();
        Navigator.pop(context);
        _msg('$_title added to library');
      } else {
        _msg('Failed to add $_title');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white54), onPressed: () => Navigator.pop(context)),
                  const Spacer(),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                children: [
                  // Cover + title
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: _imageUrl.isNotEmpty
                          ? Image.network(_imageUrl, width: 160, height: 160, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _coverPlaceholder(cs))
                          : _coverPlaceholder(cs),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _title,
                    style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                  if (_author.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(_author, style: tt.bodyMedium?.copyWith(color: Colors.white38), textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 12),

                  // Genres
                  if (_genres.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: _genres.map((g) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(g.toString(), style: tt.labelSmall?.copyWith(color: cs.primary, fontSize: 11)),
                        )).toList(),
                      ),
                    ),

                  // Feed info
                  if (_feedUrl.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.rss_feed_rounded, size: 14, color: Colors.white.withValues(alpha: 0.25)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _feedUrl,
                              style: tt.labelSmall?.copyWith(color: Colors.white.withValues(alpha: 0.25), fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Description
                  if (_description.isNotEmpty) ...[
                    Text(
                      _description,
                      style: tt.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.5), height: 1.5),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Episode preview
                  if (_loadingFeed)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (_feedEpisodes.isNotEmpty) ...[
                    Text(
                      '${_feedEpisodes.length} episodes in feed',
                      style: tt.labelMedium?.copyWith(color: Colors.white38, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    // Show first 5 episodes as preview
                    ...(_feedEpisodes.take(5).map((ep) {
                      final epMap = ep as Map<String, dynamic>;
                      final epTitle = epMap['title'] as String? ?? 'Episode';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            epTitle,
                            style: tt.bodySmall?.copyWith(color: Colors.white54),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    })),
                    if (_feedEpisodes.length > 5)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '+ ${_feedEpisodes.length - 5} more episodes',
                          style: tt.labelSmall?.copyWith(color: Colors.white24),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ],
              ),
            ),

            // Add button
            Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, MediaQuery.of(context).padding.bottom + 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _adding ? null : _addPodcast,
                  icon: _adding
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.add_rounded),
                  label: Text(_adding ? 'Adding…' : 'Add to Library', style: const TextStyle(fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) => Container(
    width: 160, height: 160,
    decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
    child: Icon(Icons.podcasts_rounded, color: cs.primary.withValues(alpha: 0.3), size: 48),
  );

  void _msg(String s) => ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
    SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
}


// ═══════════════════════════════════════════════════════════════
//  Podcast Detail — Episodes per show
// ═══════════════════════════════════════════════════════════════

class _PodcastDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final String libraryId;
  final VoidCallback onChanged;
  const _PodcastDetailScreen({required this.item, required this.libraryId, required this.onChanged});
  @override State<_PodcastDetailScreen> createState() => _PodcastDetailScreenState();
}

class _PodcastDetailScreenState extends State<_PodcastDetailScreen> with SingleTickerProviderStateMixin {
  late Map<String, dynamic> _item;
  bool _loadingFeed = false;
  List<dynamic> _feedEpisodes = [];
  final Set<String> _downloading = {};
  final Set<String> _deleting = {};
  late TabController _tabCtrl;

  String get _podcastId => _item['id'] as String? ?? '';
  Map<String, dynamic> get _media => _item['media'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _metadata => _media['metadata'] as Map<String, dynamic>? ?? {};
  List<dynamic> get _episodes => _media['episodes'] as List? ?? [];
  String get _title => _metadata['title'] as String? ?? 'Podcast';
  String get _feedUrl => _metadata['feedUrl'] as String? ?? _media['feedUrl'] as String? ?? '';

  @override
  void initState() {
    super.initState();
    _item = Map<String, dynamic>.from(widget.item);
    _tabCtrl = TabController(length: 2, vsync: this);
    _reloadItem(); // Load full item with episodes
  }

  @override
  void dispose() { _tabCtrl.dispose(); super.dispose(); }

  Future<void> _reloadItem() async {
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    try {
      final found = await api.getLibraryItem(_podcastId);
      if (found != null && mounted) setState(() => _item = Map<String, dynamic>.from(found));
    } catch (_) {}
  }

  Future<void> _loadFeed() async {
    if (_feedUrl.isEmpty) { _msg('No feed URL available'); return; }
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    setState(() => _loadingFeed = true);
    final result = await api.getPodcastFeed(_feedUrl);
    if (result != null) {
      final podcast = result['podcast'] as Map<String, dynamic>? ?? result;
      _feedEpisodes = podcast['episodes'] as List? ?? [];
    }
    if (mounted) setState(() => _loadingFeed = false);
  }

  Future<void> _downloadEpisode(Map<String, dynamic> feedEp) async {
    final epTitle = feedEp['title'] as String? ?? '';
    final epKey = feedEp['enclosureUrl'] as String? ?? feedEp['title'] as String? ?? '';
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    setState(() => _downloading.add(epKey));
    final ok = await api.downloadPodcastEpisodes(_podcastId, [feedEp]);
    if (mounted) {
      setState(() => _downloading.remove(epKey));
      _msg(ok ? 'Downloading "$epTitle"' : 'Failed to download');
    }
    widget.onChanged();
  }

  Future<void> _deleteEpisode(String episodeId, String epTitle) async {
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text('Delete Episode?', style: TextStyle(color: Colors.white)),
      content: Text('Delete "$epTitle"?', style: const TextStyle(color: Colors.white70)),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: TextStyle(color: Colors.red.shade300)))],
    ));
    if (yes != true) return;
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    setState(() => _deleting.add(episodeId));
    final ok = await api.deletePodcastEpisode(_podcastId, episodeId);
    if (mounted) { setState(() => _deleting.remove(episodeId)); _msg(ok ? 'Deleted' : 'Failed');
      if (ok) { _reloadItem(); widget.onChanged(); } }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final auth = context.read<AuthProvider>();
    final coverUrl = '${auth.serverUrl}/api/items/$_podcastId/cover?token=${auth.token}';
    final author = _metadata['author'] as String? ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(child: Column(children: [
        // Back button
        Padding(padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
          child: Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white54), onPressed: () => Navigator.pop(context)),
            const Spacer(),
          ])),

        // Show info
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(borderRadius: BorderRadius.circular(12),
              child: Image.network(coverUrl, width: 72, height: 72, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(width: 72, height: 72,
                  decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.podcasts_rounded, color: cs.primary.withValues(alpha: 0.4), size: 28)))),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (author.isNotEmpty) ...[const SizedBox(height: 2),
                Text(author, style: tt.bodySmall?.copyWith(color: Colors.white38))],
              const SizedBox(height: 6),
              Text('${_episodes.length} downloaded', style: tt.labelSmall?.copyWith(color: cs.primary.withValues(alpha: 0.7), fontSize: 11)),
            ])),
          ])),

        // Tabs
        TabBar(
          controller: _tabCtrl,
          labelColor: cs.primary,
          unselectedLabelColor: Colors.white30,
          indicatorColor: cs.primary,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: Colors.white.withValues(alpha: 0.06),
          tabs: const [Tab(text: 'Downloaded'), Tab(text: 'Feed')],
          onTap: (i) { if (i == 1 && _feedEpisodes.isEmpty && !_loadingFeed) _loadFeed(); },
        ),

        // Tab views
        Expanded(child: TabBarView(controller: _tabCtrl, children: [
          _buildDownloadedTab(cs, tt),
          _buildFeedTab(cs, tt),
        ])),
      ])),
    );
  }

  // ─── Downloaded Tab ─────────────────────────────────────────

  Widget _buildDownloadedTab(ColorScheme cs, TextTheme tt) {
    if (_episodes.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.download_done_rounded, size: 40, color: Colors.white.withValues(alpha: 0.1)),
        const SizedBox(height: 8),
        Text('No downloaded episodes', style: tt.bodyMedium?.copyWith(color: Colors.white30)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () { _tabCtrl.animateTo(1); if (_feedEpisodes.isEmpty && !_loadingFeed) _loadFeed(); },
          child: Text('Browse feed to download', style: tt.bodySmall?.copyWith(color: cs.primary))),
      ]));
    }

    final sorted = List.from(_episodes)..sort((a, b) {
      final aT = a['publishedAt'] as num? ?? 0; final bT = b['publishedAt'] as num? ?? 0;
      return bT.compareTo(aT);
    });

    return RefreshIndicator(
      onRefresh: _reloadItem,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        itemCount: sorted.length,
        itemBuilder: (_, i) {
          final ep = sorted[i] as Map<String, dynamic>;
          final epId = ep['id'] as String? ?? '';
          final epTitle = ep['title'] as String? ?? 'Episode';
          final pubAt = ep['publishedAt'] as num?;
          final duration = ep['duration'] as num?;
          final isDel = _deleting.contains(epId);

          return Padding(padding: const EdgeInsets.only(bottom: 6), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(epTitle, style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Row(children: [
                  if (pubAt != null) Text(_fmtDate(pubAt.toInt()), style: tt.labelSmall?.copyWith(color: Colors.white24, fontSize: 10)),
                  if (pubAt != null && duration != null) Text(' · ', style: tt.labelSmall?.copyWith(color: Colors.white.withValues(alpha: 0.15))),
                  if (duration != null) Text(_fmtDur(duration.toDouble()), style: tt.labelSmall?.copyWith(color: Colors.white24, fontSize: 10)),
                ]),
              ])),
              const SizedBox(width: 8),
              isDel
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white24))
                : GestureDetector(onTap: () => _deleteEpisode(epId, epTitle),
                    child: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.withValues(alpha: 0.4))),
            ]),
          ));
        },
      ),
    );
  }

  // ─── Feed Tab ───────────────────────────────────────────────

  Widget _buildFeedTab(ColorScheme cs, TextTheme tt) {
    if (_loadingFeed) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (_feedUrl.isEmpty) return Center(child: Text('No feed URL available', style: tt.bodyMedium?.copyWith(color: Colors.white30)));
    if (_feedEpisodes.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('No episodes found', style: tt.bodyMedium?.copyWith(color: Colors.white30)),
        const SizedBox(height: 8),
        GestureDetector(onTap: _loadFeed,
          child: Text('Retry', style: tt.bodySmall?.copyWith(color: cs.primary))),
      ]));
    }

    // Match by enclosure URL or title to mark already-downloaded
    final dlTitles = _episodes.map((e) => (e['title'] as String? ?? '').toLowerCase()).toSet();

    return RefreshIndicator(
      onRefresh: _loadFeed,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        itemCount: _feedEpisodes.length,
        itemBuilder: (_, i) {
          final ep = _feedEpisodes[i] as Map<String, dynamic>;
          final epTitle = ep['title'] as String? ?? 'Episode';
          final epKey = ep['enclosureUrl'] as String? ?? epTitle;
          final pubDate = ep['publishedAt'] as num? ?? ep['pubDate'] as num?;
          final already = dlTitles.contains(epTitle.toLowerCase());
          final isDl = _downloading.contains(epKey);

          return Padding(padding: const EdgeInsets.only(bottom: 6), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(epTitle, style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w600,
                  color: already ? Colors.white38 : Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                if (pubDate != null) ...[const SizedBox(height: 3),
                  Text(_fmtDate(pubDate.toInt()), style: tt.labelSmall?.copyWith(color: Colors.white24, fontSize: 10))],
              ])),
              const SizedBox(width: 8),
              if (already) Icon(Icons.check_circle_rounded, size: 18, color: Colors.green.withValues(alpha: 0.5))
              else if (isDl) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38))
              else GestureDetector(onTap: () => _downloadEpisode(ep),
                child: Icon(Icons.download_rounded, size: 20, color: cs.primary)),
            ]),
          ));
        },
      ),
    );
  }

  // ─── Helpers ────────────────────────────────────────────────

  String _fmtDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _fmtDur(double s) { final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor();
    return h > 0 ? '${h}h ${m}m' : '${m}m'; }

  void _msg(String s) => ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
    SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
}
