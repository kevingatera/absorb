import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'audio_player_service.dart';

enum SleepTimerMode { off, time, chapters }

class SleepTimerService extends ChangeNotifier {
  // Singleton
  static final SleepTimerService _instance = SleepTimerService._();
  factory SleepTimerService() => _instance;
  SleepTimerService._();

  final _player = AudioPlayerService();

  // ── State ──
  SleepTimerMode _mode = SleepTimerMode.off;
  
  // Time mode
  Duration _timeRemaining = Duration.zero;
  Timer? _timer;
  
  // Chapter mode
  int _chaptersRemaining = 0;
  int _targetChapterIndex = -1; // chapter index where we stop
  StreamSubscription? _positionSub;
  
  // Shake detection
  bool _shakeEnabled = true;
  StreamSubscription? _accelSub;
  DateTime _lastShake = DateTime(2000);
  static const _shakeThreshold = 15.0; // m/s²
  static const _shakeCooldown = Duration(seconds: 2);

  // ── Getters ──
  SleepTimerMode get mode => _mode;
  Duration get timeRemaining => _timeRemaining;
  int get chaptersRemaining => _chaptersRemaining;
  bool get isActive => _mode != SleepTimerMode.off;
  bool get shakeEnabled => _shakeEnabled;

  String get displayLabel {
    if (_mode == SleepTimerMode.time) {
      final totalMins = _timeRemaining.inMinutes;
      if (totalMins > 0) return '${totalMins}m';
      return '<1m';
    } else if (_mode == SleepTimerMode.chapters) {
      return '$_chaptersRemaining ch';
    }
    return '';
  }

  // ── Time-based sleep ──
  
  void setTimeSleep(Duration duration) {
    cancel();
    _mode = SleepTimerMode.time;
    _timeRemaining = duration;
    _startTimeCountdown();
    _startShakeDetection();
    notifyListeners();
    debugPrint('[SleepTimer] Set time sleep: ${duration.inMinutes}m');
  }

  void _startTimeCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_timeRemaining.inSeconds <= 0) {
        _triggerSleep();
        return;
      }
      // Only count down when playing
      if (_player.isPlaying) {
        _timeRemaining -= const Duration(seconds: 1);
        notifyListeners();
      }
    });
  }

  /// Add time (used by shake reset in time mode)
  void addTime(Duration extra) {
    if (_mode != SleepTimerMode.time) return;
    _timeRemaining += extra;
    notifyListeners();
    debugPrint('[SleepTimer] Added ${extra.inMinutes}m — now ${_timeRemaining.inMinutes}m');
  }

  // ── Chapter-based sleep ──

  void setChapterSleep(int numChapters) {
    cancel();
    _mode = SleepTimerMode.chapters;
    _chaptersRemaining = numChapters;
    
    // Calculate the target chapter index
    final currentIdx = _getCurrentChapterIndex();
    if (currentIdx >= 0) {
      _targetChapterIndex = currentIdx + numChapters;
      debugPrint('[SleepTimer] Set chapter sleep: $numChapters chapters '
          '(current=$currentIdx, target=$_targetChapterIndex)');
    } else {
      _targetChapterIndex = -1;
      debugPrint('[SleepTimer] Set chapter sleep: $numChapters chapters (no current chapter)');
    }
    
    _startChapterMonitor();
    _startShakeDetection();
    notifyListeners();
  }

  void _startChapterMonitor() {
    _positionSub?.cancel();
    _positionSub = _player.positionStream.listen((pos) {
      if (!_player.isPlaying) return;
      
      final currentIdx = _getCurrentChapterIndex();
      if (currentIdx < 0) return;
      
      // Update chapters remaining
      if (_targetChapterIndex >= 0) {
        _chaptersRemaining = (_targetChapterIndex - currentIdx).clamp(0, 999);
        notifyListeners();
        
        // Check if we've reached the end of the target chapter
        if (currentIdx >= _targetChapterIndex) {
          // We want to stop at the END of the target chapter, 
          // which is when we enter the NEXT chapter
          _triggerSleep();
        }
      }
    });
  }

  /// Add a chapter (used by shake reset in chapter mode)
  void addChapter() {
    if (_mode != SleepTimerMode.chapters) return;
    _chaptersRemaining++;
    _targetChapterIndex++;
    notifyListeners();
    debugPrint('[SleepTimer] Added 1 chapter — now $_chaptersRemaining remaining');
  }

  // ── Common ──

  int _getCurrentChapterIndex() {
    final chapters = _player.chapters;
    if (chapters.isEmpty) return -1;
    final pos = _player.position.inMilliseconds / 1000.0;
    for (int i = 0; i < chapters.length; i++) {
      final ch = chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      if (pos >= start && pos < end) return i;
    }
    return -1;
  }

  void _triggerSleep() {
    debugPrint('[SleepTimer] Triggering sleep — pausing playback');
    _player.pause();
    cancel();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _positionSub?.cancel();
    _positionSub = null;
    _accelSub?.cancel();
    _accelSub = null;
    _mode = SleepTimerMode.off;
    _timeRemaining = Duration.zero;
    _chaptersRemaining = 0;
    _targetChapterIndex = -1;
    notifyListeners();
    debugPrint('[SleepTimer] Cancelled');
  }

  // ── Shake detection ──

  Future<void> _startShakeDetection() async {
    _shakeEnabled = await PlayerSettings.getShakeToResetSleep();
    if (!_shakeEnabled) return;
    
    _accelSub?.cancel();
    _accelSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z);
      // Subtract gravity (~9.8) and check threshold
      if (magnitude > _shakeThreshold) {
        final now = DateTime.now();
        if (now.difference(_lastShake) > _shakeCooldown) {
          _lastShake = now;
          _onShake();
        }
      }
    });
  }

  // Toast callback — UI sets this to show snackbars
  void Function(String message)? onToast;

  void _onShake() async {
    if (!isActive) return;
    debugPrint('[SleepTimer] Shake detected!');
    
    if (_mode == SleepTimerMode.time) {
      final addMins = await PlayerSettings.getShakeAddMinutes();
      addTime(Duration(minutes: addMins));
      onToast?.call('+$addMins min added!');
    } else if (_mode == SleepTimerMode.chapters) {
      addChapter();
      onToast?.call('+1 chapter added!');
    }
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}
