import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'dart:io' show HttpClient, HttpHeaders;

/// Manages the OIDC/OAuth2 PKCE flow for audiobookshelf SSO login.
class OidcService {
  static final OidcService _instance = OidcService._();
  factory OidcService() => _instance;
  OidcService._();

  // PKCE state
  String? _codeVerifier;
  String? _codeChallenge;
  String? _state;
  String? _serverUrl;

  /// The raw cookie strings from the /auth/openid response.
  List<String> _rawCookies = [];

  static const _redirectUri = 'audiobookshelfhomelab://oauth';
  static const _clientId = 'Audiobookshelf-App';

  /// Generate a cryptographically random string of [length] bytes, base64url-encoded.
  String _generateRandom(int length) {
    final random = Random.secure();
    final bytes = List<int>.generate(length, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Generate PKCE code_verifier and code_challenge (S256).
  void _generatePkce() {
    _codeVerifier = _generateRandom(32); // 43-char min
    final bytes = utf8.encode(_codeVerifier!);
    final digest = sha256.convert(bytes);
    _codeChallenge = base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Start the OIDC login flow using a Chrome Custom Tab.
  /// Returns the callback [Uri] on success, or null on failure/cancellation.
  Future<Uri?> startLogin(String serverUrl) async {
    _serverUrl = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
    _generatePkce();
    _state = _generateRandom(16);
    _rawCookies = [];

    final authUrl = '$_serverUrl/auth/openid'
        '?code_challenge=$_codeChallenge'
        '&code_challenge_method=S256'
        '&redirect_uri=${Uri.encodeComponent(_redirectUri)}'
        '&client_id=${Uri.encodeComponent(_clientId)}'
        '&response_type=code'
        '&state=$_state';

    debugPrint('[OIDC] Starting auth flow: $authUrl');

    try {
      // Pre-flight request to capture cookies and get the OIDC provider redirect URL.
      // ABS sets a session cookie that links the PKCE challenge to this flow.
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);

      String? providerUrl;
      try {
        final request = await client.getUrl(Uri.parse(authUrl));
        request.followRedirects = false;
        request.headers.set('x-return-tokens', 'true');
        final response = await request.close();

        // Capture cookies for the callback request
        final cookies = response.cookies;
        for (final cookie in cookies) {
          _rawCookies.add('${cookie.name}=${cookie.value}');
          debugPrint('[OIDC] Captured cookie: ${cookie.name}');
        }
        if (_rawCookies.isEmpty) {
          final rawSetCookie = response.headers[HttpHeaders.setCookieHeader];
          if (rawSetCookie != null) {
            for (final sc in rawSetCookie) {
              final nameValue = sc.split(';').first.trim();
              _rawCookies.add(nameValue);
              debugPrint('[OIDC] Captured raw cookie: $nameValue');
            }
          }
        }

        if (response.statusCode == 302 || response.statusCode == 301) {
          providerUrl = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
        } else {
          final body = await response.transform(utf8.decoder).join();
          debugPrint('[OIDC] Unexpected status ${response.statusCode}: $body');
          _cleanup();
          return null;
        }
      } finally {
        client.close();
      }

      if (providerUrl == null || providerUrl.isEmpty) {
        debugPrint('[OIDC] Server did not return a redirect URL');
        _cleanup();
        return null;
      }

      debugPrint('[OIDC] Opening Custom Tab for: $providerUrl');

      // Open the OIDC provider in a Chrome Custom Tab. This blocks until the
      // provider redirects back to audiobookshelfhomelab://oauth, which the Custom Tab
      // intercepts and returns. Unlike an external browser, Custom Tabs won't
      // be hijacked by PWAs or other apps registered for the provider's domain.
      final resultUrl = await FlutterWebAuth2.authenticate(
        url: providerUrl,
        callbackUrlScheme: 'audiobookshelfhomelab',
      );

      debugPrint('[OIDC] Custom Tab returned: $resultUrl');
      return Uri.parse(resultUrl);
    } catch (e) {
      debugPrint('[OIDC] Error during login: $e');
      _cleanup();
      return null;
    }
  }

  /// Build a Cookie header string from stored cookies.
  String get _cookieHeader => _rawCookies.join('; ');

  /// Handle the callback URI returned from the Custom Tab.
  /// Returns the user login response (same as /login) or null on failure.
  Future<Map<String, dynamic>?> handleCallback(Uri uri) async {
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];

    debugPrint('[OIDC] Callback received: code=${code != null ? '***' : 'null'}, state=$state');

    if (code == null || code.isEmpty) {
      debugPrint('[OIDC] No code in callback');
      return null;
    }

    // Verify state matches
    if (state != _state) {
      debugPrint('[OIDC] State mismatch: expected=$_state, got=$state');
      return null;
    }

    if (_serverUrl == null || _codeVerifier == null) {
      debugPrint('[OIDC] Missing server URL or code verifier');
      return null;
    }

    // Call /auth/openid/callback with state + code + code_verifier
    final callbackUrl = '$_serverUrl/auth/openid/callback'
        '?state=${Uri.encodeComponent(_state!)}'
        '&code=${Uri.encodeComponent(code)}'
        '&code_verifier=${Uri.encodeComponent(_codeVerifier!)}';

    debugPrint('[OIDC] Calling callback: $callbackUrl');
    debugPrint('[OIDC] Sending ${_rawCookies.length} cookies');

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);

      try {
        final request = await client.getUrl(Uri.parse(callbackUrl));
        request.followRedirects = false;
        request.headers.set('x-return-tokens', 'true');

        if (_rawCookies.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, _cookieHeader);
        }

        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();

        debugPrint('[OIDC] Callback response: ${response.statusCode}');
        debugPrint('[OIDC] Callback body length: ${body.length}');

        if (response.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          _cleanup();
          return data;
        } else {
          debugPrint('[OIDC] Callback error: $body');
          return null;
        }
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[OIDC] Callback exception: $e');
      return null;
    }
  }

  /// Clean up after flow completes or is cancelled.
  void _cleanup() {
    _codeVerifier = null;
    _codeChallenge = null;
    _state = null;
    _rawCookies = [];
  }

  /// Cancel any in-progress flow.
  void cancel() => _cleanup();

  /// Fetch server status to check if OIDC is available.
  static Future<Map<String, dynamic>?> getServerAuthConfig(String serverUrl) async {
    final url = serverUrl.endsWith('/') ? '${serverUrl}status' : '$serverUrl/status';
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[OIDC] Failed to fetch server status: $e');
    }
    return null;
  }

  /// Check if a server has OIDC enabled.
  static Future<OidcConfig?> checkOidcEnabled(String serverUrl) async {
    final status = await getServerAuthConfig(serverUrl);
    if (status == null) return null;

    final authMethods = status['authMethods'] as List<dynamic>? ?? [];
    final hasOidc = authMethods.contains('openid');
    final authFormData = status['authFormData'] as Map<String, dynamic>? ?? {};
    final buttonText = authFormData['openIDButtonText'] as String? ?? 'Login with OpenID';

    return OidcConfig(
      enabled: hasOidc,
      buttonText: buttonText,
      hasLocalAuth: authMethods.contains('local'),
    );
  }
}

/// Configuration about what auth methods a server supports.
class OidcConfig {
  final bool enabled;
  final String buttonText;
  final bool hasLocalAuth;

  const OidcConfig({
    required this.enabled,
    required this.buttonText,
    required this.hasLocalAuth,
  });
}
