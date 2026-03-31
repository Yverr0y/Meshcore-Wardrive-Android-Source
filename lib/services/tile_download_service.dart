import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert' show utf8;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:crypto/crypto.dart' show md5;

/// Downloads map tiles for offline use within a bounding box and zoom range.
/// 
/// Tiles are saved to the same cache directory used by flutter_map_cache
/// so they're available automatically when offline.
class TileDownloadService {
  final String _cacheDir;
  bool _cancelled = false;

  TileDownloadService(this._cacheDir);

  /// Cancel an in-progress download
  void cancel() {
    _cancelled = true;
  }

  /// Calculate the number of tiles for a given bounds and zoom range
  static int estimateTileCount(LatLng sw, LatLng ne, int minZoom, int maxZoom) {
    int count = 0;
    for (int z = minZoom; z <= maxZoom; z++) {
      final xMin = _lngToTileX(sw.longitude, z);
      final xMax = _lngToTileX(ne.longitude, z);
      final yMin = _latToTileY(ne.latitude, z);
      final yMax = _latToTileY(sw.latitude, z);
      count += (xMax - xMin + 1) * (yMax - yMin + 1);
    }
    return count;
  }

  /// Download tiles for the given bounds and zoom range.
  /// 
  /// [urlTemplate] — tile URL with {z}, {x}, {y} placeholders.
  /// [onProgress] — called with (completed, total) counts.
  /// Returns the number of tiles successfully downloaded.
  Future<int> downloadTiles({
    required LatLng sw,
    required LatLng ne,
    required int minZoom,
    required int maxZoom,
    required String urlTemplate,
    void Function(int completed, int total)? onProgress,
  }) async {
    _cancelled = false;
    final total = estimateTileCount(sw, ne, minZoom, maxZoom);
    int completed = 0;
    int succeeded = 0;

    await Directory(_cacheDir).create(recursive: true);

    final client = http.Client();
    try {
      for (int z = minZoom; z <= maxZoom && !_cancelled; z++) {
        final xMin = _lngToTileX(sw.longitude, z);
        final xMax = _lngToTileX(ne.longitude, z);
        final yMin = _latToTileY(ne.latitude, z);
        final yMax = _latToTileY(sw.latitude, z);

        for (int x = xMin; x <= xMax && !_cancelled; x++) {
          for (int y = yMin; y <= yMax && !_cancelled; y++) {
            final url = urlTemplate
                .replaceFirst('{z}', z.toString())
                .replaceFirst('{x}', x.toString())
                .replaceFirst('{y}', y.toString())
                .replaceFirst('{s}', 'a');

            try {
              final hash = md5.convert(utf8.encode(url)).toString();
              final file = File('$_cacheDir/$hash');
              
              // Skip already-cached tiles
              if (await file.exists()) {
                succeeded++;
                completed++;
                onProgress?.call(completed, total);
                continue;
              }

              final response = await client
                  .get(Uri.parse(url))
                  .timeout(const Duration(seconds: 10));
              if (response.statusCode == 200) {
                await file.writeAsBytes(response.bodyBytes);
                succeeded++;
              }
            } catch (_) {
              // Skip failed tiles, continue with next
            }

            completed++;
            onProgress?.call(completed, total);
          }
        }
      }
    } finally {
      client.close();
    }

    return succeeded;
  }

  /// Convert longitude to tile X coordinate at zoom level z
  static int _lngToTileX(double lng, int z) {
    return ((lng + 180.0) / 360.0 * (1 << z)).floor();
  }

  /// Convert latitude to tile Y coordinate at zoom level z
  static int _latToTileY(double lat, int z) {
    final latRad = lat * pi / 180.0;
    return ((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / pi) / 2.0 * (1 << z)).floor();
  }
}
