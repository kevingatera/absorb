import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import '../services/chromecast_service.dart';

/// Shows a device picker bottom sheet using the devicesStream.
void showCastDevicePicker(BuildContext context) {
  final cast = ChromecastService();
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            const Text('Cast to Device', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: StreamBuilder<List<GoogleCastDevice>>(
                stream: cast.devicesStream,
                builder: (_, snap) {
                  final devices = snap.data ?? [];
                  if (devices.isEmpty) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38)),
                          SizedBox(height: 12),
                          Text('Searching for Cast devices...', style: TextStyle(color: Colors.white38, fontSize: 13)),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (_, i) {
                      final device = devices[i];
                      return ListTile(
                        leading: const Icon(Icons.cast_rounded, color: Colors.white54),
                        title: Text(device.friendlyName, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(device.modelName ?? '', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        onTap: () {
                          Navigator.pop(ctx);
                          cast.connectToDevice(device);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Bottom sheet with cast controls when connected.
class CastControlSheet extends StatelessWidget {
  const CastControlSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ChromecastService(),
      builder: (context, _) {
        final cast = ChromecastService();
        final accent = Theme.of(context).colorScheme.primary;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 20),

                Row(children: [
                  Icon(Icons.cast_connected_rounded, size: 20, color: accent),
                  const SizedBox(width: 10),
                  Expanded(child: Text(cast.connectedDeviceName ?? 'Cast Device',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: accent), overflow: TextOverflow.ellipsis)),
                ]),

                if (cast.isCasting) ...[
                  const SizedBox(height: 20),
                  Row(children: [
                    if (cast.castingCoverUrl != null)
                      ClipRRect(borderRadius: BorderRadius.circular(8),
                        child: Image.network(cast.castingCoverUrl!, width: 48, height: 48, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(width: 48, height: 48,
                            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.headphones_rounded, size: 24, color: Colors.white24)))),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cast.castingTitle ?? 'Unknown', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(cast.castingAuthor ?? '', style: const TextStyle(fontSize: 12, color: Colors.white60), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ])),
                  ]),
                  const SizedBox(height: 16),

                  StreamBuilder<Duration>(
                    stream: cast.castPositionStream?.map((d) => d ?? Duration.zero),
                    initialData: cast.castPosition,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final totalMs = (cast.castingDuration * 1000).round();
                      final progress = totalMs > 0 ? (pos.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
                      return Column(children: [
                        LinearProgressIndicator(value: progress, backgroundColor: Colors.white10, color: accent, minHeight: 3, borderRadius: BorderRadius.circular(2)),
                        const SizedBox(height: 6),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(_fmt(pos), style: const TextStyle(fontSize: 11, color: Colors.white38)),
                          Text(_fmt(Duration(seconds: cast.castingDuration.round())), style: const TextStyle(fontSize: 11, color: Colors.white38)),
                        ]),
                      ]);
                    },
                  ),
                  const SizedBox(height: 12),

                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    IconButton(onPressed: cast.skipToPreviousChapter, icon: const Icon(Icons.skip_previous_rounded, size: 24, color: Colors.white38)),
                    IconButton(onPressed: () => cast.skipBackward(10), icon: const Icon(Icons.replay_10_rounded, size: 32, color: Colors.white70)),
                    const SizedBox(width: 8),
                    Container(width: 52, height: 52,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white,
                        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.3), blurRadius: 16, spreadRadius: -4)]),
                      child: IconButton(onPressed: cast.togglePlayPause,
                        icon: Icon(cast.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28, color: Colors.black87))),
                    const SizedBox(width: 8),
                    IconButton(onPressed: () => cast.skipForward(30), icon: const Icon(Icons.forward_30_rounded, size: 32, color: Colors.white70)),
                    IconButton(onPressed: cast.skipToNextChapter, icon: const Icon(Icons.skip_next_rounded, size: 24, color: Colors.white38)),
                  ]),
                ],

                const SizedBox(height: 20),
                Row(children: [
                  if (cast.isCasting) ...[
                    Expanded(child: OutlinedButton.icon(
                      onPressed: () { cast.stopCasting(); Navigator.of(context).pop(); },
                      icon: const Icon(Icons.stop_rounded, size: 18), label: const Text('Stop Casting'),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white60, side: const BorderSide(color: Colors.white12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
                    const SizedBox(width: 12),
                  ],
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () { cast.disconnect(); Navigator.of(context).pop(); },
                    icon: const Icon(Icons.close_rounded, size: 18), label: const Text('Disconnect'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent.withValues(alpha: 0.8),
                      side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
