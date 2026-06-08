import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../services/database_service.dart';

/// Repeater Health Dashboard — per-repeater drill-down with charts,
/// degradation alerts, coverage cells, and recent ping history.
class RepeaterHealthScreen extends StatefulWidget {
  final List<Sample> samples;
  const RepeaterHealthScreen({super.key, required this.samples});

  @override
  State<RepeaterHealthScreen> createState() => _RepeaterHealthScreenState();
}

class _RepeaterHealthScreenState extends State<RepeaterHealthScreen> {
  String _sortBy = 'reliability';
  
  @override
  Widget build(BuildContext context) {
    final byRepeater = _groupByRepeater(widget.samples);
    
    if (byRepeater.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Repeater Health')),
        body: const Center(
          child: Text('No repeater data yet.\nDo some wardriving first!',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    
    final stats = byRepeater.entries
        .map((e) => _computeStats(e.key, e.value))
        .toList();
    
    switch (_sortBy) {
      case 'responseTime':
        stats.sort((a, b) => (a.avgResponseMs ?? 99999).compareTo(b.avgResponseMs ?? 99999));
        break;
      case 'pings':
        stats.sort((a, b) => b.totalPings.compareTo(a.totalPings));
        break;
      case 'degrading':
        stats.sort((a, b) {
          final aAlert = a.isDegrading ? 0 : 1;
          final bAlert = b.isDegrading ? 0 : 1;
          if (aAlert != bAlert) return aAlert.compareTo(bAlert);
          return b.responseRate.compareTo(a.responseRate);
        });
        break;
      default:
        stats.sort((a, b) => b.responseRate.compareTo(a.responseRate));
    }
    
    final degradingCount = stats.where((s) => s.isDegrading).length;
    final offlineCount = stats.where((s) => s.isOffline).length;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Repeater Health'),
        actions: [
          if (offlineCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                avatar: const Icon(Icons.cloud_off, size: 14, color: Colors.red),
                label: Text('$offlineCount offline', style: const TextStyle(fontSize: 11)),
                backgroundColor: Colors.red.withValues(alpha: 0.15),
                padding: EdgeInsets.zero,
              ),
            ),
          if (degradingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                avatar: const Icon(Icons.warning, size: 14, color: Colors.orange),
                label: Text('$degradingCount degrading', style: const TextStyle(fontSize: 11)),
                backgroundColor: Colors.orange.withValues(alpha: 0.15),
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Sort bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Text('${stats.length} repeaters',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const Spacer(),
                const Text('Sort: ', style: TextStyle(fontSize: 12)),
                DropdownButton<String>(
                  value: _sortBy,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'reliability', child: Text('Reliability', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'responseTime', child: Text('Response Time', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'pings', child: Text('Ping Count', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'degrading', child: Text('Alerts First', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _sortBy = v!),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: stats.length,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemBuilder: (context, index) {
                final s = stats[index];
                return _RepeaterCard(
                  stats: s,
                  onTap: () => _openDetail(s, byRepeater[s.id]!),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
  
  void _openDetail(_RepeaterStats stats, List<Sample> samples) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _RepeaterDetailScreen(stats: stats, samples: samples),
      ),
    );
  }
  
  Map<String, List<Sample>> _groupByRepeater(List<Sample> samples) {
    final Map<String, List<Sample>> map = {};
    for (final s in samples) {
      if (s.pingSuccess != null && s.path != null && s.path!.isNotEmpty) {
        map.putIfAbsent(s.path!, () => []);
        map[s.path!]!.add(s);
      }
    }
    return map;
  }
  
  _RepeaterStats _computeStats(String id, List<Sample> samples) {
    final successes = samples.where((s) => s.pingSuccess == true).length;
    final totalPings = samples.length;
    final responseRate = totalPings > 0 ? successes / totalPings : 0.0;
    
    final responseTimes = samples
        .where((s) => s.responseTimeMs != null)
        .map((s) => s.responseTimeMs!.toDouble())
        .toList();
    
    double? avgResponse;
    if (responseTimes.isNotEmpty) {
      avgResponse = responseTimes.reduce((a, b) => a + b) / responseTimes.length;
    }
    
    // Trend: 7-day vs 30-day
    final now = DateTime.now();
    final sevenDays = now.subtract(const Duration(days: 7));
    final thirtyDays = now.subtract(const Duration(days: 30));
    
    final recent7 = samples.where((s) => s.timestamp.isAfter(sevenDays)).toList();
    final recent30 = samples.where((s) => s.timestamp.isAfter(thirtyDays)).toList();
    
    double? rate7, rate30;
    if (recent7.length >= 3) {
      rate7 = recent7.where((s) => s.pingSuccess == true).length / recent7.length;
    }
    if (recent30.length >= 3) {
      rate30 = recent30.where((s) => s.pingSuccess == true).length / recent30.length;
    }
    
    String trend = 'stable';
    bool isDegrading = false;
    if (rate7 != null && rate30 != null) {
      if (rate7 - rate30 > 0.1) {
        trend = 'improving';
      } else if (rate30 - rate7 > 0.15) {
        trend = 'degrading';
        isDegrading = true;
      }
    }
    
    samples.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    // Count unique coverage cells
    final cells = <String>{};
    for (final s in samples) {
      cells.add(s.geohash.substring(0, min(6, s.geohash.length)));
    }
    
    // Offline detection: not seen in 7 days with 10+ pings total
    final daysSinceSeen = now.difference(samples.last.timestamp).inDays;
    final isOffline = daysSinceSeen >= 7 && totalPings >= 10;
    
    return _RepeaterStats(
      id: id,
      totalPings: totalPings,
      successCount: successes,
      responseRate: responseRate,
      avgResponseMs: avgResponse,
      trend: trend,
      isDegrading: isDegrading,
      isOffline: isOffline,
      daysSinceSeen: daysSinceSeen,
      rate7day: rate7,
      rate30day: rate30,
      firstSeen: samples.first.timestamp,
      lastSeen: samples.last.timestamp,
      coverageCells: cells.length,
    );
  }
}

// =============================================================================
// Repeater Card Widget
// =============================================================================

class _RepeaterCard extends StatelessWidget {
  final _RepeaterStats stats;
  final VoidCallback onTap;
  
  const _RepeaterCard({required this.stats, required this.onTap});
  
  @override
  Widget build(BuildContext context) {
    final displayId = stats.id.length > 8
        ? stats.id.substring(0, 8).toUpperCase()
        : stats.id.toUpperCase();
    
    final rateColor = stats.responseRate > 0.7
        ? Colors.green
        : stats.responseRate > 0.3
            ? Colors.orange
            : Colors.red;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.cell_tower, size: 18, color: rateColor),
                  const SizedBox(width: 8),
                  Text(displayId, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                  if (stats.isOffline) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.cloud_off, size: 16, color: Colors.red),
                  ] else if (stats.isDegrading) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.warning, size: 16, color: Colors.orange),
                  ],
                  const Spacer(),
                  Text(
                    '${(stats.responseRate * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: rateColor),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _miniStat('Pings', '${stats.totalPings}'),
                  _miniStat('Avg Resp', stats.avgResponseMs != null ? '${stats.avgResponseMs!.toStringAsFixed(0)}ms' : '—'),
                  _miniStat('Cells', '${stats.coverageCells}'),
                  _miniStat('Trend', _trendLabel(stats.trend), color: _trendColor(stats.trend)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'First: ${DateFormat('MMM d').format(stats.firstSeen)} • Last: ${DateFormat('MMM d').format(stats.lastSeen)}'
                '${stats.isOffline ? ' • ⚠️ Offline ${stats.daysSinceSeen}d' : ''}',
                style: TextStyle(fontSize: 10, color: stats.isOffline ? Colors.red : Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _miniStat(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
          Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
        ],
      ),
    );
  }
  
  String _trendLabel(String trend) {
    switch (trend) {
      case 'improving': return '▲ Up';
      case 'degrading': return '▼ Down';
      default: return '— Stable';
    }
  }
  
  Color _trendColor(String trend) {
    switch (trend) {
      case 'improving': return Colors.green;
      case 'degrading': return Colors.red;
      default: return Colors.grey;
    }
  }
}

// =============================================================================
// Repeater Detail Screen (Drill-Down)
// =============================================================================

class _RepeaterDetailScreen extends StatelessWidget {
  final _RepeaterStats stats;
  final List<Sample> samples;
  
  const _RepeaterDetailScreen({required this.stats, required this.samples});
  
  @override
  Widget build(BuildContext context) {
    final displayId = stats.id.length > 8
        ? stats.id.substring(0, 8).toUpperCase()
        : stats.id.toUpperCase();
    
    final sorted = List<Sample>.from(samples)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    return Scaffold(
      appBar: AppBar(title: Text('Repeater $displayId')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary card
            _buildSummaryCard(context),
            const SizedBox(height: 16),
            
            // SNR over time chart
            const Text('SNR Over Time', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(height: 200, child: _buildSnrChart(sorted)),
            const SizedBox(height: 24),
            
            // Success rate by week
            const Text('Weekly Success Rate', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(height: 200, child: _buildWeeklyChart(sorted)),
            const SizedBox(height: 24),
            
            // Time of day analysis
            const Text('Best Time of Day', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildTimeOfDay(sorted),
            const SizedBox(height: 24),
            
            // Recent pings
            const Text('Recent Pings', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildRecentPings(sorted),
          ],
        ),
      ),
    );
  }
  
  Widget _buildSummaryCard(BuildContext context) {
    final rateColor = stats.responseRate > 0.7
        ? Colors.green
        : stats.responseRate > 0.3
            ? Colors.orange
            : Colors.red;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statColumn('Success Rate', '${(stats.responseRate * 100).toStringAsFixed(0)}%', rateColor),
                _statColumn('Total Pings', '${stats.totalPings}', null),
                _statColumn('Heard', '${stats.successCount}', Colors.green),
                _statColumn('Coverage', '${stats.coverageCells} cells', null),
              ],
            ),
            if (stats.isDegrading) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.orange, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '7-day rate (${stats.rate7day != null ? "${(stats.rate7day! * 100).toStringAsFixed(0)}%" : "?"}) '
                        'dropped vs 30-day (${stats.rate30day != null ? "${(stats.rate30day! * 100).toStringAsFixed(0)}%" : "?"})',
                        style: const TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Avg response: ${stats.avgResponseMs != null ? "${stats.avgResponseMs!.toStringAsFixed(0)}ms" : "N/A"}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _statColumn(String label, String value, Color? color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }
  
  Widget _buildSnrChart(List<Sample> sorted) {
    final spots = <FlSpot>[];
    final timestamps = <double, DateTime>{};
    
    for (int i = 0; i < sorted.length; i++) {
      if (sorted[i].snr != null) {
        spots.add(FlSpot(i.toDouble(), sorted[i].snr!.toDouble()));
        timestamps[i.toDouble()] = sorted[i].timestamp;
      }
    }
    
    if (spots.isEmpty) {
      return const Center(child: Text('No SNR data', style: TextStyle(color: Colors.grey)));
    }
    
    final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final range = maxY - minY;
    final padding = range > 0 ? range * 0.15 : 5;
    
    return LineChart(
      LineChartData(
        minY: minY - padding,
        maxY: maxY + padding,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text('${v.toInt()}', style: const TextStyle(fontSize: 9)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: spots.length > 10 ? (spots.length / 5).ceilToDouble() : 1,
              getTitlesWidget: (v, _) {
                final ts = timestamps[v];
                if (ts == null) return const SizedBox.shrink();
                return Text(DateFormat('M/d').format(ts), style: const TextStyle(fontSize: 8));
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            color: Colors.green,
            barWidth: 2,
            dotData: FlDotData(show: spots.length < 30),
            belowBarData: BarAreaData(show: true, color: Colors.green.withValues(alpha: 0.1)),
          ),
        ],
      ),
    );
  }
  
  Widget _buildWeeklyChart(List<Sample> sorted) {
    if (sorted.isEmpty) {
      return const Center(child: Text('No data', style: TextStyle(color: Colors.grey)));
    }
    
    // Group by week
    final Map<String, List<Sample>> byWeek = {};
    for (final s in sorted) {
      // Week key: year-weekNumber
      final weekStart = s.timestamp.subtract(Duration(days: s.timestamp.weekday - 1));
      final key = DateFormat('M/d').format(weekStart);
      byWeek.putIfAbsent(key, () => []);
      byWeek[key]!.add(s);
    }
    
    final weeks = byWeek.entries.toList();
    if (weeks.isEmpty) {
      return const Center(child: Text('No weekly data', style: TextStyle(color: Colors.grey)));
    }
    
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: 1.0,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, __) {
              if (group.x >= weeks.length) return null;
              final week = weeks[group.x];
              final count = week.value.length;
              return BarTooltipItem(
                '${week.key}\n${(rod.toY * 100).toStringAsFixed(0)}% ($count pings)',
                const TextStyle(color: Colors.white, fontSize: 11),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: 0.25,
              getTitlesWidget: (v, _) => Text('${(v * 100).toInt()}%', style: const TextStyle(fontSize: 9)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx >= weeks.length) return const SizedBox.shrink();
                return Text(weeks[idx].key, style: const TextStyle(fontSize: 8));
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(weeks.length, (i) {
          final samples = weeks[i].value;
          final successes = samples.where((s) => s.pingSuccess == true).length;
          final rate = samples.isNotEmpty ? successes / samples.length : 0.0;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: rate,
                color: rate > 0.7 ? Colors.green : rate > 0.3 ? Colors.orange : Colors.red,
                width: weeks.length > 8 ? 10 : 20,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ],
          );
        }),
      ),
    );
  }
  
  Widget _buildTimeOfDay(List<Sample> sorted) {
    final Map<String, List<Sample>> periods = {
      'Night (0-6)': sorted.where((s) => s.timestamp.hour >= 0 && s.timestamp.hour < 6).toList(),
      'Morning (6-12)': sorted.where((s) => s.timestamp.hour >= 6 && s.timestamp.hour < 12).toList(),
      'Afternoon (12-18)': sorted.where((s) => s.timestamp.hour >= 12 && s.timestamp.hour < 18).toList(),
      'Evening (18-24)': sorted.where((s) => s.timestamp.hour >= 18 && s.timestamp.hour < 24).toList(),
    };
    
    return Column(
      children: periods.entries.map((e) {
        final total = e.value.length;
        final successes = e.value.where((s) => s.pingSuccess == true).length;
        final rate = total > 0 ? successes / total : null;
        final label = rate != null ? '${(rate * 100).toStringAsFixed(0)}% ($total pings)' : 'No data';
        final color = rate == null ? Colors.grey : rate > 0.7 ? Colors.green : rate > 0.3 ? Colors.orange : Colors.red;
        
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(e.key, style: const TextStyle(fontSize: 13)),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        );
      }).toList(),
    );
  }
  
  Widget _buildRecentPings(List<Sample> sorted) {
    final recent = sorted.reversed.take(20).toList();
    
    if (recent.isEmpty) {
      return const Text('No pings recorded', style: TextStyle(color: Colors.grey));
    }
    
    return Column(
      children: recent.map((s) {
        final time = DateFormat('MMM d HH:mm').format(s.timestamp);
        final success = s.pingSuccess == true;
        final snrText = s.snr != null ? 'SNR: ${s.snr}' : '';
        final rssiText = s.rssi != null ? 'RSSI: ${s.rssi}' : '';
        final respText = s.responseTimeMs != null ? '${s.responseTimeMs}ms' : '';
        final details = [snrText, rssiText, respText].where((t) => t.isNotEmpty).join(' • ');
        
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                success ? Icons.check_circle : Icons.cancel,
                size: 14,
                color: success ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(time, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
              const Spacer(),
              Text(details, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// Stats Model
// =============================================================================

class _RepeaterStats {
  final String id;
  final int totalPings;
  final int successCount;
  final double responseRate;
  final double? avgResponseMs;
  final String trend;
  final bool isDegrading;
  final bool isOffline;
  final int daysSinceSeen;
  final double? rate7day;
  final double? rate30day;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final int coverageCells;

  _RepeaterStats({
    required this.id,
    required this.totalPings,
    required this.successCount,
    required this.responseRate,
    this.avgResponseMs,
    required this.trend,
    required this.isDegrading,
    this.isOffline = false,
    this.daysSinceSeen = 0,
    this.rate7day,
    this.rate30day,
    required this.firstSeen,
    required this.lastSeen,
    required this.coverageCells,
  });
}
