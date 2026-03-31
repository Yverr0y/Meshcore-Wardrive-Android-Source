import 'package:flutter/services.dart';
import 'settings_service.dart';

/// Sound feedback service for wardrive events.
/// 
/// Plays distinct system tones for:
/// - Ping sent (short beep)
/// - Ping success with good signal (success beep)
/// - Ping success with weak signal (medium tone)
/// - Ping failed / no response (fail beep)
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;
  SoundService._();

  final SettingsService _settings = SettingsService();
  bool _enabled = false;
  bool _vibrationEnabled = false;

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

  /// Short beep when a ping is sent
  Future<void> playPingSent() async {
    if (_vibrationEnabled) {
      HapticFeedback.lightImpact();
    }
    if (!_enabled) return;
    SystemSound.play(SystemSoundType.click);
  }

  /// Success tone — good signal (SNR >= 0 or RSSI >= -100)
  Future<void> playPingSuccessGood() async {
    if (_vibrationEnabled) {
      HapticFeedback.mediumImpact();
    }
    if (!_enabled) return;
    SystemSound.play(SystemSoundType.click);
    // Double-click for success
    Future.delayed(const Duration(milliseconds: 150), () {
      SystemSound.play(SystemSoundType.click);
    });
  }

  /// Medium tone — weak signal (SNR < 0 or RSSI < -100)
  Future<void> playPingSuccessWeak() async {
    if (_vibrationEnabled) {
      HapticFeedback.lightImpact();
    }
    if (!_enabled) return;
    SystemSound.play(SystemSoundType.click);
  }

  /// Fail tone — no response
  Future<void> playPingFailed() async {
    if (_vibrationEnabled) {
      HapticFeedback.heavyImpact();
    }
    if (!_enabled) return;
    SystemSound.play(SystemSoundType.alert);
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
