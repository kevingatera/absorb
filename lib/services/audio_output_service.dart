import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AudioOutputDevice {
  final int id;
  final String name;
  final String typeName;
  final bool isActive;

  const AudioOutputDevice({
    required this.id,
    required this.name,
    required this.typeName,
    this.isActive = false,
  });

  IconData get icon {
    switch (typeName) {
      case 'bluetooth':
        return Icons.bluetooth_rounded;
      case 'wired':
        return Icons.headphones_rounded;
      case 'speaker':
        return Icons.phone_android_rounded;
      case 'earpiece':
        return Icons.hearing_rounded;
      case 'usb':
        return Icons.usb_rounded;
      default:
        return Icons.volume_up_rounded;
    }
  }
}

class AudioOutputService {
  static const _channel = MethodChannel('com.absorb.audio_output');

  static Future<List<AudioOutputDevice>> getOutputDevices() async {
    try {
      final result = await _channel.invokeMethod('getAudioOutputDevices');
      final list = (result as List).cast<Map>();
      return list.map((m) => AudioOutputDevice(
        id: m['id'] as int? ?? 0,
        name: m['name'] as String? ?? 'Unknown',
        typeName: m['typeName'] as String? ?? 'unknown',
        isActive: m['isActive'] as bool? ?? false,
      )).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> setOutputDevice(int deviceId) async {
    try {
      return await _channel.invokeMethod('setAudioOutputDevice', {'id': deviceId}) == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> resetToDefault() async {
    try {
      return await _channel.invokeMethod('resetAudioOutput') == true;
    } catch (_) {
      return false;
    }
  }
}
