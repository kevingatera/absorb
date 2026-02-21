import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const appVersion = '1.2.1';

  final String baseUrl;
  final String token;

  // Device info — set once at app start
  static String deviceManufacturer = '';
  static String deviceModel = '';
  static String deviceId = '';

  /// Generate or load a persistent unique device ID
  static Future<void> initDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('absorb_device_id');
    if (id == null || id.isEmpty) {
      // Generate a unique ID for this install
      id = 'absorb-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${(DateTime.now().microsecond * 31337).toRadixString(36)}';
      await prefs.setString('absorb_device_id', id);
    }
    deviceId = id;
  }

  ApiService({required this.baseUrl, required this.token});

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  String get _cleanBaseUrl =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// Login and return the full response JSON (contains user, token, etc.)
  static Future<Map<String, dynamic>?> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final url = serverUrl.endsWith('/')
        ? '${serverUrl}login'
        : '$serverUrl/login';

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Ping the server to check connectivity.
  static Future<bool> pingServer(String serverUrl) async {
    final url = serverUrl.endsWith('/')
        ? '${serverUrl}ping'
        : '$serverUrl/ping';
    try {
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Get the server version via the /status endpoint (no auth needed).
  static Future<String?> getServerVersion(String serverUrl) async {
    final url = serverUrl.endsWith('/')
        ? '${serverUrl}status'
        : '$serverUrl/status';
    try {
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['serverVersion'] as String?;
      }
    } catch (_) {}
    return null;
  }

  /// Get all libraries.
  Future<List<dynamic>> getLibraries() async {
    try {
      final response = await http.get(
        Uri.parse('$_cleanBaseUrl/api/libraries'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['libraries'] as List?) ?? [];
      }
    } catch (e) {
      // ignore
    }
    return [];
  }

  /// Get the personalized home view for a library.
  /// Returns sections like "continue-listening", "recently-added", "discover", etc.
  Future<List<dynamic>> getPersonalizedView(String libraryId) async {
    try {
      final response = await http.get(
        Uri.parse(
            '$_cleanBaseUrl/api/libraries/$libraryId/personalized'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as List<dynamic>;
      }
    } catch (e) {
      // ignore
    }
    return [];
  }

  /// Get library items (paginated).
  Future<Map<String, dynamic>?> getLibraryItems(
    String libraryId, {
    int page = 0,
    int limit = 20,
    String sort = 'addedAt',
    int desc = 1,
    String? filter,
  }) async {
    try {
      var url = '$_cleanBaseUrl/api/libraries/$libraryId/items'
          '?page=$page&limit=$limit&sort=$sort&desc=$desc';
      if (filter != null) url += '&filter=$filter';
      final response = await http.get(
        Uri.parse(url),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  /// Build a cover image URL for a library item.
  String getCoverUrl(String itemId, {int width = 400}) {
    return '$_cleanBaseUrl/api/items/$itemId/cover?width=$width&token=$token';
  }

  /// Get current user info including all mediaProgress.
  Future<Map<String, dynamic>?> getMe() async {
    try {
      final response = await http.get(
        Uri.parse('$_cleanBaseUrl/api/me'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Get user's listening stats.
  Future<Map<String, dynamic>?> getListeningStats() async {
    try {
      final response = await http.get(
        Uri.parse('$_cleanBaseUrl/api/me/listening-stats'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Get user's listening sessions (paginated).
  Future<Map<String, dynamic>?> getListeningSessions({int page = 0, int itemsPerPage = 20}) async {
    try {
      final response = await http.get(
        Uri.parse('$_cleanBaseUrl/api/me/listening-sessions?itemsPerPage=$itemsPerPage&page=$page'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Get a library's series (paginated).
  Future<Map<String, dynamic>?> getLibrarySeries(
    String libraryId, {
    int page = 0,
    int limit = 50,
    String sort = 'addedAt',
    int desc = 1,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$_cleanBaseUrl/api/libraries/$libraryId/series'
          '?page=$page&limit=$limit&sort=$sort&desc=$desc',
        ),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  /// Build an author image URL.
  String getAuthorImageUrl(String authorId, {int width = 200}) {
    return '$_cleanBaseUrl/api/authors/$authorId/image?width=$width&token=$token';
  }

  /// Expose clean base URL for audio player to build URLs
  String get cleanBaseUrl => _cleanBaseUrl;

  /// Start a playback session for a library item.
  /// POST /api/items/:id/play
  /// Returns the full session object including audioTracks with contentUrl.
  Future<Map<String, dynamic>?> startPlaybackSession(String itemId) async {
    try {
      final url = '$_cleanBaseUrl/api/items/$itemId/play';
      debugPrint('[ABS] Starting playback session: POST $url');
      final response = await http.post(
        Uri.parse(url),
        headers: _headers,
        body: jsonEncode({
          'deviceInfo': {
            'clientName': 'Absorb',
            'clientVersion': appVersion,
            'deviceId': deviceId,
            'deviceName': '${deviceManufacturer.isNotEmpty ? "$deviceManufacturer " : ""}$deviceModel'.trim(),
            'manufacturer': deviceManufacturer,
            'model': deviceModel,
          },
          'forceDirectPlay': true,
          'forceTranscode': false,
          'mediaPlayer': 'unknown',
          'supportedMimeTypes': [
            'audio/flac',
            'audio/mpeg',
            'audio/mp4',
            'audio/ogg',
            'audio/aac',
          ],
        }),
      ).timeout(const Duration(seconds: 20));

      debugPrint('[ABS] Play session response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tracks = data['audioTracks'] as List<dynamic>?;
        debugPrint('[ABS] Session ID: ${data['id']}');
        debugPrint('[ABS] Audio tracks: ${tracks?.length ?? 0}');
        if (tracks != null && tracks.isNotEmpty) {
          final firstTrack = tracks.first as Map<String, dynamic>;
          debugPrint('[ABS] First track contentUrl: ${firstTrack['contentUrl']}');
        }
        return data;
      } else {
        debugPrint('[ABS] Play session failed: ${response.body}');
      }
    } catch (e) {
      debugPrint('[ABS] Play session error: $e');
    }
    return null;
  }

  /// Build a full audio track URL from a contentUrl returned by the play session.
  String buildTrackUrl(String contentUrl) {
    if (contentUrl.startsWith('http')) return contentUrl;
    final url = '$_cleanBaseUrl$contentUrl?token=$token';
    debugPrint('[ABS] Track URL: $url');
    return url;
  }

  /// Sync playback progress.
  /// POST /api/session/:id/sync
  Future<void> syncPlaybackSession(
    String sessionId, {
    required double currentTime,
    required double duration,
  }) async {
    try {
      await http.post(
        Uri.parse('$_cleanBaseUrl/api/session/$sessionId/sync'),
        headers: _headers,
        body: jsonEncode({
          'currentTime': currentTime,
          'timeListened': 15,
          'duration': duration,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Close a playback session.
  /// POST /api/session/:id/close
  Future<void> closePlaybackSession(String sessionId) async {
    try {
      await http.post(
        Uri.parse('$_cleanBaseUrl/api/session/$sessionId/close'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Get server progress for a single item.
  /// GET /api/me/progress/:id
  Future<Map<String, dynamic>?> getItemProgress(String itemId) async {
    try {
      final resp = await http.get(
        Uri.parse('$_cleanBaseUrl/api/me/progress/$itemId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Update media progress directly (for offline sync).
  /// PATCH /api/me/progress/:id
  Future<void> updateProgress(
    String itemId, {
    required double currentTime,
    required double duration,
    bool isFinished = false,
  }) async {
    try {
      final body = jsonEncode({
        'currentTime': currentTime,
        'duration': duration,
        'progress': duration > 0 ? currentTime / duration : 0,
        'isFinished': isFinished,
      });
      debugPrint('[API] updateProgress PATCH /api/me/progress/$itemId');
      debugPrint('[API] updateProgress body: currentTime=$currentTime');
      final resp = await http.patch(
        Uri.parse('$_cleanBaseUrl/api/me/progress/$itemId'),
        headers: _headers,
        body: body,
      ).timeout(const Duration(seconds: 10));
      debugPrint('[API] updateProgress response: ${resp.statusCode} ${resp.body}');
    } catch (e) {
      debugPrint('[API] updateProgress error: $e');
      rethrow;
    }
  }

  /// Mark a book as finished on the server.
  Future<void> markFinished(String itemId, double duration) async {
    await updateProgress(
      itemId,
      currentTime: duration,
      duration: duration,
      isFinished: true,
    );
  }

  /// Mark a book as not finished (reset progress to a position).
  Future<void> markNotFinished(String itemId, {
    required double currentTime,
    required double duration,
  }) async {
    await updateProgress(
      itemId,
      currentTime: currentTime,
      duration: duration,
      isFinished: false,
    );
  }

  /// DELETE /api/me/progress/:id — fully remove progress entry
  Future<bool> deleteProgress(String itemId) async {
    try {
      final resp = await http.delete(
        Uri.parse('$_cleanBaseUrl/api/me/progress/$itemId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
      debugPrint('[API] deleteProgress response: ${resp.statusCode} ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('[API] deleteProgress error: $e');
      return false;
    }
  }

  /// Reset progress to zero.
  Future<bool> resetProgress(String itemId, double duration) async {
    try {
      // DELETE progress entry
      await http.delete(
        Uri.parse('$_cleanBaseUrl/api/me/progress/$itemId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      // Start session at 0 and close — forces server to update position
      final sessionData = await startPlaybackSession(itemId);
      if (sessionData != null) {
        final sessionId = sessionData['id'] as String?;
        if (sessionId != null) {
          await syncPlaybackSession(sessionId, currentTime: 0, duration: duration);
          await closePlaybackSession(sessionId);
        }
      }

      // PATCH last to hide from continue listening (after session sync)
      await http.patch(
        Uri.parse('$_cleanBaseUrl/api/me/progress/$itemId'),
        headers: _headers,
        body: jsonEncode({
          'currentTime': 0,
          'progress': 0,
          'isFinished': false,
          'hideFromContinueListening': true,
          'lastUpdate': DateTime.now().millisecondsSinceEpoch,
        }),
      ).timeout(const Duration(seconds: 10));

      return true;
    } catch (e) {
      debugPrint('[API] resetProgress error: $e');
      return false;
    }
  }

  /// Get a single library item with full detail (expanded=1 gives chapters, tracks, etc.)
  Future<Map<String, dynamic>?> getLibraryItem(String itemId) async {
    try {
      final response = await http.get(
        Uri.parse('$_cleanBaseUrl/api/items/$itemId?expanded=1&include=progress'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  /// Get a single series with its books.
  Future<Map<String, dynamic>?> getSeries(String seriesId, {String? libraryId}) async {
    try {
      Map<String, dynamic>? seriesMeta;
      
      // Get series metadata
      if (libraryId != null) {
        final metaResp = await http.get(
          Uri.parse('$_cleanBaseUrl/api/libraries/$libraryId/series/$seriesId'),
          headers: _headers,
        ).timeout(const Duration(seconds: 15));
        if (metaResp.statusCode == 200) {
          seriesMeta = jsonDecode(metaResp.body) as Map<String, dynamic>;
        }
      }
      
      // Get books in the series via library items filter
      // ABS filter format: series.<base64(seriesId)>
      if (libraryId != null) {
        final filterValue = base64Encode(utf8.encode(seriesId));
        final url = '$_cleanBaseUrl/api/libraries/$libraryId/items?filter=series.$filterValue&sort=media.metadata.series.sequence&limit=100&collapseseries=0';
        final itemsResp = await http.get(
          Uri.parse(url),
          headers: _headers,
        ).timeout(const Duration(seconds: 15));
        if (itemsResp.statusCode == 200) {
          final data = jsonDecode(itemsResp.body) as Map<String, dynamic>;
          final results = data['results'] as List<dynamic>? ?? [];
          return {
            'id': seriesId,
            'name': seriesMeta?['name'] ?? '',
            'books': results,
          };
        }
      }
    } catch (e) {
    }
    return null;
  }

  /// Search a library. Returns { book: [...], series: [...], authors: [...] }
  Future<Map<String, dynamic>?> searchLibrary(
    String libraryId,
    String query, {
    int limit = 25,
  }) async {
    try {
      final encoded = Uri.encodeQueryComponent(query);
      final response = await http.get(
        Uri.parse(
          '$_cleanBaseUrl/api/libraries/$libraryId/search?q=$encoded&limit=$limit',
        ),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  /// Fetch Audible rating from Audnexus API using ASIN.
  /// Returns { rating } or null.
  static Future<Map<String, dynamic>?> getAudibleRating(String asin) async {
    try {
      final response = await http.get(
        Uri.parse('https://api.audnex.us/books/$asin?update=1'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rating = data['rating'] as String?;
        if (rating != null) {
          return {
            'rating': double.tryParse(rating) ?? 0.0,
          };
        }
      }
    } catch (e) {
      // ignore — Audnexus is optional
    }
    return null;
  }

  /// Search Audible via the audiobookshelf server for an ASIN by title+author,
  /// then fetch the rating from Audnexus. Used as a fallback when the book's
  /// stored ASIN returns no rating.
  Future<Map<String, dynamic>?> searchAudibleRating(
      String title, String? author) async {
    try {
      // Use the ABS server's search endpoint to query Audible for the book
      final query = author != null && author.isNotEmpty
          ? '$title $author'
          : title;
      final encoded = Uri.encodeQueryComponent(query);
      final response = await http.get(
        Uri.parse(
          '$_cleanBaseUrl/api/search/covers?title=${Uri.encodeQueryComponent(title)}'
          '&author=${Uri.encodeQueryComponent(author ?? '')}'
          '&provider=audible',
        ),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List<dynamic>? ?? [];
        // Look for an ASIN in the results
        for (final r in results) {
          if (r is Map<String, dynamic>) {
            final asin = r['asin'] as String? ?? r['key'] as String? ?? '';
            if (asin.isNotEmpty && asin.startsWith('B')) {
              return await getAudibleRating(asin);
            }
          }
        }
      }
    } catch (e) {
      // ignore
    }
    return null;
  }
}
