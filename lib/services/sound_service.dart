import 'package:flutter/services.dart';
import 'settings_service.dart';

/// Android ToneGenerator tone constants
class AndroidTones {
  static const int TONE_PROP_BEEP = 36;
  static const int TONE_PROP_ACK = 37;
  static const int TONE_PROP_NACK = 38;
  static const int TONE_CDMA_ABBR_ALERT = 97;
  static const int TONE_CDMA_MED_L = 76;
}

/// Sound and vibration feedback service for wardrive events.
/// 
/// Uses a native Android platform channel to access ToneGenerator
/// (for audible tones) and Vibrator (for haptic feedback).
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;
  SoundService._();

  static const _channel = MethodChannel('mintylinux.meshcore.wardrive/feedback');
  final SettingsService _settings = SettingsService();
  bool _enabled = true;
  bool _vibrationEnabled = true;

  /// Load enabled state from settings
  Future<void> init() async {
    _enabled = await _settings.getSoundEnabled();
    _vibrationEnabled = await _settings.getVibrationEnabled();
  }

  /// Enable or disable sound at runtime
  void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// Enable or disable vibration at runtime
  void setVibrationEnabled(bool enabled) {
    _vibrationEnabled = enabled;
  }

  bool get isEnabled => _enabled;
  bool get isVibrationEnabled => _vibrationEnabled;

  /// Play a tone via Android ToneGenerator
  Future<void> _playTone(int tone, {int durationMs = 150}) async {
    try {
      await _channel.invokeMethod('playTone', {
        'tone': tone,
        'durationMs': durationMs,
      });
    } catch (_) {}
  }

  /// Vibrate via Android Vibrator
  Future<void> _vibrate({int durationMs = 100, int amplitude = 128}) async {
    try {
      final result = await _channel.invokeMethod('vibrate', {
        'durationMs': durationMs,
        'amplitude': amplitude,
      });
      if (result == false) {
        print('SoundService: Device has no vibrator');
      }
    } catch (e) {
      print('SoundService: Vibration error: $e');
    }
  }

  /// Short beep when a ping is sent
  Future<void> playPingSent() async {
    if (_vibrationEnabled) {
      await _vibrate(durationMs: 150, amplitude: 180);
    }
    if (_enabled) {
      await _playTone(AndroidTones.TONE_PROP_BEEP, durationMs: 100);
    }
  }

  /// Success tone — good signal (SNR >= 0 or RSSI >= -100)
  Future<void> playPingSuccessGood() async {
    if (_vibrationEnabled) {
      await _vibrate(durationMs: 200, amplitude: 255);
    }
    if (_enabled) {
      await _playTone(AndroidTones.TONE_PROP_ACK, durationMs: 200);
    }
  }

  /// Medium tone — weak signal (SNR < 0 or RSSI < -100)
  Future<void> playPingSuccessWeak() async {
    if (_vibrationEnabled) {
      await _vibrate(durationMs: 150, amplitude: 200);
    }
    if (_enabled) {
      await _playTone(AndroidTones.TONE_CDMA_MED_L, durationMs: 150);
    }
  }

  /// Fail tone — no response
  Future<void> playPingFailed() async {
    if (_vibrationEnabled) {
      await _vibrate(durationMs: 400, amplitude: 255);
    }
    if (_enabled) {
      await _playTone(AndroidTones.TONE_PROP_NACK, durationMs: 300);
    }
  }

  /// Play appropriate tone based on ping result
  Future<void> playForPingResult({
    required bool success,
    int? snr,
    int? rssi,
  }) async {
    if (!_enabled && !_vibrationEnabled) return;
    if (!success) {
      await playPingFailed();
    } else if (_isGoodSignal(snr: snr, rssi: rssi)) {
      await playPingSuccessGood();
    } else {
      await playPingSuccessWeak();
    }
  }

  /// Determine if signal quality is "good"
  bool _isGoodSignal({int? snr, int? rssi}) {
    if (snr != null) return snr >= 0;
    if (rssi != null) return rssi >= -100;
    return true; // If no signal data, treat as good
  }
}
