import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Types of playback events we track.
enum PlaybackEventType {
  play,
  pause,
  seek,
  syncLocal,
  syncServer,
  autoRewind,
  skipForward,
  skipBackward,
  speedChange,
}

/// A single playback event entry.
class PlaybackEvent {
  final PlaybackEventType type;
  final double positionSeconds;
  final DateTime timestamp;
  final String? detail;

  PlaybackEvent({
    required this.type,
    required this.positionSeconds,
    required this.timestamp,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'pos': positionSeconds,
        'ts': timestamp.millisecondsSinceEpoch,
        if (detail != null) 'detail': detail,
      };

  factory PlaybackEvent.fromJson(Map<String, dynamic> json) {
    return PlaybackEvent(
      type: PlaybackEventType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => PlaybackEventType.play,
      ),
      positionSeconds: (json['pos'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int),
      detail: json['detail'] as String?,
    );
  }

  String get label {
    switch (type) {
      case PlaybackEventType.play:
        return 'Resumed playback';
      case PlaybackEventType.pause:
        return 'Paused';
      case PlaybackEventType.seek:
        return 'Seeked';
      case PlaybackEventType.syncLocal:
        return 'Saved locally';
      case PlaybackEventType.syncServer:
        return 'Synced to server';
      case PlaybackEventType.autoRewind:
        return 'Auto-rewound';
      case PlaybackEventType.skipForward:
        return 'Skipped forward';
      case PlaybackEventType.skipBackward:
        return 'Skipped back';
      case PlaybackEventType.speedChange:
        return 'Speed changed';
    }
  }

  String get icon {
    switch (type) {
      case PlaybackEventType.play:
        return '▶';
      case PlaybackEventType.pause:
        return '⏸';
      case PlaybackEventType.seek:
        return '⏩';
      case PlaybackEventType.syncLocal:
        return '💾';
      case PlaybackEventType.syncServer:
        return '☁';
      case PlaybackEventType.autoRewind:
        return '⏪';
      case PlaybackEventType.skipForward:
        return '⏭';
      case PlaybackEventType.skipBackward:
        return '⏮';
      case PlaybackEventType.speedChange:
        return '⚡';
    }
  }
}

/// Stores per-book playback history in SharedPreferences.
class PlaybackHistoryService {
  static final PlaybackHistoryService _instance = PlaybackHistoryService._();
  factory PlaybackHistoryService() => _instance;
  PlaybackHistoryService._();

  static const int _maxEventsPerBook = 200;

  /// Log an event for a book.
  Future<void> log({
    required String itemId,
    required PlaybackEventType type,
    required double positionSeconds,
    String? detail,
  }) async {
    final event = PlaybackEvent(
      type: type,
      positionSeconds: positionSeconds,
      timestamp: DateTime.now(),
      detail: detail,
    );

    final prefs = await SharedPreferences.getInstance();
    final key = 'playback_history_$itemId';
    final existing = prefs.getStringList(key) ?? [];

    existing.add(jsonEncode(event.toJson()));

    // Trim to max size (keep most recent)
    if (existing.length > _maxEventsPerBook) {
      existing.removeRange(0, existing.length - _maxEventsPerBook);
    }

    await prefs.setStringList(key, existing);
  }

  /// Get all events for a book, newest first.
  Future<List<PlaybackEvent>> getHistory(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'playback_history_$itemId';
    final stored = prefs.getStringList(key) ?? [];

    final events = <PlaybackEvent>[];
    for (final json in stored) {
      try {
        events.add(PlaybackEvent.fromJson(jsonDecode(json)));
      } catch (e) {
        debugPrint('[History] Failed to parse event: $e');
      }
    }

    return events.reversed.toList(); // newest first
  }

  /// Clear history for a book.
  Future<void> clearHistory(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('playback_history_$itemId');
  }
}
