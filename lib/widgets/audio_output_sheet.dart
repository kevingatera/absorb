import 'package:flutter/material.dart';
import '../services/audio_output_service.dart';

class AudioOutputSheet extends StatefulWidget {
  final Color accent;
  const AudioOutputSheet({super.key, required this.accent});

  @override
  State<AudioOutputSheet> createState() => _AudioOutputSheetState();
}

class _AudioOutputSheetState extends State<AudioOutputSheet> {
  List<AudioOutputDevice> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    final devices = await AudioOutputService.getOutputDevices();
    if (mounted) setState(() { _devices = devices; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text('Audio Output', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            else if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No output devices found',
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5))),
              )
            else
              ..._devices.map((device) => _buildDeviceTile(device, cs)),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceTile(AudioOutputDevice device, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: () async {
          await AudioOutputService.setOutputDevice(device.id);
          await _loadDevices();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            color: device.isActive
                ? widget.accent.withValues(alpha: 0.12)
                : cs.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: device.isActive
                  ? widget.accent.withValues(alpha: 0.3)
                  : cs.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Icon(device.icon, size: 22,
                  color: device.isActive ? widget.accent : cs.onSurface.withValues(alpha: 0.6)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(device.name,
                    style: TextStyle(
                      fontWeight: device.isActive ? FontWeight.w600 : FontWeight.w500,
                      color: device.isActive ? widget.accent : cs.onSurface,
                    )),
              ),
              if (device.isActive)
                Icon(Icons.check_rounded, size: 20, color: widget.accent),
            ],
          ),
        ),
      ),
    );
  }
}
