import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:app_links/app_links.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/oidc_service.dart';
import '../widgets/absorb_wave_icon.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocus = FocusNode();

  bool _obscurePassword = true;
  bool _isConnecting = false;
  String _protocol = 'https://';

  // Server validation state
  bool _serverValid = false;
  bool _serverChecking = false;
  String? _serverError;
  Timer? _debounce;

  // Login error
  String? _loginError;

  // OIDC state
  OidcConfig? _oidcConfig;
  bool _isOidcLoading = false;
  StreamSubscription? _linkSub;

  // App version
  String _appVersion = '';

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
    );
    _slideAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.3, 1.0, curve: Curves.easeOutCubic),
    );
    _animController.forward();
    _serverController.addListener(_onServerChanged);
    _loadVersion();
    _initDeepLinkListener();
  }

  /// Listen for deep links (audiobookshelf://oauth callback).
  void _initDeepLinkListener() {
    final appLinks = AppLinks();
    _linkSub = appLinks.uriLinkStream.listen((uri) {
      debugPrint('[Login] Deep link received: $uri');
      if (uri.scheme == 'audiobookshelf' && uri.host == 'oauth') {
        _handleOidcCallback(uri);
      }
    });
  }

  /// Handle the OIDC callback URI from deep link.
  Future<void> _handleOidcCallback(Uri uri) async {
    final oidc = OidcService();
    if (!oidc.isWaitingForCallback) {
      debugPrint('[Login] No OIDC flow in progress, ignoring callback');
      return;
    }

    setState(() {
      _isOidcLoading = true;
      _loginError = null;
    });

    final result = await oidc.handleCallback(uri);
    if (result != null && mounted) {
      final serverText = _serverController.text.trim();
      final cleanUrl = serverText.replaceAll(RegExp(r'^https?://'), '');
      final fullUrl = '$_protocol$cleanUrl';

      final auth = context.read<AuthProvider>();
      final success = await auth.loginWithOidc(
        serverUrl: fullUrl,
        result: result,
      );

      if (mounted) {
        setState(() => _isOidcLoading = false);
        if (!success) {
          setState(() => _loginError = auth.errorMessage ?? 'SSO login failed');
        }
      }
    } else if (mounted) {
      setState(() {
        _isOidcLoading = false;
        _loginError = 'SSO authentication failed. Please try again.';
      });
    }
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = 'v${info.version}');
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _linkSub?.cancel();
    _animController.dispose();
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    OidcService().cancel();
    super.dispose();
  }

  void _onServerChanged() {
    final text = _serverController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _serverValid = false;
        _serverChecking = false;
        _serverError = null;
      });
      _debounce?.cancel();
      return;
    }

    setState(() {
      _serverValid = false;
      _serverChecking = true;
      _serverError = null;
    });

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () => _checkServer());
  }

  Future<void> _checkServer() async {
    final text = _serverController.text.trim();
    if (text.isEmpty) return;

    final cleanUrl = text.replaceAll(RegExp(r'^https?://'), '');
    final fullUrl = '$_protocol$cleanUrl';

    try {
      final ok = await ApiService.pingServer(fullUrl);
      if (!mounted) return;
      if (_serverController.text.trim() != text) return;

      setState(() {
        _serverChecking = false;
        _serverValid = ok;
        _serverError = ok ? null : 'Could not reach server';
        if (!ok) _oidcConfig = null;
      });

      if (ok) {
        // Also check if OIDC is available
        OidcService.checkOidcEnabled(fullUrl).then((config) {
          if (mounted && _serverController.text.trim() == text) {
            setState(() => _oidcConfig = config);
          }
        });

        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) _usernameFocus.requestFocus();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverChecking = false;
        _serverValid = false;
        _serverError = 'Could not reach server';
        _oidcConfig = null;
      });
    }
  }

  Future<void> _handleLogin() async {
    if (!_serverValid) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isConnecting = true;
      _loginError = null;
    });

    final auth = context.read<AuthProvider>();
    final serverText = _serverController.text.trim();
    final cleanUrl = serverText.replaceAll(RegExp(r'^https?://'), '');
    final fullUrl = '$_protocol$cleanUrl';
    final success = await auth.login(
      serverUrl: fullUrl,
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );

    if (mounted) {
      setState(() => _isConnecting = false);

      if (!success) {
        setState(() {
          _loginError = auth.errorMessage ?? 'Login failed';
        });
      }
    }
  }

  Future<void> _handleOidcLogin() async {
    if (!_serverValid) return;

    setState(() {
      _isOidcLoading = true;
      _loginError = null;
    });

    final serverText = _serverController.text.trim();
    final cleanUrl = serverText.replaceAll(RegExp(r'^https?://'), '');
    final fullUrl = '$_protocol$cleanUrl';

    final error = await OidcService().startLogin(fullUrl);
    if (error != null && mounted) {
      setState(() {
        _isOidcLoading = false;
        _loginError = error;
      });
    }
    // If no error, we're waiting for the deep link callback.
    // _isOidcLoading stays true until callback arrives.
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0.0, 0.4, 0.7, 1.0],
            colors: [
              cs.primary.withValues(alpha: 0.15),
              cs.primary.withValues(alpha: 0.05),
              cs.surface,
              cs.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Logo + Tagline ──
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: Column(
                      children: [
                        // Wave icon with glow
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: cs.primary.withValues(alpha: 0.3),
                                blurRadius: 40,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.primary.withValues(alpha: 0.1),
                              border: Border.all(
                                color: cs.primary.withValues(alpha: 0.15),
                                width: 1.5,
                              ),
                            ),
                            child: Center(
                              child: AbsorbWaveIcon(
                                size: 44,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          'A B S O R B',
                          style: tt.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w200,
                            color: cs.onSurface,
                            letterSpacing: 10,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Start Absorbing',
                          style: tt.bodyLarge?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),

                  // ── Glass form card ──
                  SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.12),
                      end: Offset.zero,
                    ).animate(_slideAnim),
                    child: FadeTransition(
                      opacity: _slideAnim,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: cs.outlineVariant.withValues(alpha: 0.15),
                              ),
                            ),
                            child: Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Section label
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4, bottom: 16),
                                    child: Text(
                                      'Connect to your server',
                                      style: tt.titleSmall?.copyWith(
                                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),

                                  // Server URL
                                  _buildInputField(
                                    controller: _serverController,
                                    label: 'Server address',
                                    hint: 'abs.example.com',
                                    keyboardType: TextInputType.url,
                                    textInputAction: TextInputAction.next,
                                    onFieldSubmitted: (_) {
                                      if (!_serverValid && !_serverChecking) _checkServer();
                                    },
                                    cs: cs,
                                    prefixIcon: Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: _protocol,
                                          isDense: true,
                                          style: TextStyle(
                                            color: cs.primary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          items: const [
                                            DropdownMenuItem(
                                              value: 'https://',
                                              child: Text('https://'),
                                            ),
                                            DropdownMenuItem(
                                              value: 'http://',
                                              child: Text('http://'),
                                            ),
                                          ],
                                          onChanged: (v) {
                                            if (v != null) {
                                              setState(() {
                                                _protocol = v;
                                                _serverValid = false;
                                              });
                                              _onServerChanged();
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                    suffixIcon: _serverChecking
                                        ? const Padding(
                                            padding: EdgeInsets.all(14),
                                            child: SizedBox(
                                              width: 18, height: 18,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            ),
                                          )
                                        : _serverValid
                                            ? Icon(Icons.check_circle_rounded,
                                                color: Colors.green.shade400, size: 22)
                                            : _serverError != null
                                                ? Icon(Icons.error_outline_rounded,
                                                    color: cs.error, size: 22)
                                                : null,
                                    borderColor: _serverValid
                                        ? Colors.green.shade400.withValues(alpha: 0.4)
                                        : _serverError != null
                                            ? cs.error.withValues(alpha: 0.4)
                                            : null,
                                    errorText: _serverError,
                                  ),

                                  // Credentials — animated in when server is valid
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 350),
                                    curve: Curves.easeOutCubic,
                                    alignment: Alignment.topCenter,
                                    child: _serverValid
                                        ? _buildCredentialFields(cs, tt)
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── Version label ──
                  const SizedBox(height: 32),
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: Text(
                      _appVersion,
                      style: tt.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required ColorScheme cs,
    String? hint,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    FocusNode? focusNode,
    Widget? prefixIcon,
    Widget? suffixIcon,
    Color? borderColor,
    String? errorText,
    bool obscureText = false,
    void Function(String)? onFieldSubmitted,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      style: TextStyle(color: cs.onSurface),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        errorText: errorText,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: borderColor ?? cs.outlineVariant.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.6), width: 1.5),
        ),
        filled: true,
        fillColor: cs.surface.withValues(alpha: 0.4),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _buildCredentialFields(ColorScheme cs, TextTheme tt) {
    return Column(
      children: [
        const SizedBox(height: 16),

        // Login error message
        if (_loginError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.error.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _loginError!,
                      style: tt.bodySmall?.copyWith(color: cs.error),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Username
        _buildInputField(
          controller: _usernameController,
          focusNode: _usernameFocus,
          label: 'Username',
          cs: cs,
          textInputAction: TextInputAction.next,
          prefixIcon: Icon(Icons.person_outline_rounded, size: 20,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Please enter your username';
            }
            return null;
          },
        ),
        const SizedBox(height: 14),

        // Password
        _buildInputField(
          controller: _passwordController,
          label: 'Password',
          cs: cs,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _handleLogin(),
          prefixIcon: Icon(Icons.lock_outline_rounded, size: 20,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            onPressed: () {
              setState(() => _obscurePassword = !_obscurePassword);
            },
          ),
          validator: (v) {
            if (v == null || v.isEmpty) {
              return 'Please enter your password';
            }
            return null;
          },
        ),
        const SizedBox(height: 24),

        // Sign In button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: _isConnecting || _isOidcLoading ? null : _handleLogin,
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _isConnecting
                  ? SizedBox(
                      key: const ValueKey('loading'),
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: cs.onPrimary,
                      ),
                    )
                  : Text(
                      'Sign In',
                      key: const ValueKey('text'),
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimary,
                      ),
                    ),
            ),
          ),
        ),

        // SSO / OIDC button
        if (_oidcConfig != null && _oidcConfig!.enabled) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Divider(color: cs.outlineVariant.withValues(alpha: 0.2))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text('or', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.5))),
              ),
              Expanded(child: Divider(color: cs.outlineVariant.withValues(alpha: 0.2))),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _isConnecting || _isOidcLoading ? null : _handleOidcLogin,
              icon: _isOidcLoading
                  ? SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                    )
                  : Icon(Icons.login_rounded, size: 20, color: cs.primary),
              label: Text(
                _isOidcLoading ? 'Waiting for SSO...' : _oidcConfig!.buttonText,
                style: tt.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: cs.primary.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
