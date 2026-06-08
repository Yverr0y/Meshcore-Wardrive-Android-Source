import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/achievement_service.dart';

class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  List<Achievement> _achievements = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Check for new unlocks first
    await AchievementService().checkAndUnlock();
    final all = await AchievementService().getAll();
    setState(() {
      _achievements = all;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = _achievements.where((a) => a.unlocked).length;
    final total = _achievements.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Achievements'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Progress header
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text('$unlocked / $total',
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: total > 0 ? unlocked / total : 0,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        unlocked == total
                            ? 'All achievements unlocked!'
                            : '${total - unlocked} remaining',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Achievement list
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _achievements.length,
                    itemBuilder: (context, index) {
                      final a = _achievements[index];
                      return ListTile(
                        leading: Text(
                          a.unlocked ? a.icon : '🔒',
                          style: TextStyle(
                            fontSize: 28,
                            color: a.unlocked ? null : Colors.grey,
                          ),
                        ),
                        title: Text(
                          a.title,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: a.unlocked ? null : Colors.grey,
                          ),
                        ),
                        subtitle: Text(
                          a.unlocked && a.unlockedAt != null
                              ? '${a.description}\nUnlocked ${DateFormat('MMM d, yyyy').format(a.unlockedAt!)}'
                              : a.description,
                          style: TextStyle(
                            color: a.unlocked ? null : Colors.grey,
                          ),
                        ),
                        trailing: a.unlocked
                            ? const Icon(Icons.check_circle,
                                color: Colors.green)
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
