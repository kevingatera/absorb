import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import '../services/chromecast_service.dart';
import '../services/api_service.dart';

/// Shows a device picker. If castAfter params are provided, automatically
/// casts the book after connecting to the selected device.
void showCastDevicePicker(
  BuildContext context, {
  ApiService? api,
  String? itemId,
  String? title,
  String? author,
  String? coverUrl,
  double? totalDuration,
  List<dynamic>? chapters,
}) {
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
                          if (api != null && itemId != null) {
                            _waitAndCast(cast, api: api, itemId: itemId,
                              title: title ?? '', author: author ?? '',
                              coverUrl: coverUrl, totalDuration: totalDuration ?? 0,
                              chapters: chapters ?? []);
                          }
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

/// Wait for connection to establish, then cast the item.
void _waitAndCast(
  ChromecastService cast, {
  required ApiService api,
  required String itemId,
  required String title,
  required String author,
  required String? coverUrl,
  required double totalDuration,
  required List<dynamic> chapters,
}) {
  if (cast.isConnected) {
    cast.castItem(api: api, itemId: itemId, title: title, author: author,
      coverUrl: coverUrl, totalDuration: totalDuration, chapters: chapters);
    return;
  }

  StreamSubscription? sub;
  Timer? timeout;

  void cleanup() {
    sub?.cancel();
    timeout?.cancel();
  }

  sub = GoogleCastSessionManager.instance.currentSessionStream.listen((session) {
    if (cast.isConnected) {
      cleanup();
      Future.delayed(const Duration(milliseconds: 500), () {
        cast.castItem(api: api, itemId: itemId, title: title, author: author,
          coverUrl: coverUrl, totalDuration: totalDuration, chapters: chapters);
      });
    }
  });

  timeout = Timer(const Duration(seconds: 15), () {
    debugPrint('[Cast] Connection timeout — giving up auto-cast');
    cleanup();
  });
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
                  // Book info + chapter
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
                      if (cast.currentChapterTitle != null) ...[
                        const SizedBox(height: 2),
                        Text(cast.currentChapterTitle!, style: TextStyle(fontSize: 11, color: accent.withValues(alpha: 0.7)), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ])),
                  ]),
                  const SizedBox(height: 16),

                  // Progress bar
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

                  // Playback controls
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

                  // Speed control
                  const SizedBox(height: 12),
                  _CastSpeedControl(cast: cast, accent: accent),

                  // Volume control
                  const SizedBox(height: 8),
                  _CastVolumeControl(cast: cast, accent: accent),
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

// ─── Cast Speed Control ─────────────────────────────────────

class _CastSpeedControl extends StatelessWidget {
  final ChromecastService cast;
  final Color accent;
  const _CastSpeedControl({required this.cast, required this.accent});

  static const _presets = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    final speed = cast.castSpeed;
    return Row(
      children: [
        Icon(Icons.speed_rounded, size: 16, color: accent),
        const SizedBox(width: 8),
        Text('${speed.toStringAsFixed(2)}x',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _presets.map((s) {
                final selected = (s - speed).abs() < 0.01;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => cast.setSpeed(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected ? accent.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: selected ? accent.withValues(alpha: 0.4) : Colors.white12),
                      ),
                      child: Text('${s}x',
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: selected ? accent : Colors.white54,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Cast Volume Control ────────────────────────────────────

class _CastVolumeControl extends StatefulWidget {
  final ChromecastService cast;
  final Color accent;
  const _CastVolumeControl({required this.cast, required this.accent});

  @override
  State<_CastVolumeControl> createState() => _CastVolumeControlState();
}

class _CastVolumeControlState extends State<_CastVolumeControl> {
  late double _localVolume;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _localVolume = widget.cast.volume;
  }

  @override
  Widget build(BuildContext context) {
    final vol = _dragging ? _localVolume : widget.cast.volume;
    return Row(
      children: [
        Icon(
          vol <= 0.01 ? Icons.volume_off_rounded
            : vol < 0.5 ? Icons.volume_down_rounded
            : Icons.volume_up_rounded,
          size: 18, color: Colors.white54,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: widget.accent,
              inactiveTrackColor: Colors.white12,
              thumbColor: widget.accent,
              overlayColor: widget.accent.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: vol.clamp(0.0, 1.0),
              min: 0.0,
              max: 1.0,
              onChangeStart: (_) => _dragging = true,
              onChanged: (v) => setState(() => _localVolume = v),
              onChangeEnd: (v) {
                _dragging = false;
                widget.cast.setVolume(v);
              },
            ),
          ),
        ),
      ],
    );
  }
}
