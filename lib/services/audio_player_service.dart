import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'download_service.dart';
import 'playback_history_service.dart' hide PlaybackEvent;
import 'progress_sync_service.dart';
import 'sleep_timer_service.dart';
import 'equalizer_service.dart';
import 'android_auto_service.dart';

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
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
  );
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
    if (_service != null) {
      final skipAmount = await PlayerSettings.getForwardSkip();
      await _service!.skipForward(skipAmount);
    } else {
      final skipAmount = await PlayerSettings.getForwardSkip();
      await _player.seek(_player.position + Duration(seconds: skipAmount));
    }
    debugPrint('[Handler] fastForward done — playing=${_player.playing}');
  }

  @override
  Future<void> rewind() async {
    debugPrint('[Handler] rewind() — seeking back');
    if (_service != null) {
      final skipAmount = await PlayerSettings.getBackSkip();
      await _service!.skipBackward(skipAmount);
    } else {
      final skipAmount = await PlayerSettings.getBackSkip();
      var pos = _player.position - Duration(seconds: skipAmount);
      if (pos < Duration.zero) pos = Duration.zero;
      await _player.seek(pos);
    }
    debugPrint('[Handler] rewind done — playing=${_player.playing}');
  }

  // Note: skipToNext/skipToPrevious are intentionally NOT overridden here.
  // Android Auto renders controls based on which actions the handler declares.
  // Overriding skip methods causes Auto to show track-skip (⏭) icons instead
  // of the rewind/forward (↻) circular arrows we want for audiobooks.
  // Headset button presses route through onClick() below instead.

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

  // ─── Android Auto browse tree ──────────────────────────────────────

  final _autoService = AndroidAutoService();

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    debugPrint('[Handler] getChildren($parentMediaId)');
    await _autoService.refresh();
    return _autoService.getChildrenOf(parentMediaId);
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    debugPrint('[Handler] getMediaItem($mediaId)');
    return _autoService.getMediaItem(mediaId);
  }

  @override
  Future<List<MediaItem>> search(String query,
      [Map<String, dynamic>? extras]) async {
    debugPrint('[Handler] search("$query")');
    return _autoService.search(query);
  }

  @override
  Future<void> prepareFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    debugPrint('[Handler] prepareFromMediaId($mediaId)');
    await _playFromAutoMediaId(mediaId);
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    debugPrint('[Handler] playFromMediaId($mediaId)');
    await _playFromAutoMediaId(mediaId);
  }

  Future<void> _playFromAutoMediaId(String mediaId) async {
    final absId = AutoMediaIds.absItemId(mediaId);
    if (absId == null) {
      debugPrint('[Handler] Invalid media ID for playback: $mediaId');
      return;
    }

    if (_service == null) {
      debugPrint('[Handler] No service bound — cannot play');
      return;
    }

    final api = await _autoService.getApi();
    if (api == null) {
      debugPrint('[Handler] No API credentials — cannot play');
      return;
    }

    // Try to find in cached entries first
    var entry = _autoService.findEntry(absId);

    // If not in cache (e.g. from series/author drilldown or search),
    // fetch the item details from server
    if (entry == null) {
      debugPrint('[Handler] Book not cached, fetching from server: $absId');
      try {
        final response = await api.getLibraryItem(absId);
        if (response != null) {
          final media = response['media'] as Map<String, dynamic>?;
          final metadata = media?['metadata'] as Map<String, dynamic>? ?? {};
          entry = AutoBookEntry(
            id: absId,
            title: metadata['title'] as String? ?? 'Unknown',
            author: metadata['authorName'] as String? ?? '',
            duration: (media?['duration'] as num?)?.toDouble() ?? 0,
            coverUrl: api.getCoverUrl(absId, width: 400),
            chapters: media?['chapters'] as List<dynamic>? ?? [],
          );
        }
      } catch (e) {
        debugPrint('[Handler] Error fetching item: $e');
      }
    }

    if (entry == null) {
      debugPrint('[Handler] Book not found: $absId');
      return;
    }

    debugPrint('[Handler] Android Auto play: "${entry.title}" by ${entry.author}');

    await _service!.playItem(
      api: api,
      itemId: entry.id,
      title: entry.title,
      author: entry.author,
      coverUrl: entry.coverUrl,
      totalDuration: entry.duration,
      chapters: entry.chapters,
      startTime: entry.currentTime ?? 0,
    );
  }
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

  // ── Multi-file track offset tracking ──
  // For ConcatenatingAudioSource, _player.position is track-relative.
  // We store cumulative start offsets so we can compute absolute book position.
  List<double> _trackStartOffsets = []; // [0, dur0, dur0+dur1, ...]
  int _currentTrackIndex = 0;
  StreamSubscription? _indexSub;

  /// The last seek target in seconds (absolute book position).
  /// UI can use this to immediately snap to the target before stream catches up.
  double? _lastSeekTargetSeconds;
  DateTime? _lastSeekTime;

  /// If a seek happened within the last 2 seconds, returns the seek target.
  /// Otherwise returns null (use the stream position).
  double? get activeSeekTarget {
    if (_lastSeekTargetSeconds == null || _lastSeekTime == null) return null;
    final elapsed = DateTime.now().difference(_lastSeekTime!).inMilliseconds;
    if (elapsed > 2000) {
      _lastSeekTargetSeconds = null;
      _lastSeekTime = null;
      return null;
    }
    return _lastSeekTargetSeconds;
  }

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

  /// Absolute book position (accounts for multi-file track offsets).
  Duration get position {
    if (_player == null) return Duration.zero;
    final trackRelative = _player!.position;
    if (_trackStartOffsets.length <= 1) return trackRelative; // single file
    final offsetMs = (_trackStartOffsets[_currentTrackIndex] * 1000).round();
    final result = trackRelative + Duration(milliseconds: offsetMs);
    // Don't log every call — this is called very frequently by sync and UI
    return result;
  }

  /// Absolute book position stream (adjusted for multi-file offsets).
  /// IMPORTANT: Always returns a mapped stream that checks offsets at event time.
  /// Do NOT short-circuit to raw positionStream — the caller may subscribe before
  /// track offsets are built, and would miss the offset transform forever.
  Stream<Duration> get absolutePositionStream {
    if (_player == null) return const Stream.empty();
    return _player!.positionStream.map((trackRelative) {
      if (_trackStartOffsets.length <= 1) return trackRelative; // single file, no offset
      final trackIdx = _currentTrackIndex;
      final offsetMs = (_trackStartOffsets[trackIdx] * 1000).round();
      final absolute = trackRelative + Duration(milliseconds: offsetMs);
      return absolute;
    });
  }

  Duration get duration => _player?.duration ?? Duration.zero;
  double get speed => _player?.speed ?? 1.0;

  /// Build track start offsets from audioTracks list.
  void _buildTrackOffsets(List<dynamic> audioTracks) {
    _trackStartOffsets = [0.0];
    double acc = 0;
    for (final t in audioTracks) {
      final track = t as Map<String, dynamic>;
      final dur = (track['duration'] as num?)?.toDouble() ?? 0;
      acc += dur;
      _trackStartOffsets.add(acc);
    }
    debugPrint('[Player] Track offsets: $_trackStartOffsets');
  }

  /// Subscribe to track index changes for multi-file playback.
  void _subscribeTrackIndex() {
    _indexSub?.cancel();
    if (_player == null || _trackStartOffsets.length <= 1) return;
    _indexSub = _player!.currentIndexStream.listen((index) {
      if (index != null) {
        _currentTrackIndex = index.clamp(0, _trackStartOffsets.length - 2);
      }
    });
  }

  /// Seek to an absolute book position, handling multi-file offset conversion.
  Future<void> _seekAbsolute(double absoluteSeconds) async {
    if (_player == null) return;

    // Record seek target so UI can snap immediately
    _lastSeekTargetSeconds = absoluteSeconds;
    _lastSeekTime = DateTime.now();

    if (_trackStartOffsets.length <= 1) {
      // Single file — seek directly
      await _player!.seek(Duration(milliseconds: (absoluteSeconds * 1000).round()));
      return;
    }
    // Multi-file — find the right track and local offset
    for (int i = 0; i < _trackStartOffsets.length - 1; i++) {
      final trackStart = _trackStartOffsets[i];
      final trackEnd = _trackStartOffsets[i + 1];
      if (absoluteSeconds < trackEnd || i == _trackStartOffsets.length - 2) {
        final localOffset = absoluteSeconds - trackStart;
        // Update index BEFORE seeking so positionStream events use the right offset
        _currentTrackIndex = i;
        await _player!.seek(Duration(milliseconds: (localOffset * 1000).round()), index: i);
        return;
      }
    }
  }

  /// MUST be called after Activity is ready.
  static Future<void> init() async {
    _handler = await AudioService.init<AudioPlayerHandler>(
      builder: () => AudioPlayerHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.audiobookshelf.app.channel.audio',
        androidNotificationChannelName: 'Absorb',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'drawable/ic_notification',
        androidBrowsableRootExtras: {
          AndroidContentStyle.supportedKey: true,
          AndroidContentStyle.browsableHintKey:
              AndroidContentStyle.categoryListItemHintValue,
          AndroidContentStyle.playableHintKey:
              AndroidContentStyle.gridItemHintValue,
          'android.media.browse.SEARCH_SUPPORTED': true,
        },
      ),
    );
    // Bind service so handler routes play/pause through service (for auto-rewind)
    _handler!.bindService(_instance);
    debugPrint('[Player] AudioService initialized');

    // Configure audio session for audiobook playback
    await _configureAudioSession();
  }

  static StreamSubscription? _interruptSub;
  static StreamSubscription? _noisySub;

  static Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    _interruptSub?.cancel();
    _interruptSub = session.interruptionEventStream.listen((event) async {
      final service = _instance;

      if (event.begin) {
        if (service.isPlaying) {
          debugPrint('[AudioSession] Interrupted (${event.type}) — pausing');
          service._wasPlayingBeforeInterrupt = true;
          await service.pause();
        }
      } else {
        if (service._wasPlayingBeforeInterrupt) {
          debugPrint('[AudioSession] Interruption ended — resuming');
          service._wasPlayingBeforeInterrupt = false;
          await Future.delayed(const Duration(milliseconds: 300));
          await service.play();
        }
      }
    });

    // Headphones unplugged — pause, no auto-resume
    _noisySub?.cancel();
    _noisySub = session.becomingNoisyEventStream.listen((_) async {
      final service = _instance;
      if (service.isPlaying) {
        debugPrint('[AudioSession] Becoming noisy — pausing');
        await service.pause();
      }
    });
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
    // New book = fresh session — clear any auto sleep dismissal
    SleepTimerService().resetDismiss();
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
    final currentAbsolutePos = position; // use absolute position getter
    final currentSpeed = _player!.speed;

    debugPrint('[Player] Hot-swapping to local files at ${currentAbsolutePos.inSeconds}s');

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

    // Rebuild track offsets for local files
    if (audioTracks != null) {
      _buildTrackOffsets(audioTracks);
    } else {
      _trackStartOffsets = [0.0];
    }
    _currentTrackIndex = 0;

    try {
      AudioSource source;
      if (localPaths.length == 1) {
        source = AudioSource.file(localPaths.first);
      } else {
        final sources = localPaths.map((p) => AudioSource.file(p) as AudioSource).toList();
        source = ConcatenatingAudioSource(children: sources);
      }

      await _player!.setAudioSource(source);

      // Seek to the same absolute position
      final posSeconds = currentAbsolutePos.inMilliseconds / 1000.0;
      await _seekAbsolute(posSeconds);

      _subscribeTrackIndex();

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
      // Build multi-file track offsets for absolute position tracking
      if (audioTracks != null) {
        _buildTrackOffsets(audioTracks);
      } else {
        _trackStartOffsets = [0.0]; // single file fallback
      }
      _currentTrackIndex = 0;

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
        await _seekAbsolute(startTime);
      }

      _subscribeTrackIndex();
      _pushMediaItem(itemId, title, author, coverUrl, totalDuration);
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      await _player!.setSpeed(speed);
      debugPrint('[Player] Starting local playback at ${speed}x');
      _player!.play();
      notifyListeners();
      _setupSync();
      // Fresh session — reset auto sleep dismiss and check
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();
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
      // Build multi-file track offsets for absolute position tracking
      _buildTrackOffsets(audioTracks);
      _currentTrackIndex = 0;

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
        await _seekAbsolute(startTime);
      }

      _subscribeTrackIndex();
      _pushMediaItem(itemId, title, author, coverUrl, totalDuration);
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      await _player!.setSpeed(speed);
      debugPrint('[Player] Starting stream playback at ${speed}x');
      _player!.play();
      notifyListeners();
      _setupSync();
      // Fresh session — reset auto sleep dismiss and check
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();
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
    _trackStartOffsets = [];
    _currentTrackIndex = 0;
    _lastSeekTargetSeconds = null;
    _lastSeekTime = null;
    _indexSub?.cancel();
    _indexSub = null;
    _syncSub?.cancel();
    _syncSub = null;
    _completionSub?.cancel();
    _completionSub = null;
    _eqSessionSub?.cancel();
    _eqSessionSub = null;
    notifyListeners();
  }

  int _lastSyncSecond = -1;

  StreamSubscription? _eqSessionSub;

  void _attachEqualizer() {
    _eqSessionSub?.cancel();
    _eqSessionSub = null;
    if (_player == null) return;

    // Try immediately — works if audio source is already set
    final sessionId = _player!.androidAudioSessionId;
    if (sessionId != null && sessionId > 0) {
      EqualizerService().attachToSession(sessionId);
      return;
    }

    // Not available yet — poll briefly after playback starts
    // (safer than androidAudioSessionIdStream which may not exist in all versions)
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_player == null) return;
      final id = _player!.androidAudioSessionId;
      if (id != null && id > 0) {
        debugPrint('[Player] Got audio session ID (delayed): $id');
        EqualizerService().attachToSession(id);
      } else {
        // Try once more after another second
        Future.delayed(const Duration(seconds: 1), () {
          if (_player == null) return;
          final id2 = _player!.androidAudioSessionId;
          if (id2 != null && id2 > 0) {
            debugPrint('[Player] Got audio session ID (retry): $id2');
            EqualizerService().attachToSession(id2);
          }
        });
      }
    });
  }

  void _setupSync() {
    _syncSub?.cancel();
    _lastSyncSecond = -1;

    // Attach equalizer to current audio session
    _attachEqualizer();

    _syncSub = _player?.positionStream.listen((trackRelativePos) async {
      // Convert track-relative position to absolute book position
      final absolutePos = position; // uses the getter which adds track offset
      final sec = absolutePos.inSeconds;
      if (sec <= 0) return;

      // ─── Completion detection ─────────────────────────────
      // Check if we've reached the end of the book
      final posSeconds = absolutePos.inMilliseconds / 1000.0;
      if (_totalDuration > 0 && posSeconds >= _totalDuration - 1.0) {
        _onPlaybackComplete();
        return;
      }

      // Save locally every 5 seconds (always works, even offline)
      if (sec % 5 == 0 && sec != _lastSyncSecond && _currentItemId != null) {
        _lastSyncSecond = sec;
        _saveProgressLocal(absolutePos);

        // Also sync to server every 15 seconds (unless manual offline)
        if (sec % 15 == 0) {
          final prefs = await SharedPreferences.getInstance();
          final manualOffline = prefs.getBool('manual_offline_mode') ?? false;

          if (manualOffline) {
            // Manual offline — local save only, no server sync
          } else if (!_isOfflineMode && _playbackSessionId != null) {
            // Streaming/local with session: sync via session
            _syncToServer(absolutePos);
          } else if (!_isOfflineMode && _api != null && _currentItemId != null) {
            // No session but online — sync via progress update endpoint
            debugPrint('[Player] No-session sync — sending to server at ${absolutePos.inSeconds}s');
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
    final ct = pos.inMilliseconds / 1000.0;
    await _progressSync.saveLocal(
      itemId: _currentItemId!,
      currentTime: ct,
      duration: _totalDuration,
      speed: speed,
    );
    // _logEvent(PlaybackEventType.syncLocal); // too noisy for history
  }

  Future<void> _syncToServer(Duration pos) async {
    if (_api == null || _playbackSessionId == null) return;
    final ct = pos.inMilliseconds / 1000.0;
    try {
      await _api!.syncPlaybackSession(
        _playbackSessionId!,
        currentTime: ct,
        duration: _totalDuration,
      );
      // _logEvent(PlaybackEventType.syncServer); // too noisy for history
    } catch (_) {}
  }

  DateTime? _lastPauseTime;
  bool _wasPlayingBeforeInterrupt = false;

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
          final currentAbsolutePos = position.inMilliseconds / 1000.0;
          var newPosSeconds = currentAbsolutePos - rewindSeconds;
          if (newPosSeconds < 0) newPosSeconds = 0;
          await _seekAbsolute(newPosSeconds);
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
    // Check auto sleep on every resume — catches window entry between pauses
    SleepTimerService().checkAutoSleep();
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
    await _seekAbsolute(pos.inMilliseconds / 1000.0);
    _logEvent(PlaybackEventType.seek,
        detail: 'to ${_formatPos(pos)}');
    notifyListeners();
  }

  Future<void> skipForward([int seconds = 30]) async {
    if (_player == null) return;
    debugPrint('[Service] skipForward(${seconds}s) — playing=${_player!.playing}');
    final newPos = position + Duration(seconds: seconds);
    await _seekAbsolute(newPos.inMilliseconds / 1000.0);
    _logEvent(PlaybackEventType.skipForward, detail: '+${seconds}s');
    debugPrint('[Service] skipForward done — playing=${_player!.playing}');
  }

  Future<void> skipBackward([int seconds = 10]) async {
    if (_player == null) return;
    debugPrint('[Service] skipBackward(${seconds}s) — playing=${_player!.playing}');
    var n = position - Duration(seconds: seconds);
    if (n < Duration.zero) n = Duration.zero;
    await _seekAbsolute(n.inMilliseconds / 1000.0);
    _logEvent(PlaybackEventType.skipBackward, detail: '-${seconds}s');
    debugPrint('[Service] skipBackward done — playing=${_player!.playing}');
  }

  Future<void> skipToNextChapter() async {
    if (_player == null || _chapters.isEmpty) return;
    final posS = position.inMilliseconds / 1000.0;
    for (int i = 0; i < _chapters.length; i++) {
      final start = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
      if (start > posS + 1.0) {
        debugPrint('[Service] skipToNextChapter → chapter $i at ${start}s');
        await _seekAbsolute(start);
        _logEvent(PlaybackEventType.seek, detail: 'next chapter');
        notifyListeners();
        return;
      }
    }
  }

  Future<void> skipToPreviousChapter() async {
    if (_player == null || _chapters.isEmpty) return;
    final posS = position.inMilliseconds / 1000.0;
    // If more than 3s into current chapter, go to start of current chapter
    // Otherwise go to previous chapter
    for (int i = _chapters.length - 1; i >= 0; i--) {
      final start = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
      if (start < posS - 3.0) {
        debugPrint('[Service] skipToPreviousChapter → chapter $i at ${start}s');
        await _seekAbsolute(start);
        _logEvent(PlaybackEventType.seek, detail: 'prev chapter');
        notifyListeners();
        return;
      }
    }
    // If at the very start, seek to 0
    await _seekAbsolute(0);
    notifyListeners();
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
    final pos = position.inMilliseconds / 1000.0; // absolute book position
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
    // Cancel sleep timer when playback is stopped
    if (SleepTimerService().isActive) {
      SleepTimerService().cancel();
    }
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
    _indexSub?.cancel();
    _player?.dispose();
    super.dispose();
  }
}
