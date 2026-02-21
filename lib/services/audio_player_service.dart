import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'download_service.dart';
import 'playback_history_service.dart' hide PlaybackEvent;
import 'progress_sync_service.dart';

// ─── Auto-rewind settings ───

class AutoRewindSettings {
  final bool enabled;
  final double minRewind;
  final double maxRewind;
  final double activationDelay; // seconds — how long pause must be before rewind kicks in

  const AutoRewindSettings({
    this.enabled = true,
    this.minRewind = 1.0,
    this.maxRewind = 30.0,
    this.activationDelay = 0.0, // 0 = always rewind on resume
  });

  static Future<AutoRewindSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AutoRewindSettings(
      enabled: prefs.getBool('autoRewind_enabled') ?? true,
      minRewind: prefs.getDouble('autoRewind_min') ?? 1.0,
      maxRewind: prefs.getDouble('autoRewind_max') ?? 30.0,
      activationDelay: prefs.getDouble('autoRewind_delay') ?? 0.0,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoRewind_enabled', enabled);
    await prefs.setDouble('autoRewind_min', minRewind);
    await prefs.setDouble('autoRewind_max', maxRewind);
    await prefs.setDouble('autoRewind_delay', activationDelay);
  }
}

class PlayerSettings {
  /// Notifier that fires when any player setting changes.
  /// Widgets can listen to this instead of polling SharedPreferences.
  static final ChangeNotifier settingsChanged = ChangeNotifier();
  static void _notify() {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    settingsChanged.notifyListeners();
  }

  // ── Private helpers to eliminate boilerplate ──

  static Future<T> _get<T>(String key, T defaultValue) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.get(key);
    if (value is T) return value;
    return defaultValue;
  }

  static Future<void> _set<T>(String key, T value, {bool notify = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
    if (notify) _notify();
  }

  // ── General settings ──

  static Future<double> getDefaultSpeed() => _get('defaultSpeed', 1.0);
  static Future<void> setDefaultSpeed(double speed) => _set('defaultSpeed', speed);

  static Future<bool> getWifiOnlyDownloads() => _get('wifiOnlyDownloads', false);
  static Future<void> setWifiOnlyDownloads(bool value) => _set('wifiOnlyDownloads', value);

  static Future<bool> getAutoContinueSeries() => _get('autoContinueSeries', true);
  static Future<void> setAutoContinueSeries(bool value) => _set('autoContinueSeries', value);

  // ── Player UI settings (notify listeners on change) ──

  static Future<bool> getShowBookSlider() => _get('showBookSlider', false);
  static Future<void> setShowBookSlider(bool value) => _set('showBookSlider', value, notify: true);

  static Future<bool> getSpeedAdjustedTime() => _get('speedAdjustedTime', true);
  static Future<void> setSpeedAdjustedTime(bool value) => _set('speedAdjustedTime', value, notify: true);

  static Future<int> getForwardSkip() => _get('forwardSkip', 30);
  static Future<void> setForwardSkip(int seconds) => _set('forwardSkip', seconds, notify: true);

  static Future<int> getBackSkip() => _get('backSkip', 10);
  static Future<void> setBackSkip(int seconds) => _set('backSkip', seconds, notify: true);

  // ── Sleep timer settings ──

  static Future<bool> getShakeToResetSleep() => _get('shakeToResetSleep', true);
  static Future<void> setShakeToResetSleep(bool value) => _set('shakeToResetSleep', value);

  static Future<int> getShakeAddMinutes() => _get('shakeAddMinutes', 5);
  static Future<void> setShakeAddMinutes(int minutes) => _set('shakeAddMinutes', minutes);

  // ── Per-book speed persistence ──

  static Future<double?> getBookSpeed(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('bookSpeed_$itemId');
  }

  static Future<void> setBookSpeed(String itemId, double speed) =>
      _set('bookSpeed_$itemId', speed);
}

// ─── AudioHandler (runs in background, controls notification) ───

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  AudioPlayerService? _service; // back-reference for auto-rewind

  AudioPlayer get player => _player;

  void bindService(AudioPlayerService service) => _service = service;

  AudioPlayerHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.rewind,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      // Report actual speed — always
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }

  @override
  Future<void> play() async {
    debugPrint('[Handler] play() called — routing to service');
    if (_service != null) {
      await _service!.play();
    } else {
      await _player.play();
    }
  }

  @override
  Future<void> pause() async {
    debugPrint('[Handler] pause() called — routing to service');
    if (_service != null) {
      await _service!.pause();
    } else {
      await _player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) {
    debugPrint('[Handler] seek(${position.inSeconds}s)');
    return _player.seek(position);
  }

  @override
  Future<void> stop() async {
    debugPrint('[Handler] stop()');
    await _player.stop();
    return super.stop();
  }

  /// Called when the user swipes the app away from recents.
  @override
  Future<void> onTaskRemoved() async {
    debugPrint('[Handler] onTaskRemoved — app swiped away');
    // Stop playback and sync via the service if available
    if (_service != null) {
      await _service!.pause();
      await _service!.stop();
    } else {
      await _player.stop();
    }
    await super.onTaskRemoved();
  }

  @override
  Future<void> fastForward() async {
    debugPrint('[Handler] fastForward() — seeking forward');
    final skipAmount = await PlayerSettings.getForwardSkip();
    await _player.seek(_player.position + Duration(seconds: skipAmount));
    debugPrint('[Handler] fastForward done — playing=${_player.playing}');
  }

  @override
  Future<void> rewind() async {
    debugPrint('[Handler] rewind() — seeking back');
    final skipAmount = await PlayerSettings.getBackSkip();
    var pos = _player.position - Duration(seconds: skipAmount);
    if (pos < Duration.zero) pos = Duration.zero;
    await _player.seek(pos);
    debugPrint('[Handler] rewind done — playing=${_player.playing}');
  }

  @override
  Future<void> skipToNext() {
    debugPrint('[Handler] skipToNext() → fastForward');
    return fastForward();
  }

  @override
  Future<void> skipToPrevious() {
    debugPrint('[Handler] skipToPrevious() → rewind');
    return rewind();
  }

  // Custom click handler with proper multi-press detection
  Timer? _clickTimer;
  int _clickCount = 0;
  DateTime? _hardwareButtonTime; // cooldown after hardware next/prev

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    debugPrint('[Handler] click(button=$button) count=${_clickCount + 1} playing=${_player.playing}');

    if (button != MediaButton.media) {
      // Hardware next/prev button — set cooldown to ignore phantom media click
      _hardwareButtonTime = DateTime.now();
      if (button == MediaButton.next) {
        debugPrint('[Handler] Hardware NEXT button');
        await fastForward();
      } else if (button == MediaButton.previous) {
        debugPrint('[Handler] Hardware PREV button');
        await rewind();
      }
      return;
    }

    // Ignore phantom media click that follows hardware next/prev within 500ms
    if (_hardwareButtonTime != null) {
      final elapsed = DateTime.now().difference(_hardwareButtonTime!).inMilliseconds;
      if (elapsed < 500) {
        debugPrint('[Handler] Ignoring phantom media click (${elapsed}ms after hardware button)');
        _hardwareButtonTime = null;
        return;
      }
      _hardwareButtonTime = null;
    }

    _clickCount++;
    _clickTimer?.cancel();
    _clickTimer = Timer(const Duration(milliseconds: 400), () async {
      final count = _clickCount;
      _clickCount = 0;
      debugPrint('[Handler] click resolved: count=$count playing=${_player.playing}');
      switch (count) {
        case 1:
          if (_player.playing) {
            debugPrint('[Handler] → single press → PAUSE');
            await pause();
          } else {
            debugPrint('[Handler] → single press → PLAY');
            await play();
          }
          break;
        case 2:
          debugPrint('[Handler] → double press → SKIP FORWARD');
          await fastForward();
          break;
        case 3:
        default:
          debugPrint('[Handler] → triple press → SKIP BACK');
          await rewind();
          break;
      }
    });
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
}

// ─── Singleton service ───

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._();

  static AudioPlayerHandler? _handler;
  AudioPlayer? get _player => _handler?.player;

  String? _currentItemId;
  String? _currentTitle;
  String? _currentAuthor;
  String? _currentCoverUrl;
  double _totalDuration = 0;
  List<dynamic> _chapters = [];
  ApiService? _api;
  String? _playbackSessionId;
  bool _isOfflineMode = false;
  StreamSubscription? _syncSub;
  StreamSubscription? _completionSub;

  final _progressSync = ProgressSyncService();
  final _downloadService = DownloadService();
  final _history = PlaybackHistoryService();

  /// Log a playback event to history.
  void _logEvent(PlaybackEventType type, {String? detail}) {
    if (_currentItemId == null) return;
    _history.log(
      itemId: _currentItemId!,
      type: type,
      positionSeconds: position.inMilliseconds / 1000.0,
      detail: detail,
    );
  }

  static String _formatPos(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String? get currentItemId => _currentItemId;
  String? get currentTitle => _currentTitle;
  String? get currentAuthor => _currentAuthor;
  String? get currentCoverUrl => _currentCoverUrl;
  double get totalDuration => _totalDuration;
  List<dynamic> get chapters => _chapters;

  void updateChapters(List<dynamic> chapters) {
    _chapters = chapters;
    notifyListeners();
  }
  bool get hasBook => _currentItemId != null;
  bool get isPlaying => _player?.playing ?? false;
  bool get isOfflineMode => _isOfflineMode;

  Stream<Duration> get positionStream =>
      _player?.positionStream ?? const Stream.empty();
  Stream<Duration?> get durationStream =>
      _player?.durationStream ?? const Stream.empty();
  Stream<PlayerState> get playerStateStream =>
      _player?.playerStateStream ?? const Stream.empty();

  Duration get position => _player?.position ?? Duration.zero;
  Duration get duration => _player?.duration ?? Duration.zero;
  double get speed => _player?.speed ?? 1.0;

  /// MUST be called after Activity is ready.
  static Future<void> init() async {
    _handler = await AudioService.init<AudioPlayerHandler>(
      builder: () => AudioPlayerHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.audiobookshelf.app.channel.audio',
        androidNotificationChannelName: 'Absorb',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'drawable/ic_notification',
      ),
    );
    // Bind service so handler routes play/pause through service (for auto-rewind)
    _handler!.bindService(_instance);
    debugPrint('[Player] AudioService initialized');
  }

  Future<bool> playItem({
    required ApiService api,
    required String itemId,
    required String title,
    required String author,
    required String? coverUrl,
    required double totalDuration,
    required List<dynamic> chapters,
    double startTime = 0,
  }) async {
    if (_handler == null) {
      debugPrint('[Player] Handler not initialized!');
      return false;
    }

    _api = api;
    _currentItemId = itemId;
    _currentTitle = title;
    _currentAuthor = author;
    _currentCoverUrl = coverUrl;
    _totalDuration = totalDuration;
    _chapters = chapters;
    notifyListeners();

    // Check for local saved position (always prefer local — it's the freshest)
    final localPos = await _progressSync.getSavedPosition(itemId);
    if (localPos > 0 && startTime == 0) {
      startTime = localPos;
      debugPrint('[Player] Resuming from local position: ${startTime}s');
    }

    // Check if downloaded — play locally
    if (_downloadService.isDownloaded(itemId)) {
      return _playFromLocal(itemId, title, author, coverUrl, totalDuration,
          chapters, startTime);
    }

    // Check manual offline — don't stream from server
    final prefs = await SharedPreferences.getInstance();
    final manualOffline = prefs.getBool('manual_offline_mode') ?? false;
    if (manualOffline) {
      debugPrint('[Player] Manual offline — cannot stream non-downloaded book');
      _clearState();
      return false;
    }

    // Otherwise stream from server
    return _playFromServer(api, itemId, title, author, coverUrl,
        totalDuration, chapters, startTime);
  }

  /// Hot-swap from streaming to local files without interrupting playback position.
  /// Called when a download completes for the currently-playing item.
  Future<bool> switchToLocal(String itemId) async {
    if (_currentItemId != itemId) return false;
    if (!_downloadService.isDownloaded(itemId)) return false;
    if (_player == null) return false;

    final wasPlaying = _player!.playing;
    final currentPos = _player!.position;
    final currentSpeed = _player!.speed;

    debugPrint('[Player] Hot-swapping to local files at ${currentPos.inSeconds}s');

    final localPaths = _downloadService.getLocalPaths(itemId);
    if (localPaths == null || localPaths.isEmpty) return false;

    // Get cached session data for track durations (multi-file seeking)
    final cachedJson = _downloadService.getCachedSessionData(itemId);
    List<dynamic>? audioTracks;
    if (cachedJson != null) {
      try {
        final session = jsonDecode(cachedJson) as Map<String, dynamic>;
        audioTracks = session['audioTracks'] as List<dynamic>?;
      } catch (_) {}
    }

    try {
      AudioSource source;
      if (localPaths.length == 1) {
        source = AudioSource.file(localPaths.first);
      } else {
        final sources = localPaths.map((p) => AudioSource.file(p) as AudioSource).toList();
        source = ConcatenatingAudioSource(children: sources);
      }

      await _player!.setAudioSource(source);

      // Seek to the same position
      final posSeconds = currentPos.inMilliseconds / 1000.0;
      if (localPaths.length == 1) {
        await _player!.seek(currentPos);
      } else if (audioTracks != null) {
        double acc = 0;
        for (int i = 0; i < audioTracks.length && i < localPaths.length; i++) {
          final t = audioTracks[i] as Map<String, dynamic>;
          final dur = (t['duration'] as num?)?.toDouble() ?? 0;
          if (posSeconds < acc + dur) {
            await _player!.seek(Duration(seconds: (posSeconds - acc).round()), index: i);
            break;
          }
          acc += dur;
        }
      }

      // Restore speed
      await _player!.setSpeed(currentSpeed);

      // Resume if was playing
      if (wasPlaying) _player!.play();

      _logEvent(PlaybackEventType.play, detail: 'Switched to local playback');
      debugPrint('[Player] Hot-swap complete — now playing from local files');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[Player] Hot-swap failed: $e');
      return false;
    }
  }

  Future<bool> _playFromLocal(
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime,
  ) async {
    debugPrint('[Player] Playing from local files: $title');
    _isOfflineMode = false; // We still sync to server if possible
    _playbackSessionId = null;

    // Check if manual offline mode is on
    final prefs = await SharedPreferences.getInstance();
    final manualOffline = prefs.getBool('manual_offline_mode') ?? false;
    debugPrint('[Player] manualOffline=$manualOffline, api=${_api != null}');

    // Try to start a server session for sync (unless manual offline)
    if (_api != null && !manualOffline) {
      try {
        debugPrint('[Player] Starting server session for local playback...');
        final sessionData = await _api!.startPlaybackSession(itemId);
        if (sessionData != null) {
          _playbackSessionId = sessionData['id'] as String?;
          debugPrint('[Player] Got server session for local playback: $_playbackSessionId');

          // Compare server position vs local position — last-write-wins
          final serverPos = (sessionData['currentTime'] as num?)?.toDouble() ?? 0;
          if (serverPos > 0) {
            // Get local timestamp to compare
            final localData = await _progressSync.getLocal(itemId);
            final localTimestamp = (localData?['timestamp'] as num?)?.toInt() ?? 0;

            // Server session has updatedAt in epoch ms
            final serverTimestamp = (sessionData['updatedAt'] as num?)?.toInt() ?? 0;

            if (serverTimestamp > localTimestamp && (serverPos - startTime).abs() > 1.0) {
              debugPrint('[Player] Server position is newer: server=${serverPos}s ($serverTimestamp) vs local=${startTime}s ($localTimestamp) — using server');
              startTime = serverPos;
              // Update local to match
              await _progressSync.saveLocal(
                itemId: itemId,
                currentTime: serverPos,
                duration: totalDuration,
                speed: 1.0,
              );
            } else if (startTime == 0 && serverPos > 0) {
              debugPrint('[Player] No local position, using server: ${serverPos}s');
              startTime = serverPos;
            } else {
              debugPrint('[Player] Local position is newer: local=${startTime}s ($localTimestamp) vs server=${serverPos}s ($serverTimestamp) — keeping local');
            }
          }
        } else {
          debugPrint('[Player] startPlaybackSession returned null');
        }
      } catch (e) {
        debugPrint('[Player] Could not start server session: $e');
      }
    } else {
      debugPrint('[Player] Skipping server session — manual offline or no API');
    }

    // If no session, fall back to offline mode
    if (_playbackSessionId == null) {
      _isOfflineMode = true;
      debugPrint('[Player] No server session — true offline mode');
    }

    final localPaths = _downloadService.getLocalPaths(itemId);
    if (localPaths == null || localPaths.isEmpty) {
      debugPrint('[Player] No local files found');
      _clearState();
      return false;
    }

    // Get cached session data for track durations
    final cachedJson = _downloadService.getCachedSessionData(itemId);
    List<dynamic>? audioTracks;
    if (cachedJson != null) {
      try {
        final session = jsonDecode(cachedJson) as Map<String, dynamic>;
        audioTracks = session['audioTracks'] as List<dynamic>?;
      } catch (_) {}
    }

    try {
      AudioSource source;
      if (localPaths.length == 1) {
        source = AudioSource.file(localPaths.first);
      } else {
        final sources = localPaths
            .map((p) => AudioSource.file(p) as AudioSource)
            .toList();
        source = ConcatenatingAudioSource(children: sources);
      }

      await _player!.setAudioSource(source);

      if (startTime > 0) {
        if (localPaths.length == 1) {
          await _player!.seek(Duration(seconds: startTime.round()));
        } else if (audioTracks != null) {
          double acc = 0;
          for (int i = 0; i < audioTracks.length && i < localPaths.length; i++) {
            final t = audioTracks[i] as Map<String, dynamic>;
            final dur = (t['duration'] as num?)?.toDouble() ?? 0;
            if (startTime < acc + dur) {
              await _player!.seek(
                  Duration(seconds: (startTime - acc).round()), index: i);
              break;
            }
            acc += dur;
          }
        }
      }

      _pushMediaItem(itemId, title, author, coverUrl, totalDuration);
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      await _player!.setSpeed(speed);
      debugPrint('[Player] Starting local playback at ${speed}x');
      _player!.play();
      notifyListeners();
      _setupSync();
      return true;
    } catch (e, stack) {
      debugPrint('[Player] Local play error: $e\n$stack');
      _clearState();
      return false;
    }
  }

  Future<bool> _playFromServer(
    ApiService api,
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime,
  ) async {
    debugPrint('[Player] Streaming from server: $title');
    _isOfflineMode = false;

    final sessionData = await api.startPlaybackSession(itemId);
    if (sessionData == null) {
      debugPrint('[Player] Failed to start playback session');
      _clearState();
      return false;
    }

    _playbackSessionId = sessionData['id'] as String?;
    final audioTracks = sessionData['audioTracks'] as List<dynamic>?;
    if (audioTracks == null || audioTracks.isEmpty) {
      _clearState();
      return false;
    }

    // Compare server position vs local position — last-write-wins
    final serverPos = (sessionData['currentTime'] as num?)?.toDouble() ?? 0;
    if (serverPos > 0) {
      final localData = await _progressSync.getLocal(itemId);
      final localTimestamp = (localData?['timestamp'] as num?)?.toInt() ?? 0;
      final serverTimestamp = (sessionData['updatedAt'] as num?)?.toInt() ?? 0;

      if (serverTimestamp > localTimestamp && (serverPos - startTime).abs() > 1.0) {
        debugPrint('[Player] Server position is newer: server=${serverPos}s ($serverTimestamp) vs local=${startTime}s ($localTimestamp) — using server');
        startTime = serverPos;
      } else if (startTime == 0) {
        debugPrint('[Player] No local position, using server: ${serverPos}s');
        startTime = serverPos;
      } else {
        debugPrint('[Player] Local position is newer: local=${startTime}s ($localTimestamp) vs server=${serverPos}s ($serverTimestamp) — keeping local');
      }
    }

    try {
      AudioSource source;
      if (audioTracks.length == 1) {
        final track = audioTracks.first as Map<String, dynamic>;
        final contentUrl = track['contentUrl'] as String? ?? '';
        final fullUrl = api.buildTrackUrl(contentUrl);
        source = AudioSource.uri(Uri.parse(fullUrl));
      } else {
        final sources = <AudioSource>[];
        for (final t in audioTracks) {
          final track = t as Map<String, dynamic>;
          final contentUrl = track['contentUrl'] as String? ?? '';
          final fullUrl = api.buildTrackUrl(contentUrl);
          sources.add(AudioSource.uri(Uri.parse(fullUrl)));
        }
        source = ConcatenatingAudioSource(children: sources);
      }

      await _player!.setAudioSource(source);

      if (startTime > 0) {
        if (audioTracks.length == 1) {
          await _player!.seek(Duration(seconds: startTime.round()));
        } else {
          double acc = 0;
          for (int i = 0; i < audioTracks.length; i++) {
            final t = audioTracks[i] as Map<String, dynamic>;
            final dur = (t['duration'] as num?)?.toDouble() ?? 0;
            if (startTime < acc + dur) {
              await _player!.seek(
                  Duration(seconds: (startTime - acc).round()), index: i);
              break;
            }
            acc += dur;
          }
        }
      }

      _pushMediaItem(itemId, title, author, coverUrl, totalDuration);
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      await _player!.setSpeed(speed);
      debugPrint('[Player] Starting stream playback at ${speed}x');
      _player!.play();
      notifyListeners();
      _setupSync();
      return true;
    } catch (e, stack) {
      debugPrint('[Player] Stream error: $e\n$stack');
      _clearState();
      return false;
    }
  }

  void _pushMediaItem(String itemId, String title, String author,
      String? coverUrl, double totalDuration) {
    _updateNotificationMediaItem(itemId, title, author, coverUrl, totalDuration);
  }

  void _updateNotificationMediaItem(String itemId, String title, String author,
      String? coverUrl, double totalDuration) {
    _handler!.mediaItem.add(MediaItem(
      id: itemId,
      title: title,
      artist: author,
      album: title,
      duration: Duration(seconds: totalDuration.round()),
      artUri: coverUrl != null ? Uri.tryParse(coverUrl) : null,
    ));
  }

  void _clearState() {
    _currentItemId = null;
    _currentTitle = null;
    _currentAuthor = null;
    _currentCoverUrl = null;
    _playbackSessionId = null;
    _isOfflineMode = false;
    _syncSub?.cancel();
    _syncSub = null;
    _completionSub?.cancel();
    _completionSub = null;
    notifyListeners();
  }

  int _lastSyncSecond = -1;

  void _setupSync() {
    _syncSub?.cancel();
    _lastSyncSecond = -1;

    _syncSub = _player?.positionStream.listen((pos) async {
      final sec = pos.inSeconds;
      if (sec <= 0) return;

      // ─── Completion detection ─────────────────────────────
      // Check if we've reached the end of the book
      final posSeconds = pos.inMilliseconds / 1000.0;
      if (_totalDuration > 0 && posSeconds >= _totalDuration - 1.0) {
        _onPlaybackComplete();
        return;
      }

      // Save locally every 5 seconds (always works, even offline)
      if (sec % 5 == 0 && sec != _lastSyncSecond && _currentItemId != null) {
        _lastSyncSecond = sec;
        _saveProgressLocal(pos);

        // Also sync to server every 15 seconds (unless manual offline)
        if (sec % 15 == 0) {
          final prefs = await SharedPreferences.getInstance();
          final manualOffline = prefs.getBool('manual_offline_mode') ?? false;

          if (manualOffline) {
            // Manual offline — local save only, no server sync
          } else if (!_isOfflineMode && _playbackSessionId != null) {
            // Streaming/local with session: sync via session
            _syncToServer(pos);
          } else if (!_isOfflineMode && _api != null && _currentItemId != null) {
            // No session but online — sync via progress update endpoint
            debugPrint('[Player] No-session sync — sending to server at ${pos.inSeconds}s');
            try {
              final ok = await _progressSync.syncToServer(
                  api: _api!, itemId: _currentItemId!);
              if (ok) {
                debugPrint('[Player] No-session sync succeeded');
              } else {
                debugPrint('[Player] No-session sync returned false');
              }
            } catch (e) {
              debugPrint('[Player] No-session sync error: $e');
            }
          }
        }
      }
    });
  }

  bool _isCompletingBook = false;

  Future<void> _onPlaybackComplete() async {
    if (_isCompletingBook) return; // prevent re-entry
    _isCompletingBook = true;

    debugPrint('[Player] Book complete: $_currentTitle');
    _logEvent(PlaybackEventType.pause, detail: 'Book finished');

    // Pause immediately so audio doesn't keep running
    await _player?.pause();

    // Mark as finished on the server
    final itemId = _currentItemId;
    if (itemId != null && _api != null) {
      try {
        await _api!.markFinished(itemId, _totalDuration);
        debugPrint('[Player] Marked as finished on server');
      } catch (e) {
        debugPrint('[Player] Failed to mark finished: $e');
      }
    }

    // Also save locally as finished
    if (itemId != null) {
      await _progressSync.saveLocal(
        itemId: itemId,
        currentTime: _totalDuration,
        duration: _totalDuration,
        speed: speed,
      );
    }

    // Close the playback session
    if (_playbackSessionId != null && _api != null) {
      try {
        await _api!.closePlaybackSession(_playbackSessionId!);
      } catch (_) {}
    }

    // Stop and clear state
    await _player?.stop();
    _clearState();
    _chapters = [];
    _isCompletingBook = false;
    notifyListeners();
  }

  Future<void> _saveProgressLocal(Duration pos) async {
    if (_currentItemId == null) return;
    await _progressSync.saveLocal(
      itemId: _currentItemId!,
      currentTime: pos.inMilliseconds / 1000.0,
      duration: _totalDuration,
      speed: speed,
    );
    // _logEvent(PlaybackEventType.syncLocal); // too noisy for history
  }

  Future<void> _syncToServer(Duration pos) async {
    if (_api == null || _playbackSessionId == null) return;
    try {
      await _api!.syncPlaybackSession(
        _playbackSessionId!,
        currentTime: pos.inMilliseconds / 1000.0,
        duration: _totalDuration,
      );
      // _logEvent(PlaybackEventType.syncServer); // too noisy for history
    } catch (_) {}
  }

  DateTime? _lastPauseTime;

  /// Auto-rewind calculation using exponential curve.
  /// activationDelay = minimum pause before rewind kicks in (0 = always).
  static double calculateAutoRewind(
      Duration pauseDuration, double minRewind, double maxRewind,
      {double activationDelay = 0}) {
    const tau = 500.0;
    final pauseSeconds = pauseDuration.inSeconds.toDouble();

    // Don't rewind if pause is shorter than activation delay
    if (pauseSeconds < activationDelay || pauseSeconds < 2) return 0;

    final range = maxRewind - minRewind;
    final rewind = minRewind + range * (1 - exp(-pauseSeconds / tau));
    return rewind.clamp(minRewind, maxRewind);
  }

  Future<void> play() async {
    debugPrint('[Service] play() called — lastPause=${_lastPauseTime != null}');
    // Auto-rewind on resume if enabled
    if (_lastPauseTime != null && _player != null) {
      final settings = await AutoRewindSettings.load();
      if (settings.enabled) {
        final pauseDuration = DateTime.now().difference(_lastPauseTime!);
        final rewindSeconds = calculateAutoRewind(
            pauseDuration, settings.minRewind, settings.maxRewind,
            activationDelay: settings.activationDelay);
        if (rewindSeconds > 0.5) {
          var newPos = _player!.position -
              Duration(milliseconds: (rewindSeconds * 1000).round());
          if (newPos < Duration.zero) newPos = Duration.zero;
          await _player!.seek(newPos);
          _logEvent(PlaybackEventType.autoRewind,
              detail: '${rewindSeconds.toStringAsFixed(1)}s rewind');
          debugPrint(
              '[Player] Auto-rewind ${rewindSeconds.toStringAsFixed(1)}s '
              '(paused ${pauseDuration.inSeconds}s)');
        }
      }
    }
    _lastPauseTime = null;
    _player?.play();
    _logEvent(PlaybackEventType.play);
    notifyListeners();
  }

  Future<void> pause() async {
    debugPrint('[Service] pause() called');
    _lastPauseTime = DateTime.now();
    await _player?.pause();
    _logEvent(PlaybackEventType.pause);
    notifyListeners();
    _saveProgressLocal(position);

    // Check manual offline before syncing
    final prefs = await SharedPreferences.getInstance();
    final manualOffline = prefs.getBool('manual_offline_mode') ?? false;
    if (manualOffline) return;

    if (!_isOfflineMode && _playbackSessionId != null) {
      _syncToServer(position);
    } else if (!_isOfflineMode && _currentItemId != null && _api != null) {
      _progressSync.syncToServer(api: _api!, itemId: _currentItemId!);
    }
  }

  Future<void> togglePlayPause() async {
    debugPrint('[Service] togglePlayPause() — isPlaying=$isPlaying');
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seekTo(Duration pos) async {
    debugPrint('[Service] seekTo(${pos.inSeconds}s)');
    await _player?.seek(pos);
    _logEvent(PlaybackEventType.seek,
        detail: 'to ${_formatPos(pos)}');
    notifyListeners();
  }

  Future<void> skipForward([int seconds = 30]) async {
    if (_player == null) return;
    debugPrint('[Service] skipForward(${seconds}s) — playing=${_player!.playing}');
    await _player!.seek(_player!.position + Duration(seconds: seconds));
    _logEvent(PlaybackEventType.skipForward, detail: '+${seconds}s');
    debugPrint('[Service] skipForward done — playing=${_player!.playing}');
  }

  Future<void> skipBackward([int seconds = 10]) async {
    if (_player == null) return;
    debugPrint('[Service] skipBackward(${seconds}s) — playing=${_player!.playing}');
    var n = _player!.position - Duration(seconds: seconds);
    if (n < Duration.zero) n = Duration.zero;
    await _player!.seek(n);
    _logEvent(PlaybackEventType.skipBackward, detail: '-${seconds}s');
    debugPrint('[Service] skipBackward done — playing=${_player!.playing}');
  }

  Future<void> setSpeed(double s) async {
    if (_player == null) return;
    debugPrint('[Service] setSpeed(${s}x) — before: ${_player!.speed}x');
    await _player!.setSpeed(s);
    debugPrint('[Service] setSpeed done — after: ${_player!.speed}x');
    _logEvent(PlaybackEventType.speedChange, detail: '${s.toStringAsFixed(2)}x');
    if (_currentItemId != null) {
      PlayerSettings.setBookSpeed(_currentItemId!, s);
    }
    notifyListeners();
  }

  Map<String, dynamic>? get currentChapter {
    if (_chapters.isEmpty || _player == null) return null;
    final pos = _player!.position.inMilliseconds / 1000.0;
    for (final ch in _chapters) {
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      if (pos >= start && pos < end) return ch as Map<String, dynamic>;
    }
    return null;
  }

  Future<void> stop() async {
    // Save final position locally
    if (_currentItemId != null) {
      await _saveProgressLocal(position);
    }

    // Check manual offline before syncing
    final prefs = await SharedPreferences.getInstance();
    final manualOffline = prefs.getBool('manual_offline_mode') ?? false;

    if (!manualOffline) {
      // Try server sync
      if (_playbackSessionId != null && _api != null) {
        await _syncToServer(position);
        try {
          await _api!.closePlaybackSession(_playbackSessionId!);
        } catch (_) {}
      } else if (_currentItemId != null && _api != null) {
        await _progressSync.syncToServer(api: _api!, itemId: _currentItemId!);
      }
    }

    await _player?.stop();
    _clearState();
    _chapters = [];
  }

  /// Stop playback without saving progress — used by reset progress.
  Future<void> stopWithoutSaving() async {
    // Close server session without syncing position
    if (_playbackSessionId != null && _api != null) {
      try {
        await _api!.closePlaybackSession(_playbackSessionId!);
      } catch (_) {}
    }
    await _player?.stop();
    _clearState();
    _chapters = [];
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _completionSub?.cancel();
    _player?.dispose();
    super.dispose();
  }
}
