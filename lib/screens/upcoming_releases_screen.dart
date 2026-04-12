import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../services/upcoming_releases_service.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/audible_series_sheet.dart';
import '../widgets/overlay_toast.dart';

class UpcomingReleasesScreen extends StatefulWidget {
  const UpcomingReleasesScreen({super.key});

  @override
  State<UpcomingReleasesScreen> createState() => _UpcomingReleasesScreenState();
}

class _UpcomingReleasesScreenState extends State<UpcomingReleasesScreen> {
  final _service = UpcomingReleasesService();
  String _region = 'us';
  bool _sortByDate = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _initAndStart();
  }

  Future<void> _initAndStart() async {
    final saved = await PlayerSettings.getAudibleRegion();
    _region = saved.isNotEmpty ? saved : ApiService.debugRegion;
    _service.setRegion(_region);

    // If already running (e.g. came back to this screen), just attach
    if (_service.isRunning) {
      if (mounted) setState(() {});
      return;
    }

    // Try loading cache first
    final hasCache = await _service.loadCache();
    if (mounted) setState(() {});
    if (hasCache) {
      // If cache is stale, prompt for rescan
      if (_service.isCacheStale && mounted) {
        _showStalePrompt();
      }
      return;
    }

    // No cache - start a fresh scan
    _startScan();
  }

  void _startScan() {
    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;
    final libraryId = lib.selectedLibraryId;
    if (api == null || libraryId == null) return;

    _service.start(api: api, libraryId: libraryId, region: _region);
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _changeRegion() async {
    final chosen = await showAudibleRegionPicker(context, currentRegion: _region);
    if (chosen == null || chosen == _region || !mounted) return;

    await PlayerSettings.setAudibleRegion(chosen);
    setState(() => _region = chosen);
    _service.setRegion(chosen);
    _startScan();
  }

  void _rescan() {
    _startScan();
  }

  void _showStalePrompt() {
    final days = DateTime.now().difference(_service.cacheTime!).inDays;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rescan?'),
        content: Text(
          'These results are $days days old. Release dates may have changed - would you like to rescan?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
          FilledButton(onPressed: () { Navigator.pop(ctx); _rescan(); }, child: const Text('Rescan')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  String _formatDate(String dateStr) {
    final date = DateTime.tryParse(dateStr);
    if (date == null) return dateStr;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                     'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatRuntime(dynamic minutes) {
    final mins = (minutes is num) ? minutes.toInt() : 0;
    if (mins <= 0) return '';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }

  void _showBookMenu(Map<String, dynamic> book, String seriesName) {
    showAudibleBookMenu(context,
      book: book,
      seriesName: seriesName,
      region: _region,
      extraActions: [
        ListTile(
          leading: Icon(Icons.refresh_rounded, color: Theme.of(context).colorScheme.primary, size: 22),
          title: const Text('Rescan Release Date', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          dense: true, visualDensity: VisualDensity.compact,
          onTap: () {
            Navigator.pop(context);
            _rescanBook(book['asin'] as String? ?? '');
          },
        ),
      ],
    );
  }

  Future<void> _rescanBook(String asin) async {
    if (!mounted) return;
    showOverlayToast(context, 'Rescanning...', icon: Icons.refresh_rounded);
    final updated = await _service.rescanBook(asin);
    if (!mounted) return;
    if (updated != null) {
      final newDate = updated['releaseDate'] as String? ?? '';
      if (newDate.isNotEmpty) {
        showOverlayToast(context, 'Updated - ${_formatDate(newDate)}', icon: Icons.check_rounded);
      } else {
        showOverlayToast(context, 'No release date found', icon: Icons.info_outline_rounded);
      }
    } else {
      showOverlayToast(context, 'Rescan failed', icon: Icons.error_outline_rounded);
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
            AbsorbPageHeader(
              title: 'Upcoming Releases',
              actions: [
                // Sort by date toggle (only when scan is done and has results)
                if (_service.isComplete && _service.results.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _sortByDate = !_sortByDate),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: _sortByDate ? cs.primary.withValues(alpha: 0.15) : cs.onSurface.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: _sortByDate ? Border.all(color: cs.primary.withValues(alpha: 0.3)) : null,
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.calendar_today_rounded, size: 13,
                          color: _sortByDate ? cs.primary : cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text('Date', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: _sortByDate ? cs.primary : cs.onSurfaceVariant)),
                      ]),
                    ),
                  ),
                // Rescan button (only when not already scanning)
                if (_service.isComplete)
                  GestureDetector(
                    onTap: _rescan,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.refresh_rounded, size: 18, color: cs.onSurfaceVariant),
                    ),
                  ),
                // Region button
                GestureDetector(
                  onTap: _changeRegion,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.language_rounded, size: 14, color: cs.primary),
                      const SizedBox(width: 4),
                      Text(
                        ApiService.audibleRegions[_region] ?? _region.toUpperCase(),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary),
                      ),
                    ]),
                  ),
                ),
              ],
            ),

            // Progress indicator
            if (_service.isRunning) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _service.totalSeries > 0
                            ? _service.processedCount / _service.totalSeries
                            : null,
                        minHeight: 3,
                        backgroundColor: cs.surfaceContainerHighest,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _service.currentSeriesName != null
                          ? 'Checking ${_service.currentSeriesName}... (${_service.processedCount}/${_service.totalSeries})'
                          : 'Loading series...',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],

            // Summary when complete
            if (_service.isComplete)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(children: [
                  Text(
                    _buildSummary(),
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  if (_service.hasCachedResults && _service.cacheTime != null) ...[
                    const SizedBox(width: 6),
                    Text(_cacheAgeLabel(), style: tt.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 11)),
                  ],
                ]),
              ),

            const SizedBox(height: 8),

            // Results list
            Expanded(
              child: _buildContent(cs, tt),
            ),
          ],
        ),
      ),
    );
  }

  String _cacheAgeLabel() {
    final age = DateTime.now().difference(_service.cacheTime!);
    if (age.inDays == 0) return '(scanned today)';
    if (age.inDays == 1) return '(scanned yesterday)';
    return '(scanned ${age.inDays} days ago)';
  }

  String _buildSummary() {
    final totalUpcoming = _service.results.fold<int>(0, (sum, r) => sum + r.upcomingBooks.length);
    final totalRecent = _service.results.fold<int>(0, (sum, r) => sum + r.recentBooks.length);
    final parts = <String>[];
    if (totalUpcoming > 0) parts.add('$totalUpcoming upcoming');
    if (totalRecent > 0) parts.add('$totalRecent recent');
    if (parts.isEmpty) return 'No upcoming or recent releases found';
    final seriesCount = _service.results.length;
    return '${parts.join(', ')} across $seriesCount series';
  }

  Widget _buildContent(ColorScheme cs, TextTheme tt) {
    if (_service.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded, size: 48, color: cs.error.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(_service.error!, style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    if (_service.isComplete && _service.results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.event_available_rounded, size: 48, color: cs.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text('No upcoming or recent releases found', style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Checked ${_service.totalSeries} series on Audible',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
              textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    if (!_service.isRunning && !_service.isComplete && _service.results.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (_sortByDate && !_service.isRunning) {
      return _buildDateSortedList(cs, tt);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _service.results.length + (_service.isRunning ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _service.results.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return _buildSeriesSection(cs, tt, _service.results[index]);
      },
    );
  }

  Widget _buildDateSortedList(ColorScheme cs, TextTheme tt) {
    // Flatten all books with their series name and upcoming/recent status
    final allBooks = <({Map<String, dynamic> book, String seriesName, bool isUpcoming})>[];
    for (final result in _service.results) {
      for (final book in result.upcomingBooks) {
        allBooks.add((book: book, seriesName: result.seriesName, isUpcoming: true));
      }
      for (final book in result.recentBooks) {
        allBooks.add((book: book, seriesName: result.seriesName, isUpcoming: false));
      }
    }

    // Sort by release date (soonest first for upcoming, most recent first for recent)
    allBooks.sort((a, b) {
      final dateA = DateTime.tryParse(a.book['releaseDate'] as String? ?? '') ?? DateTime(2099);
      final dateB = DateTime.tryParse(b.book['releaseDate'] as String? ?? '') ?? DateTime(2099);
      return dateA.compareTo(dateB);
    });

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: allBooks.length,
      itemBuilder: (context, index) {
        final entry = allBooks[index];
        return _buildDateSortedCard(cs, tt, entry.book, entry.seriesName, entry.isUpcoming);
      },
    );
  }

  Widget _buildDateSortedCard(ColorScheme cs, TextTheme tt, Map<String, dynamic> book, String seriesName, bool isUpcoming) {
    final title = book['title'] as String? ?? '';
    final subtitle = book['subtitle'] as String? ?? '';
    final authors = book['authors'] as String? ?? '';
    final sequence = book['sequence'] as String? ?? '';
    final coverUrl = book['coverUrl'] as String? ?? '';
    final releaseDate = book['releaseDate'] as String? ?? '';
    final runtime = _formatRuntime(book['runtimeMinutes']);
    final isOwned = book['_owned'] == true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final downloadGreen = isDark ? Colors.greenAccent[400]! : Colors.green.shade700;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _showBookMenu(book, seriesName),
        child: Card(
          elevation: 0,
          color: isUpcoming
              ? cs.primaryContainer.withValues(alpha: 0.3)
              : isOwned
                  ? cs.surfaceContainerHigh.withValues(alpha: 0.5)
                  : cs.surfaceContainerHigh,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 100),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Cover
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: Stack(children: [
                    Positioned.fill(
                      child: coverUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: coverUrl, fit: BoxFit.cover,
                              placeholder: (_, __) => _placeholder(cs),
                              errorWidget: (_, __, ___) => _placeholder(cs))
                          : _placeholder(cs),
                    ),
                    if (sequence.isNotEmpty)
                      Positioned(top: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
                          child: Text('#$sequence', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    if (isUpcoming)
                      Positioned(bottom: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
                          child: const Text('UPCOMING', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    if (!isUpcoming)
                      Positioned(bottom: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: isOwned ? downloadGreen.withValues(alpha: 0.9) : cs.error.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(isOwned ? 'ADDED' : 'MISSING',
                            style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                ),
              ),
              // Details
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Series name label
                      Text(seriesName, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(color: cs.primary, fontSize: 10, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
                      if (subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 11)),
                        ),
                      const SizedBox(height: 4),
                      if (authors.isNotEmpty)
                        Text(authors, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
                      const SizedBox(height: 4),
                      Row(children: [
                        if (releaseDate.isNotEmpty) ...[
                          Icon(isUpcoming ? Icons.event_rounded : Icons.calendar_today_rounded,
                            size: 11, color: isUpcoming ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5)),
                          const SizedBox(width: 3),
                          Text(_formatDate(releaseDate),
                            style: TextStyle(fontSize: 10,
                              fontWeight: isUpcoming ? FontWeight.w600 : FontWeight.w400,
                              color: isUpcoming ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5))),
                        ],
                        if (releaseDate.isNotEmpty && runtime.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text('.', style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.3), fontSize: 10)),
                          ),
                        if (runtime.isNotEmpty) ...[
                          Icon(Icons.schedule_rounded, size: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                          const SizedBox(width: 3),
                          Text(runtime, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant.withValues(alpha: 0.5))),
                        ],
                      ]),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildSeriesSection(ColorScheme cs, TextTheme tt, UpcomingSeriesResult result) {
    final totalCount = result.upcomingBooks.length + result.recentBooks.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Series header
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(children: [
              Expanded(
                child: Text(
                  result.seriesName,
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$totalCount',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cs.primary),
                ),
              ),
            ]),
          ),
          // Upcoming books
          ...result.upcomingBooks.map((book) => _buildBookCard(cs, tt, book, result.seriesName, isUpcoming: true)),
          // Recent releases
          ...result.recentBooks.map((book) => _buildBookCard(cs, tt, book, result.seriesName, isUpcoming: false)),
        ],
      ),
    );
  }

  Widget _buildBookCard(ColorScheme cs, TextTheme tt, Map<String, dynamic> book, String seriesName, {required bool isUpcoming}) {
    final title = book['title'] as String? ?? '';
    final subtitle = book['subtitle'] as String? ?? '';
    final authors = book['authors'] as String? ?? '';
    final narrators = book['narrators'] as String? ?? '';
    final sequence = book['sequence'] as String? ?? '';
    final coverUrl = book['coverUrl'] as String? ?? '';
    final releaseDate = book['releaseDate'] as String? ?? '';
    final runtime = _formatRuntime(book['runtimeMinutes']);
    final isOwned = book['_owned'] == true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final downloadGreen = isDark ? Colors.greenAccent[400]! : Colors.green.shade700;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _showBookMenu(book, seriesName),
        child: Card(
          elevation: 0,
          color: isUpcoming
              ? cs.primaryContainer.withValues(alpha: 0.3)
              : isOwned
                  ? cs.surfaceContainerHigh.withValues(alpha: 0.5)
                  : cs.surfaceContainerHigh,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 100),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Cover
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: Stack(children: [
                    Positioned.fill(
                      child: coverUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: coverUrl, fit: BoxFit.cover,
                              placeholder: (_, __) => _placeholder(cs),
                              errorWidget: (_, __, ___) => _placeholder(cs))
                          : _placeholder(cs),
                    ),
                    if (sequence.isNotEmpty)
                      Positioned(top: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
                          child: Text('#$sequence', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    if (isUpcoming)
                      Positioned(bottom: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
                          child: const Text('UPCOMING', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    if (!isUpcoming)
                      Positioned(bottom: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: isOwned
                                ? downloadGreen.withValues(alpha: 0.9)
                                : cs.error.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isOwned ? 'ADDED' : 'MISSING',
                            style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              // Details
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
                      if (subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 11)),
                        ),
                      const SizedBox(height: 6),
                      if (authors.isNotEmpty)
                        Text(authors, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
                      if (narrators.isNotEmpty)
                        Text('Narrated by $narrators', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6), fontSize: 10)),
                      const SizedBox(height: 4),
                      Row(children: [
                        if (releaseDate.isNotEmpty) ...[
                          Icon(isUpcoming ? Icons.event_rounded : Icons.calendar_today_rounded,
                            size: 11, color: isUpcoming ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5)),
                          const SizedBox(width: 3),
                          Text(_formatDate(releaseDate),
                            style: TextStyle(fontSize: 10,
                              fontWeight: isUpcoming ? FontWeight.w600 : FontWeight.w400,
                              color: isUpcoming ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5))),
                        ],
                        if (releaseDate.isNotEmpty && runtime.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text('.', style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.3), fontSize: 10)),
                          ),
                        if (runtime.isNotEmpty) ...[
                          Icon(Icons.schedule_rounded, size: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                          const SizedBox(width: 3),
                          Text(runtime, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant.withValues(alpha: 0.5))),
                        ],
                      ]),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(child: Icon(Icons.auto_stories_rounded, color: cs.onSurface.withValues(alpha: 0.15), size: 28)),
    );
  }
}
