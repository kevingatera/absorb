import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/progress_sync_service.dart';
import '../services/metadata_override_service.dart';
import '../screens/app_shell.dart';
import '../screens/library_screen.dart';
import 'absorbing_shared.dart';
import 'metadata_lookup_sheet.dart';

// ─── BOOK DETAIL BOTTOM SHEET ───────────────────────────────

void showBookDetailSheet(BuildContext context, String itemId) {
  showModalBottomSheet(
    context: context, isScrollControlled: true, useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false, initialChildSize: 0.85, minChildSize: 0.5, maxChildSize: 0.95,
      builder: (ctx, sc) => _BookDetailSheetContent(itemId: itemId, scrollController: sc),
    ),
  );
}

class _BookDetailSheetContent extends StatefulWidget {
  final String itemId;
  final ScrollController scrollController;
  const _BookDetailSheetContent({required this.itemId, required this.scrollController});
  @override State<_BookDetailSheetContent> createState() => _BookDetailSheetContentState();
}

class _BookDetailSheetContentState extends State<_BookDetailSheetContent> {
  Map<String, dynamic>? _item;
  Map<String, dynamic>? _rating;
  bool _isLoading = true;
  bool _chaptersExpanded = false;
  bool _isAbsorbing = false;
  bool _hasLocalOverride = false;
  bool _showGoodreads = false;

  @override void initState() {
    super.initState();
    _loadItem();
    PlayerSettings.getShowGoodreadsButton().then((v) { if (mounted) setState(() => _showGoodreads = v); });
  }

  Future<void> _loadItem() async {
    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;

    // Try server first
    if (api != null && !lib.isOffline) {
      try {
        final item = await api.getLibraryItem(widget.itemId);
        if (item != null && mounted) {
          // Apply local metadata overrides
          final overrideService = MetadataOverrideService();
          final override = await overrideService.get(widget.itemId);
          Map<String, dynamic> finalItem = item;
          if (override != null) {
            finalItem = overrideService.applyOverrides(item, override);
            _hasLocalOverride = true;
          }

          setState(() { _item = finalItem; _isLoading = false; });

          // Fetch Audible rating
          final media = finalItem['media'] as Map<String, dynamic>? ?? {};
          final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
          final asin = metadata['asin'] as String?;
          final title = metadata['title'] as String? ?? '';
          final author = metadata['authorName'] as String?;

          Map<String, dynamic>? rating;
          if (asin != null && asin.isNotEmpty) {
            rating = await ApiService.getAudibleRating(asin);
          }
          if ((rating == null || (rating['rating'] as num).toDouble() <= 0) &&
              title.isNotEmpty) {
            final fallback = await api.searchAudibleRating(title, author);
            if (fallback != null && (fallback['rating'] as num).toDouble() > 0) {
              rating = fallback;
            }
          }
          if (rating != null && mounted) {
            setState(() => _rating = rating);
          }
          return;
        }
      } catch (_) {
        // Server unreachable — fall through to offline
      }
    }

    // Offline fallback: build item from local download data
    final dl = DownloadService().getInfo(widget.itemId);
    if (dl.sessionData != null) {
      try {
        final session = jsonDecode(dl.sessionData!) as Map<String, dynamic>;
        final localItem = session['libraryItem'] as Map<String, dynamic>?;
        if (localItem != null && mounted) {
          setState(() { _item = localItem; _isLoading = false; });
          return;
        }
      } catch (_) {}
    }
    // Minimal fallback from DownloadInfo metadata
    if (dl.title != null && mounted) {
      setState(() {
        _item = {
          'id': widget.itemId,
          'media': {
            'metadata': {
              'title': dl.title,
              'authorName': dl.author ?? '',
            },
          },
        };
        _isLoading = false;
      });
      return;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  String? get _coverUrl {
    // Check for local override cover first
    final localCover = _item?['_localCoverUrl'] as String?;
    if (localCover != null && localCover.isNotEmpty) return localCover;
    final auth = context.read<AuthProvider>();
    return auth.apiService?.getCoverUrl(widget.itemId, width: 800);
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(color: Color(0xFF111111), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Stack(children: [
        if (_coverUrl != null)
          Positioned.fill(child: CachedNetworkImage(
            imageUrl: _coverUrl!, fit: BoxFit.cover,
            httpHeaders: context.read<LibraryProvider>().mediaHeaders,
            imageBuilder: (_, p) => ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80, tileMode: TileMode.decal),
              child: Image(image: p, fit: BoxFit.cover)),
            placeholder: (_, __) => const SizedBox(),
            errorWidget: (_, __, ___) => const SizedBox(),
          )),
        Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [const Color(0xFF111111).withValues(alpha: 0.6), const Color(0xFF111111).withValues(alpha: 0.85), const Color(0xFF111111)],
        )))),
        _isLoading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24))
            : _item == null
                ? Center(child: Text('Failed to load', style: tt.bodyMedium?.copyWith(color: Colors.white38)))
                : AnimatedOpacity(
                    opacity: 1.0, duration: const Duration(milliseconds: 300),
                    child: _buildContent(context, cs, tt)),
      ]),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme cs, TextTheme tt) {
    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];
    final title = metadata['title'] as String? ?? 'Unknown';
    final authorName = metadata['authorName'] as String? ?? '';
    final narrator = metadata['narratorName'] as String? ?? '';
    final descRaw = metadata['description'] as String? ?? '';
    final desc = descRaw.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&nbsp;', ' ').trim();
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final seriesEntries = metadata['series'] as List<dynamic>? ?? [];
    final genres = (metadata['genres'] as List<dynamic>?)?.cast<String>() ?? [];
    final publisher = metadata['publisher'] as String? ?? '';
    final year = metadata['publishedYear'] as String? ?? '';
    final lib = context.watch<LibraryProvider>();
    final progress = lib.getProgress(widget.itemId);
    final auth = context.read<AuthProvider>();

    final progressData = lib.getProgressData(widget.itemId);
    final isFinished = progressData?['isFinished'] == true;
    final currentTime = (progressData?['currentTime'] as num?)?.toDouble() ?? 0;
    final ebookFile = media['ebookFile'] as Map<String, dynamic>?;

    final isEbookOnly = PlayerSettings.isEbookOnly(_item!);

    return ListView(controller: widget.scrollController, padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + MediaQuery.of(context).viewPadding.bottom), children: [
      Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
      Text(title, textAlign: TextAlign.center, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
      const SizedBox(height: 4),
      Text(authorName, textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: Colors.white60)),
      if (narrator.isNotEmpty) ...[const SizedBox(height: 2),
        Text('Narrated by $narrator', textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: Colors.white38))],
      // ─── AUDIBLE RATING (space always reserved) ─────────
      const SizedBox(height: 8),
      SizedBox(
        height: 20,
        child: (_rating != null && (_rating!['rating'] as num).toDouble() > 0)
          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ..._buildStars((_rating!['rating'] as num).toDouble(), cs),
              const SizedBox(width: 6),
              Text((_rating!['rating'] as num).toStringAsFixed(1),
                style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: Colors.white70)),
              const SizedBox(width: 4),
              Text('on Audible', style: tt.labelSmall?.copyWith(color: Colors.white38)),
            ])
          : null,
      ),
      const SizedBox(height: 12),
      if (progress > 0 && !isFinished) ...[
        ClipRRect(borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.1), valueColor: AlwaysStoppedAnimation(cs.primary))),
        const SizedBox(height: 4),
        Text('${(progress * 100).toStringAsFixed(1)}% complete', textAlign: TextAlign.center,
          style: tt.labelSmall?.copyWith(color: Colors.white38)),
        const SizedBox(height: 12),
      ],
      if (isEbookOnly)
        SizedBox(height: 52, child: FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.menu_book_rounded, size: 24),
          label: Text('eBook Only — No Audio',
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ))
      else
      SizedBox(height: 52, child: FilledButton.icon(
        onPressed: _isAbsorbing ? null : () {
          setState(() => _isAbsorbing = true);
          _startAbsorb(context, auth: auth, title: title, author: authorName,
            coverUrl: _coverUrl, duration: duration, chapters: chapters);
        },
        icon: _isAbsorbing
            ? SizedBox(width: 24, height: 24, child: AbsorbingWave(color: cs.onPrimary))
            : const Icon(Icons.waves_rounded, size: 24),
        label: Text(_isAbsorbing ? 'Absorbing…' : 'Absorb',
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onPrimary)),
        style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      )),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: DownloadWideButton(itemId: widget.itemId, coverUrl: _coverUrl, title: title, author: authorName, accent: cs.primary)),
        const SizedBox(width: 10),
        Expanded(child: GestureDetector(
          onTap: () => isFinished
              ? _markNotFinished(context, auth, currentTime, duration)
              : _markFinished(context, auth, duration),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: isFinished ? Colors.green.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isFinished ? Colors.green.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(
                isFinished ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
                size: 16,
                color: isFinished ? Colors.green : Colors.white54,
              ),
              const SizedBox(width: 6),
              Text(
                isFinished ? 'Fully Absorbed' : 'Fully Absorb',
                style: TextStyle(
                  color: isFinished ? Colors.green : Colors.white54,
                  fontSize: 12, fontWeight: FontWeight.w500,
                ),
              ),
            ]),
          ),
        )),
      ]),
      if (ebookFile != null) ...[
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _openEbook(context, auth, ebookFile, title),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _ebookLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
                  : const Icon(Icons.menu_book_rounded, size: 16, color: Colors.white54),
              const SizedBox(width: 6),
              Text(
                _ebookLoading ? 'Opening…' : 'Open ePub in Another App',
                style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ]),
          ),
        ),
      ],
      const SizedBox(height: 8),
      Builder(builder: (ctx) {
        final lib = ctx.watch<LibraryProvider>();
        final isOnList = lib.isOnAbsorbingList(widget.itemId);
        return GestureDetector(
          onTap: () async {
            if (isOnList) {
              final confirmed = await showDialog<bool>(
                context: ctx,
                builder: (dCtx) => AlertDialog(
                  title: const Text('Remove from Absorbing?'),
                  content: const Text('This will only remove it from the absorbing page. Your progress will be kept and it will still appear in Continue Listening on the library.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('Remove')),
                  ],
                ),
              );
              if (confirmed == true && ctx.mounted) {
                // Stop playback if this book is currently playing
                final player = AudioPlayerService();
                if (player.currentItemId == widget.itemId) {
                  await player.pause();
                  await player.stop();
                }
                await lib.removeFromAbsorbing(widget.itemId);
              }
            } else {
              await lib.addToAbsorbing(widget.itemId);
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                  content: Text('Added to absorbing list'),
                  behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
              }
            }
          },
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: isOnList ? cs.primary.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isOnList ? cs.primary.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(
                isOnList ? Icons.remove_circle_outline_rounded : Icons.add_circle_outline_rounded,
                size: 16,
                color: isOnList ? cs.primary : Colors.white54,
              ),
              const SizedBox(width: 6),
              Text(
                isOnList ? 'Remove from Absorbing' : 'Add to Absorbing',
                style: TextStyle(
                  color: isOnList ? cs.primary : Colors.white54,
                  fontSize: 12, fontWeight: FontWeight.w500,
                ),
              ),
            ]),
          ),
        );
      }),
      if (progress > 0 || isFinished) ...[
        const SizedBox(height: 8),
        _sheetBtn(icon: Icons.restart_alt_rounded,
          label: 'Reset Progress', onTap: () => _resetProgress(context, auth, duration)),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (year.isNotEmpty) _chip(Icons.calendar_today_rounded, year),
        _chip(Icons.schedule_rounded, _fmtDur(duration)),
        if (chapters.isNotEmpty) _chip(Icons.list_rounded, '${chapters.length} chapters'),
        if (publisher.isNotEmpty) _chip(Icons.business_rounded, publisher),
        ...genres.take(3).map((g) => _chip(Icons.tag_rounded, g)),
      ]),
      if (seriesEntries.isNotEmpty) ...[const SizedBox(height: 16),
        ...seriesEntries.map((s) {
          final name = s['name'] as String? ?? '';
          final seq = s['sequence'] as String? ?? '';
          final seriesId = s['id'] as String?;
          return Padding(padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              onTap: () => _openSeries(context, seriesId, name),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
                ),
                child: Row(children: [
                  Icon(Icons.auto_stories_rounded, size: 16, color: cs.primary.withValues(alpha: 0.7)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('$name${seq.isNotEmpty ? ' #$seq' : ''}',
                    style: tt.bodySmall?.copyWith(color: cs.primary.withValues(alpha: 0.9), fontWeight: FontWeight.w500))),
                  Icon(Icons.chevron_right_rounded, size: 18, color: cs.primary.withValues(alpha: 0.5)),
                ]),
              ),
            ));
        })],
      if (desc.isNotEmpty) ...[const SizedBox(height: 16),
        Text('About', style: tt.titleSmall?.copyWith(color: Colors.white54, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(desc, style: tt.bodySmall?.copyWith(color: Colors.white70, height: 1.5))],
      if (chapters.isNotEmpty) ...[const SizedBox(height: 16),
        GestureDetector(onTap: () => setState(() => _chaptersExpanded = !_chaptersExpanded),
          child: Row(children: [
            Text('Chapters (${chapters.length})', style: tt.titleSmall?.copyWith(color: Colors.white54, fontWeight: FontWeight.w600)),
            const Spacer(), Icon(_chaptersExpanded ? Icons.expand_less : Icons.expand_more, color: Colors.white38, size: 20)])),
        if (_chaptersExpanded) ...[const SizedBox(height: 8),
          ...chapters.asMap().entries.map((e) {
            final ch = e.value as Map<String, dynamic>;
            return Padding(padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 28, child: Text('${e.key + 1}', style: tt.labelSmall?.copyWith(color: Colors.white30))),
                Expanded(child: Text(ch['title'] as String? ?? 'Chapter ${e.key + 1}', maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: Colors.white60))),
                Text(_fmtDur(((ch['end'] as num?)?.toDouble() ?? 0) - ((ch['start'] as num?)?.toDouble() ?? 0)), style: tt.labelSmall?.copyWith(color: Colors.white30)),
              ]));
          })]],
      // ─── Metadata lookup (bottom of sheet) ─────────────────
      if (_showGoodreads) ...[
        const SizedBox(height: 8),
        _sheetBtn(
          icon: Icons.local_library_rounded,
          label: 'Search on Goodreads',
          onTap: () => _openGoodreads(title, authorName),
        ),
      ],
      if (auth.apiService != null && !lib.isOffline) ...[
        const SizedBox(height: 20),
        _sheetBtn(
          icon: Icons.manage_search_rounded,
          label: _hasLocalOverride ? 'Re-Lookup Metadata' : 'Lookup Metadata',
          onTap: () => _openMetadataLookup(context, auth, title, authorName),
        ),
      ],
      if (_hasLocalOverride) ...[
        const SizedBox(height: 8),
        _sheetBtn(
          icon: Icons.layers_clear_rounded,
          label: 'Clear Local Metadata',
          onTap: () => _clearOverride(context),
        ),
      ],
    ]);
  }

  Widget _sheetBtn({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(onTap: onTap, child: Container(height: 44,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1))),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 16, color: Colors.white54), const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500))])));
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: Colors.white38), const SizedBox(width: 4),
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis, maxLines: 1,
          style: const TextStyle(color: Colors.white54, fontSize: 11)))]));
  }

  String _fmtDur(double s) {
    final h = (s / 3600).floor(); final m = ((s % 3600) / 60).floor();
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  List<Widget> _buildStars(double rating, ColorScheme cs) {
    final stars = <Widget>[];
    final fullStars = rating.floor();
    final hasHalf = (rating - fullStars) >= 0.4;
    for (int i = 0; i < 5; i++) {
      if (i < fullStars) {
        stars.add(Icon(Icons.star_rounded, size: 16, color: cs.primary));
      } else if (i == fullStars && hasHalf) {
        stars.add(Icon(Icons.star_half_rounded, size: 16, color: cs.primary));
      } else {
        stars.add(Icon(Icons.star_outline_rounded, size: 16, color: Colors.white24));
      }
    }
    return stars;
  }

  Future<void> _openSeries(BuildContext context, String? seriesId, String seriesName) async {
    if (seriesId == null) return;
    final auth = context.read<AuthProvider>();
    // Show series sheet on top of the detail sheet (don't close detail)
    showSeriesBooksSheet(
      context,
      seriesName: seriesName,
      seriesId: seriesId,
      serverUrl: auth.serverUrl,
      token: auth.token,
    );
  }

  bool _ebookLoading = false;

  Future<void> _openEbook(BuildContext context, AuthProvider auth, Map<String, dynamic> ebookFile, String bookTitle) async {
    if (_ebookLoading) return;
    setState(() => _ebookLoading = true);

    try {
      final api = auth.apiService;
      if (api == null) return;

      final ino = ebookFile['ino'] as String?;
      if (ino == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ebook file found')));
        }
        return;
      }

      // Get the file extension from the ebook metadata
      final ebookName = ebookFile['metadata']?['filename'] as String? ?? ebookFile['name'] as String? ?? 'book.epub';
      final ext = ebookName.contains('.') ? ebookName.substring(ebookName.lastIndexOf('.')) : '.epub';

      // Download to cache directory
      final cacheDir = await getTemporaryDirectory();
      final safeTitle = bookTitle.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      final filePath = '${cacheDir.path}/$safeTitle$ext';
      final file = File(filePath);

      // Only download if not already cached
      if (!file.existsSync()) {
        final cleanBase = api.baseUrl.endsWith('/') ? api.baseUrl.substring(0, api.baseUrl.length - 1) : api.baseUrl;
        final url = '$cleanBase/api/items/${widget.itemId}/file/$ino';
        final response = await http.get(
          Uri.parse(url),
          headers: {'Authorization': 'Bearer ${api.token}'},
        ).timeout(const Duration(seconds: 60));

        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to download ebook (${response.statusCode})')));
          }
          return;
        }
      }

      // Open with system handler
      final result = await OpenFilex.open(filePath);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message.isNotEmpty ? result.message : 'No app found to open ebook')));
      }
    } catch (e) {
      debugPrint('[Ebook] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening ebook: $e')));
      }
    } finally {
      if (mounted) setState(() => _ebookLoading = false);
    }
  }

  Future<void> _startAbsorb(BuildContext context, {required AuthProvider auth, required String title, required String author, required String? coverUrl, required double duration, required List<dynamic> chapters}) async {
    final player = AudioPlayerService();
    // Grab the root navigator before we pop the sheet
    final rootNav = Navigator.of(context, rootNavigator: true);

    // Ensure this book is on the absorbing list (clear any manual remove)
    if (context.mounted) {
      final lib = context.read<LibraryProvider>();
      lib.addToAbsorbing(widget.itemId);
    }
    
    if (player.currentItemId == widget.itemId) {
      if (!player.isPlaying) player.play();
      rootNav.pop();
      Future.delayed(const Duration(milliseconds: 100), () {
        AppShell.goToAbsorbingGlobal();
      });
      return;
    }
    final api = auth.apiService;
    if (api == null) return;
    
    // Start playback
    await player.playItem(api: api, itemId: widget.itemId, title: title, author: author, coverUrl: coverUrl, totalDuration: duration, chapters: chapters);
    
    // Refresh library so the absorbing screen picks up the new book
    if (context.mounted) {
      final lib = context.read<LibraryProvider>();
      lib.refreshLocalProgress();
      lib.refresh();
    }
    
    // Close sheet and navigate
    rootNav.pop();
    Future.delayed(const Duration(milliseconds: 100), () {
      AppShell.goToAbsorbingGlobal();
    });
  }

  Future<void> _markFinished(BuildContext context, AuthProvider auth, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Fully Absorbed?'),
        content: const Text('This will set your progress to 100% and stop playback if this book is playing.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fully Absorb')),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    final player = AudioPlayerService();
    if (player.currentItemId == widget.itemId) await player.stop();
    try {
      await api.markFinished(widget.itemId, duration);
      await ProgressSyncService().deleteLocal(widget.itemId);
      if (context.mounted) {
        await _loadItem();
        await context.read<LibraryProvider>().refresh();
        if (mounted) setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 3), content: const Text('Marked as finished — nice work!'),
          behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      }
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3), content: const Text('Failed to update — check your connection'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }

  Future<void> _markNotFinished(BuildContext context, AuthProvider auth, double currentTime, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Not Finished?'),
        content: const Text('This will clear the finished status but keep your current position.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unmark')),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    try {
      await api.markNotFinished(widget.itemId, currentTime: currentTime, duration: duration);
      await ProgressSyncService().deleteLocal(widget.itemId);
      if (context.mounted) {
        await _loadItem();
        await context.read<LibraryProvider>().refresh();
        if (mounted) setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 3), content: const Text('Marked as not finished — back at it!'),
          behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      }
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3), content: const Text('Failed to update — check your connection'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }

  Future<void> _resetProgress(BuildContext context, AuthProvider auth, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Progress?'),
        content: const Text('This will erase all progress for this book and set it back to the beginning. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    final player = AudioPlayerService();
    
    // Stop player without saving progress
    if (player.currentItemId == widget.itemId) {
      await player.stopWithoutSaving();
    }
    
    // Clear local progress
    await ProgressSyncService().deleteLocal(widget.itemId);
    
    // Reset server progress (PATCH to zero + hide from continue listening)
    final serverSuccess = await api.resetProgress(widget.itemId, duration);
    
    // Clear from library provider (mark as reset — forces 0 progress)
    if (context.mounted) context.read<LibraryProvider>().resetProgressFor(widget.itemId);
    if (context.mounted) {
      await _loadItem();
      await context.read<LibraryProvider>().refresh();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(serverSuccess ? 'Progress reset — fresh start!' : 'Reset may not have synced — check your server'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    }
  }

  void _openGoodreads(String title, String author) async {
    final q = author.isNotEmpty ? '$title $author' : title;
    final uri = Uri.https('www.goodreads.com', '/search', {'q': q});
    try {
      // Open in Goodreads app if installed
      if (!await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // App not installed — fall back to browser
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openMetadataLookup(BuildContext context, AuthProvider auth, String title, String author) {
    final api = auth.apiService;
    if (api == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (ctx, sc) => MetadataLookupSheet(
          itemId: widget.itemId,
          api: api,
          initialTitle: title,
          initialAuthor: author,
          onApplied: () {
            // Reload the item to show the new override
            _loadItem();
          },
        ),
      ),
    );
  }

  Future<void> _clearOverride(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Local Metadata?'),
        content: const Text(
            'This will remove the locally stored metadata and revert to whatever the server has.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed != true) return;
    await MetadataOverrideService().delete(widget.itemId);
    if (mounted) {
      setState(() => _hasLocalOverride = false);
      await _loadItem();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Local metadata cleared'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    }
  }
}
