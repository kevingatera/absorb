import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'audio_player_service.dart';
import 'download_notification_service.dart';

enum DownloadStatus { none, downloading, downloaded, error }

class DownloadInfo {
  final String itemId;
  final DownloadStatus status;
  final double progress;
  final List<String> localPaths;
  final String? sessionData;
  // Metadata for offline display
  final String? title;
  final String? author;
  final String? coverUrl;

  DownloadInfo({
    required this.itemId,
    this.status = DownloadStatus.none,
    this.progress = 0,
    this.localPaths = const [],
    this.sessionData,
    this.title,
    this.author,
    this.coverUrl,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'status': status.index,
        'localPaths': localPaths,
        'sessionData': sessionData,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
      };

  factory DownloadInfo.fromJson(Map<String, dynamic> json) {
    String? title = json['title'] as String?;
    String? author = json['author'] as String?;
    String? coverUrl = json['coverUrl'] as String?;

    // Fallback: extract metadata from cached sessionData for old downloads
    if ((title == null || title.isEmpty) && json['sessionData'] != null) {
      try {
        final session = jsonDecode(json['sessionData'] as String) as Map<String, dynamic>;
        // Try session-level metadata first
        final sessionMeta = session['mediaMetadata'] as Map<String, dynamic>?;
        if (sessionMeta != null) {
          title ??= sessionMeta['title'] as String?;
          author ??= sessionMeta['authorName'] as String?;
        }
        // Try libraryItem path
        if (title == null || title.isEmpty) {
          final libItem = session['libraryItem'] as Map<String, dynamic>? ?? {};
          final media = libItem['media'] as Map<String, dynamic>? ?? {};
          final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
          title ??= metadata['title'] as String?;
          author ??= metadata['authorName'] as String?;
        }
        // Try direct displayTitle/displayAuthor
        title ??= session['displayTitle'] as String?;
        author ??= session['displayAuthor'] as String?;
      } catch (_) {}
    }

    return DownloadInfo(
      itemId: json['itemId'] as String,
      status: DownloadStatus.values[json['status'] as int? ?? 0],
      localPaths: (json['localPaths'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      sessionData: json['sessionData'] as String?,
      title: title,
      author: author,
      coverUrl: coverUrl,
    );
  }
}

class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._();

  final Map<String, DownloadInfo> _downloads = {};
  String? _activeDownloadId;
  http.Client? _httpClient;
  String? _customDownloadPath;

  /// The current download directory path, or null if using default.
  String? get customDownloadPath => _customDownloadPath;

  /// Get the effective download base directory.
  Future<String> get downloadBasePath async {
    if (_customDownloadPath != null && _customDownloadPath!.isNotEmpty) {
      return _customDownloadPath!;
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/downloads';
  }

  /// Set a custom download location. Pass null to revert to default.
  Future<void> setCustomDownloadPath(String? path) async {
    _customDownloadPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path != null && path.isNotEmpty) {
      await prefs.setString('custom_download_path', path);
    } else {
      await prefs.remove('custom_download_path');
    }
    notifyListeners();
  }

  /// Get a human-readable label for the current download location.
  Future<String> get downloadLocationLabel async {
    if (_customDownloadPath != null && _customDownloadPath!.isNotEmpty) {
      // Shorten the path for display
      final path = _customDownloadPath!;
      // Try to show a friendly path relative to common roots
      if (path.contains('/emulated/0/')) {
        return path.split('/emulated/0/').last;
      }
      if (path.contains('/storage/')) {
        return path.split('/storage/').last;
      }
      // Last two segments
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) {
        return '${segments[segments.length - 2]}/${segments.last}';
      }
      return path;
    }
    return 'App Internal Storage (Default)';
  }

  /// Calculate total size of all downloaded files.
  Future<int> get totalDownloadSize async {
    int total = 0;
    for (final info in _downloads.values) {
      if (info.status == DownloadStatus.downloaded) {
        for (final path in info.localPaths) {
          try {
            final file = File(path);
            if (file.existsSync()) {
              total += file.lengthSync();
            }
          } catch (_) {}
        }
      }
    }
    return total;
  }

  DownloadInfo getInfo(String itemId) =>
      _downloads[itemId] ?? DownloadInfo(itemId: itemId);

  bool isDownloaded(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.downloaded;

  bool isDownloading(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.downloading;

  double downloadProgress(String itemId) =>
      _downloads[itemId]?.progress ?? 0;

  /// Get all downloaded items (for home screen display).
  List<DownloadInfo> get downloadedItems =>
      _downloads.values
          .where((d) => d.status == DownloadStatus.downloaded)
          .toList();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _customDownloadPath = prefs.getString('custom_download_path');
    final json = prefs.getString('downloads');
    if (json != null) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final info =
              DownloadInfo.fromJson(entry.value as Map<String, dynamic>);
          debugPrint('[Download] Loaded: ${entry.key} '
              'title="${info.title}" author="${info.author}" '
              'cover=${info.coverUrl != null ? "yes" : "null"} '
              'sessionData=${info.sessionData != null ? "${info.sessionData!.length} chars" : "null"}');
          if (info.status == DownloadStatus.downloaded) {
            bool allExist = true;
            for (final path in info.localPaths) {
              if (!File(path).existsSync()) {
                allExist = false;
                break;
              }
            }
            if (allExist) {
              _downloads[entry.key] = info;
            }
          }
        }
      } catch (e) {
        debugPrint('[Download] Init error: $e');
      }
    }
    // Re-save to persist any metadata extracted from sessionData
    if (_downloads.isNotEmpty) await _save();
    notifyListeners();
  }

  /// Try to fill in missing metadata from the API (for old downloads).
  Future<void> enrichMetadata(ApiService api) async {
    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);
    for (final entry in entries.entries) {
      final info = entry.value;
      if (info.status == DownloadStatus.downloaded &&
          (info.title == null || info.title!.isEmpty)) {
        try {
          final item = await api.getLibraryItem(info.itemId);
          if (item != null) {
            final media = item['media'] as Map<String, dynamic>? ?? {};
            final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
            final title = metadata['title'] as String?;
            final author = metadata['authorName'] as String?;
            final coverUrl = api.getCoverUrl(info.itemId);
            _downloads[entry.key] = DownloadInfo(
              itemId: info.itemId,
              status: info.status,
              localPaths: info.localPaths,
              sessionData: info.sessionData,
              title: title ?? info.title,
              author: author ?? info.author,
              coverUrl: coverUrl ?? info.coverUrl,
            );
            changed = true;
            debugPrint('[Download] Enriched metadata for ${info.itemId}: $title');
          }
        } catch (e) {
          debugPrint('[Download] Enrich failed for ${info.itemId}: $e');
        }
      }
    }
    if (changed) {
      await _save();
      notifyListeners();
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final entry in _downloads.entries) {
      if (entry.value.status == DownloadStatus.downloaded) {
        map[entry.key] = entry.value.toJson();
      }
    }
    await prefs.setString('downloads', jsonEncode(map));
  }

  List<String>? getLocalPaths(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return null;
    return info.localPaths;
  }

  String? getCachedSessionData(String itemId) {
    return _downloads[itemId]?.sessionData;
  }

  /// Returns null on success, error message string on failure.
  Future<String?> downloadItem({
    required ApiService api,
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
  }) async {
    if (_activeDownloadId == itemId) return null;
    if (isDownloaded(itemId)) return null;

    // Check wifi-only setting
    final wifiOnly = await PlayerSettings.getWifiOnlyDownloads();
    if (wifiOnly) {
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) {
        return 'Downloads are set to Wi-Fi only. Connect to Wi-Fi or change this in Settings.';
      }
    }

    _activeDownloadId = itemId;
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloading,
      progress: 0,
      title: title,
      author: author,
      coverUrl: coverUrl,
    );
    notifyListeners();

    // Show persistent download notification
    final notif = DownloadNotificationService();
    await notif.showProgress(title: title, author: author, progress: 0);

    try {
      final sessionData = await api.startPlaybackSession(itemId);
      if (sessionData == null) throw Exception('Failed to start session');

      final audioTracks = sessionData['audioTracks'] as List<dynamic>?;
      if (audioTracks == null || audioTracks.isEmpty) {
        throw Exception('No audio tracks');
      }

      final basePath = await downloadBasePath;
      final bookDir = Directory('$basePath/$itemId');
      if (!bookDir.existsSync()) {
        bookDir.createSync(recursive: true);
      }

      final localPaths = List<String?>.filled(audioTracks.length, null);
      _httpClient = http.Client();

      // Track progress per-track for overall calculation
      final trackProgress = List<double>.filled(audioTracks.length, 0.0);
      int _lastNotifPercent = -1;
      DateTime _lastUIUpdate = DateTime.now();

      void _updateProgress() {
        final overall = trackProgress.reduce((a, b) => a + b) / audioTracks.length;
        final now = DateTime.now();
        // Throttle UI updates to max ~4/sec
        if (now.difference(_lastUIUpdate).inMilliseconds > 250) {
          _lastUIUpdate = now;
          _downloads[itemId] = DownloadInfo(
            itemId: itemId,
            status: DownloadStatus.downloading,
            progress: overall,
            title: title,
            author: author,
            coverUrl: coverUrl,
          );
          notifyListeners();
        }
        // Throttle notification to every 2%
        final pct = (overall * 50).round();
        if (pct != _lastNotifPercent) {
          _lastNotifPercent = pct;
          notif.showProgress(title: title, author: author, progress: overall);
        }
      }

      Future<void> _downloadTrack(int i) async {
        final track = audioTracks[i] as Map<String, dynamic>;
        final contentUrl = track['contentUrl'] as String? ?? '';
        final fullUrl = api.buildTrackUrl(contentUrl);

        final mimeType = track['mimeType'] as String? ?? 'audio/mpeg';
        final ext = mimeType.contains('mp4')
            ? 'm4a'
            : mimeType.contains('flac')
                ? 'flac'
                : mimeType.contains('ogg')
                    ? 'ogg'
                    : 'mp3';

        final filePath =
            '${bookDir.path}/track_${i.toString().padLeft(3, '0')}.$ext';
        final file = File(filePath);

        debugPrint('[Download] Track ${i + 1}/${audioTracks.length}: $fullUrl');

        final request = http.Request('GET', Uri.parse(fullUrl));
        final response = await _httpClient!.send(request);

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode} for track ${i + 1}');
        }

        final totalBytes = response.contentLength ?? -1;
        int receivedBytes = 0;
        final sink = file.openWrite();

        await for (final chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          trackProgress[i] = totalBytes > 0 ? receivedBytes / totalBytes : 0.5;
          _updateProgress();
        }

        await sink.close();
        localPaths[i] = filePath;
      }

      // Download tracks in parallel batches of 3
      const concurrency = 3;
      for (int batch = 0; batch < audioTracks.length; batch += concurrency) {
        final end = (batch + concurrency).clamp(0, audioTracks.length);
        await Future.wait([
          for (int i = batch; i < end; i++) _downloadTrack(i),
        ]);
      }

      // Final UI update
      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.downloading,
        progress: 1.0,
        title: title,
        author: author,
        coverUrl: coverUrl,
      );
      notifyListeners();

      final completedPaths = localPaths.whereType<String>().toList();

      final sessionId = sessionData['id'] as String?;
      if (sessionId != null) {
        try {
          await api.closePlaybackSession(sessionId);
        } catch (_) {}
      }

      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.downloaded,
        localPaths: completedPaths,
        sessionData: jsonEncode(sessionData),
        title: title,
        author: author,
        coverUrl: coverUrl,
      );
      await _save();

      // Show completion notification
      await notif.showComplete(title: title);

      // If this book is currently streaming, hot-swap to local files
      final player = AudioPlayerService();
      if (player.currentItemId == itemId && player.hasBook) {
        await player.switchToLocal(itemId);
      }

      debugPrint('[Download] Complete: $title (${completedPaths.length} files)');
    } catch (e) {
      debugPrint('[Download] Error: $e');
      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.error,
        title: title,
        author: author,
        coverUrl: coverUrl,
      );
      // Show error notification
      await notif.showError(title: title, message: 'Download failed: $title');
    }

    _activeDownloadId = null;
    _httpClient = null;
    notifyListeners();
    return null;
  }

  Future<void> deleteDownload(String itemId) async {
    final info = _downloads[itemId];
    if (info == null) return;

    for (final path in info.localPaths) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }

    try {
      final basePath = await downloadBasePath;
      final bookDir = Directory('$basePath/$itemId');
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    } catch (_) {}

    _downloads.remove(itemId);
    await _save();
    notifyListeners();
  }

  void cancelDownload(String itemId) {
    if (_activeDownloadId == itemId) {
      _httpClient?.close();
      _httpClient = null;
      _activeDownloadId = null;
      DownloadNotificationService().dismiss();
    }
    _downloads.remove(itemId);
    notifyListeners();
  }
}
