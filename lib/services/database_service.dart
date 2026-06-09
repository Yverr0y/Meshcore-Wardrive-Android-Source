import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import 'dart:io';

class DatabaseService {
  static Database? _database;
  static const String _databaseName = 'meshcore_wardrive.db';
  static const int _databaseVersion = 12;
  static const String tableDuctingCache = 'ducting_cache';

  static const String tableSamples = 'samples';
  static const String tableUploads = 'uploads';
  static const String tableSessions = 'sessions';
  static const String tableMarkers = 'planned_markers';
  static const String tablePrivacyZones = 'privacy_zones';
  static const String tableDevices = 'devices';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String path = join(appDocDir.path, _databaseName);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableSamples (
        id TEXT PRIMARY KEY,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        timestamp INTEGER NOT NULL,
        path TEXT,
        geohash TEXT NOT NULL,
        rssi INTEGER,
        snr INTEGER,
        pingSuccess INTEGER,
        observerNames TEXT,
        uploaded INTEGER DEFAULT 0,
        response_time_ms INTEGER,
        ducting_risk TEXT,
        source TEXT
      )
    ''');

    // Create index on geohash for faster queries
    await db.execute('''
      CREATE INDEX idx_samples_geohash ON $tableSamples (geohash)
    ''');

    // Create index on timestamp for sorting
    await db.execute('''
      CREATE INDEX idx_samples_timestamp ON $tableSamples (timestamp)
    ''');
    
    // Create ducting cache table
    await db.execute('''
      CREATE TABLE $tableDuctingCache (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        risk TEXT NOT NULL,
        n_surface REAL,
        n_925 REAL,
        gradient REAL,
        fetched_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_ducting_timestamp ON $tableDuctingCache (timestamp)
    ''');
    
    // Create uploads tracking table (per-endpoint upload tracking)
    await db.execute('''
      CREATE TABLE $tableUploads (
        sample_id TEXT NOT NULL,
        endpoint_url TEXT NOT NULL,
        uploaded_at INTEGER NOT NULL,
        PRIMARY KEY (sample_id, endpoint_url)
      )
    ''');
    
    // Create index on endpoint_url for faster queries
    await db.execute('''
      CREATE INDEX idx_uploads_endpoint ON $tableUploads (endpoint_url)
    ''');
    
    // Create sessions table
    await db.execute('''
      CREATE TABLE $tableSessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_time INTEGER NOT NULL,
        end_time INTEGER,
        distance_meters REAL DEFAULT 0,
        sample_count INTEGER DEFAULT 0,
        ping_count INTEGER DEFAULT 0,
        success_count INTEGER DEFAULT 0,
        notes TEXT
      )
    ''');
    
    // Create planned markers table
    await db.execute('''
      CREATE TABLE $tableMarkers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        label TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    
    // Create privacy zones table
    await db.execute('''
      CREATE TABLE $tablePrivacyZones (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        radius_meters REAL NOT NULL,
        label TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add new columns for ping data
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN rssi INTEGER');
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN snr INTEGER');
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN pingSuccess INTEGER');
    }
    if (oldVersion < 3) {
      // Add observer names column
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN observerNames TEXT');
    }
    if (oldVersion < 4) {
      // Add uploaded tracking column
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN uploaded INTEGER DEFAULT 0');
    }
    if (oldVersion < 5) {
      // Create uploads tracking table for per-endpoint upload tracking
      await db.execute('''
        CREATE TABLE $tableUploads (
          sample_id TEXT NOT NULL,
          endpoint_url TEXT NOT NULL,
          uploaded_at INTEGER NOT NULL,
          PRIMARY KEY (sample_id, endpoint_url)
        )
      ''');
      
      await db.execute('''
        CREATE INDEX idx_uploads_endpoint ON $tableUploads (endpoint_url)
      ''');
      
      // Migrate existing uploaded samples to new table (assume default endpoint)
      await db.execute('''
        INSERT INTO $tableUploads (sample_id, endpoint_url, uploaded_at)
        SELECT id, 'https://meshwar-map.pages.dev/api/samples', ?
        FROM $tableSamples WHERE uploaded = 1
      ''', [DateTime.now().millisecondsSinceEpoch]);
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE $tableSessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          start_time INTEGER NOT NULL,
          end_time INTEGER,
          distance_meters REAL DEFAULT 0,
          sample_count INTEGER DEFAULT 0,
          ping_count INTEGER DEFAULT 0,
          success_count INTEGER DEFAULT 0,
          notes TEXT
        )
      ''');
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN response_time_ms INTEGER');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN ducting_risk TEXT');
      await db.execute('''
        CREATE TABLE $tableDuctingCache (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp INTEGER NOT NULL,
          lat REAL NOT NULL,
          lon REAL NOT NULL,
          risk TEXT NOT NULL,
          n_surface REAL,
          n_925 REAL,
          gradient REAL,
          fetched_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE INDEX idx_ducting_timestamp ON $tableDuctingCache (timestamp)
      ''');
    }
    if (oldVersion < 9) {
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN source TEXT');
      await db.execute('CREATE INDEX idx_samples_source ON $tableSamples (source)');
    }
    if (oldVersion < 10) {
      await db.execute('''
        CREATE TABLE $tableMarkers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          lat REAL NOT NULL,
          lon REAL NOT NULL,
          label TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 11) {
      await db.execute('''
        CREATE TABLE $tablePrivacyZones (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          lat REAL NOT NULL,
          lon REAL NOT NULL,
          radius_meters REAL NOT NULL,
          label TEXT
        )
      ''');
    }
    if (oldVersion < 12) {
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN device_id TEXT');
      await db.execute('''
        CREATE TABLE $tableDevices (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          public_key TEXT UNIQUE NOT NULL,
          name TEXT,
          connection_type TEXT,
          first_used INTEGER NOT NULL,
          last_used INTEGER NOT NULL
        )
      ''');
    }
  }

  /// Insert a sample into the database
  Future<void> insertSample(Sample sample) async {
    final db = await database;
    await db.insert(
      tableSamples,
      sample.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Insert multiple samples
  Future<void> insertSamples(List<Sample> samples) async {
    final db = await database;
    final batch = db.batch();
    for (final sample in samples) {
      batch.insert(
        tableSamples,
        sample.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Get all samples
  Future<List<Sample>> getAllSamples() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get samples within a time range
  Future<List<Sample>> getSamplesByTimeRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'timestamp >= ? AND timestamp <= ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get samples since a specific time
  Future<List<Sample>> getSamplesSince(DateTime since) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'timestamp > ?',
      whereArgs: [since.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get only samples that haven't been uploaded yet
  Future<List<Sample>> getUnuploadedSamples() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'uploaded = 0',
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Mark specific samples as uploaded
  Future<void> markSamplesAsUploaded(List<String> sampleIds) async {
    final db = await database;
    final batch = db.batch();
    for (final id in sampleIds) {
      batch.update(
        tableSamples,
        {'uploaded': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }
  
  /// Mark samples as uploaded to a specific endpoint
  Future<void> markSamplesAsUploadedToEndpoint(List<String> sampleIds, String endpointUrl) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    
    for (final id in sampleIds) {
      batch.insert(
        tableUploads,
        {
          'sample_id': id,
          'endpoint_url': endpointUrl,
          'uploaded_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }
  
  /// Get samples that haven't been uploaded to a specific endpoint
  Future<List<Sample>> getUnuploadedSamplesForEndpoint(String endpointUrl) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT s.* FROM $tableSamples s
      LEFT JOIN $tableUploads u ON s.id = u.sample_id AND u.endpoint_url = ?
      WHERE u.sample_id IS NULL
      ORDER BY s.timestamp DESC
    ''', [endpointUrl]);
    
    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get count of unuploaded samples
  Future<int> getUnuploadedSampleCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableSamples WHERE uploaded = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get the most recent sample
  Future<Sample?> getMostRecentSample() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      orderBy: 'timestamp DESC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Sample.fromMap(maps.first);
  }

  /// Get sample count
  Future<int> getSampleCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableSamples');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Delete all samples
  Future<void> deleteAllSamples() async {
    final db = await database;
    await db.delete(tableSamples);
  }

  /// Delete samples older than a certain date
  Future<void> deleteSamplesOlderThan(DateTime date) async {
    final db = await database;
    await db.delete(
      tableSamples,
      where: 'timestamp < ?',
      whereArgs: [date.millisecondsSinceEpoch],
    );
  }

  /// Export all samples as JSON
  Future<List<Map<String, dynamic>>> exportSamples() async {
    final samples = await getAllSamples();
    return samples.map((s) => s.toJson()).toList();
  }
  
  /// Export all data (samples + sessions + repeaters) as a unified JSON map
  /// Pass discoveredRepeaters from the LoRa service to include them.
  Future<Map<String, dynamic>> exportAllData({List<Map<String, dynamic>>? repeaters}) async {
    final samples = await getAllSamples();
    final sessions = await getAllSessions();
    final data = <String, dynamic>{
      '_format': 'meshcore_wardrive_data',
      '_version': 2,
      'samples': samples.map((s) => s.toJson()).toList(),
      'sessions': sessions.map((s) => s.toJson()).toList(),
    };
    if (repeaters != null && repeaters.isNotEmpty) {
      data['repeaters'] = repeaters;
    }
    return data;
  }
  
  /// Import data from unified format (samples + sessions).
  /// Also handles legacy format (plain sample array).
  /// Returns {samples: imported, sessions: imported}.
  Future<Map<String, int>> importAllData(dynamic jsonData) async {
    List<Map<String, dynamic>> samplesList;
    List<Map<String, dynamic>> sessionsList = [];
    
    if (jsonData is Map<String, dynamic> && jsonData.containsKey('samples')) {
      // New unified format
      samplesList = (jsonData['samples'] as List<dynamic>).cast<Map<String, dynamic>>();
      if (jsonData.containsKey('sessions')) {
        sessionsList = (jsonData['sessions'] as List<dynamic>).cast<Map<String, dynamic>>();
      }
    } else if (jsonData is List) {
      // Legacy format: plain array of samples
      samplesList = jsonData.cast<Map<String, dynamic>>();
    } else {
      throw const FormatException('Unrecognized export format');
    }
    
    // Import samples
    final samplesImported = await importSamples(samplesList);
    
    // Import sessions (skip duplicates by start_time)
    int sessionsImported = 0;
    if (sessionsList.isNotEmpty) {
      final db = await database;
      for (final json in sessionsList) {
        try {
          final session = WSession.fromJson(json);
          // Check for duplicate by start time
          final existing = await db.query(
            tableSessions,
            where: 'start_time = ?',
            whereArgs: [session.startTime.millisecondsSinceEpoch],
            limit: 1,
          );
          if (existing.isEmpty) {
            await db.insert(tableSessions, session.toMap());
            sessionsImported++;
          }
        } catch (e) {
          print('Error importing session: $e');
        }
      }
    }
    
    return {'samples': samplesImported, 'sessions': sessionsImported};
  }

  /// Import samples from JSON (skips duplicates by ID)
  Future<int> importSamples(List<Map<String, dynamic>> jsonData) async {
    final db = await database;
    int importedCount = 0;
    
    for (final json in jsonData) {
      try {
        final sample = Sample.fromJson(json);
        
        // Check if sample with this ID already exists
        final existing = await db.query(
          tableSamples,
          where: 'id = ?',
          whereArgs: [sample.id],
          limit: 1,
        );
        
        if (existing.isEmpty) {
          await db.insert(
            tableSamples,
            sample.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          importedCount++;
        }
      } catch (e) {
        print('Error importing sample: $e');
        // Skip invalid samples
      }
    }
    
    return importedCount;
  }

  /// Create a new session, returns the session ID
  Future<int> createSession(WSession session) async {
    final db = await database;
    return await db.insert(tableSessions, session.toMap());
  }
  
  /// Update an existing session
  Future<void> updateSession(WSession session) async {
    final db = await database;
    await db.update(
      tableSessions,
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }
  
  /// Get all sessions, newest first
  Future<List<WSession>> getAllSessions() async {
    final db = await database;
    final maps = await db.query(
      tableSessions,
      orderBy: 'start_time DESC',
    );
    return maps.map((m) => WSession.fromMap(m)).toList();
  }
  
  /// Delete a session by ID
  Future<void> deleteSession(int id) async {
    final db = await database;
    await db.delete(tableSessions, where: 'id = ?', whereArgs: [id]);
  }
  
  /// Get sample counts for a session's time range
  Future<Map<String, int>> getSessionSampleCounts(DateTime start, DateTime end) async {
    final db = await database;
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    
    final totalResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE timestamp >= ? AND timestamp <= ?',
      [startMs, endMs],
    );
    final pingResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE timestamp >= ? AND timestamp <= ? AND pingSuccess IS NOT NULL',
      [startMs, endMs],
    );
    final successResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE timestamp >= ? AND timestamp <= ? AND pingSuccess = 1',
      [startMs, endMs],
    );
    
    return {
      'total': Sqflite.firstIntValue(totalResult) ?? 0,
      'pings': Sqflite.firstIntValue(pingResult) ?? 0,
      'successes': Sqflite.firstIntValue(successResult) ?? 0,
    };
  }

  /// Get all distinct source names from samples
  Future<List<String>> getDistinctSources() async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT DISTINCT source FROM $tableSamples WHERE source IS NOT NULL ORDER BY source',
    );
    return results.map((r) => r['source'] as String).toList();
  }
  
  /// Get samples filtered by source
  Future<List<Sample>> getSamplesBySource(String source) async {
    final db = await database;
    final maps = await db.query(
      tableSamples,
      where: 'source = ?',
      whereArgs: [source],
      orderBy: 'timestamp DESC',
    );
    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get all distinct repeater IDs (node_id / path) that have ever responded to a ping
  Future<Set<String>> getDistinctRepeaterIds() async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT DISTINCT path FROM $tableSamples WHERE path IS NOT NULL AND path != \'\'',
    );
    return results.map((r) => (r['path'] as String).toUpperCase()).toSet();
  }

  /// Check if a coverage cell (geohash prefix) is a known dead zone.
  /// Returns true if there are ping samples AND all of them failed.
  Future<bool> isDeadZoneCell(String geohashPrefix) async {
    final db = await database;
    // Count pings (pingSuccess IS NOT NULL) in this cell
    final totalResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE geohash LIKE ? AND pingSuccess IS NOT NULL',
      ['$geohashPrefix%'],
    );
    final total = Sqflite.firstIntValue(totalResult) ?? 0;
    if (total == 0) return false; // No ping data = not a dead zone
    
    // Count successful pings
    final successResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE geohash LIKE ? AND pingSuccess = 1',
      ['$geohashPrefix%'],
    );
    final successes = Sqflite.firstIntValue(successResult) ?? 0;
    return successes == 0; // Dead zone = all pings failed
  }

  // ============================================================================
  // DEVICES
  // ============================================================================
  
  /// Add or update a paired device
  Future<void> upsertDevice(String publicKey, String name, String connectionType) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await db.query(tableDevices, where: 'public_key = ?', whereArgs: [publicKey], limit: 1);
    if (existing.isEmpty) {
      await db.insert(tableDevices, {
        'public_key': publicKey,
        'name': name,
        'connection_type': connectionType,
        'first_used': now,
        'last_used': now,
      });
    } else {
      await db.update(tableDevices, {
        'name': name,
        'connection_type': connectionType,
        'last_used': now,
      }, where: 'public_key = ?', whereArgs: [publicKey]);
    }
  }
  
  /// Get all paired devices
  Future<List<Map<String, dynamic>>> getAllDevices() async {
    final db = await database;
    return await db.query(tableDevices, orderBy: 'last_used DESC');
  }
  
  /// Get per-device stats from samples tagged with device_id
  Future<Map<String, dynamic>> getDeviceStats(String publicKey) async {
    final db = await database;
    final total = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE device_id = ? AND pingSuccess IS NOT NULL',
      [publicKey],
    )) ?? 0;
    final successes = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE device_id = ? AND pingSuccess = 1',
      [publicKey],
    )) ?? 0;
    final failures = total - successes;
    final cells = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(DISTINCT substr(geohash, 1, 6)) FROM $tableSamples WHERE device_id = ? AND pingSuccess IS NOT NULL',
      [publicKey],
    )) ?? 0;
    
    final avgResp = await db.rawQuery(
      'SELECT AVG(response_time_ms) as avg_resp FROM $tableSamples WHERE device_id = ? AND response_time_ms IS NOT NULL',
      [publicKey],
    );
    final avgResponseMs = (avgResp.first['avg_resp'] as num?)?.toDouble();
    
    final avgSignal = await db.rawQuery(
      'SELECT AVG(snr) as avg_snr, AVG(rssi) as avg_rssi FROM $tableSamples WHERE device_id = ? AND pingSuccess = 1',
      [publicKey],
    );
    final avgSnr = (avgSignal.first['avg_snr'] as num?)?.toDouble();
    final avgRssi = (avgSignal.first['avg_rssi'] as num?)?.toDouble();
    
    return {
      'totalPings': total,
      'successes': successes,
      'failures': failures,
      'successRate': total > 0 ? successes / total : 0.0,
      'uniqueCells': cells,
      'avgResponseMs': avgResponseMs,
      'avgSnr': avgSnr,
      'avgRssi': avgRssi,
    };
  }

  // ============================================================================
  // PLANNED MARKERS
  // ============================================================================
  
  /// Add a planned repeater marker
  Future<int> addMarker(double lat, double lon, String? label) async {
    final db = await database;
    return await db.insert(tableMarkers, {
      'lat': lat,
      'lon': lon,
      'label': label,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }
  
  /// Get all planned markers
  Future<List<Map<String, dynamic>>> getAllMarkers() async {
    final db = await database;
    return await db.query(tableMarkers, orderBy: 'created_at DESC');
  }
  
  /// Delete a planned marker by ID
  Future<void> deleteMarker(int id) async {
    final db = await database;
    await db.delete(tableMarkers, where: 'id = ?', whereArgs: [id]);
  }
  
  /// Update a marker's label
  Future<void> updateMarkerLabel(int id, String? label) async {
    final db = await database;
    await db.update(tableMarkers, {'label': label}, where: 'id = ?', whereArgs: [id]);
  }
  
  // ============================================================================
  // DELETE DATA
  // ============================================================================
  
  /// Delete a single sample by ID
  Future<void> deleteSample(String sampleId) async {
    final db = await database;
    await db.delete(tableSamples, where: 'id = ?', whereArgs: [sampleId]);
  }
  
  /// Delete all samples in a coverage cell (by geohash prefix)
  /// Uses the coverage precision to match the cell
  Future<int> deleteSamplesByGeohash(String geohashPrefix) async {
    final db = await database;
    return await db.delete(
      tableSamples,
      where: 'geohash LIKE ?',
      whereArgs: ['$geohashPrefix%'],
    );
  }

  // ============================================================================
  // PRIVACY ZONES
  // ============================================================================
  
  /// Add a privacy zone (circular exclusion area)
  Future<int> addPrivacyZone(double lat, double lon, double radiusMeters, String? label) async {
    final db = await database;
    return await db.insert(tablePrivacyZones, {
      'lat': lat,
      'lon': lon,
      'radius_meters': radiusMeters,
      'label': label,
    });
  }
  
  /// Get all privacy zones
  Future<List<Map<String, dynamic>>> getAllPrivacyZones() async {
    final db = await database;
    return await db.query(tablePrivacyZones);
  }
  
  /// Delete a privacy zone by ID
  Future<void> deletePrivacyZone(int id) async {
    final db = await database;
    await db.delete(tablePrivacyZones, where: 'id = ?', whereArgs: [id]);
  }
  
  /// Check if a lat/lon point falls inside any privacy zone
  /// Uses haversine approximation (good enough for small radii)
  Future<bool> isInPrivacyZone(double lat, double lon) async {
    final zones = await getAllPrivacyZones();
    for (final zone in zones) {
      final dlat = (lat - (zone['lat'] as double)) * 111320; // meters per degree lat
      final dlon = (lon - (zone['lon'] as double)) * 111320 * cos(lat * 3.14159 / 180);
      final dist = sqrt(dlat * dlat + dlon * dlon);
      if (dist <= (zone['radius_meters'] as double)) return true;
    }
    return false;
  }
  
  /// Filter a list of samples, removing those inside privacy zones
  Future<List<Sample>> filterByPrivacyZones(List<Sample> samples) async {
    final zones = await getAllPrivacyZones();
    if (zones.isEmpty) return samples;
    
    return samples.where((s) {
      for (final zone in zones) {
        final dlat = (s.position.latitude - (zone['lat'] as double)) * 111320;
        final dlon = (s.position.longitude - (zone['lon'] as double)) * 111320 * cos(s.position.latitude * 3.14159 / 180);
        final dist = sqrt(dlat * dlat + dlon * dlon);
        if (dist <= (zone['radius_meters'] as double)) return false;
      }
      return true;
    }).toList();
  }

  /// Close the database
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
