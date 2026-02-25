import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/scoped_prefs.dart';
import 'auth_provider.dart';
import '../services/api_service.dart';
import '../services/progress_sync_service.dart';
import '../services/download_service.dart';
import '../services/android_auto_service.dart';

/// Holds library data and personalized home sections.
class LibraryProvider extends ChangeNotifier {
  AuthProvider? _auth;
  ApiService? get _api => _auth?.apiService;

  // State
  List<dynamic> _libraries = [];
  String? _selectedLibraryId;
  List<dynamic> _personalizedSections = [];
  List<dynamic> _series = [];
  bool _isLoading = false;
  bool _isLoadingSeries = false;
  String? _errorMessage;

  // Offline mode
  bool _manualOffline = false;
  bool _networkOffline = false;
  bool get isOffline => _manualOffline || _networkOffline;
  bool get isManualOffline => _manualOffline;

  /// Toggle manual offline mode.
  Future<void> setManualOffline(bool value) async {
    debugPrint('[Library] setManualOffline($value)');
    _manualOffline = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('manual_offline_mode', value);
    if (!value && !_networkOffline) {
      // Going back online — flush pending syncs and refresh
      if (_api != null) {
        debugPrint('[Library] Manual offline off — flushing pending syncs');
        ProgressSyncService().flushPendingSync(api: _api!);
      }
      refresh();
    } else {
      // Going offline — show downloaded books
      _buildOfflineSections();
    }
    notifyListeners();
  }

  /// Called on init to restore manual offline preference.
  Future<void> restoreOfflineMode() async {
    final prefs = await SharedPreferences.getInstance();
    _manualOffline = prefs.getBool('manual_offline_mode') ?? false;
  }

  /// Called when network connectivity changes.
  void setNetworkOffline(bool offline) {
    final wasOffline = _networkOffline;
    _networkOffline = offline;
    if (offline && !wasOffline) {
      // Just went offline — show downloads, and force AA to clear server tabs
      _buildOfflineSections();
      notifyListeners();
      AndroidAutoService().refresh(force: true);
    } else if (!offline && wasOffline && !_manualOffline) {
      // Came back online — immediately flush pending syncs, then refresh
      if (_api != null) {
        debugPrint('[Library] Back online — flushing pending syncs');
        ProgressSyncService().flushPendingSync(api: _api!);
      }
      refresh();
      AndroidAutoService().refresh(force: true);
    }
  }

  /// Build home sections from downloaded books.
  void _buildOfflineSections() {
    final downloads = DownloadService().downloadedItems;
    debugPrint('[Library] Building offline sections: ${downloads.length} downloads');
    if (downloads.isEmpty) {
      _personalizedSections = [];
      _errorMessage = null;
      _isLoading = false;
      notifyListeners();
      return;
    }

    // Build fake entities from download metadata
    final entities = <Map<String, dynamic>>[];
    for (final dl in downloads) {
      // Try to extract duration from cached session data
      double duration = 0;
      List<dynamic> chapters = [];
      if (dl.sessionData != null) {
        try {
          final session = jsonDecode(dl.sessionData!) as Map<String, dynamic>;
          duration = (session['duration'] as num?)?.toDouble() ?? 0;
          chapters = session['chapters'] as List<dynamic>? ?? [];
        } catch (_) {}
      }

      entities.add({
        'id': dl.itemId,
        'media': {
          'metadata': {
            'title': dl.title ?? 'Unknown Title',
            'authorName': dl.author ?? '',
          },
          'duration': duration,
          'chapters': chapters,
        },
      });
    }

    _personalizedSections = [
      {
        'id': 'downloaded-books',
        'label': 'Downloaded Books',
        'type': 'book',
        'entities': entities,
      },
    ];
    _errorMessage = null;
    _isLoading = false;
  }

  // User's media progress, keyed by libraryItemId
  Map<String, Map<String, dynamic>> _progressMap = {};

  // Getters
  List<dynamic> get libraries => _libraries;
  String? get selectedLibraryId => _selectedLibraryId;
  List<dynamic> get personalizedSections => _personalizedSections;
  List<dynamic> get series => _series;
  bool get isLoading => _isLoading;
  bool get isLoadingSeries => _isLoadingSeries;
  String? get errorMessage => _errorMessage;

  /// Get progress (0.0–1.0) for a library item by ID.
  /// Checks local progress first (freshest), falls back to server data.
  double getProgress(String? itemId) {
    if (itemId == null) return 0;
    // If item was reset this session, always return 0
    if (_resetItems.contains(itemId)) return 0;
    // Check local override first
    final local = _localProgressOverrides[itemId];
    if (local != null) return local;
    // Fall back to server data
    final mp = _progressMap[itemId];
    if (mp == null) return 0;
    return (mp['progress'] as num?)?.toDouble() ?? 0;
  }

  /// Get the raw progress data map for an item (includes isFinished, currentTime, etc.)
  Map<String, dynamic>? getProgressData(String? itemId) {
    if (itemId == null) return null;
    if (_resetItems.contains(itemId)) return null;
    return _progressMap[itemId];
  }

  /// Count of books marked as finished in the progress map.
  int get finishedCount => _progressMap.values
      .where((p) => p['isFinished'] == true)
      .length;

  // Local progress overrides (from ProgressSyncService)
  final Map<String, double> _localProgressOverrides = {};
  // Items that have been reset — force progress to 0 until app restart
  final Set<String> _resetItems = {};

  /// Merge local progress into the display. Call after playback.
  Future<void> refreshLocalProgress() async {
    final sync = ProgressSyncService();
    // Check both server-known items and downloaded items
    final itemIds = <String>{..._progressMap.keys};
    for (final dl in DownloadService().downloadedItems) {
      itemIds.add(dl.itemId);
    }
    for (final itemId in itemIds) {
      final data = await sync.getLocal(itemId);
      if (data != null) {
        final currentTime = (data['currentTime'] as num?)?.toDouble() ?? 0;
        final duration = (data['duration'] as num?)?.toDouble() ?? 0;
        if (duration > 0) {
          _localProgressOverrides[itemId] = (currentTime / duration).clamp(0.0, 1.0);
          // If item was reset but is now being played, clear the reset flag
          if (currentTime > 0) _resetItems.remove(itemId);
        }
      }
    }
    notifyListeners();
  }

  /// Clear all local progress caches for an item (used after mark finished/not finished).
  void clearProgressFor(String itemId) {
    _progressMap.remove(itemId);
    _localProgressOverrides.remove(itemId);
    notifyListeners();
  }

  /// Clear progress AND mark as reset — forces 0 progress until playback resumes.
  void resetProgressFor(String itemId) {
    _progressMap.remove(itemId);
    _localProgressOverrides.remove(itemId);
    _resetItems.add(itemId);
    notifyListeners();
  }

  Map<String, dynamic>? get selectedLibrary {
    if (_selectedLibraryId == null) return null;
    try {
      return _libraries.firstWhere(
        (l) => l['id'] == _selectedLibraryId,
      ) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  StreamSubscription? _connectivitySub;

  /// Called by ProxyProvider when auth changes.
  String? _lastAuthKey; // Guard against redundant updateAuth from ProxyProvider

  void updateAuth(AuthProvider auth) {
    final wasAuthenticated = _auth?.isAuthenticated ?? false;
    final previousUserId = _auth?.userId;
    _auth = auth;

    if (auth.isAuthenticated) {
      final isNewUser = previousUserId != null && previousUserId != auth.userId;
      final isFreshLogin = !wasAuthenticated;

      // Build a key to detect duplicate calls from ProxyProvider re-triggering
      final authKey = '${auth.userId}@${auth.serverUrl}';
      final isDuplicate = authKey == _lastAuthKey && !isNewUser && !isFreshLogin;
      _lastAuthKey = authKey;

      if (isDuplicate) return; // Skip redundant update

      if (isNewUser || isFreshLogin) {
        _libraries = [];
        _personalizedSections = [];
        _series = [];
        _progressMap = {};
        _localProgressOverrides.clear();
        _resetItems.clear();
        _manualAbsorbAdds.clear();
        _manualAbsorbRemoves.clear();
        _isLoading = true;
        notifyListeners(); // Immediately clear old user's data from UI
      }

      // Restore manual offline preference and start connectivity monitoring
      // Must complete before loading libraries so offline state is correct
      restoreOfflineMode().then((_) {
        _startConnectivityMonitoring();
        _loadManualAbsorbing();

        // If server was unreachable on startup, force offline mode
        if (!auth.serverReachable) {
          _networkOffline = true;
          _buildOfflineSections();
          _isLoading = false;
          notifyListeners();
          return;
        }

        _buildProgressMap(auth);
        if (_api != null && !isOffline) {
          ProgressSyncService().flushPendingSync(api: _api!);
          DownloadService().enrichMetadata(_api!);
        }
        loadLibraries();
      });
    } else {
      _lastAuthKey = null;
      _libraries = [];
      _personalizedSections = [];
      _series = [];
      _progressMap = {};
      _localProgressOverrides.clear();
      _selectedLibraryId = null;
      _errorMessage = null;
      _connectivitySub?.cancel();
      notifyListeners();
    }
  }

  void _startConnectivityMonitoring() {
    _connectivitySub?.cancel();
    // Check current state immediately
    Connectivity().checkConnectivity().then((result) {
      final offline = result.contains(ConnectivityResult.none);
      if (offline) setNetworkOffline(true);
    });
    // Then listen for changes
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final offline = result.contains(ConnectivityResult.none);
      setNetworkOffline(offline);
    });
  }

  void _buildProgressMap(AuthProvider auth) {
    _progressMap = {};
    final userJson = auth.userJson;
    if (userJson == null) return;
    final progressList = userJson['mediaProgress'] as List<dynamic>?;
    if (progressList == null) return;
    for (final mp in progressList) {
      if (mp is Map<String, dynamic>) {
        final itemId = mp['libraryItemId'] as String?;
        if (itemId != null) {
          _progressMap[itemId] = mp;
        }
      }
    }
  }

  /// Fetch all libraries and auto-select the default.
  Future<void> loadLibraries() async {
    if (_api == null) return;

    if (isOffline) {
      _buildOfflineSections();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _libraries = await _api!.getLibraries();

      if (_libraries.isNotEmpty) {
        // Prefer the user's default library, otherwise pick the first book library
        final bookLibraries = _libraries.where(
            (l) => (l['mediaType'] as String? ?? 'book') != 'podcast').toList();
        final defaultId = _auth?.defaultLibraryId;
        if (defaultId != null && bookLibraries.any((l) => l['id'] == defaultId)) {
          _selectedLibraryId = defaultId;
        } else if (bookLibraries.isNotEmpty) {
          _selectedLibraryId = bookLibraries.first['id'];
        } else {
          _selectedLibraryId = _libraries.first['id'];
        }
        await loadPersonalizedView();
      }
    } catch (e) {
      // Network error — auto-switch to offline view
      _networkOffline = true;
      _buildOfflineSections();
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Change the selected library and reload data.
  Future<void> selectLibrary(String libraryId) async {
    _selectedLibraryId = libraryId;
    _series = [];
    notifyListeners();
    await loadPersonalizedView();
  }

  /// Fetch personalized home sections for the selected library.
  Future<void> loadPersonalizedView() async {
    if (_api == null || _selectedLibraryId == null) return;

    if (isOffline) {
      _buildOfflineSections();
      return;
    }

    // Only show loading spinner if we have NO existing data.
    // If we already have sections, do a silent background refresh.
    final hadData = _personalizedSections.isNotEmpty;
    if (!hadData) {
      _isLoading = true;
      notifyListeners();
    }

    try {
      await _refreshProgress();
      _personalizedSections =
          await _api!.getPersonalizedView(_selectedLibraryId!);
    } catch (e) {
      // Network error — auto-switch to offline view
      _networkOffline = true;
      _buildOfflineSections();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _refreshProgress() async {
    if (_api == null) return;
    try {
      final me = await _api!.getMe();
      if (me != null) {
        final progressList = me['mediaProgress'] as List<dynamic>?;
        if (progressList != null) {
          _progressMap = {};
          for (final mp in progressList) {
            if (mp is Map<String, dynamic>) {
              final itemId = mp['libraryItemId'] as String?;
              if (itemId != null) {
                _progressMap[itemId] = mp;
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Refresh data (pull-to-refresh).
  Future<void> refresh() async {
    if (isOffline) {
      _buildOfflineSections();
      notifyListeners();
      return;
    }
    // Flush local progress to server first, then pull fresh data
    if (_api != null) {
      await ProgressSyncService().flushPendingSync(api: _api!);
    }
    await Future.wait([
      loadPersonalizedView(),
      _refreshProgress(),
    ]);
    // Clear stale local overrides — server data is now authoritative
    _localProgressOverrides.clear();
    // Update local SharedPreferences from fresh server data so they stay in sync
    final sync = ProgressSyncService();
    for (final entry in _progressMap.entries) {
      final itemId = entry.key;
      final mp = entry.value;
      final currentTime = (mp['currentTime'] as num?)?.toDouble() ?? 0;
      final duration = (mp['duration'] as num?)?.toDouble() ?? 0;
      if (duration > 0 && currentTime > 0) {
        await sync.saveLocal(
          itemId: itemId,
          currentTime: currentTime,
          duration: duration,
          speed: 1.0,
        );
      }
    }
    // Clear pending syncs since we just pulled fresh server data
    await ScopedPrefs.setStringList('pending_syncs', []);
    notifyListeners();
  }

  /// Fetch series for the selected library.
  Future<void> loadSeries({String sort = 'addedAt', int desc = 1}) async {
    if (_api == null || _selectedLibraryId == null) return;

    _isLoadingSeries = true;
    notifyListeners();

    try {
      final result = await _api!.getLibrarySeries(
        _selectedLibraryId!,
        sort: sort,
        desc: desc,
      );
      if (result != null) {
        _series = (result['results'] as List<dynamic>?) ?? [];
      }
    } catch (e) {
      // ignore
    }

    _isLoadingSeries = false;
    notifyListeners();
  }

  /// Build a cover URL for an item.
  String? getCoverUrl(String? itemId) {
    if (itemId == null) return null;
    // Try API first
    if (_api != null) {
      return _api!.getCoverUrl(itemId);
    }
    // Fallback: check download info for cached cover URL
    final dl = DownloadService().getInfo(itemId);
    return dl.coverUrl;
  }

  /// Headers needed for authenticated media requests (covers, audio).
  /// Returns empty map if no API is available.
  Map<String, String> get mediaHeaders => _api?.mediaHeaders ?? {};

  // ── Manual Absorbing List ──

  Set<String> _manualAbsorbAdds = {};
  Set<String> _manualAbsorbRemoves = {};

  Set<String> get manualAbsorbAdds => _manualAbsorbAdds;
  Set<String> get manualAbsorbRemoves => _manualAbsorbRemoves;

  Future<void> _loadManualAbsorbing() async {
    _manualAbsorbAdds = (await ScopedPrefs.getStringList('absorbing_manual_adds')).toSet();
    _manualAbsorbRemoves = (await ScopedPrefs.getStringList('absorbing_manual_removes')).toSet();
  }

  Future<void> _saveManualAbsorbing() async {
    await ScopedPrefs.setStringList('absorbing_manual_adds', _manualAbsorbAdds.toList());
    await ScopedPrefs.setStringList('absorbing_manual_removes', _manualAbsorbRemoves.toList());
  }

  /// Add a book to the absorbing list manually.
  Future<void> addToAbsorbing(String itemId) async {
    _manualAbsorbAdds.add(itemId);
    _manualAbsorbRemoves.remove(itemId);
    await _saveManualAbsorbing();
    notifyListeners();
  }

  /// Remove a book from the absorbing list manually.
  Future<void> removeFromAbsorbing(String itemId) async {
    _manualAbsorbRemoves.add(itemId);
    _manualAbsorbAdds.remove(itemId);
    await _saveManualAbsorbing();
    notifyListeners();
  }

  /// Check if a book is manually added or on the absorbing page.
  bool isOnAbsorbingList(String itemId) {
    if (_manualAbsorbRemoves.contains(itemId)) return false;
    if (_manualAbsorbAdds.contains(itemId)) return true;
    // Check if it's in the server sections
    for (final section in _personalizedSections) {
      final id = section['id'] as String? ?? '';
      if (id == 'continue-listening' || id == 'continue-series' || id == 'downloaded-books') {
        for (final e in (section['entities'] as List<dynamic>? ?? [])) {
          if (e is Map<String, dynamic> && e['id'] == itemId) return true;
        }
      }
    }
    return false;
  }
}
