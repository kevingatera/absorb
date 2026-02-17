import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'api_service.dart';

/// Manages local progress storage and server sync.
/// Progress is ALWAYS saved locally first, then synced to server when online.
class ProgressSyncService {
  static final ProgressSyncService _instance = ProgressSyncService._();
  factory ProgressSyncService() => _instance;
  ProgressSyncService._();

  StreamSubscription? _connectivitySub;
  bool _isOnline = true;

  /// Initialize — start listening for connectivity changes.
  Future<void> init() async {
    // Check initial state
    final result = await Connectivity().checkConnectivity();
    _isOnline = !result.contains(ConnectivityResult.none);

    // Listen for changes
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final wasOffline = !_isOnline;
      _isOnline = !result.contains(ConnectivityResult.none);
      if (_isOnline && wasOffline) {
        debugPrint('[Sync] Back online — flushing pending syncs');
        flushPendingSync();
      }
    });
  }

  bool get isOnline => _isOnline;

  /// Save progress locally. Always succeeds.
  Future<void> saveLocal({
    required String itemId,
    required double currentTime,
    required double duration,
    required double speed,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Save current position
    final data = {
      'itemId': itemId,
      'currentTime': currentTime,
      'duration': duration,
      'speed': speed,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString('progress_$itemId', jsonEncode(data));

    // Also mark as pending server sync
    final pendingList = prefs.getStringList('pending_syncs') ?? [];
    if (!pendingList.contains(itemId)) {
      pendingList.add(itemId);
      await prefs.setStringList('pending_syncs', pendingList);
    }
  }

  /// Get locally saved progress for an item.
  Future<Map<String, dynamic>?> getLocal(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('progress_$itemId');
    if (json == null) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Get the saved currentTime for an item (for resuming).
  Future<double> getSavedPosition(String itemId) async {
    final data = await getLocal(itemId);
    return (data?['currentTime'] as num?)?.toDouble() ?? 0;
  }

  /// Delete locally saved progress for an item.
  Future<void> deleteLocal(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('progress_$itemId');
    final pendingList = prefs.getStringList('pending_syncs') ?? [];
    pendingList.remove(itemId);
    await prefs.setStringList('pending_syncs', pendingList);
  }

  /// Sync a single item to the server. Returns true if synced.
  Future<bool> syncToServer({
    required ApiService api,
    required String itemId,
    String? sessionId,
  }) async {
    if (!_isOnline) {
      debugPrint('[Sync] Skipped — offline');
      return false;
    }

    final data = await getLocal(itemId);
    if (data == null) {
      debugPrint('[Sync] Skipped — no local data for $itemId');
      return false;
    }

    final currentTime = (data['currentTime'] as num?)?.toDouble() ?? 0;
    final duration = (data['duration'] as num?)?.toDouble() ?? 0;
    debugPrint('[Sync] Syncing $itemId: currentTime=$currentTime, duration=$duration, sessionId=$sessionId');

    try {
      if (sessionId != null) {
        // Sync via active session
        await api.syncPlaybackSession(
          sessionId,
          currentTime: currentTime,
          duration: duration,
        );
      } else {
        // Sync via media progress update endpoint
        await api.updateProgress(
          itemId,
          currentTime: currentTime,
          duration: duration,
        );
      }

      // Remove from pending
      final prefs = await SharedPreferences.getInstance();
      final pendingList = prefs.getStringList('pending_syncs') ?? [];
      pendingList.remove(itemId);
      await prefs.setStringList('pending_syncs', pendingList);

      debugPrint('[Sync] Synced $itemId: ${currentTime}s');
      return true;
    } catch (e) {
      debugPrint('[Sync] Failed for $itemId: $e');
      return false;
    }
  }

  /// Flush all pending syncs (call when coming back online).
  /// Uses session-based sync for reliability since PATCH doesn't always work.
  Future<void> flushPendingSync({ApiService? api}) async {
    if (!_isOnline || api == null) return;

    final prefs = await SharedPreferences.getInstance();
    final pendingList = List<String>.from(
        prefs.getStringList('pending_syncs') ?? []);

    if (pendingList.isEmpty) return;
    debugPrint('[Sync] Flushing ${pendingList.length} pending syncs');

    for (final itemId in pendingList) {
      final data = await getLocal(itemId);
      if (data == null) continue;

      final currentTime = (data['currentTime'] as num?)?.toDouble() ?? 0;
      final duration = (data['duration'] as num?)?.toDouble() ?? 0;
      if (currentTime <= 0) continue;

      try {
        // Start a temp session, sync, then close — most reliable method
        final session = await api.startPlaybackSession(itemId);
        if (session != null) {
          final sessionId = session['id'] as String?;
          if (sessionId != null) {
            await api.syncPlaybackSession(
              sessionId,
              currentTime: currentTime,
              duration: duration,
            );
            await api.closePlaybackSession(sessionId);
            debugPrint('[Sync] Flushed $itemId via session: ${currentTime}s');
          }
        }

        // Remove from pending
        final updated = prefs.getStringList('pending_syncs') ?? [];
        updated.remove(itemId);
        await prefs.setStringList('pending_syncs', updated);
      } catch (e) {
        debugPrint('[Sync] Flush failed for $itemId: $e');
      }
    }
  }

  void dispose() {
    _connectivitySub?.cancel();
  }
}
