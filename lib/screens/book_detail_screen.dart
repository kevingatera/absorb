import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../services/progress_sync_service.dart';
import 'series_detail_screen.dart';
import 'app_shell.dart';

class BookDetailScreen extends StatefulWidget {
  final String itemId;

  const BookDetailScreen({super.key, required this.itemId});

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> with RouteAware {
  Map<String, dynamic>? _item;
  Map<String, dynamic>? _rating;
  int get _ratingCount {
    final raw = _rating?['numRatings'];
    if (raw == null) return 0;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }
  double? _localCurrentTime;
  bool _isLoading = true;
  bool _chaptersExpanded = false;
  Color? _dominantColor;
  final _player = AudioPlayerService();

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayerChanged);
    Future.microtask(() => _loadItem());
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    // Refresh local progress when player state changes (pause, stop, seek)
    _refreshLocalProgress();
  }

  Future<void> _refreshLocalProgress() async {
    final localData = await ProgressSyncService().getLocal(widget.itemId);
    final localTime = (localData?['currentTime'] as num?)?.toDouble();
    if (mounted && localTime != _localCurrentTime) {
      setState(() => _localCurrentTime = localTime);
    }
  }

  Future<void> _loadItem() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    final lib = context.read<LibraryProvider>();

    // Load local progress (may be more recent than server)
    final localData = await ProgressSyncService().getLocal(widget.itemId);
    final localTime = (localData?['currentTime'] as num?)?.toDouble();

    // Try server first (unless offline)
    Map<String, dynamic>? item;
    if (api != null && !lib.isOffline) {
      try {
        item = await api.getLibraryItem(widget.itemId);
      } catch (_) {
        debugPrint('[Detail] API fetch failed, trying offline fallback');
      }
    }

    // Fallback: build item from download metadata
    if (item == null) {
      final dl = DownloadService().getInfo(widget.itemId);
      if (dl.status == DownloadStatus.downloaded) {
        double duration = 0;
        List<dynamic> chapters = [];
        if (dl.sessionData != null) {
          try {
            final session = jsonDecode(dl.sessionData!) as Map<String, dynamic>;
            duration = (session['duration'] as num?)?.toDouble() ?? 0;
            chapters = session['chapters'] as List<dynamic>? ?? [];
          } catch (_) {}
        }
        item = {
          'id': dl.itemId,
          'media': {
            'metadata': {
              'title': dl.title ?? 'Unknown Title',
              'authorName': dl.author ?? '',
            },
            'duration': duration,
            'chapters': chapters,
          },
        };
      }
    }

    if (item != null && mounted) {
      setState(() {
        _item = item;
        _localCurrentTime = localTime;
        _isLoading = false;
      });

      // Try to fetch Audible rating if ASIN is available (only when online)
      if (!lib.isOffline) {
        final media = item['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final asin = metadata['asin'] as String?;
        if (asin != null && asin.isNotEmpty) {
          final rating = await ApiService.getAudibleRating(asin);
          if (rating != null && mounted) {
            setState(() => _rating = rating);
          }
        }
      }
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  /// Called when the cover image loads — extract a tint color from it.
  void _onCoverLoaded(ImageProvider imageProvider) {
    // Use ColorScheme.fromImageProvider to get a palette from the cover
    ColorScheme.fromImageProvider(
      provider: imageProvider,
      brightness: Theme.of(context).brightness,
    ).then((scheme) {
      if (mounted) {
        setState(() => _dominantColor = scheme.primaryContainer);
      }
    }).catchError((_) {});
  }

  /// Navigate to the series detail screen.
  /// First checks the already-loaded series list, then falls back to API.
  Future<void> _openSeriesDetail(
    BuildContext context,
    AuthProvider auth,
    String? seriesId,
    String seriesName,
  ) async {
    if (seriesId == null) return;

    // First: check if the series is already loaded in the provider
    final lib = context.read<LibraryProvider>();
    for (final s in lib.series) {
      final sMap = s as Map<String, dynamic>? ?? {};
      if (sMap['id'] == seriesId) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SeriesDetailScreen(series: sMap),
          ),
        );
        return;
      }
    }

    // Fallback: load from API
    final api = auth.apiService;
    if (api == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final seriesData = await api.getSeries(seriesId, libraryId: context.read<LibraryProvider>().selectedLibraryId);
    if (mounted) Navigator.pop(context); // dismiss loading

    if (seriesData != null && mounted) {
      // Normalize: the API may return "books" or "libraryItems"
      final books = seriesData['books']
          ?? seriesData['libraryItems']
          ?? [];
      final seriesMap = <String, dynamic>{
        'id': seriesId,
        'name': seriesData['name'] ?? seriesName,
        'books': books,
      };
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SeriesDetailScreen(series: seriesMap),
        ),
      );
    }
  }

  /// Start audio playback and open the player screen.
  Future<void> _startPlayback(
    BuildContext context, {
    required AuthProvider auth,
    required String title,
    required String author,
    required String? coverUrl,
    required double duration,
    required List<dynamic> chapters,
    required double startTime,
  }) async {
    final player = AudioPlayerService();

    // If this book is already loaded in the player, just go to Absorbing tab
    if (player.currentItemId == widget.itemId) {
      if (!player.isPlaying) {
        player.play();
      }
      if (mounted) {
        // Pop back to app shell and switch to Absorbing tab
        Navigator.of(context).popUntil((route) => route.isFirst);
        AppShell.goToAbsorbing(context);
      }
      return;
    }

    final api = auth.apiService;
    if (api == null) return;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );

    final success = await player.playItem(
      api: api,
      itemId: widget.itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      totalDuration: duration,
      chapters: chapters,
      startTime: startTime,
    );

    // Dismiss loading dialog
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    if (success && mounted) {
      // Refresh library so absorbing screen picks up new book
      final lib = context.read<LibraryProvider>();
      lib.refreshLocalProgress();
      lib.refresh();
      // Pop back to app shell and switch to Absorbing tab
      Navigator.of(context).popUntil((route) => route.isFirst);
      AppShell.goToAbsorbing(context);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(seconds: 3), 
          content: const Text('Failed to start playback. Check server connection.'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  Future<void> _markFinished(
      BuildContext context, AuthProvider auth, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Finished?'),
        content: const Text(
            'This will set your progress to 100% and stop playback if this book is playing.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mark Finished')),
        ],
      ),
    );
    if (confirmed != true) return;

    final api = auth.apiService;
    if (api == null) return;

    final player = AudioPlayerService();
    if (player.currentItemId == widget.itemId) {
      await player.stop();
    }

    try {
      await api.markFinished(widget.itemId, duration);
      // Clear local caches so UI reflects server state
      await ProgressSyncService().deleteLocal(widget.itemId);
      if (mounted) {
        context.read<LibraryProvider>().clearProgressFor(widget.itemId);
        await _loadItem();
        context.read<LibraryProvider>().refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(seconds: 3), 
            content: const Text('Marked as finished — nice work!'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(seconds: 3), 
            content: const Text('Failed to update — check your connection'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  Future<void> _markNotFinished(BuildContext context, AuthProvider auth,
      double currentTime, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Not Finished?'),
        content: const Text(
            'This will clear the finished status but keep your current position.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unmark')),
        ],
      ),
    );
    if (confirmed != true) return;

    final api = auth.apiService;
    if (api == null) return;

    try {
      await api.markNotFinished(
        widget.itemId,
        currentTime: currentTime,
        duration: duration,
      );
      // Clear local caches so UI reflects server state
      await ProgressSyncService().deleteLocal(widget.itemId);
      if (mounted) {
        context.read<LibraryProvider>().clearProgressFor(widget.itemId);
        await _loadItem();
        context.read<LibraryProvider>().refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(seconds: 3), 
            content: const Text('Marked as not finished — back at it!'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(seconds: 3), 
            content: const Text('Failed to update — check your connection'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  Future<void> _resetProgress(
      BuildContext context, AuthProvider auth, double duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Progress?'),
        content: const Text(
            'This will erase all progress for this book and set it back to the beginning. This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;

    final api = auth.apiService;
    if (api == null) return;

    final player = AudioPlayerService();
    if (player.currentItemId == widget.itemId) {
      await player.stop();
    }

    // Clear all local caches
    await ProgressSyncService().deleteLocal(widget.itemId);
    if (mounted) {
      context.read<LibraryProvider>().clearProgressFor(widget.itemId);
    }

    // Reset on server via PATCH
    final serverSuccess = await api.resetProgress(widget.itemId, duration);

    if (mounted) {
      await _loadItem();
      await context.read<LibraryProvider>().refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(seconds: 3), 
          content: Text(serverSuccess
              ? 'Progress reset — fresh start!'
              : 'Reset may not have synced — check your server'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 16),
              // Shimmer cover
              Center(
                child: Container(
                  width: 200, height: 200,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Shimmer title
              Container(
                width: 200, height: 20,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: 140, height: 14,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 72),
                child: LinearProgressIndicator(
                  backgroundColor: cs.surfaceContainerHighest.withOpacity(0.3),
                  color: cs.primary.withOpacity(0.3),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_item == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
              const SizedBox(height: 12),
              const Text('Failed to load book details'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final auth = context.read<AuthProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];

    final title = metadata['title'] as String? ?? 'Unknown Title';
    final subtitle = metadata['subtitle'] as String?;
    final authorName = metadata['authorName'] as String? ?? '';
    final narratorName = metadata['narratorName'] as String? ?? '';
    final description = metadata['description'] as String? ?? '';
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final seriesName = metadata['seriesName'] as String?;

    // Series info — the expanded item may have metadata.series as a list or object
    String? seriesId;
    String? seriesSequence;
    final seriesField = metadata['series'];
    if (seriesField is List && seriesField.isNotEmpty) {
      final first = seriesField.first as Map<String, dynamic>? ?? {};
      seriesId = first['id'] as String?;
      seriesSequence = first['sequence'] as String?;
    } else if (seriesField is Map<String, dynamic>) {
      seriesId = seriesField['id'] as String?;
      seriesSequence = seriesField['sequence'] as String?;
    }

    // Progress — use local if it's ahead of server (e.g. downloaded book not yet synced)
    final progress = _item!['userMediaProgress'] as Map<String, dynamic>?
        ?? _item!['mediaProgress'] as Map<String, dynamic>?;
    final serverProgress =
        (progress?['progress'] as num?)?.toDouble() ?? 0.0;
    final isFinished = progress?['isFinished'] == true;
    final serverCurrentTime =
        (progress?['currentTime'] as num?)?.toDouble() ?? 0.0;
    
    // Use whichever position is more recent (higher currentTime)
    final currentTime = (_localCurrentTime != null && _localCurrentTime! > serverCurrentTime)
        ? _localCurrentTime!
        : serverCurrentTime;
    
    // Recalculate progress from currentTime if using local
    final rawProgress = (currentTime > serverCurrentTime && duration > 0)
        ? (currentTime / duration).clamp(0.0, 1.0)
        : serverProgress;
    
    // If currentTime is 0 and not finished, treat as no progress
    // (server can return stale progress value after reset)
    final progressPercent =
        (currentTime <= 0 && !isFinished) ? 0.0 : rawProgress;

    final coverUrl = auth.apiService?.getCoverUrl(widget.itemId, width: 800);

    // Tint color from cover, with fallback
    final tint = _dominantColor ?? cs.primaryContainer;
    final headerGradientTop = isDark
        ? Color.lerp(tint, Colors.black, 0.55)!
        : Color.lerp(tint, Colors.white, 0.3)!;
    final headerGradientBottom = cs.surface;

    return CustomScrollView(
      slivers: [
        // ─── HERO HEADER ─────────────────────────────────────
        SliverToBoxAdapter(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [headerGradientTop, headerGradientBottom],
                stops: const [0.0, 1.0],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // Back button
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                    ],
                  ),

                  // Cover image — centered, padded, shows full art
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 8),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Card(
                        elevation: 12,
                        shadowColor: Colors.black54,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: coverUrl != null
                            ? CachedNetworkImage(
                                imageUrl: coverUrl,
                                fit: BoxFit.contain,
                                imageBuilder: (context, imageProvider) {
                                  // Extract color from cover on first load
                                  if (_dominantColor == null) {
                                    _onCoverLoaded(imageProvider);
                                  }
                                  return Image(
                                    image: imageProvider,
                                    fit: BoxFit.contain,
                                  );
                                },
                                placeholder: (_, __) =>
                                    _coverPlaceholder(cs),
                                errorWidget: (_, __, ___) =>
                                    _coverPlaceholder(cs),
                              )
                            : _coverPlaceholder(cs),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Title
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: tt.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),

                  // Subtitle
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: tt.titleSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],

                  // Series chip — tappable
                  if (seriesName != null && seriesName.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => _openSeriesDetail(context, auth, seriesId, seriesName),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            color: cs.tertiaryContainer.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                seriesName,
                                style: tt.labelMedium?.copyWith(
                                  color: cs.onTertiaryContainer,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 16,
                                color: cs.onTertiaryContainer,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),

        // ─── METADATA ROW ────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 20,
              runSpacing: 10,
              children: [
                if (authorName.isNotEmpty)
                  _MetaItem(
                    icon: Icons.person_outline_rounded,
                    label: 'Author',
                    value: authorName,
                    cs: cs,
                    tt: tt,
                  ),
                if (narratorName.isNotEmpty)
                  _MetaItem(
                    icon: Icons.mic_none_rounded,
                    label: 'Narrator',
                    value: narratorName,
                    cs: cs,
                    tt: tt,
                  ),
                if (duration > 0)
                  _MetaItem(
                    icon: Icons.schedule_rounded,
                    label: 'Length',
                    value: _formatDuration(duration),
                    cs: cs,
                    tt: tt,
                  ),
                if (chapters.isNotEmpty)
                  _MetaItem(
                    icon: Icons.list_rounded,
                    label: 'Chapters',
                    value: '${chapters.length}',
                    cs: cs,
                    tt: tt,
                  ),
              ],
            ),
          ),
        ),

        // ─── AUDIBLE RATING (always reserves space) ────────────
        SliverToBoxAdapter(
          child: SizedBox(
            height: 40,
            child: (_rating != null &&
                (_rating!['rating'] as num).toDouble() > 0)
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ..._buildStars(
                          (_rating!['rating'] as num).toDouble(), cs),
                      const SizedBox(width: 8),
                      Text(
                        (_rating!['rating'] as num).toStringAsFixed(1),
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      if (_ratingCount > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          '(${_formatCount(_ratingCount)})',
                          style: tt.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Text(
                        'on Audible',
                        style: tt.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : null,
          ),
        ),

        // ─── PROGRESS CARD ───────────────────────────────────
        if (progressPercent > 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Card(
                elevation: 0,
                color: cs.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            isFinished
                                ? Icons.check_circle_rounded
                                : Icons.headphones_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            isFinished
                                ? 'Finished'
                                : '${(progressPercent * 100).round()}% complete',
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          if (!isFinished && duration > 0)
                            Text(
                              '${_formatDuration(duration - currentTime)} left',
                              style: tt.labelMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: progressPercent.clamp(0.0, 1.0)),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) => ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: value,
                            minHeight: 6,
                            backgroundColor: cs.surfaceContainerHighest,
                            valueColor:
                                AlwaysStoppedAnimation(cs.primary),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // ─── PLAY BUTTON ─────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: () => _startPlayback(
                  context,
                  auth: auth,
                  title: title,
                  author: authorName,
                  coverUrl: coverUrl,
                  duration: duration,
                  chapters: chapters,
                  startTime: isFinished ? 0.0 : currentTime,
                ),
                icon: const Icon(Icons.headphones_rounded, size: 28),
                label: Text(
                  'Absorb',
                  style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimary,
                  ),
                ),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
        ),

        // ─── DOWNLOAD BUTTON (wide glass style) ──────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: _DownloadWideButton(
              itemId: widget.itemId,
              title: title,
              author: authorName,
              coverUrl: coverUrl,
              api: auth.apiService,
              accent: cs.primary,
            ),
          ),
        ),

        // ─── MARK FINISHED / NOT FINISHED + RESET ──────────────
        if (progressPercent > 0 || isFinished)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        onPressed: () => isFinished
                            ? _markNotFinished(context, auth, currentTime, duration)
                            : _markFinished(context, auth, duration),
                        icon: Icon(
                          isFinished
                              ? Icons.replay_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 20,
                        ),
                        label: Text(
                          isFinished
                              ? 'Mark Not Finished'
                              : 'Mark Finished',
                        ),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _resetProgress(context, auth, duration),
                      icon: Icon(
                        Icons.restart_alt_rounded,
                        size: 20,
                        color: cs.error,
                      ),
                      label: Text('Reset',
                        style: TextStyle(color: cs.error)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: cs.error.withOpacity(0.5)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ─── DESCRIPTION ─────────────────────────────────────
        if (description.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'About this book',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _stripHtml(description),
                    style: tt.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ─── CHAPTERS ────────────────────────────────────────
        if (chapters.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Card(
                elevation: 0,
                color: cs.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    // Expandable header
                    InkWell(
                      onTap: () => setState(
                          () => _chaptersExpanded = !_chaptersExpanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            Icon(Icons.list_rounded,
                                size: 20, color: cs.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${chapters.length} Chapters',
                                style: tt.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            AnimatedRotation(
                              turns: _chaptersExpanded ? 0.5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Chapter list
                    AnimatedCrossFade(
                      firstChild: const SizedBox.shrink(),
                      secondChild: Column(
                        children: [
                          const Divider(height: 1),
                          ...chapters.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final ch =
                                entry.value as Map<String, dynamic>;
                            final chTitle = ch['title'] as String? ??
                                'Chapter ${idx + 1}';
                            final chStart =
                                (ch['start'] as num?)?.toDouble() ?? 0;
                            final chEnd =
                                (ch['end'] as num?)?.toDouble() ?? 0;
                            final chDuration = chEnd - chStart;

                            final isCurrent = currentTime >= chStart &&
                                currentTime < chEnd &&
                                progressPercent > 0;

                            return Container(
                              color: isCurrent
                                  ? cs.primaryContainer.withOpacity(0.3)
                                  : null,
                              child: ListTile(
                                dense: true,
                                leading: SizedBox(
                                  width: 28,
                                  child: Text(
                                    '${idx + 1}',
                                    textAlign: TextAlign.center,
                                    style: tt.labelMedium?.copyWith(
                                      fontWeight: isCurrent
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                      color: isCurrent
                                          ? cs.primary
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  chTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tt.bodyMedium?.copyWith(
                                    fontWeight: isCurrent
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: isCurrent
                                        ? cs.primary
                                        : cs.onSurface,
                                  ),
                                ),
                                trailing: Text(
                                  _formatDuration(chDuration),
                                  style: tt.labelSmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                      crossFadeState: _chaptersExpanded
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      duration: const Duration(milliseconds: 250),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: 60)),
      ],
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: 48,
          color: cs.onSurfaceVariant.withOpacity(0.4),
        ),
      ),
    );
  }

  List<Widget> _buildStars(double rating, ColorScheme cs) {
    final stars = <Widget>[];
    final fullStars = rating.floor();
    final hasHalf = (rating - fullStars) >= 0.4;

    for (int i = 0; i < 5; i++) {
      if (i < fullStars) {
        stars.add(Icon(Icons.star_rounded, size: 20, color: cs.primary));
      } else if (i == fullStars && hasHalf) {
        stars
            .add(Icon(Icons.star_half_rounded, size: 20, color: cs.primary));
      } else {
        stars.add(Icon(Icons.star_outline_rounded,
            size: 20, color: cs.onSurfaceVariant.withOpacity(0.4)));
      }
    }
    return stars;
  }

  String _formatDuration(double seconds) {
    final h = (seconds / 3600).floor();
    final m = ((seconds % 3600) / 60).floor();
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(count >= 10000 ? 0 : 1)}K';
    return count.toString();
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }
}

/// Compact metadata display: icon, label, value stacked.
class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ColorScheme cs;
  final TextTheme tt;

  const _MetaItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.cs,
    required this.tt,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(height: 4),
        Text(
          label,
          style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            value,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tt.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── DOWNLOAD WIDE BUTTON (matches Absorbing screen style) ──

class _DownloadWideButton extends StatefulWidget {
  final String itemId;
  final String title;
  final String? author;
  final String? coverUrl;
  final ApiService? api;
  final Color accent;

  const _DownloadWideButton({
    required this.itemId,
    required this.title,
    this.author,
    this.coverUrl,
    required this.api,
    required this.accent,
  });

  @override
  State<_DownloadWideButton> createState() => _DownloadWideButtonState();
}

class _DownloadWideButtonState extends State<_DownloadWideButton> {
  final _dl = DownloadService();

  @override void initState() { super.initState(); _dl.addListener(_rebuild); }
  @override void dispose() { _dl.removeListener(_rebuild); super.dispose(); }
  void _rebuild() { if (mounted) setState(() {}); }

  @override
  Widget build(BuildContext context) {
    final downloading = _dl.isDownloading(widget.itemId);
    final downloaded = _dl.isDownloaded(widget.itemId);
    final progress = _dl.downloadProgress(widget.itemId);

    final IconData icon;
    final String label;
    final Color color;
    if (downloaded) {
      icon = Icons.download_done_rounded;
      label = 'Saved';
      color = Colors.greenAccent.withOpacity(0.7);
    } else if (downloading) {
      icon = Icons.downloading_rounded;
      label = '${(progress * 100).toStringAsFixed(0)}%';
      color = widget.accent;
    } else {
      icon = Icons.download_outlined;
      label = 'Download';
      color = Colors.white54;
    }

    return GestureDetector(
      onTap: () => _handleTap(context),
      child: Container(
        height: 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: downloaded
              ? Colors.greenAccent.withOpacity(0.06)
              : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: downloaded
                ? Colors.greenAccent.withOpacity(0.15)
                : Colors.white.withOpacity(0.08),
          ),
        ),
        child: Stack(
          children: [
            if (downloading)
              FractionallySizedBox(
                widthFactor: progress.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleTap(BuildContext context) {
    if (widget.api == null) return;
    if (_dl.isDownloaded(widget.itemId)) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Remove download?',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            'The audiobook will be removed from your device.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                _dl.deleteDownload(widget.itemId);
                Navigator.pop(ctx);
              },
              child: const Text('Remove',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      );
    } else if (_dl.isDownloading(widget.itemId)) {
      _dl.cancelDownload(widget.itemId);
    } else {
      _dl.downloadItem(
        api: widget.api!,
        itemId: widget.itemId,
        title: widget.title,
        author: widget.author,
        coverUrl: widget.coverUrl,
      );
    }
  }
}
