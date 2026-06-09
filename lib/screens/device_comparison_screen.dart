import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/database_service.dart';

class DeviceComparisonScreen extends StatefulWidget {
  const DeviceComparisonScreen({super.key});

  @override
  State<DeviceComparisonScreen> createState() => _DeviceComparisonScreenState();
}

class _DeviceComparisonScreenState extends State<DeviceComparisonScreen> {
  List<Map<String, dynamic>> _devices = [];
  Map<String, Map<String, dynamic>> _deviceStats = {};
  bool _loading = true;
  String? _compareA;
  String? _compareB;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = DatabaseService();
    final devices = await db.getAllDevices();
    final stats = <String, Map<String, dynamic>>{};
    
    for (final d in devices) {
      final key = d['public_key'] as String;
      stats[key] = await db.getDeviceStats(key);
    }
    
    setState(() {
      _devices = devices;
      _deviceStats = stats;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Comparison')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _devices.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No devices tracked yet.\n\nConnect a LoRa device and start wardriving — '
                      'the app will automatically log which device you use.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Device list
                      Text('${_devices.length} device(s) tracked',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      ..._devices.map((d) => _buildDeviceCard(d)),
                      
                      // Comparison section
                      if (_devices.length >= 2) ...[
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 8),
                        const Text('Compare Devices',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButton<String>(
                                value: _compareA,
                                hint: const Text('Device A', style: TextStyle(fontSize: 13)),
                                isExpanded: true,
                                items: _devices.map((d) {
                                  final key = d['public_key'] as String;
                                  return DropdownMenuItem(
                                    value: key,
                                    child: Text(d['name'] as String? ?? key, style: const TextStyle(fontSize: 13)),
                                  );
                                }).toList(),
                                onChanged: (v) => setState(() => _compareA = v),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Text('vs', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            Expanded(
                              child: DropdownButton<String>(
                                value: _compareB,
                                hint: const Text('Device B', style: TextStyle(fontSize: 13)),
                                isExpanded: true,
                                items: _devices.map((d) {
                                  final key = d['public_key'] as String;
                                  return DropdownMenuItem(
                                    value: key,
                                    child: Text(d['name'] as String? ?? key, style: const TextStyle(fontSize: 13)),
                                  );
                                }).toList(),
                                onChanged: (v) => setState(() => _compareB = v),
                              ),
                            ),
                          ],
                        ),
                        if (_compareA != null && _compareB != null && _compareA != _compareB)
                          _buildComparisonTable(),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildDeviceCard(Map<String, dynamic> device) {
    final key = device['public_key'] as String;
    final name = device['name'] as String? ?? 'Unknown';
    final connType = device['connection_type'] as String? ?? '?';
    final firstUsed = DateTime.fromMillisecondsSinceEpoch(device['first_used'] as int);
    final lastUsed = DateTime.fromMillisecondsSinceEpoch(device['last_used'] as int);
    final stats = _deviceStats[key];

    final totalPings = stats?['totalPings'] ?? 0;
    final successRate = stats?['successRate'] ?? 0.0;
    final cells = stats?['uniqueCells'] ?? 0;

    final rateColor = successRate > 0.7
        ? Colors.green
        : successRate > 0.3
            ? Colors.orange
            : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connType == 'bluetooth' ? Icons.bluetooth : Icons.usb,
                  size: 18,
                  color: connType == 'bluetooth' ? Colors.blue : Colors.green,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                if (totalPings > 0)
                  Text('${(successRate * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold, color: rateColor)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _miniStat('Pings', '$totalPings'),
                _miniStat('Cells', '$cells'),
                _miniStat('Avg Resp', stats?['avgResponseMs'] != null
                    ? '${stats!['avgResponseMs'].toStringAsFixed(0)}ms'
                    : '—'),
                _miniStat('Avg SNR', stats?['avgSnr'] != null
                    ? '${stats!['avgSnr'].toStringAsFixed(1)}'
                    : '—'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'First: ${DateFormat('MMM d').format(firstUsed)} • Last: ${DateFormat('MMM d').format(lastUsed)}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonTable() {
    final a = _deviceStats[_compareA!] ?? {};
    final b = _deviceStats[_compareB!] ?? {};
    final nameA = _devices.firstWhere((d) => d['public_key'] == _compareA)['name'] as String? ?? _compareA!;
    final nameB = _devices.firstWhere((d) => d['public_key'] == _compareB)['name'] as String? ?? _compareB!;

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                const Expanded(flex: 2, child: Text('Stat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                Expanded(child: Text(nameA, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center)),
                Expanded(child: Text(nameB, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center)),
                const Expanded(child: Text('Winner', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center)),
              ],
            ),
            const Divider(),
            _compRow('Total Pings', a['totalPings'] ?? 0, b['totalPings'] ?? 0, higher: true),
            _compRow('Success Rate', a['successRate'] ?? 0.0, b['successRate'] ?? 0.0, higher: true, pct: true),
            _compRow('Failures', a['failures'] ?? 0, b['failures'] ?? 0, higher: false),
            _compRow('Unique Cells', a['uniqueCells'] ?? 0, b['uniqueCells'] ?? 0, higher: true),
            _compRow('Avg Response', a['avgResponseMs'], b['avgResponseMs'], higher: false, suffix: 'ms'),
            _compRow('Avg SNR', a['avgSnr'], b['avgSnr'], higher: true, suffix: 'dB'),
            _compRow('Avg RSSI', a['avgRssi'], b['avgRssi'], higher: true, suffix: 'dBm'),
          ],
        ),
      ),
    );
  }

  Widget _compRow(String label, dynamic valA, dynamic valB, {bool higher = true, bool pct = false, String? suffix}) {
    String fmt(dynamic v) {
      if (v == null) return '—';
      if (pct) return '${(v * 100).toStringAsFixed(1)}%';
      if (v is double) return '${v.toStringAsFixed(1)}${suffix ?? ''}';
      return '$v${suffix ?? ''}';
    }

    String winner = '—';
    Color winColor = Colors.grey;
    if (valA != null && valB != null) {
      final a = (valA is int) ? valA.toDouble() : (valA as double);
      final b = (valB is int) ? valB.toDouble() : (valB as double);
      if (a != b) {
        final aWins = higher ? a > b : a < b;
        final nameA = _devices.firstWhere((d) => d['public_key'] == _compareA)['name'] as String? ?? 'A';
        final nameB = _devices.firstWhere((d) => d['public_key'] == _compareB)['name'] as String? ?? 'B';
        winner = aWins ? nameA : nameB;
        winColor = Colors.green;
      } else {
        winner = 'Tie';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey))),
          Expanded(child: Text(fmt(valA), style: const TextStyle(fontSize: 12), textAlign: TextAlign.center)),
          Expanded(child: Text(fmt(valB), style: const TextStyle(fontSize: 12), textAlign: TextAlign.center)),
          Expanded(child: Text(winner, style: TextStyle(fontSize: 11, color: winColor, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
