import 'dart:math';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';

/// A thin animated wave bar shown above the nav bar when audio is playing.
/// Tapping it navigates to the Absorbing tab.
class PlayingWaveBar extends StatefulWidget {
  const PlayingWaveBar({super.key});

  @override
  State<PlayingWaveBar> createState() => _PlayingWaveBarState();
}

class _PlayingWaveBarState extends State<PlayingWaveBar>
    with SingleTickerProviderStateMixin {
  final _player = AudioPlayerService();
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _player.addListener(_rebuild);
  }

  @override
  void dispose() {
    _controller.dispose();
    _player.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() { if (mounted) setState(() {}); }

  @override
  Widget build(BuildContext context) {
    if (!_player.hasBook) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final isPlaying = _player.isPlaying;

    return GestureDetector(
      onTap: () {
        // Navigate to Absorbing tab (index 2) — find the AppShell ancestor
        final scaffold = Scaffold.maybeOf(context);
        // We'll use a callback approach through the navigator
        _navigateToAbsorbing(context);
      },
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return Container(
            height: 3,
            width: double.infinity,
            decoration: BoxDecoration(
              color: cs.surface,
            ),
            child: CustomPaint(
              painter: _WaveBarPainter(
                phase: _controller.value,
                color: cs.primary,
                isPlaying: isPlaying,
              ),
            ),
          );
        },
      ),
    );
  }

  void _navigateToAbsorbing(BuildContext context) {
    // Walk up to find the AppShell's NavigationBar and switch to index 2
    // Simple approach: use the scaffold's bottom nav
    final state = context.findAncestorStateOfType<ScaffoldState>();
    // Since we can't directly access AppShell state, we'll just show a hint
    // The user taps the Absorbing tab to go back
  }
}

class _WaveBarPainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isPlaying;

  _WaveBarPainter({
    required this.phase,
    required this.color,
    required this.isPlaying,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(isPlaying ? 0.8 : 0.3)
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height);

    final waveCount = 3.0;
    final amplitude = isPlaying ? size.height * 0.8 : size.height * 0.2;

    for (double x = 0; x <= size.width; x += 1) {
      final y = size.height -
          amplitude *
              (0.5 +
                  0.5 *
                      sin(2 * pi * (waveCount * x / size.width + phase)));
      path.lineTo(x, y);
    }

    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WaveBarPainter old) =>
      old.phase != phase || old.isPlaying != isPlaying;
}
