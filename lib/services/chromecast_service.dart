import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'api_service.dart';
import 'audio_player_service.dart';
import 'progress_sync_service.dart';

enum CastConnectionState { disconnected, connecting, connected }
enum CastPlaybackState { idle, loading, playing, paused, buffering }

class ChromecastService extends ChangeNotifier {
  static final ChromecastService _instance = ChromecastService._();
  factory ChromecastService() => _instance;
  ChromecastService._();

  CastConnectionState _connectionState = CastConnectionState.disconnected;
  CastPlaybackState _playbackState = CastPlaybackState.idle;

  CastConnectionState get connectionState => _connectionState;
  CastPlaybackState get playbackState => _playbackState;
  bool get isConnected => _connectionState == CastConnectionState.connected;
  bool get isCasting => isConnected && _playbackState != CastPlaybackState.idle;
  bool get isPlaying => _playbackState == CastPlaybackState.playing;

  String? _castingItemId, _castingTitle, _castingAuthor, _castingCoverUrl;
  double _castingDuration = 0;
  List<dynamic> _castingChapters = [];
  ApiService? _api;
  Duration _castPosition = Duration.zero;
  String? _connectedDeviceName;

  String? get castingItemId => _castingItemId;
  String? get castingTitle => _castingTitle;
  String? get castingAuthor => _castingAuthor;
  String? get castingCoverUrl => _castingCoverUrl;
  double get castingDuration => _castingDuration;
  List<dynamic> get castingChapters => _castingChapters;
  Duration get castPosition => _castPosition;
  String? get connectedDeviceName => _connectedDeviceName;

  StreamSubscription? _sessionSub, _mediaStatusSub, _positionSub;
  Timer? _syncTimer;
  final _progressSync = ProgressSyncService();
  bool _initialized = false;

  // ── Init ──

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
      final options = GoogleCastOptionsAndroid(appId: appId);
      GoogleCastContext.instance.setSharedInstanceWithOptions(options);
      debugPrint('[Cast] Initialized');
    } catch (e) {
      debugPrint('[Cast] Init error: $e');
      _initialized = false;
      return;
    }
    _listenToSessionChanges();
  }

  // ── Session ──

  void _listenToSessionChanges() {
    _sessionSub?.cancel();
    _sessionSub = GoogleCastSessionManager.instance.currentSessionStream.listen((session) {
      final state = GoogleCastSessionManager.instance.connectionState;
      debugPrint('[Cast] Session update — state: $state');
      if (state == GoogleCastConnectState.connected) {
        _connectionState = CastConnectionState.connected;
        _connectedDeviceName = session?.device?.friendlyName;
        debugPrint('[Cast] Connected to: $_connectedDeviceName');
        _listenToMediaStatus();
        _listenToPosition();
      } else if (state == GoogleCastConnectState.disconnected) {
        _onDisconnected();
      } else {
        _connectionState = CastConnectionState.connecting;
      }
      notifyListeners();
    });
  }

  void _onDisconnected() {
    if (_castingItemId != null && _castPosition > Duration.zero) _saveProgressLocal();
    _connectionState = CastConnectionState.disconnected;
    _playbackState = CastPlaybackState.idle;
    _connectedDeviceName = null;
    _castingItemId = _castingTitle = _castingAuthor = _castingCoverUrl = null;
    _castingDuration = 0;
    _castingChapters = [];
    _castPosition = Duration.zero;
    _mediaStatusSub?.cancel();
    _positionSub?.cancel();
    _syncTimer?.cancel();
    notifyListeners();
  }

  void _listenToMediaStatus() {
    _mediaStatusSub?.cancel();
    _mediaStatusSub = GoogleCastRemoteMediaClient.instance.mediaStatusStream.listen((status) {
      if (status == null) {
        _playbackState = CastPlaybackState.idle;
      } else {
        switch (status.playerState) {
          case CastMediaPlayerState.playing: _playbackState = CastPlaybackState.playing; break;
          case CastMediaPlayerState.paused: _playbackState = CastPlaybackState.paused; break;
          case CastMediaPlayerState.buffering: _playbackState = CastPlaybackState.buffering; break;
          case CastMediaPlayerState.loading: _playbackState = CastPlaybackState.loading; break;
          default: _playbackState = CastPlaybackState.idle;
        }
      }
      notifyListeners();
    });
  }

  void _listenToPosition() {
    _positionSub?.cancel();
    _positionSub = GoogleCastRemoteMediaClient.instance.playerPositionStream?.listen((pos) {
      if (pos != null) _castPosition = pos;
    });
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (isCasting && _castingItemId != null) {
        _saveProgressLocal();
        _syncProgressToServer();
      }
    });
  }

  Stream<Duration>? get castPositionStream =>
      GoogleCastRemoteMediaClient.instance.playerPositionStream;

  // ── Discovery / Connection ──

  Stream<List<GoogleCastDevice>> get devicesStream =>
      GoogleCastDiscoveryManager.instance.devicesStream;

  Future<void> connectToDevice(GoogleCastDevice device) async {
    try {
      await GoogleCastSessionManager.instance.startSessionWithDevice(device);
    } catch (e) { debugPrint('[Cast] Connect error: $e'); }
  }

  Future<void> disconnect() async {
    if (_castingItemId != null && _castPosition > Duration.zero) {
      await _saveProgressLocal();
      await _syncProgressToServer();
    }
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } catch (e) { debugPrint('[Cast] Disconnect error: $e'); }
  }

  // ── Media Loading ──

  Future<bool> castItem({
    required ApiService api, required String itemId,
    required String title, required String author,
    required String? coverUrl, required double totalDuration,
    required List<dynamic> chapters, double startTime = 0,
  }) async {
    if (!isConnected) return false;

    final localPlayer = AudioPlayerService();
    if (localPlayer.hasBook) await localPlayer.stop();

    _api = api;
    _castingItemId = itemId;
    _castingTitle = title;
    _castingAuthor = author;
    _castingCoverUrl = coverUrl;
    _castingDuration = totalDuration;
    _castingChapters = chapters;
    _playbackState = CastPlaybackState.loading;
    notifyListeners();

    final localPos = await _progressSync.getSavedPosition(itemId);
    if (localPos > 0 && startTime == 0) startTime = localPos;

    try {
      final sessionData = await api.startPlaybackSession(itemId);
      if (sessionData == null) {
        _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
      }

      final serverPos = (sessionData['currentTime'] as num?)?.toDouble() ?? 0;
      if (serverPos > 0) {
        final localData = await _progressSync.getLocal(itemId);
        final lt = (localData?['timestamp'] as num?)?.toInt() ?? 0;
        final st = (sessionData['updatedAt'] as num?)?.toInt() ?? 0;
        if (st > lt && (serverPos - startTime).abs() > 1.0) startTime = serverPos;
        else if (startTime == 0 && serverPos > 0) startTime = serverPos;
      }

      final audioTracks = sessionData['audioTracks'] as List<dynamic>?;
      if (audioTracks == null || audioTracks.isEmpty) {
        _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
      }

      final sid = sessionData['id'] as String?;
      if (sid != null) try { await api.closePlaybackSession(sid); } catch (_) {}

      if (audioTracks.length == 1) {
        return _loadSingleTrack(api, audioTracks.first, title, author, coverUrl, totalDuration, startTime);
      } else {
        return _loadMultiTrackQueue(api, audioTracks, title, author, coverUrl, totalDuration, chapters, startTime);
      }
    } catch (e) {
      debugPrint('[Cast] Error: $e');
      _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
    }
  }

  Future<bool> _loadSingleTrack(ApiService api, dynamic track, String title,
      String author, String? coverUrl, double totalDuration, double startTime) async {
    final m = track as Map<String, dynamic>;
    final fullUrl = api.buildTrackUrl(m['contentUrl'] as String? ?? '');
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        GoogleCastMediaInformation(
          contentId: fullUrl,
          streamType: CastMediaStreamType.buffered,
          contentUrl: Uri.parse(fullUrl),
          contentType: _contentType(fullUrl),
          metadata: GoogleCastMusicMediaMetadata(
            title: title, artist: author, albumName: title,
            images: coverUrl != null ? [GoogleCastImage(url: Uri.parse(coverUrl), height: 400, width: 400)] : null,
          ),
          duration: Duration(seconds: totalDuration.round()),
        ),
        autoPlay: true,
        playPosition: Duration(milliseconds: (startTime * 1000).round()),
      );
      _castPosition = Duration(milliseconds: (startTime * 1000).round());
      return true;
    } catch (e) {
      debugPrint('[Cast] Load error: $e');
      _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
    }
  }

  Future<bool> _loadMultiTrackQueue(ApiService api, List<dynamic> tracks, String title,
      String author, String? coverUrl, double totalDuration, List<dynamic> chapters, double startTime) async {
    final offsets = <double>[0.0];
    for (final t in tracks) {
      final dur = ((t as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0.0;
      offsets.add(offsets.last + dur);
    }

    double localStart = startTime;
    for (int i = 0; i < offsets.length - 1; i++) {
      if (startTime < offsets[i + 1] || i == offsets.length - 2) {
        localStart = startTime - offsets[i];
        break;
      }
    }

    try {
      final items = <GoogleCastQueueItem>[];
      for (int i = 0; i < tracks.length; i++) {
        final m = tracks[i] as Map<String, dynamic>;
        final fullUrl = api.buildTrackUrl(m['contentUrl'] as String? ?? '');
        items.add(GoogleCastQueueItem(
          mediaInformation: GoogleCastMediaInformation(
            contentId: fullUrl,
            streamType: CastMediaStreamType.buffered,
            contentUrl: Uri.parse(fullUrl),
            contentType: _contentType(fullUrl),
            metadata: GoogleCastMusicMediaMetadata(
              title: title, artist: '$author · Track ${i + 1}', albumName: title,
              images: coverUrl != null ? [GoogleCastImage(url: Uri.parse(coverUrl), height: 400, width: 400)] : null,
            ),
          ),
        ));
      }
      await GoogleCastRemoteMediaClient.instance.queueLoadItems(items);

      // Seek to the correct position after queue loads
      if (localStart > 0.5) {
        // Small delay to let the queue initialize
        await Future.delayed(const Duration(milliseconds: 500));
        await GoogleCastRemoteMediaClient.instance.seek(
          GoogleCastMediaSeekOption(position: Duration(milliseconds: (localStart * 1000).round())),
        );
      }
      _castPosition = Duration(milliseconds: (startTime * 1000).round());
      return true;
    } catch (e) {
      debugPrint('[Cast] Queue error: $e');
      _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
    }
  }

  String _contentType(String url) {
    final l = url.toLowerCase();
    if (l.contains('.m4b') || l.contains('.m4a') || l.contains('.aac')) return 'audio/mp4';
    if (l.contains('.ogg') || l.contains('.opus')) return 'audio/ogg';
    if (l.contains('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }

  // ── Controls ──

  Future<void> play() async { if (isConnected) try { await GoogleCastRemoteMediaClient.instance.play(); } catch (_) {} }
  Future<void> pause() async { if (isConnected) try { await GoogleCastRemoteMediaClient.instance.pause(); _saveProgressLocal(); _syncProgressToServer(); } catch (_) {} }
  Future<void> togglePlayPause() async { isPlaying ? await pause() : await play(); }

  Future<void> seekTo(Duration position) async {
    if (!isConnected) return;
    try {
      await GoogleCastRemoteMediaClient.instance.seek(GoogleCastMediaSeekOption(position: position));
      _castPosition = position;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> skipForward([int s = 30]) => seekTo(_castPosition + Duration(seconds: s));
  Future<void> skipBackward([int s = 10]) async {
    var p = _castPosition - Duration(seconds: s);
    if (p < Duration.zero) p = Duration.zero;
    await seekTo(p);
  }

  Future<void> stopCasting() async {
    if (!isConnected) return;
    await _saveProgressLocal();
    await _syncProgressToServer();
    try { await GoogleCastRemoteMediaClient.instance.stop(); } catch (_) {}
    _playbackState = CastPlaybackState.idle;
    _castingItemId = _castingTitle = _castingAuthor = _castingCoverUrl = null;
    _castingDuration = 0; _castingChapters = [];
    notifyListeners();
  }

  // ── Sync ──

  Future<void> _saveProgressLocal() async {
    if (_castingItemId == null) return;
    final ct = _castPosition.inMilliseconds / 1000.0;
    if (ct <= 0) return;
    await _progressSync.saveLocal(itemId: _castingItemId!, currentTime: ct, duration: _castingDuration, speed: 1.0);
  }

  Future<void> _syncProgressToServer() async {
    if (_castingItemId == null || _api == null) return;
    try { await _progressSync.syncToServer(api: _api!, itemId: _castingItemId!); } catch (_) {}
  }

  // ── Chapters ──

  Map<String, dynamic>? get currentChapter {
    if (_castingChapters.isEmpty) return null;
    final p = _castPosition.inMilliseconds / 1000.0;
    for (final ch in _castingChapters) {
      final m = ch as Map<String, dynamic>;
      if (p >= ((m['start'] as num?)?.toDouble() ?? 0) && p < ((m['end'] as num?)?.toDouble() ?? 0)) return m;
    }
    return null;
  }

  Future<void> skipToNextChapter() async {
    if (_castingChapters.isEmpty) return;
    final p = _castPosition.inMilliseconds / 1000.0;
    for (final ch in _castingChapters) {
      final s = ((ch as Map)['start'] as num?)?.toDouble() ?? 0;
      if (s > p + 1.0) { await seekTo(Duration(milliseconds: (s * 1000).round())); return; }
    }
  }

  Future<void> skipToPreviousChapter() async {
    if (_castingChapters.isEmpty) return;
    final p = _castPosition.inMilliseconds / 1000.0;
    for (int i = _castingChapters.length - 1; i >= 0; i--) {
      final s = ((_castingChapters[i] as Map)['start'] as num?)?.toDouble() ?? 0;
      if (s < p - 3.0) { await seekTo(Duration(milliseconds: (s * 1000).round())); return; }
    }
    await seekTo(Duration.zero);
  }

  @override
  void dispose() { _sessionSub?.cancel(); _mediaStatusSub?.cancel(); _positionSub?.cancel(); _syncTimer?.cancel(); super.dispose(); }
}
