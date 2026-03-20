import 'package:flutter/material.dart';
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
  final bool showPlayButton;
  const CardPlaybackControls({super.key, required this.player, required this.accent, required this.isActive, required this.isStarting, required this.onStart, this.itemId, this.showPlayButton = false});
  @override State<CardPlaybackControls> createState() => _CardPlaybackControlsState();
}

class _CardPlaybackControlsState extends State<CardPlaybackControls> {
  int _backSkip = 10;
  int _forwardSkip = 30;

  @override void initState() {
    super.initState();
    _loadSkipSettings();
    PlayerSettings.settingsChanged.addListener(_loadSkipSettings);
  }

  void _loadSkipSettings() {
    PlayerSettings.getBackSkip().then((v) { if (mounted && v != _backSkip) setState(() => _backSkip = v); });
    PlayerSettings.getForwardSkip().then((v) { if (mounted && v != _forwardSkip) setState(() => _forwardSkip = v); });
  }

  @override void dispose() {
    PlayerSettings.settingsChanged.removeListener(_loadSkipSettings);
    super.dispose();
  }

  Widget _skipIcon(int seconds, bool isForward, {bool active = true}) {
    final cs = Theme.of(context).colorScheme;
    final hasBuiltIn = [5, 10, 30].contains(seconds);
    if (hasBuiltIn) {
      IconData icon;
      if (isForward) { icon = seconds == 5 ? Icons.forward_5_rounded : seconds == 10 ? Icons.forward_10_rounded : Icons.forward_30_rounded; }
      else { icon = seconds == 5 ? Icons.replay_5_rounded : seconds == 10 ? Icons.replay_10_rounded : Icons.replay_30_rounded; }
      return Icon(icon, size: 42, color: active ? cs.onSurface.withValues(alpha: 0.7) : cs.onSurface.withValues(alpha: 0.24));
    }
    return Stack(alignment: Alignment.center, children: [
      Icon(isForward ? Icons.rotate_right_rounded : Icons.rotate_left_rounded, size: 42, color: active ? cs.onSurface.withValues(alpha: 0.7) : cs.onSurface.withValues(alpha: 0.24)),
      Padding(padding: const EdgeInsets.only(top: 2), child: Text('$seconds', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: active ? cs.onSurface : cs.onSurface.withValues(alpha: 0.24)))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
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

  Widget _playPauseButton(ColorScheme cs, {required bool playing, required bool loading, required VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.onSurface,
          boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.4), blurRadius: 25, spreadRadius: -5)],
        ),
        child: loading
            ? Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: widget.accent)))
            : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: cs.surface),
      ),
    );
  }

  /// Controls that route to ChromecastService
  Widget _buildCastControls(ChromecastService cast) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: cast.skipToPreviousChapter,
          child: SizedBox(width: 52, height: 52, child: Center(
            child: Icon(Icons.skip_previous_rounded, size: 34, color: cs.onSurfaceVariant),
          )),
        ),
        GestureDetector(
          onTap: () => cast.skipBackward(_backSkip),
          child: SizedBox(width: 60, height: 60, child: Center(child: _skipIcon(_backSkip, false))),
        ),
        if (widget.showPlayButton)
          _playPauseButton(cs, playing: cast.isPlaying, loading: false, onTap: cast.togglePlayPause),
        GestureDetector(
          onTap: () => cast.skipForward(_forwardSkip),
          child: SizedBox(width: 60, height: 60, child: Center(child: _skipIcon(_forwardSkip, true))),
        ),
        GestureDetector(
          onTap: cast.skipToNextChapter,
          child: SizedBox(width: 52, height: 52, child: Center(
            child: Icon(Icons.skip_next_rounded, size: 34, color: cs.onSurfaceVariant),
          )),
        ),
      ],
    );
  }

  /// Original local player controls
  Widget _buildLocalControls() {
    final cs = Theme.of(context).colorScheme;
    final loading = widget.isStarting || (widget.isActive && widget.player.isLoadingOrBuffering);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: widget.isActive ? widget.player.skipToPreviousChapter : null,
          child: SizedBox(width: 52, height: 52, child: Center(
            child: Icon(Icons.skip_previous_rounded, size: 34, color: widget.isActive ? cs.onSurfaceVariant : cs.onSurface.withValues(alpha: 0.12)),
          )),
        ),
        GestureDetector(
          onTap: widget.isActive ? () => widget.player.skipBackward(_backSkip) : null,
          child: SizedBox(width: 60, height: 60, child: Center(child: _skipIcon(_backSkip, false, active: widget.isActive))),
        ),
        if (widget.showPlayButton)
          _playPauseButton(cs, playing: widget.isActive && widget.player.isPlaying, loading: loading,
            onTap: widget.isActive ? widget.player.togglePlayPause : widget.onStart),
        GestureDetector(
          onTap: widget.isActive ? () => widget.player.skipForward(_forwardSkip) : null,
          child: SizedBox(width: 60, height: 60, child: Center(child: _skipIcon(_forwardSkip, true, active: widget.isActive))),
        ),
        GestureDetector(
          onTap: widget.isActive ? widget.player.skipToNextChapter : null,
          child: SizedBox(width: 52, height: 52, child: Center(
            child: Icon(Icons.skip_next_rounded, size: 34, color: widget.isActive ? cs.onSurfaceVariant : cs.onSurface.withValues(alpha: 0.12)),
          )),
        ),
      ],
    );
  }
}
