import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' hide PlaybackEvent;
import '../services/audio_player_service.dart';
import '../services/chromecast_service.dart';

// ─── PLAYBACK CONTROLS (card version) ───────────────────────

class CardPlaybackControls extends StatefulWidget {
  final AudioPlayerService player;
  final Color accent;
  final bool isActive;
  final bool isStarting;
  final VoidCallback onStart;
  final String? itemId;
  const CardPlaybackControls({super.key, required this.player, required this.accent, required this.isActive, required this.isStarting, required this.onStart, this.itemId});
  @override State<CardPlaybackControls> createState() => _CardPlaybackControlsState();
}

class _CardPlaybackControlsState extends State<CardPlaybackControls> with SingleTickerProviderStateMixin {
  int _backSkip = 10;
  int _forwardSkip = 30;
  late AnimationController _playPauseController;

  @override void initState() {
    super.initState();
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0, // 0 = play icon, 1 = pause icon
    );
    _loadSkipSettings();
    PlayerSettings.settingsChanged.addListener(_loadSkipSettings);
  }

  @override void didUpdateWidget(covariant CardPlaybackControls old) {
    super.didUpdateWidget(old);
  }

  void _loadSkipSettings() {
    PlayerSettings.getBackSkip().then((v) { if (mounted && v != _backSkip) setState(() => _backSkip = v); });
    PlayerSettings.getForwardSkip().then((v) { if (mounted && v != _forwardSkip) setState(() => _forwardSkip = v); });
  }

  @override void dispose() {
    PlayerSettings.settingsChanged.removeListener(_loadSkipSettings);
    _playPauseController.dispose();
    super.dispose();
  }

  Widget _skipIcon(int seconds, bool isForward, {bool active = true}) {
    final hasBuiltIn = [5, 10, 30].contains(seconds);
    if (hasBuiltIn) {
      IconData icon;
      if (isForward) { icon = seconds == 5 ? Icons.forward_5_rounded : seconds == 10 ? Icons.forward_10_rounded : Icons.forward_30_rounded; }
      else { icon = seconds == 5 ? Icons.replay_5_rounded : seconds == 10 ? Icons.replay_10_rounded : Icons.replay_30_rounded; }
      return Icon(icon, size: 38, color: active ? Colors.white70 : Colors.white24);
    }
    return Stack(alignment: Alignment.center, children: [
      Icon(isForward ? Icons.rotate_right_rounded : Icons.rotate_left_rounded, size: 38, color: active ? Colors.white70 : Colors.white24),
      Padding(padding: const EdgeInsets.only(top: 2), child: Text('$seconds', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: active ? Colors.white : Colors.white24))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isStarting) {
      return SizedBox(height: 64,
        child: Center(child: SizedBox(width: 64, height: 64,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.4), blurRadius: 25, spreadRadius: -5)],
            ),
            child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: widget.accent))),
          ),
        )),
      );
    }

    final cast = ChromecastService();

    return ListenableBuilder(
      listenable: cast,
      builder: (context, _) {
        // Check if we're casting this specific book
        final castItemId = widget.itemId ?? widget.player.currentItemId;
        final isCastingThis = cast.isCasting && cast.castingItemId == castItemId;

        if (isCastingThis) {
          return _buildCastControls(cast);
        }

        return _buildLocalControls();
      },
    );
  }

  /// Controls that route to ChromecastService
  Widget _buildCastControls(ChromecastService cast) {
    final isPlaying = cast.isPlaying;

    if (isPlaying) {
      _playPauseController.forward();
    } else {
      _playPauseController.reverse();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: cast.skipToPreviousChapter,
          child: SizedBox(width: 40, height: 40, child: Center(
            child: Icon(Icons.skip_previous_rounded, size: 24, color: Colors.white38),
          )),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () => cast.skipBackward(_backSkip),
          child: SizedBox(width: 52, height: 52, child: Center(child: _skipIcon(_backSkip, false))),
        ),
        const SizedBox(width: 16),
        GestureDetector(
          onTap: cast.togglePlayPause,
          child: SizedBox(
            width: 80, height: 80,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.4), blurRadius: 25, spreadRadius: -5)],
                  ),
                  child: Center(
                    child: AnimatedIcon(
                      icon: AnimatedIcons.play_pause,
                      progress: _playPauseController,
                      size: 34,
                      color: Colors.black87,
                    ),
                  ),
                ),
                // Cast indicator badge
                Positioned(
                  bottom: 4,
                  child: Icon(Icons.cast_connected_rounded, size: 14, color: widget.accent.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        GestureDetector(
          onTap: () => cast.skipForward(_forwardSkip),
          child: SizedBox(width: 52, height: 52, child: Center(child: _skipIcon(_forwardSkip, true))),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: cast.skipToNextChapter,
          child: SizedBox(width: 40, height: 40, child: Center(
            child: Icon(Icons.skip_next_rounded, size: 24, color: Colors.white38),
          )),
        ),
      ],
    );
  }

  /// Original local player controls
  Widget _buildLocalControls() {
    return StreamBuilder<PlayerState>(
      stream: widget.isActive ? widget.player.playerStateStream : const Stream.empty(),
      builder: (_, snapshot) {
        final isPlaying = widget.isActive && (snapshot.data?.playing ?? false);
        final isLoading = widget.isActive && (snapshot.data?.processingState == ProcessingState.loading || snapshot.data?.processingState == ProcessingState.buffering);

        if (isPlaying) {
          _playPauseController.forward();
        } else {
          _playPauseController.reverse();
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: widget.isActive ? widget.player.skipToPreviousChapter : null,
              child: SizedBox(width: 40, height: 40, child: Center(
                child: Icon(Icons.skip_previous_rounded, size: 24, color: widget.isActive ? Colors.white38 : Colors.white12),
              )),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: widget.isActive ? () => widget.player.skipBackward(_backSkip) : null,
              child: SizedBox(width: 52, height: 52, child: Center(child: _skipIcon(_backSkip, false, active: widget.isActive))),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: widget.isActive ? widget.player.togglePlayPause : widget.onStart,
              child: SizedBox(
                width: 80, height: 80,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.4), blurRadius: 25, spreadRadius: -5)],
                      ),
                      child: isLoading
                          ? Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: widget.accent)))
                          : Center(
                              child: AnimatedIcon(
                                icon: AnimatedIcons.play_pause,
                                progress: _playPauseController,
                                size: 34,
                                color: Colors.black87,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: widget.isActive ? () => widget.player.skipForward(_forwardSkip) : null,
              child: SizedBox(width: 52, height: 52, child: Center(child: _skipIcon(_forwardSkip, true, active: widget.isActive))),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: widget.isActive ? widget.player.skipToNextChapter : null,
              child: SizedBox(width: 40, height: 40, child: Center(
                child: Icon(Icons.skip_next_rounded, size: 24, color: widget.isActive ? Colors.white38 : Colors.white12),
              )),
            ),
          ],
        );
      },
    );
  }
}
