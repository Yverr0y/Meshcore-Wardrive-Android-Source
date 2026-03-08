import 'package:home_widget/home_widget.dart';

/// Wraps HomeWidget calls to push app state to the Android home screen widget.
class WidgetService {
  static const String _androidWidgetName = 'WardriveWidgetProvider';
  static const String _appGroupId = 'mintylinux.meshcore.wardrive';

  static Future<void> initialize() async {
    await HomeWidget.setAppGroupId(_appGroupId);
  }

  /// Push current stats to the widget.
  static Future<void> update({
    required int sampleCount,
    required bool isTracking,
    required String connectionLabel,
    String successRate = '--',
    String distance = '--',
  }) async {
    await HomeWidget.saveWidgetData('samples', sampleCount.toString());
    await HomeWidget.saveWidgetData(
        'status', isTracking ? 'Tracking' : 'Idle');
    await HomeWidget.saveWidgetData('connection', connectionLabel);
    await HomeWidget.saveWidgetData('success_rate', successRate);
    await HomeWidget.saveWidgetData('distance', distance);
    await HomeWidget.updateWidget(
      androidName: _androidWidgetName,
    );
  }

  /// Convenience: update only tracking status.
  static Future<void> updateTrackingStatus(bool isTracking) async {
    await HomeWidget.saveWidgetData(
        'status', isTracking ? 'Tracking' : 'Idle');
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }

  /// Convenience: update only connection label.
  static Future<void> updateConnection(String label) async {
    await HomeWidget.saveWidgetData('connection', label);
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }
}
