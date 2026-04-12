import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

/// Result for a single series that has upcoming or recently released books.
class UpcomingSeriesResult {
  final String seriesId;
  final String seriesName;
  final String audibleAsin;
  final List<Map<String, dynamic>> upcomingBooks;
  final List<Map<String, dynamic>> recentBooks; // released in last 30 days

  UpcomingSeriesResult({
    required this.seriesId,
    required this.seriesName,
    required this.audibleAsin,
    required this.upcomingBooks,
    this.recentBooks = const [],
  });

  Map<String, dynamic> toJson() => {
    'seriesId': seriesId,
    'seriesName': seriesName,
    'audibleAsin': audibleAsin,
    'upcomingBooks': upcomingBooks,
    'recentBooks': recentBooks,
  };

  factory UpcomingSeriesResult.fromJson(Map<String, dynamic> json) => UpcomingSeriesResult(
    seriesId: json['seriesId'] as String? ?? '',
    seriesName: json['seriesName'] as String? ?? '',
    audibleAsin: json['audibleAsin'] as String? ?? '',
    upcomingBooks: (json['upcomingBooks'] as List<dynamic>?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList() ?? [],
    recentBooks: (json['recentBooks'] as List<dynamic>?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList() ?? [],
  );
}

/// Scans library series for upcoming Audible releases.
///
/// Singleton service that survives screen navigation and continues in the
/// background. Results are cached to SharedPreferences so they persist
/// across app restarts.
class UpcomingReleasesService extends ChangeNotifier {
  // Singleton
  static final UpcomingReleasesService _instance = UpcomingReleasesService._();
  factory UpcomingReleasesService() => _instance;
  UpcomingReleasesService._();

  final List<UpcomingSeriesResult> _results = [];
  List<UpcomingSeriesResult> get results => _results;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  bool _isComplete = false;
  bool get isComplete => _isComplete;

  bool _hasCachedResults = false;
  bool get hasCachedResults => _hasCachedResults;

  int _processedCount = 0;
  int get processedCount => _processedCount;

  int _totalSeries = 0;
  int get totalSeries => _totalSeries;

  String? _currentSeriesName;
  String? get currentSeriesName => _currentSeriesName;

  String? _error;
  String? get error => _error;

  String _region = 'us';
  String get region => _region;

  int _generation = 0;

  // Cache: series ID -> Audible ASIN (or empty string if unresolvable)
  final Map<String, String> _asinCache = {};
  // Cache: Audible ASIN -> discovered books
  final Map<String, List<Map<String, dynamic>>> _discoveryCache = {};

  // Notification
  static const _notifChannelId = 'absorb_upcoming_scan';
  static const _notifChannelName = 'Upcoming Release Scan';
  static const _notifChannelDesc = 'Shows progress while scanning for upcoming releases';
  static const _scanNotifId = 9100;
  static const _completeNotifId = 9101;

  // Persistence keys
  static const _cacheKey = 'upcomingReleasesCache';
  static const _cacheTimeKey = 'upcomingReleasesCacheTime';
  static const _cacheRegionKey = 'upcomingReleasesCacheRegion';

  DateTime? _cacheTime;
  DateTime? get cacheTime => _cacheTime;

  /// Whether the cache is older than 2 weeks (suggest rescan).
  bool get isCacheStale =>
      _cacheTime != null && DateTime.now().difference(_cacheTime!).inDays >= 14;

  /// Load cached results from SharedPreferences.
  /// Returns true if valid cache was loaded (regardless of age).
  Future<bool> loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheTimeMs = prefs.getInt(_cacheTimeKey) ?? 0;
      final cachedRegion = prefs.getString(_cacheRegionKey) ?? '';
      if (cacheTimeMs == 0) return false;
      if (cachedRegion != _region) return false;

      final json = prefs.getString(_cacheKey);
      if (json == null || json.isEmpty) return false;

      final list = jsonDecode(json) as List<dynamic>;
      _results.clear();
      for (final item in list) {
        _results.add(UpcomingSeriesResult.fromJson(item as Map<String, dynamic>));
      }
      _cacheTime = DateTime.fromMillisecondsSinceEpoch(cacheTimeMs);
      _hasCachedResults = true;
      _isComplete = true;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[Upcoming] loadCache error: $e');
      return false;
    }
  }

  /// Save current results to SharedPreferences.
  Future<void> _saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_results.map((r) => r.toJson()).toList());
      await prefs.setString(_cacheKey, json);
      await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(_cacheRegionKey, _region);
    } catch (e) {
      debugPrint('[Upcoming] saveCache error: $e');
    }
  }

  /// Start scanning all series in the library.
  Future<void> start({
    required ApiService api,
    required String libraryId,
    required String region,
  }) async {
    if (_isRunning) return;
    _generation++;
    final gen = _generation;
    _region = region;

    _isRunning = true;
    _isComplete = false;
    _processedCount = 0;
    _totalSeries = 0;
    _error = null;
    _results.clear();
    _hasCachedResults = false;
    _currentSeriesName = null;
    notifyListeners();

    await _showScanNotification('Starting scan...');

    try {
      // First page to get total count
      final firstPage = await api.getLibrarySeries(libraryId, page: 0, limit: 50);
      if (_generation != gen) return;
      if (firstPage == null) {
        _error = 'Failed to load series';
        _isRunning = false;
        await _cancelScanNotification();
        notifyListeners();
        return;
      }

      _totalSeries = (firstPage['total'] as int?) ?? 0;
      notifyListeners();

      if (_totalSeries == 0) {
        _isRunning = false;
        _isComplete = true;
        await _cancelScanNotification();
        notifyListeners();
        return;
      }

      // Process first page
      final firstResults = (firstPage['results'] as List<dynamic>?) ?? [];
      await _processBatch(api, firstResults, gen);
      if (_generation != gen) return;

      // Fetch remaining pages
      final totalPages = (_totalSeries / 50).ceil();
      for (var page = 1; page < totalPages; page++) {
        if (_generation != gen) return;
        final pageData = await api.getLibrarySeries(libraryId, page: page, limit: 50);
        if (_generation != gen) return;
        if (pageData == null) continue;
        final pageResults = (pageData['results'] as List<dynamic>?) ?? [];
        await _processBatch(api, pageResults, gen);
      }

      if (_generation != gen) return;
      _isRunning = false;
      _isComplete = true;
      _currentSeriesName = null;
      notifyListeners();

      await _saveCache();
      await _cancelScanNotification();
      await _showCompleteNotification();
    } catch (e) {
      if (_generation != gen) return;
      debugPrint('[Upcoming] scan error: $e');
      _error = 'Scan failed: $e';
      _isRunning = false;
      await _cancelScanNotification();
      notifyListeners();
    }
  }

  /// Process a batch of series from one API page.
  Future<void> _processBatch(ApiService api, List<dynamic> seriesList, int gen) async {
    for (final s in seriesList) {
      if (_generation != gen) return;
      if (s is! Map<String, dynamic>) {
        _processedCount++;
        notifyListeners();
        continue;
      }

      final seriesId = s['id'] as String? ?? '';
      final seriesName = s['name'] as String? ?? 'Unknown Series';
      final books = s['books'] as List<dynamic>? ?? [];

      _currentSeriesName = seriesName;
      notifyListeners();

      // Update scan notification periodically
      if (_processedCount % 5 == 0) {
        await _showScanNotification(
          'Checking $seriesName... (${_processedCount + 1}/$_totalSeries)',
        );
      }

      // Try to resolve the Audible series ASIN
      String? audibleAsin;
      if (_asinCache.containsKey(seriesId)) {
        final cached = _asinCache[seriesId]!;
        audibleAsin = cached.isEmpty ? null : cached;
        debugPrint('[Upcoming] $seriesName: ASIN cache ${cached.isEmpty ? "miss (no ASIN)" : cached}');
      } else {
        audibleAsin = await _resolveSeriesAsin(books, seriesName, gen);
        if (_generation != gen) return;
        _asinCache[seriesId] = audibleAsin ?? '';
        debugPrint('[Upcoming] $seriesName: resolved ASIN=${audibleAsin ?? "NONE"} (${books.length} books checked)');
      }

      if (audibleAsin != null) {
        // Collect owned titles and ASINs from library books for ownership check
        final ownedTitles = <String>{};
        final ownedAsins = <String>{};
        for (final b in books) {
          if (b is! Map<String, dynamic>) continue;
          final media = b['media'] as Map<String, dynamic>? ?? {};
          final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
          final title = metadata['title'] as String? ?? '';
          final asin = metadata['asin'] as String? ?? '';
          if (title.isNotEmpty) ownedTitles.add(title);
          if (asin.isNotEmpty) ownedAsins.add(asin);
        }

        // Get all books in the series from Audible
        List<Map<String, dynamic>> allBooks;
        if (_discoveryCache.containsKey(audibleAsin)) {
          allBooks = _discoveryCache[audibleAsin]!;
        } else {
          allBooks = [];
          for (var attempt = 0; attempt < 3; attempt++) {
            if (_generation != gen) return;
            try {
              allBooks = await ApiService.discoverAudibleSeries(audibleAsin, region: _region);
              if (_generation != gen) return;
              _discoveryCache[audibleAsin] = allBooks;
              break;
            } catch (e) {
              debugPrint('[Upcoming] discover error for $seriesName (attempt ${attempt + 1}/3): $e');
              if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
            }
          }
        }

        debugPrint('[Upcoming] $seriesName: discovered ${allBooks.length} books on Audible');

        // Filter to upcoming and recently released
        final upcoming = allBooks.where(_isUpcoming).toList();
        final recent = <Map<String, dynamic>>[];
        for (final book in allBooks) {
          if (_isRecentRelease(book)) {
            final owned = _isOwnedBook(book, ownedTitles, ownedAsins);
            recent.add({...book, '_owned': owned});
          }
        }

        if (upcoming.isNotEmpty || recent.isNotEmpty) {
          debugPrint('[Upcoming] $seriesName: ${upcoming.length} upcoming, ${recent.length} recent');
          _results.add(UpcomingSeriesResult(
            seriesId: seriesId,
            seriesName: seriesName,
            audibleAsin: audibleAsin,
            upcomingBooks: upcoming,
            recentBooks: recent,
          ));
        }
      }

      _processedCount++;
      notifyListeners();

      // Small delay between series to be nice to Audible API
      if (_generation == gen) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  /// Rescan a single book to refresh its release date and details.
  /// Returns the updated book data, or null on failure.
  Future<Map<String, dynamic>?> rescanBook(String asin) async {
    try {
      final details = await ApiService.getAudibleBookDetails(asin, region: _region);
      if (details == null) return null;

      final authors = (details['authors'] as List<dynamic>? ?? [])
          .map((a) => (a as Map<String, dynamic>)['name'] ?? '').join(', ');
      final narrators = (details['narrators'] as List<dynamic>? ?? [])
          .map((n) => (n as Map<String, dynamic>)['name'] ?? '').join(', ');
      final rating = details['rating'] as Map<String, dynamic>?;

      final updated = <String, dynamic>{
        'asin': asin,
        'title': details['title'] ?? '',
        'subtitle': details['subtitle'] ?? '',
        'authors': authors,
        'narrators': narrators,
        'releaseDate': details['release_date'] ?? '',
        'runtimeMinutes': details['runtime_length_min'] ?? 0,
        'rating': rating?['overall_distribution']?['display_average_rating'] ?? 0.0,
        'numRatings': rating?['overall_distribution']?['num_ratings'] ?? 0,
        'coverUrl': details['product_images']?['500'] ?? details['product_images']?['1024'] ?? '',
        'sequence': '',
        'sort': '0',
        'publisherSummary': details['publisher_summary'] ?? '',
      };

      // Update in results (check both upcoming and recent lists)
      for (final result in _results) {
        for (var i = 0; i < result.upcomingBooks.length; i++) {
          if (result.upcomingBooks[i]['asin'] == asin) {
            updated['sequence'] = result.upcomingBooks[i]['sequence'] ?? '';
            updated['sort'] = result.upcomingBooks[i]['sort'] ?? '0';
            updated['allAsins'] = result.upcomingBooks[i]['allAsins'] ?? <String>[asin];

            if (_isUpcoming(updated)) {
              result.upcomingBooks[i] = updated;
            } else {
              result.upcomingBooks.removeAt(i);
            }
            break;
          }
        }
        for (var i = 0; i < result.recentBooks.length; i++) {
          if (result.recentBooks[i]['asin'] == asin) {
            updated['sequence'] = result.recentBooks[i]['sequence'] ?? '';
            updated['sort'] = result.recentBooks[i]['sort'] ?? '0';
            updated['allAsins'] = result.recentBooks[i]['allAsins'] ?? <String>[asin];
            updated['_owned'] = result.recentBooks[i]['_owned'] ?? false;
            result.recentBooks[i] = updated;
            break;
          }
        }
      }

      // Remove empty series results
      _results.removeWhere((r) => r.upcomingBooks.isEmpty && r.recentBooks.isEmpty);
      notifyListeners();
      await _saveCache();
      return updated;
    } catch (e) {
      debugPrint('[Upcoming] rescanBook error: $e');
      return null;
    }
  }

  /// Try to find the Audible series ASIN from the books' metadata ASINs via Audnexus.
  Future<String?> _resolveSeriesAsin(List<dynamic> books, String seriesName, int gen) async {
    int booksWithAsin = 0;
    int audnexusAttempts = 0;
    for (final book in books) {
      if (_generation != gen) return null;
      if (book is! Map<String, dynamic>) continue;

      final media = book['media'] as Map<String, dynamic>? ?? {};
      final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
      final bookAsin = metadata['asin'] as String? ?? '';
      if (bookAsin.isEmpty) continue;
      booksWithAsin++;
      audnexusAttempts++;

      for (var attempt = 0; attempt < 3; attempt++) {
        if (_generation != gen) return null;
        try {
          final audnexus = await ApiService.getAudnexusBook(bookAsin, region: _region);
          if (_generation != gen) return null;
          if (audnexus == null) {
            debugPrint('[Upcoming]   $seriesName: Audnexus returned null for ASIN=$bookAsin');
            break; // null response means the book isn't on Audnexus, no point retrying
          }

          final primary = audnexus['seriesPrimary'] as Map<String, dynamic>?;
          if (primary != null && primary['asin'] != null) {
            debugPrint('[Upcoming]   $seriesName: found via seriesPrimary from book ASIN=$bookAsin');
            return primary['asin'] as String;
          }
          final secondary = audnexus['seriesSecondary'] as Map<String, dynamic>?;
          if (secondary != null && secondary['asin'] != null) {
            debugPrint('[Upcoming]   $seriesName: found via seriesSecondary from book ASIN=$bookAsin');
            return secondary['asin'] as String;
          }
          debugPrint('[Upcoming]   $seriesName: Audnexus has no series ASIN for book ASIN=$bookAsin');
          break; // got a valid response but no series info, no point retrying
        } catch (e) {
          debugPrint('[Upcoming]   $seriesName: Audnexus error for $bookAsin (attempt ${attempt + 1}/3): $e');
          if (attempt < 2) {
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }
    }
    debugPrint('[Upcoming]   $seriesName: no series ASIN found ($booksWithAsin books had ASINs, $audnexusAttempts checked)');
    return null;
  }

  bool _isUpcoming(Map<String, dynamic> book) {
    final dateStr = book['releaseDate'] as String? ?? '';
    if (dateStr.isEmpty) return false;
    final date = DateTime.tryParse(dateStr);
    if (date == null) return false;
    final now = DateTime.now();
    if (date.year > now.year + 5) return false;
    return date.isAfter(now);
  }

  /// Check if a book was released within the last 30 days.
  bool _isRecentRelease(Map<String, dynamic> book) {
    final dateStr = book['releaseDate'] as String? ?? '';
    if (dateStr.isEmpty) return false;
    final date = DateTime.tryParse(dateStr);
    if (date == null) return false;
    final now = DateTime.now();
    if (date.isAfter(now)) return false; // upcoming, not recent
    return now.difference(date).inDays <= 30;
  }

  static final _parenthetical = RegExp(r'\s*\([^)]*\)\s*');
  static final _nonAlphaNum = RegExp(r'[^a-z0-9 ]');
  static final _multiSpace = RegExp(r'\s+');

  String _normalizeTitle(String title) {
    return title
        .toLowerCase()
        .replaceAll(_parenthetical, ' ')
        .replaceAll(_nonAlphaNum, ' ')
        .replaceAll(_multiSpace, ' ')
        .trim();
  }

  /// Check if a discovered Audible book is owned in the library.
  bool _isOwnedBook(Map<String, dynamic> book, Set<String> ownedTitles, Set<String> ownedAsins) {
    final asin = book['asin'] as String? ?? '';
    if (ownedAsins.contains(asin)) return true;
    final allAsins = book['allAsins'] as List<dynamic>? ?? [];
    for (final a in allAsins) {
      if (ownedAsins.contains(a)) return true;
    }
    final title = _normalizeTitle(book['title'] as String? ?? '');
    if (title.isEmpty) return false;
    for (final owned in ownedTitles) {
      if (_normalizeTitle(owned) == title) return true;
    }
    return false;
  }

  /// Cancel the current scan.
  void cancel() {
    _generation++;
    _isRunning = false;
    _currentSeriesName = null;
    _cancelScanNotification();
    notifyListeners();
  }

  /// Set region (for cache loading before scan).
  void setRegion(String region) => _region = region;

  // ─── Notifications ───────────────────────────────────────────

  Future<void> _showScanNotification(String body) async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      final androidPlugin = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _notifChannelId,
            _notifChannelName,
            description: _notifChannelDesc,
            importance: Importance.low,
            showBadge: false,
          ),
        );
      }

      final progress = _totalSeries > 0 ? _processedCount : 0;
      final max = _totalSeries > 0 ? _totalSeries : 0;

      await plugin.show(
        _scanNotifId,
        'Scanning for upcoming releases',
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _notifChannelId,
            _notifChannelName,
            channelDescription: _notifChannelDesc,
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            showProgress: max > 0,
            maxProgress: max,
            progress: progress,
            icon: 'drawable/ic_notification',
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Upcoming] notification error: $e');
    }
  }

  Future<void> _cancelScanNotification() async {
    try {
      await FlutterLocalNotificationsPlugin().cancel(_scanNotifId);
    } catch (_) {}
  }

  Future<void> _showCompleteNotification() async {
    try {
      final totalBooks = _results.fold<int>(0, (sum, r) => sum + r.upcomingBooks.length);
      if (totalBooks == 0) return;

      final plugin = FlutterLocalNotificationsPlugin();
      final androidPlugin = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _notifChannelId,
            _notifChannelName,
            description: _notifChannelDesc,
            importance: Importance.defaultImportance,
          ),
        );
      }

      final seriesCount = _results.length;
      await plugin.show(
        _completeNotifId,
        'Upcoming releases found!',
        '$totalBooks upcoming across $seriesCount series',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _notifChannelId,
            _notifChannelName,
            channelDescription: _notifChannelDesc,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            icon: 'drawable/ic_notification',
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Upcoming] complete notification error: $e');
    }
  }
}
