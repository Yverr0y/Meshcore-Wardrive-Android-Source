import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Tropospheric ducting forecast viewer using dxinfocentre.com forecast maps.
class DuctingForecastScreen extends StatefulWidget {
  const DuctingForecastScreen({super.key});

  @override
  State<DuctingForecastScreen> createState() => _DuctingForecastScreenState();
}

class _DuctingForecastScreenState extends State<DuctingForecastScreen> {
  static const _regionKey = 'ducting_forecast_region';

  static const Map<String, String> _regions = {
    'wam': 'Western North America',
    'eam': 'Eastern North America',
    'enp': 'Eastern North Pacific',
    'esp': 'Eastern South Pacific',
    'car': 'Gulf-Caribbean',
    'nsa': 'Northern South America',
    'sam': 'Central South America',
    'sat': 'South Atlantic',
    'nat': 'North Atlantic',
    'ent': 'Eastern North Atlantic',
    'nwe': 'Northwestern Europe',
    'eur': 'Europe',
    'eeu': 'Eastern Europe',
    'afi': 'South Africa',
    'mid': 'Middle East',
    'nca': 'North Central Asia',
    'ino': 'Indian Ocean',
    'sea': 'Southeast Asia',
    'eas': 'Far East',
    'nea': 'Eastern Siberia',
    'aus': 'Australia & New Zealand',
    'oce': 'Oceania',
    'wnp': 'Western North Pacific',
  };

  // 3h intervals for first 36h, then 6h intervals to 138h
  static const List<int> _forecastHours = [
    6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36,
    42, 48, 54, 60, 66, 72, 78, 84, 90, 96,
    102, 108, 114, 120, 126, 132, 138,
  ];

  String _region = 'wam';
  int _currentIndex = 0;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadRegion();
  }

  Future<void> _loadRegion() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_regionKey);
    if (saved != null && _regions.containsKey(saved)) {
      setState(() => _region = saved);
    }
  }

  Future<void> _setRegion(String region) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_regionKey, region);
    setState(() {
      _region = region;
      _currentIndex = 0;
    });
  }

  String get _currentImageUrl {
    final hours = _forecastHours[_currentIndex].toString().padLeft(3, '0');
    return 'https://www.dxinfocentre.com/tr_map/fcst/$_region$hours.png';
  }

  String get _timeLabel {
    final hours = _forecastHours[_currentIndex];
    if (hours < 24) return '+${hours}h';
    final days = hours ~/ 24;
    final rem = hours % 24;
    return rem == 0 ? '+${days}d' : '+${days}d ${rem}h';
  }

  void _play() {
    setState(() => _isPlaying = true);
    _animate();
  }

  void _animate() async {
    while (_isPlaying && _currentIndex < _forecastHours.length - 1) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!_isPlaying || !mounted) return;
      setState(() => _currentIndex++);
    }
    if (mounted) setState(() => _isPlaying = false);
  }

  void _stop() {
    if (mounted) setState(() => _isPlaying = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tropo Ducting Forecast'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open in browser',
            onPressed: () {
              final page = _region == 'eam' ? 'tropo' : 'tropo_$_region';
              final url = Uri.parse('https://dxinfocentre.com/$page.html');
              launchUrl(url, mode: LaunchMode.externalApplication);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Region selector
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DropdownButtonFormField<String>(
              value: _region,
              decoration: const InputDecoration(
                labelText: 'Region',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              isExpanded: true,
              items: _regions.entries.map((e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value, style: const TextStyle(fontSize: 14)),
              )).toList(),
              onChanged: (v) => v != null ? _setRegion(v) : null,
            ),
          ),

          // Forecast image (pinch to zoom)
          Expanded(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.network(
                _currentImageUrl,
                fit: BoxFit.contain,
                loadingBuilder: (ctx, child, progress) {
                  if (progress == null) return child;
                  return const Center(child: CircularProgressIndicator());
                },
                errorBuilder: (ctx, error, stack) => const Center(
                  child: Text('Failed to load forecast image.\nCheck internet connection.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                ),
              ),
            ),
          ),

          // Time slider + playback controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(_timeLabel,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Spacer(),
                    Text('${_currentIndex + 1} / ${_forecastHours.length}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                Slider(
                  value: _currentIndex.toDouble(),
                  min: 0,
                  max: (_forecastHours.length - 1).toDouble(),
                  divisions: _forecastHours.length - 1,
                  onChanged: (v) {
                    _stop();
                    setState(() => _currentIndex = v.round());
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: _currentIndex > 0
                          ? () { _stop(); setState(() => _currentIndex = 0); }
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: _currentIndex > 0
                          ? () { _stop(); setState(() => _currentIndex--); }
                          : null,
                    ),
                    IconButton(
                      icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                      iconSize: 36,
                      onPressed: _isPlaying ? _stop : _play,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: _currentIndex < _forecastHours.length - 1
                          ? () { _stop(); setState(() => _currentIndex++); }
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: _currentIndex < _forecastHours.length - 1
                          ? () { _stop(); setState(() => _currentIndex = _forecastHours.length - 1); }
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Legend
          Container(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendDot(const Color(0xFF00AA00), 'None'),
                _legendDot(Colors.yellow, 'Marginal'),
                _legendDot(Colors.orange, 'Moderate'),
                _legendDot(Colors.red, 'High'),
                _legendDot(Colors.purple, 'Extreme'),
              ],
            ),
          ),

          // Attribution
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Forecast © William R. Hepburn — dxinfocentre.com',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 3),
          Text(label, style: const TextStyle(fontSize: 9)),
        ],
      ),
    );
  }
}
