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
    debugPrint('[Cast] >>> init() called');
    try {
      const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
      debugPrint('[Cast] Using appId: $appId');
      final options = GoogleCastOptionsAndroid(appId: appId);
      GoogleCastContext.instance.setSharedInstanceWithOptions(options);
      debugPrint('[Cast] Context initialized OK');
    } catch (e, st) {
      debugPrint('[Cast] Init error: $e\n$st');
      _initialized = false;
      return;
    }
    _listenToSessionChanges();

    try {
      await GoogleCastDiscoveryManager.instance.startDiscovery();
      debugPrint('[Cast] Discovery started');
    } catch (e) {
      debugPrint('[Cast] Discovery start error: $e');
    }
  }

  // ── Session ──

  void _listenToSessionChanges() {
    debugPrint('[Cast] >>> _listenToSessionChanges() subscribing');
    _sessionSub?.cancel();
    _sessionSub = GoogleCastSessionManager.instance.currentSessionStream.listen(
      (session) {
        final state = GoogleCastSessionManager.instance.connectionState;
        debugPrint('[Cast] SESSION EVENT — connectionState: $state, session: ${session?.device?.friendlyName ?? "null"}');
        if (state == GoogleCastConnectState.connected) {
          _connectionState = CastConnectionState.connected;
          _connectedDeviceName = session?.device?.friendlyName;
          debugPrint('[Cast] ✓ CONNECTED to: $_connectedDeviceName');
          _listenToMediaStatus();
          _listenToPosition();
          _updateVolumeFromSession();
        } else if (state == GoogleCastConnectState.disconnected) {
          debugPrint('[Cast] ✗ DISCONNECTED');
          _onDisconnected();
        } else {
          debugPrint('[Cast] ~ CONNECTING...');
          _connectionState = CastConnectionState.connecting;
        }
        notifyListeners();
      },
      onError: (e) => debugPrint('[Cast] Session stream ERROR: $e'),
      onDone: () => debugPrint('[Cast] Session stream DONE (closed)'),
    );
    debugPrint('[Cast] Session stream subscription active');
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
        debugPrint('[Cast] Media status: ${status.playerState}');
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
    debugPrint('[Cast] >>> connectToDevice() — ${device.friendlyName}');
    debugPrint('[Cast] Current connectionState before connect: $_connectionState');
    _connectionState = CastConnectionState.connecting;
    notifyListeners();
    try {
      debugPrint('[Cast] Calling startSessionWithDevice...');
      await GoogleCastSessionManager.instance.startSessionWithDevice(device);
      debugPrint('[Cast] startSessionWithDevice returned (awaited)');
    } catch (e, st) {
      debugPrint('[Cast] Connect error: $e\n$st');
      _connectionState = CastConnectionState.disconnected;
      notifyListeners();
    }
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
    debugPrint('[Cast] >>> castItem() — "$title" (id: $itemId)');
    debugPrint('[Cast] isConnected=$isConnected, connectionState=$_connectionState');
    if (!isConnected) {
      debugPrint('[Cast] NOT CONNECTED — aborting castItem');
      return false;
    }

    final localPlayer = AudioPlayerService();
    if (localPlayer.hasBook) {
      debugPrint('[Cast] Stopping local player');
      await localPlayer.stop();
    }

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
    debugPrint('[Cast] Local saved position: $localPos');
    if (localPos > 0 && startTime == 0) startTime = localPos;

    try {
      debugPrint('[Cast] Starting playback session with server...');
      final sessionData = await api.startPlaybackSession(itemId);
      if (sessionData == null) {
        debugPrint('[Cast] Server returned null session — aborting');
        _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
      }
      debugPrint('[Cast] Got session data, keys: ${sessionData.keys.toList()}');

      final serverPos = (sessionData['currentTime'] as num?)?.toDouble() ?? 0;
      debugPrint('[Cast] Server position: $serverPos');
      if (serverPos > 0) {
        final localData = await _progressSync.getLocal(itemId);
        final lt = (localData?['timestamp'] as num?)?.toInt() ?? 0;
        final st = (sessionData['updatedAt'] as num?)?.toInt() ?? 0;
        if (st > lt && (serverPos - startTime).abs() > 1.0) startTime = serverPos;
        else if (startTime == 0 && serverPos > 0) startTime = serverPos;
      }

      final audioTracks = sessionData['audioTracks'] as List<dynamic>?;
      debugPrint('[Cast] Audio tracks count: ${audioTracks?.length ?? 0}');
      if (audioTracks == null || audioTracks.isEmpty) {
        debugPrint('[Cast] No audio tracks — aborting');
        _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
      }

      final sid = sessionData['id'] as String?;
      if (sid != null) try { await api.closePlaybackSession(sid); } catch (_) {}

      debugPrint('[Cast] Starting from position: ${startTime}s');
      if (audioTracks.length == 1) {
        debugPrint('[Cast] Single track mode');
        return _loadSingleTrack(api, audioTracks.first, title, author, coverUrl, totalDuration, startTime);
      } else {
        debugPrint('[Cast] Multi-track queue mode (${audioTracks.length} tracks)');
        return _loadMultiTrackQueue(api, audioTracks, title, author, coverUrl, totalDuration, chapters, startTime);
      }
    } catch (e, st) {
      debugPrint('[Cast] castItem error: $e\n$st');
      _playbackState = CastPlaybackState.idle; notifyListeners(); return false;
    }
  }

  Future<bool> _loadSingleTrack(ApiService api, dynamic track, String title,
      String author, String? coverUrl, double totalDuration, double startTime) async {
    final m = track as Map<String, dynamic>;
    final fullUrl = api.buildTrackUrl(m['contentUrl'] as String? ?? '');
    debugPrint('[Cast] Loading single track URL: $fullUrl');
    final subtitle = _buildSubtitle(author, startTime);
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        GoogleCastMediaInformation(
          contentId: fullUrl,
          streamType: CastMediaStreamType.buffered,
          contentUrl: Uri.parse(fullUrl),
          contentType: _contentType(fullUrl),
          metadata: GoogleCastGenericMediaMetadata(
            title: title,
            subtitle: subtitle,
            images: coverUrl != null ? [GoogleCastImage(url: Uri.parse(coverUrl), height: 400, width: 400)] : null,
          ),
          duration: Duration(seconds: totalDuration.round()),
        ),
        autoPlay: true,
        playPosition: Duration(milliseconds: (startTime * 1000).round()),
      );
      debugPrint('[Cast] ✓ loadMedia completed');
      _castPosition = Duration(milliseconds: (startTime * 1000).round());
      return true;
    } catch (e, st) {
      debugPrint('[Cast] loadMedia error: $e\n$st');
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

    debugPrint('[Cast] Multi-track: startTime=$startTime, localStart=$localStart');
    try {
      final items = <GoogleCastQueueItem>[];
      for (int i = 0; i < tracks.length; i++) {
        final m = tracks[i] as Map<String, dynamic>;
        final fullUrl = api.buildTrackUrl(m['contentUrl'] as String? ?? '');
        debugPrint('[Cast] Track $i URL: $fullUrl');
        items.add(GoogleCastQueueItem(
          mediaInformation: GoogleCastMediaInformation(
            contentId: fullUrl,
            streamType: CastMediaStreamType.buffered,
            contentUrl: Uri.parse(fullUrl),
            contentType: _contentType(fullUrl),
            metadata: GoogleCastGenericMediaMetadata(
              title: title,
              subtitle: '$author · Track ${i + 1} of ${tracks.length}',
              images: coverUrl != null ? [GoogleCastImage(url: Uri.parse(coverUrl), height: 400, width: 400)] : null,
            ),
          ),
        ));
      }
      debugPrint('[Cast] Calling queueLoadItems with ${items.length} items...');
      await GoogleCastRemoteMediaClient.instance.queueLoadItems(items);
      debugPrint('[Cast] ✓ queueLoadItems completed');

      if (localStart > 0.5) {
        await Future.delayed(const Duration(milliseconds: 500));
        debugPrint('[Cast] Seeking to $localStart...');
        await GoogleCastRemoteMediaClient.instance.seek(
          GoogleCastMediaSeekOption(position: Duration(milliseconds: (localStart * 1000).round())),
        );
        debugPrint('[Cast] ✓ Seek completed');
      }
      _castPosition = Duration(milliseconds: (startTime * 1000).round());
      return true;
    } catch (e, st) {
      debugPrint('[Cast] Queue error: $e\n$st');
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

  /// Build a subtitle string with author + current chapter name
  String _buildSubtitle(String author, double position) {
    if (_castingChapters.isEmpty) return author;
    for (final ch in _castingChapters) {
      final m = ch as Map<String, dynamic>;
      final s = (m['start'] as num?)?.toDouble() ?? 0;
      final e = (m['end'] as num?)?.toDouble() ?? 0;
      if (position >= s && position < e) {
        final chTitle = m['title'] as String?;
        if (chTitle != null && chTitle.isNotEmpty) return '$author · $chTitle';
        break;
      }
    }
    return author;
  }

  /// Get the current chapter title based on cast position
  String? get currentChapterTitle {
    final ch = currentChapter;
    return ch?['title'] as String?;
  }

  // ── Volume ──

  double _volume = 1.0;
  double get volume => _volume;

  void _updateVolumeFromSession() {
    try {
      final session = GoogleCastSessionManager.instance.currentSession;
      if (session != null) {
        _volume = session.currentDeviceVolume.clamp(0.0, 1.0);
      }
    } catch (_) {}
  }

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    notifyListeners();
    try {
      GoogleCastSessionManager.instance.setDeviceVolume(value);
    } catch (e) {
      debugPrint('[Cast] setDeviceVolume error: $e');
    }
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

  // ── Speed ──

  double _castSpeed = 1.0;
  double get castSpeed => _castSpeed;

  Future<void> setSpeed(double speed) async {
    _castSpeed = speed.clamp(0.5, 3.0);
    if (!isConnected) return;
    try {
      await GoogleCastRemoteMediaClient.instance.setPlaybackRate(speed);
      debugPrint('[Cast] Speed set to ${speed}x');
    } catch (e) {
      debugPrint('[Cast] setPlaybackRate error (may not be supported): $e');
    }
    notifyListeners();
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
