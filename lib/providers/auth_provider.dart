import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';

class AuthProvider extends ChangeNotifier {
  String? _token;
  String? _serverUrl;
  String? _username;
  String? _userId;
  String? _defaultLibraryId;
  Map<String, dynamic>? _userJson;
  Map<String, dynamic>? _serverSettings;
  String? _serverVersion;
  bool _serverReachable = true;

  bool _isLoading = true;
  String? _errorMessage;

  // Getters
  bool get isAuthenticated => _token != null && _serverUrl != null;
  bool get isLoading => _isLoading;
  bool get serverReachable => _serverReachable;
  String? get token => _token;
  String? get serverUrl => _serverUrl;
  String? get username => _username;
  String? get userId => _userId;
  String? get defaultLibraryId => _defaultLibraryId;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get userJson => _userJson;
  Map<String, dynamic>? get serverSettings => _serverSettings;
  String? get serverVersion => _serverVersion;

  ApiService? get apiService {
    if (_serverUrl != null && _token != null) {
      return ApiService(baseUrl: _serverUrl!, token: _token!);
    }
    return null;
  }

  /// Try to restore a saved session from SharedPreferences.
  /// If the server is unreachable, still restore credentials so offline mode works.
  Future<void> tryRestoreSession() async {
    _isLoading = true;
    _serverReachable = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('server_url');
      final savedToken = prefs.getString('token');
      final savedUsername = prefs.getString('username');
      final savedLibraryId = prefs.getString('default_library_id');

      if (savedUrl != null && savedToken != null) {
        // Always restore credentials so we can at least go offline
        _serverUrl = savedUrl;
        _token = savedToken;
        _username = savedUsername;
        _defaultLibraryId = savedLibraryId;

        // Check if server is actually reachable
        final reachable = await ApiService.pingServer(savedUrl);
        _serverReachable = reachable;
      }
    } catch (_) {
      // Restore failed — but if we already set credentials, keep them
      _serverReachable = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Login with username/password.
  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    // Normalize server URL
    String url = serverUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // Check server reachability
    final reachable = await ApiService.pingServer(url);
    if (!reachable) {
      _errorMessage = 'Cannot reach server at $url';
      _isLoading = false;
      notifyListeners();
      return false;
    }

    // Attempt login
    final result = await ApiService.login(
      serverUrl: url,
      username: username,
      password: password,
    );

    if (result == null) {
      _errorMessage = 'Invalid username or password';
      _isLoading = false;
      notifyListeners();
      return false;
    }

    // Extract user info
    final user = result['user'] as Map<String, dynamic>?;
    if (user == null) {
      _errorMessage = 'Unexpected server response';
      _isLoading = false;
      notifyListeners();
      return false;
    }

    _serverUrl = url;
    _token = user['token'] as String?;
    _username = user['username'] as String?;
    _userId = user['id'] as String?;
    _defaultLibraryId = result['userDefaultLibraryId'] as String?;
    _userJson = user;
    _serverSettings = result['serverSettings'] as Map<String, dynamic>?;

    // Fetch server version from /status endpoint (fire and forget)
    _fetchServerVersion(url);

    // Persist session
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', _serverUrl!);
      if (_token != null) await prefs.setString('token', _token!);
      if (_username != null) await prefs.setString('username', _username!);
      if (_defaultLibraryId != null) {
        await prefs.setString('default_library_id', _defaultLibraryId!);
      }
    } catch (_) {}

    _isLoading = false;
    notifyListeners();
    return true;
  }

  /// Login using OIDC callback response data.
  /// [result] is the JSON from /auth/openid/callback — same shape as /login response.
  Future<bool> loginWithOidc({
    required String serverUrl,
    required Map<String, dynamic> result,
  }) async {
    _errorMessage = null;

    String url = serverUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);

    final user = result['user'] as Map<String, dynamic>?;
    if (user == null) {
      _errorMessage = 'SSO returned an unexpected response';
      notifyListeners();
      return false;
    }

    _serverUrl = url;
    _token = user['token'] as String?;
    _username = user['username'] as String?;
    _userId = user['id'] as String?;
    _defaultLibraryId = result['userDefaultLibraryId'] as String?;
    _userJson = user;
    _serverSettings = result['serverSettings'] as Map<String, dynamic>?;
    _serverReachable = true;

    // Fetch server version
    _fetchServerVersion(url);

    // Persist session
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', _serverUrl!);
      if (_token != null) await prefs.setString('token', _token!);
      if (_username != null) await prefs.setString('username', _username!);
      if (_defaultLibraryId != null) {
        await prefs.setString('default_library_id', _defaultLibraryId!);
      }
    } catch (_) {}

    _isLoading = false;
    notifyListeners();
    return true;
  }

  /// Logout and clear stored session.
  /// Fetch server version asynchronously (non-blocking).
  void _fetchServerVersion(String url) async {
    try {
      final version = await ApiService.getServerVersion(url);
      if (version != null) {
        _serverVersion = version;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> logout() async {
    // Stop any active playback
    try {
      final player = AudioPlayerService();
      if (player.hasBook) {
        await player.pause();
        await player.stop();
      }
    } catch (_) {}

    _token = null;
    _serverUrl = null;
    _username = null;
    _userId = null;
    _defaultLibraryId = null;
    _userJson = null;
    _serverSettings = null;
    _serverVersion = null;
    _errorMessage = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('server_url');
      await prefs.remove('token');
      await prefs.remove('username');
      await prefs.remove('default_library_id');
    } catch (_) {}

    notifyListeners();
  }
}
