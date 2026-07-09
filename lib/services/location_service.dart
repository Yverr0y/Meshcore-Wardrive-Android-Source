import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/models.dart';
import 'database_service.dart';
import 'lora_companion_service.dart';
import '../utils/geohash_utils.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'persistent_debug_logger.dart';
import 'settings_service.dart';
import 'widget_service.dart';
import 'ducting_service.dart';
import 'carpeater_service.dart';
import 'sound_service.dart';

class LocationService {
  final DatabaseService _dbService = DatabaseService();
  final LoRaCompanionService _loraCompanion = LoRaCompanionService();
  final PersistentDebugLogger _logger = PersistentDebugLogger();
  final SettingsService _settings = SettingsService();
  final DuctingService _ductingService = DuctingService();
  final SoundService _soundService = SoundService();
  
  LocationService() {
    _carpeaterService = CarpeaterService(_loraCompanion, _settings);
    // Auto-disable auto-ping on device disconnect
    _loraCompanion.disconnectStream.listen((_) {
      if (_autoPingEnabled) {
        disableAutoPing();
        _logger.logPingEvent('Auto-ping disabled (device disconnected)');
      }
    });
  }
  StreamSubscription<Position>? _positionStreamSubscription;
  bool _isTracking = false;
  bool _autoPingEnabled = false;
  double _pingIntervalMeters = 805.0; // Default 0.5 miles
  LatLng? _lastPingPosition;
  
  // Ping mode: 'distance', 'time', or 'both'
  String _pingMode = 'distance';
  int _pingTimeIntervalSeconds = 60;
  Timer? _timePingTimer;
  bool _pingInProgress = false; // Guard against overlapping pings
  DateTime? _lastPingTimestamp; // When the last ping was triggered (any source)
  
  // Distance tracking
  double _totalDistanceMeters = 0.0;
  LatLng? _lastPosition;
  
  // Session ping stats for live notification
  int _sessionPingCount = 0;
  int _sessionSuccessCount = 0;
  
  // Session tracking
  int? _currentSessionId;
  DateTime? _sessionStartTime;
  
  // Stream for broadcasting current position
  final _currentPositionController = StreamController<LatLng>.broadcast();
  Stream<LatLng> get currentPositionStream => _currentPositionController.stream;
  
  // Stream for broadcasting when samples are saved
  final _sampleSavedController = StreamController<void>.broadcast();
  Stream<void> get sampleSavedStream => _sampleSavedController.stream;
  
  // Stream for broadcasting ping events
  final _pingEventController = StreamController<String>.broadcast();
  Stream<String> get pingEventStream => _pingEventController.stream;
  
  // Stream for broadcasting total distance updates
  final _totalDistanceController = StreamController<double>.broadcast();
  Stream<double> get totalDistanceStream => _totalDistanceController.stream;
  
  // Stream for broadcasting current speed (m/s)
  final _speedController = StreamController<double>.broadcast();
  Stream<double> get speedStream => _speedController.stream;
  double _currentSpeedMps = 0.0;
  double get currentSpeedMph => _currentSpeedMps * 2.23694;
  double get currentSpeedKmh => _currentSpeedMps * 3.6;
  
  // Dead zone alerts — throttle to once per cell per session
  final Set<String> _deadZoneAlertedCells = {};
  final _deadZoneController = StreamController<String>.broadcast();
  Stream<String> get deadZoneStream => _deadZoneController.stream;
  bool _deadZoneAlertsEnabled = true;
  
  // Battery saver mode
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batteryStateSubscription;
  bool _batterySaverActive = false;
  double _normalPingInterval = 805.0; // Saved before battery saver doubles it
  final _batterySaverController = StreamController<bool>.broadcast();
  Stream<bool> get batterySaverStream => _batterySaverController.stream;
  bool get isBatterySaverActive => _batterySaverActive;
  
  // Ducting monitoring
  bool _ductingEnabled = false;
  Timer? _ductingFetchTimer;
  
  // Carpeater mode
  late final CarpeaterService _carpeaterService;
  bool _carpeaterModeEnabled = false;
  StreamSubscription<List<Map<String, dynamic>>>? _carpeaterNeighboursSubscription;
  StreamSubscription<void>? _carpeaterDiscoveryStartedSubscription;
  LatLng? _carpeaterDiscoveryPosition; // GPS snapshot at moment of discovery
  
  /// Get ducting service for UI access
  DuctingService get ductingService => _ductingService;
  
  /// Get session ping stats
  int get sessionPingCount => _sessionPingCount;
  int get sessionSuccessCount => _sessionSuccessCount;
  
  /// Update foreground notification with live wardrive stats
  void _updateLiveNotification() {
    if (!_isTracking) return;
    final rate = _sessionPingCount > 0
        ? ((_sessionSuccessCount / _sessionPingCount) * 100).toStringAsFixed(0)
        : '--';
    final dist = (_totalDistanceMeters / 1609.34).toStringAsFixed(1);
    FlutterForegroundTask.updateService(
      notificationTitle: 'MeshCore Wardrive',
      notificationText: '✅ $rate% | 📍 $_sessionPingCount pings | 🛣️ ${dist}mi',
    );
  }
  
  /// Get carpeater service for UI access
  CarpeaterService get carpeaterService => _carpeaterService;
  
  /// Enable or disable ducting monitoring at runtime
  void setDuctingEnabled(bool enabled) {
    _ductingEnabled = enabled;
    if (enabled && _isTracking && _lastPosition != null) {
      // Kick off an initial fetch and start periodic timer
      _ductingService.fetchAndCache(_lastPosition!.latitude, _lastPosition!.longitude);
      _ductingFetchTimer?.cancel();
      _ductingFetchTimer = Timer.periodic(const Duration(minutes: 60), (_) async {
        if (_lastPosition != null) {
          await _ductingService.fetchAndCache(
            _lastPosition!.latitude, _lastPosition!.longitude,
          );
        }
      });
    } else if (!enabled) {
      _ductingFetchTimer?.cancel();
      _ductingFetchTimer = null;
    }
  }
  
  /// Enable or disable Carpeater mode at runtime
  void setCarpeaterMode(bool enabled) {
    final wasEnabled = _carpeaterModeEnabled;
    _carpeaterModeEnabled = enabled;
    _logger.logServiceEvent('Carpeater mode ${enabled ? "enabled" : "disabled"}');
    
    if (enabled && !wasEnabled && _isTracking && _loraCompanion.isDeviceConnected) {
      // Switching to carpeater mid-tracking: disable auto-ping and start carpeater
      disableAutoPing();
      startCarpeater();
    } else if (!enabled && wasEnabled) {
      // Switching off carpeater: stop it and resume auto-ping if tracking
      _carpeaterNeighboursSubscription?.cancel();
      _carpeaterDiscoveryStartedSubscription?.cancel();
      _carpeaterService.stop();
      if (_isTracking && _loraCompanion.isDeviceConnected) {
        enableAutoPing();
      }
    }
  }

  /// Check if location permissions are granted
  Future<bool> checkPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    await _logger.logPermission('Location', permission.toString());
    
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      await _logger.logPermission('Location (after request)', permission.toString());
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      await _logger.logPermission('Location', 'DENIED_FOREVER');
      return false;
    }

    return true;
  }

  /// Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Get current position once
  Future<LatLng?> getCurrentPosition() async {
    try {
      final hasPermission = await checkPermissions();
      if (!hasPermission) return null;

      final isEnabled = await isLocationServiceEnabled();
      if (!isEnabled) return null;

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: Platform.isAndroid
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
                forceLocationManager: true,
              )
            : const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
              ),
      );

      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      print('Error getting current position: $e');
      return null;
    }
  }

  /// Initialize foreground service
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshcore_wardrive_location',
        channelName: 'MeshCore Wardrive Location Tracking',
        channelDescription: 'This notification appears when location tracking is active',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // Update every 5 seconds
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Start tracking location
  Future<bool> startTracking() async {
    await _logger.init();
    await _logger.logServiceEvent('startTracking() called');
    
    if (_isTracking) {
      await _logger.logServiceEvent('Already tracking - returning early');
      return true;
    }

    final hasPermission = await checkPermissions();
    if (!hasPermission) {
      await _logger.logError('Permissions', 'Location permission not granted');
      return false;
    }

    final isEnabled = await isLocationServiceEnabled();
    if (!isEnabled) {
      await _logger.logError('Location Service', 'GPS is disabled');
      return false;
    }

    // Request notification permission for Android 13+
    final notificationStatus = await Permission.notification.request();
    await _logger.logPermission('Notification', notificationStatus.toString());
    if (!notificationStatus.isGranted) {
      print('Notification permission denied - foreground service may not work properly');
    }

    try {
      // Initialize and start foreground service
      _initForegroundTask();
      await _logger.logServiceEvent('Foreground task initialized');
      
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'MeshCore Wardrive',
        notificationText: 'Location tracking active',
        notificationButtons: [
          const NotificationButton(id: 'stop', text: 'Stop Tracking'),
        ],
        callback: null, // We handle location in Flutter, not in service callback
      );
      
      await _logger.logServiceEvent('Foreground service started successfully');
      print('Foreground service started');
      
      final locationSettings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5, // Update every 5 meters
              forceLocationManager: true,
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          _handleNewPosition(position);
        },
        onError: (error) {
          _logger.logError('Location Stream', error.toString());
          print('Location stream error: $error');
        },
      );

      await _logger.logLocationEvent('Position stream started with 5m distance filter');

      // Enable wakelock to prevent screen from sleeping and stopping tracking
      await WakelockPlus.enable();
      await _logger.logPowerEvent('Wakelock enabled');
      print('Wakelock enabled - app will stay active during tracking');

      _isTracking = true;
      _sessionPingCount = 0;
      _sessionSuccessCount = 0;
      _deadZoneAlertedCells.clear();
      WidgetService.updateTrackingStatus(true);
      
      // Start monitoring device battery for battery saver mode
      _startBatteryMonitoring();
      
      // Load alert settings
      _deadZoneAlertsEnabled = await _settings.getDeadZoneAlertsEnabled();
      
      // Store connected device in DB if available
      try {
        final deviceId = _loraCompanion.connectedDeviceId;
        if (deviceId != null) {
          final deviceName = _loraCompanion.deviceName ?? 'Unknown';
          final connType = _loraCompanion.connectionType == ConnectionType.bluetooth ? 'bluetooth' : 'usb';
          await _dbService.upsertDevice(deviceId, deviceName, connType);
        }
      } catch (e) {
        await _logger.logError('Device Tracking', e.toString());
      }
      
      // Reset distance tracking for new session
      _totalDistanceMeters = 0.0;
      _lastPosition = null;
      _totalDistanceController.add(_totalDistanceMeters);
      
      // Start ducting monitoring if enabled (non-blocking)
      _ductingEnabled = await _settings.getShowDucting();
      if (_ductingEnabled) {
        // Fire-and-forget initial fetch using the position stream (don't block with getCurrentPosition)
        _ductingFetchTimer?.cancel();
        _ductingFetchTimer = Timer.periodic(const Duration(minutes: 60), (_) async {
          if (_lastPosition != null) {
            await _ductingService.fetchAndCache(
              _lastPosition!.latitude, _lastPosition!.longitude,
            );
          }
        });
        // Kick off first fetch after a short delay so GPS has time to get a fix
        Future.delayed(const Duration(seconds: 5), () {
          if (_lastPosition != null) {
            _ductingService.fetchAndCache(_lastPosition!.latitude, _lastPosition!.longitude);
          }
        });
      }
      
      // Create a new session record
      _sessionStartTime = DateTime.now();
      try {
        final session = WSession(
          startTime: _sessionStartTime!,
        );
        _currentSessionId = await _dbService.createSession(session);
        await _logger.logServiceEvent('Session created with ID: $_currentSessionId');
      } catch (e) {
        await _logger.logError('Session Create', e.toString());
      }
      
      await _logger.logServiceEvent('Tracking started successfully');
      return true;
    } catch (e) {
      await _logger.logError('Start Tracking', e.toString());
      print('Error starting location tracking: $e');
      return false;
    }
  }

  /// Get LoRa companion service
  LoRaCompanionService get loraCompanion => _loraCompanion;

  /// Enable auto-ping (requires LoRa device to be connected)
  void enableAutoPing() {
    final isConnected = _loraCompanion.isDeviceConnected;
    final connectionType = _loraCompanion.connectionType;
    _logger.logPingEvent('enableAutoPing() called - Device connected: $isConnected, Type: ${connectionType.name}');
    
    if (isConnected) {
      _autoPingEnabled = true;
      _logger.logPingEvent('Auto-ping enabled (mode: $_pingMode, distance: ${_pingIntervalMeters}m, time: ${_pingTimeIntervalSeconds}s)');
      _restartTimePingTimer();
    } else {
      _logger.logPingEvent('Auto-ping enable FAILED - no device connected');
    }
  }

  /// Disable auto-ping
  void disableAutoPing() {
    _autoPingEnabled = false;
    _timePingTimer?.cancel();
    _timePingTimer = null;
    _logger.logPingEvent('Auto-ping disabled');
  }

  /// Check if auto-ping is enabled
  bool get isAutoPingEnabled => _autoPingEnabled;

  /// Check if ready for auto-ping
  bool get isReadyForAutoPing => 
      _loraCompanion.isDeviceConnected;
  
  /// Set ping interval in meters
  void setPingInterval(double meters) {
    _pingIntervalMeters = meters;
  }
  
  /// Get current ping interval in meters
  double get pingIntervalMeters => _pingIntervalMeters;
  
  /// Set ping mode ('distance', 'time', or 'both')
  void setPingMode(String mode) {
    _pingMode = mode;
    _logger.logPingEvent('Ping mode set to: $mode');
    _restartTimePingTimer();
  }
  
  /// Get current ping mode
  String get pingMode => _pingMode;
  
  /// Set ping time interval in seconds
  void setPingTimeInterval(int seconds) {
    _pingTimeIntervalSeconds = seconds;
    _logger.logPingEvent('Ping time interval set to: ${seconds}s');
    _restartTimePingTimer();
  }
  
  /// Get current ping time interval in seconds
  int get pingTimeIntervalSeconds => _pingTimeIntervalSeconds;
  
  /// Start or restart the time-based ping timer
  void _restartTimePingTimer() {
    _timePingTimer?.cancel();
    _timePingTimer = null;
    
    if (!_isTracking || !_autoPingEnabled || _carpeaterModeEnabled) return;
    if (_pingMode == 'distance') return; // No timer needed for distance-only mode
    
    _timePingTimer = Timer.periodic(
      Duration(seconds: _pingTimeIntervalSeconds),
      (_) => _handleTimePing(),
    );
    _logger.logPingEvent('Time-based ping timer started (${_pingTimeIntervalSeconds}s)');
  }
  
  /// Handle a time-triggered ping
  void _handleTimePing() async {
    if (!_autoPingEnabled || _carpeaterModeEnabled || _pingInProgress) return;
    if (!_loraCompanion.isDeviceConnected) return;
    
    final position = _lastPosition;
    if (position == null) return;
    
    // In 'both' mode, skip if a distance ping fired recently
    // (no point pinging the same spot twice)
    if (_pingMode == 'both' && _lastPingTimestamp != null) {
      final elapsed = DateTime.now().difference(_lastPingTimestamp!);
      if (elapsed.inSeconds < _pingTimeIntervalSeconds ~/ 2) {
        _logger.logPingEvent('Time ping skipped — distance ping fired ${elapsed.inSeconds}s ago');
        return;
      }
    }
    
    _pingInProgress = true;
    _lastPingPosition = position;
    _lastPingTimestamp = DateTime.now();
    
    final geohash = GeohashUtils.sampleKey(position.latitude, position.longitude);
    await _logger.logPingEvent('Time-based ping triggered at ${position.latitude}, ${position.longitude}');
    
    _pingEventController.add('pinging');
    _soundService.playPingSent();
    
    FlutterForegroundTask.updateService(
      notificationTitle: 'MeshCore Wardrive',
      notificationText: 'Pinging...',
    );
    
    _performPingInBackground(position, geohash);
  }
  
  /// Get total distance traveled in meters
  double get totalDistanceMeters => _totalDistanceMeters;
  
  /// Get total distance traveled in miles
  double get totalDistanceMiles => _totalDistanceMeters / 1609.34;
  
  /// Get total distance traveled in kilometers
  double get totalDistanceKm => _totalDistanceMeters / 1000.0;

  /// Handle new position from location stream
  void _handleNewPosition(Position position) async {
    final latLng = LatLng(position.latitude, position.longitude);
    await _logger.logLocationEvent('GPS update: ${latLng.latitude}, ${latLng.longitude}, accuracy: ${position.accuracy}m');
    
    // Update speed (filter out invalid negative values)
    _currentSpeedMps = (position.speed >= 0) ? position.speed : 0.0;
    _speedController.add(_currentSpeedMps);
    
    // Calculate distance traveled
    if (_lastPosition != null) {
      final distanceMeters = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        latLng.latitude,
        latLng.longitude,
      );
      _totalDistanceMeters += distanceMeters;
      _totalDistanceController.add(_totalDistanceMeters);
    }
    _lastPosition = latLng;
    
    // Broadcast current position to listeners
    _currentPositionController.add(latLng);

    // Validate location
    if (!GeohashUtils.isValidLocation(latLng)) {
      print('Location outside valid range: $latLng');
      return;
    }
    
    // Dead zone alert: check if current coverage cell is a known dead zone
    _checkDeadZone(latLng);

    // Create sample
    final geohash = GeohashUtils.sampleKey(
      position.latitude,
      position.longitude,
    );

    // Check if we should trigger a ping (but don't wait for it)
    final isConnected = _loraCompanion.isDeviceConnected;
    
    // Log detailed debug info on every GPS update when auto-ping is enabled
    if (_autoPingEnabled) {
      await _logger.logPingEvent('Checking ping condition: autoPing=$_autoPingEnabled, deviceConnected=$isConnected, lastPingPos=${_lastPingPosition != null ? "set" : "null"}');
    }
    
    if (_autoPingEnabled && isConnected && !_carpeaterModeEnabled && _pingMode != 'time') {
      bool shouldPing = false;
      
      if (_lastPingPosition == null) {
        // First ping
        shouldPing = true;
      } else {
        // Calculate distance from last ping
        final distance = Geolocator.distanceBetween(
          _lastPingPosition!.latitude,
          _lastPingPosition!.longitude,
          latLng.latitude,
          latLng.longitude,
        );
        
        await _logger.logPingEvent('Distance from last ping: ${distance.toStringAsFixed(1)}m (threshold: ${_pingIntervalMeters}m)');
        
        if (distance >= _pingIntervalMeters) {
          shouldPing = true;
        }
      }
      
      if (shouldPing) {
        // Fire ping immediately — no _pingInProgress guard.
        // v1.0.33 allowed overlapping pings for dense coverage.
        // Each ping has a unique discovery tag so responses correlate correctly.
        _lastPingPosition = latLng;
        _lastPingTimestamp = DateTime.now();
        await _logger.logPingEvent('Distance-based ping triggered at ${latLng.latitude}, ${latLng.longitude}');
        
        // Notify UI that ping is starting
        _pingEventController.add('pinging');
        _soundService.playPingSent();
        
        // Update foreground notification
        FlutterForegroundTask.updateService(
          notificationTitle: 'MeshCore Wardrive',
          notificationText: 'Pinging...',
        );
        
        // Start ping in background - don't wait for it
        print('Triggering auto-ping via LoRa at ${latLng.latitude}, ${latLng.longitude}');
        _performPingInBackground(latLng, geohash);
        return; // Don't save GPS sample when auto-pinging - wait for ping result
      }
    }

    // Only save GPS sample if auto-ping is disabled or no ping triggered
    // Tag with ducting risk if monitoring is enabled
    String? ductingRisk;
    if (_ductingEnabled) {
      ductingRisk = await _ductingService.getCurrentRisk(DateTime.now());
      if (ductingRisk == DuctingRisk.unknown) ductingRisk = null;
    }
    
    final sample = Sample(
      id: _generateUniqueId(),
      position: latLng,
      timestamp: DateTime.now(),
      path: null,
      geohash: geohash,
      rssi: null,
      snr: null,
      pingSuccess: null, // GPS-only sample (no ping attempted)
      ductingRisk: ductingRisk,
    );

    // Save to database
    try {
      await _dbService.insertSample(sample);
      print('Saved GPS sample: ${sample.id} at ${latLng.latitude}, ${latLng.longitude}');
      // Notify listeners that a sample was saved
      _sampleSavedController.add(null);
    } catch (e) {
      print('Error saving sample: $e');
    }
  }
  
  /// Start monitoring device battery level for battery saver mode
  void _startBatteryMonitoring() {
    _batteryStateSubscription?.cancel();
    _batteryStateSubscription = _battery.onBatteryStateChanged.listen((_) async {
      try {
        final level = await _battery.batteryLevel;
        if (level <= 20 && !_batterySaverActive) {
          _activateBatterySaver();
        } else if (level > 30 && _batterySaverActive) {
          _deactivateBatterySaver();
        }
      } catch (e) {
        // Battery API not available — ignore
      }
    });
    // Also check immediately
    _battery.batteryLevel.then((level) {
      if (level <= 20 && !_batterySaverActive) {
        _activateBatterySaver();
      }
    }).catchError((_) {});
  }
  
  void _activateBatterySaver() {
    _batterySaverActive = true;
    _normalPingInterval = _pingIntervalMeters;
    _pingIntervalMeters = _normalPingInterval * 2;
    _batterySaverController.add(true);
    _logger.logPowerEvent('Battery saver ON — ping interval doubled to ${_pingIntervalMeters.toStringAsFixed(0)}m');
  }
  
  void _deactivateBatterySaver() {
    _batterySaverActive = false;
    _pingIntervalMeters = _normalPingInterval;
    _batterySaverController.add(false);
    _logger.logPowerEvent('Battery saver OFF — ping interval restored to ${_pingIntervalMeters.toStringAsFixed(0)}m');
  }
  
  /// Check if the current position is in a known dead zone and alert once per cell
  void _checkDeadZone(LatLng latLng) async {
    if (!_deadZoneAlertsEnabled) return;
    try {
      final precision = await _settings.getCoveragePrecision();
      final cellHash = GeohashUtils.coverageKey(
        latLng.latitude, latLng.longitude, precision: precision,
      );
      if (_deadZoneAlertedCells.contains(cellHash)) return;
      
      final isDead = await _dbService.isDeadZoneCell(cellHash);
      if (isDead) {
        _deadZoneAlertedCells.add(cellHash);
        _deadZoneController.add(cellHash);
        _soundService.playPingFailed();
        await _logger.logPingEvent('Dead zone alert: cell $cellHash');
      }
    } catch (e) {
      // Non-critical — don't break GPS tracking
    }
  }
  
  /// Perform ping in background and update sample when complete
  void _performPingInBackground(LatLng latLng, String geohash) async {
    try {
      // Get user-configured discovery timeout
      final timeoutSeconds = await _settings.getDiscoveryTimeout();
      await _logger.logPingEvent('Sending ping to LoRa device (timeout: ${timeoutSeconds}s)...');
      final pingResult = await _loraCompanion.ping(
        latitude: latLng.latitude,
        longitude: latLng.longitude,
        timeoutSeconds: timeoutSeconds,
      );
      
      final pingSuccess = pingResult.status == PingStatus.success;
      final nodeId = pingResult.nodeId;
      
      await _logger.logPingEvent('Ping result: ${pingResult.status.name}, Node: $nodeId, RSSI: ${pingResult.rssi}, SNR: ${pingResult.snr}');
      print('Ping complete: ${pingResult.status.name}, Node: $nodeId, RSSI: ${pingResult.rssi}, SNR: ${pingResult.snr}');
      
      // Sound feedback based on result quality
      _soundService.playForPingResult(
        success: pingSuccess,
        snr: pingResult.snr,
        rssi: pingResult.rssi,
      );
      
      // Update notification with result
      final shortId = (nodeId != null && nodeId.isNotEmpty)
          ? (nodeId.length > 8 ? nodeId.substring(0, 8).toUpperCase() : nodeId.toUpperCase())
          : 'repeater';
      final resultText = pingSuccess ? '✅ Heard by $shortId' : '❌ No response';
      FlutterForegroundTask.updateService(
        notificationTitle: 'MeshCore Wardrive',
        notificationText: resultText,
      );
      
      // Update session stats
      _sessionPingCount++;
      if (pingSuccess) _sessionSuccessCount++;
      
      // Notify UI
      _pingEventController.add(pingSuccess ? 'success' : 'failed');
      
      // Update notification with live stats
      Future.delayed(const Duration(seconds: 3), () {
        _updateLiveNotification();
      });
      
      // Tag with ducting risk if monitoring is enabled
      String? ductingRisk;
      if (_ductingEnabled) {
        ductingRisk = await _ductingService.getCurrentRisk(DateTime.now());
        if (ductingRisk == DuctingRisk.unknown) ductingRisk = null;
      }
      
      // Create a new sample with ping results
      final sample = Sample(
        id: _generateUniqueId(),
        position: latLng,
        timestamp: DateTime.now(),
        path: nodeId,
        geohash: geohash,
        rssi: pingResult.rssi,
        snr: pingResult.snr,
        pingSuccess: pingSuccess,
        responseTimeMs: pingResult.responseTimeMs,
        ductingRisk: ductingRisk,
        deviceId: _loraCompanion.connectedDeviceId,
      );
      
      // Save ping result as new sample
      await _dbService.insertSample(sample);
      print('Saved ping result: ${sample.id}');
      // Notify listeners
      _sampleSavedController.add(null);
    } catch (e) {
      await _logger.logError('Background Ping', e.toString());
      print('Error during background ping: $e');
      // Save failed ping result
      final sample = Sample(
        id: _generateUniqueId(),
        position: latLng,
        timestamp: DateTime.now(),
        path: null,
        geohash: geohash,
        rssi: null,
        snr: null,
        pingSuccess: false,
        deviceId: _loraCompanion.connectedDeviceId,
      );
      await _dbService.insertSample(sample);
      // Notify listeners
      _sampleSavedController.add(null);
    } finally {
      _pingInProgress = false;
    }
  }

  /// Stop tracking location
  Future<void> stopTracking() async {
    await _logger.logServiceEvent('stopTracking() called');
    
    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    
    // Stop ducting monitoring
    _ductingFetchTimer?.cancel();
    _ductingFetchTimer = null;
    
    // Stop time-based ping timer
    _timePingTimer?.cancel();
    _timePingTimer = null;
    
    // Stop battery monitoring and deactivate battery saver
    _batteryStateSubscription?.cancel();
    _batteryStateSubscription = null;
    if (_batterySaverActive) {
      _deactivateBatterySaver();
    }
    
    // Stop Carpeater mode
    _carpeaterNeighboursSubscription?.cancel();
    _carpeaterDiscoveryStartedSubscription?.cancel();
    _carpeaterService.stop();
    
    // Stop foreground service
    await FlutterForegroundTask.stopService();
    await _logger.logServiceEvent('Foreground service stopped');
    
    // Disable wakelock when tracking stops
    await WakelockPlus.disable();
    await _logger.logPowerEvent('Wakelock disabled');
    print('Wakelock disabled');
    
    // Finalize session
    if (_currentSessionId != null && _sessionStartTime != null) {
      try {
        final endTime = DateTime.now();
        final counts = await _dbService.getSessionSampleCounts(_sessionStartTime!, endTime);
        final session = WSession(
          id: _currentSessionId,
          startTime: _sessionStartTime!,
          endTime: endTime,
          distanceMeters: _totalDistanceMeters,
          sampleCount: counts['total'] ?? 0,
          pingCount: counts['pings'] ?? 0,
          successCount: counts['successes'] ?? 0,
        );
        await _dbService.updateSession(session);
        await _logger.logServiceEvent('Session $_currentSessionId finalized: ${counts['total']} samples, ${counts['pings']} pings, ${counts['successes']} successes, ${_totalDistanceMeters.toStringAsFixed(0)}m');
      } catch (e) {
        await _logger.logError('Session Finalize', e.toString());
      }
      _currentSessionId = null;
      _sessionStartTime = null;
    }
    
    _isTracking = false;
    WidgetService.updateTrackingStatus(false);
    await _logger.logServiceEvent('Tracking stopped successfully');
  }

  /// Check if currently tracking
  bool get isTracking => _isTracking;

  /// Get all recorded samples
  Future<List<Sample>> getAllSamples() async {
    return await _dbService.getAllSamples();
  }

  /// Get sample count
  Future<int> getSampleCount() async {
    return await _dbService.getSampleCount();
  }

  /// Clear all samples
  Future<void> clearAllSamples() async {
    await _dbService.deleteAllSamples();
  }

  /// Export samples as JSON
  Future<List<Map<String, dynamic>>> exportSamples() async {
    return await _dbService.exportSamples();
  }

  /// Import samples from JSON file (returns count of imported samples)
  Future<int> importSamples(List<Map<String, dynamic>> jsonData) async {
    return await _dbService.importSamples(jsonData);
  }

  /// Get the debug log file path
  String? get debugLogPath => _logger.logFilePath;
  
  /// Generate a unique ID for samples
  String _generateUniqueId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999).toString().padLeft(6, '0');
    return '${timestamp}_$random';
  }

  /// Start Carpeater discovery and subscribe to results
  Future<bool> startCarpeater() async {
    // Subscribe to discovery started (snapshot GPS position)
    _carpeaterDiscoveryStartedSubscription = _carpeaterService.discoveryStartedStream.listen((_) {
      _carpeaterDiscoveryPosition = _lastPosition;
      _pingEventController.add('pinging');
      _soundService.playPingSent();
    });
    
    // Subscribe to neighbour results
    _carpeaterNeighboursSubscription = _carpeaterService.neighboursStream.listen(_onCarpeaterNeighbours);
    
    final started = await _carpeaterService.start();
    if (!started) {
      _carpeaterDiscoveryStartedSubscription?.cancel();
      _carpeaterNeighboursSubscription?.cancel();
    }
    return started;
  }
  
  /// Handle Carpeater neighbour results — save as samples
  void _onCarpeaterNeighbours(List<Map<String, dynamic>> neighbours) async {
    final position = _carpeaterDiscoveryPosition ?? _lastPosition;
    if (position == null) return;
    
    final geohash = GeohashUtils.sampleKey(position.latitude, position.longitude);
    
    // Filter out the target repeater itself — it always shows up as its own neighbour
    final targetId = _carpeaterService.targetRepeaterId?.toUpperCase();
    final filtered = neighbours.where((n) {
      final pubkey = n['pubkey'] as String?;
      if (pubkey == null || targetId == null) return true;
      final nId = pubkey.length >= 8 ? pubkey.substring(0, 8).toUpperCase() : pubkey.toUpperCase();
      return !nId.startsWith(targetId);
    }).toList();
    
    // Also filter ignored repeater prefixes if set (comma-separated)
    final ignoredPrefixStr = _loraCompanion.ignoredRepeaterPrefix;
    final results = ignoredPrefixStr != null && ignoredPrefixStr.isNotEmpty
        ? filtered.where((n) {
            final pubkey = n['pubkey'] as String?;
            if (pubkey == null) return true;
            final nId = pubkey.length >= 8 ? pubkey.substring(0, 8).toUpperCase() : pubkey.toUpperCase();
            final prefixes = ignoredPrefixStr.split(',').map((s) => s.trim().toUpperCase()).where((s) => s.isNotEmpty);
            return !prefixes.any((prefix) => nId.startsWith(prefix));
          }).toList()
        : filtered;
    
    // Get ducting risk if enabled
    String? ductingRisk;
    if (_ductingEnabled) {
      ductingRisk = await _ductingService.getCurrentRisk(DateTime.now());
      if (ductingRisk == DuctingRisk.unknown) ductingRisk = null;
    }
    
    if (results.isEmpty) {
      // Dead zone — repeater heard nobody
      final sample = Sample(
        id: _generateUniqueId(),
        position: position,
        timestamp: DateTime.now(),
        path: _carpeaterService.targetRepeaterId,
        geohash: geohash,
        pingSuccess: false,
        ductingRisk: ductingRisk,
        deviceId: _loraCompanion.connectedDeviceId,
      );
      await _dbService.insertSample(sample);
      _pingEventController.add('failed');
      _soundService.playPingFailed();
    } else {
      // Save one sample per neighbour
      for (final n in results) {
        final pubkey = n['pubkey'] as String?;
        final snr = (n['snr'] as num?)?.toInt();
        final repeaterId = pubkey != null && pubkey.length >= 8
            ? pubkey.substring(0, 8)
            : pubkey;
        
        final sample = Sample(
          id: _generateUniqueId(),
          position: position,
          timestamp: DateTime.now(),
          path: repeaterId,
          geohash: geohash,
          snr: snr,
          pingSuccess: true,
          ductingRisk: ductingRisk,
          deviceId: _loraCompanion.connectedDeviceId,
        );
        await _dbService.insertSample(sample);
      }
      _pingEventController.add('success');
      // Use best SNR from filtered results for sound quality
      final bestSnr = results
          .map((n) => (n['snr'] as num?)?.toInt())
          .where((s) => s != null)
          .fold<int?>(null, (best, s) => best == null || s! > best ? s : best);
      _soundService.playForPingResult(success: true, snr: bestSnr);
    }
    
    _sampleSavedController.add(null);
    
    FlutterForegroundTask.updateService(
      notificationTitle: 'MeshCore Wardrive',
      notificationText: results.isEmpty
          ? 'Carpeater: No neighbours'
          : 'Carpeater: ${results.length} neighbours found',
    );
    Future.delayed(const Duration(seconds: 3), () {
      FlutterForegroundTask.updateService(
        notificationTitle: 'MeshCore Wardrive',
        notificationText: 'Carpeater mode active',
      );
    });
  }

  /// Dispose resources
  void dispose() {
    stopTracking();
    _logger.close();
    _currentPositionController.close();
    _sampleSavedController.close();
    _pingEventController.close();
    _totalDistanceController.close();
    _speedController.close();
    _deadZoneController.close();
    _batterySaverController.close();
    _batteryStateSubscription?.cancel();
    _carpeaterNeighboursSubscription?.cancel();
    _carpeaterDiscoveryStartedSubscription?.cancel();
    _carpeaterService.dispose();
    _loraCompanion.dispose();
  }
}
