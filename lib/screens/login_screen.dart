import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';

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

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    );
    _slideAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOutCubic),
    );
    _animController.forward();
    _serverController.addListener(_onServerChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _animController.dispose();
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
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
      if (_serverController.text.trim() != text) return; // stale

      setState(() {
        _serverChecking = false;
        _serverValid = ok;
        _serverError = ok ? null : 'Could not reach server';
      });

      if (ok) {
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated logo
                FadeTransition(
                  opacity: _fadeAnim,
                  child: Column(
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Icon(
                          Icons.waves_rounded,
                          size: 44,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'A B S O R B',
                        style: tt.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w300,
                          color: cs.primary,
                          letterSpacing: 8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Connect to your server',
                        style: tt.bodyLarge?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 36),

                // Slide-in form
                SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.15),
                    end: Offset.zero,
                  ).animate(_slideAnim),
                  child: FadeTransition(
                    opacity: _slideAnim,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          // Server URL with protocol dropdown
                          TextFormField(
                            controller: _serverController,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            onFieldSubmitted: (_) {
                              if (!_serverValid && !_serverChecking) _checkServer();
                            },
                            decoration: InputDecoration(
                              labelText: 'Server address',
                              hintText: 'abs.example.com',
                              prefixIcon: Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _protocol,
                                    isDense: true,
                                    style: TextStyle(
                                      color: cs.primary,
                                      fontSize: 14,
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
                                        width: 20, height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    )
                                  : _serverValid
                                      ? Icon(Icons.check_circle_rounded,
                                          color: Colors.green.shade400)
                                      : _serverError != null
                                          ? Icon(Icons.error_outline_rounded,
                                              color: cs.error)
                                          : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              enabledBorder: _serverValid
                                  ? OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      borderSide: BorderSide(
                                        color: Colors.green.shade400.withOpacity(0.5),
                                      ),
                                    )
                                  : _serverError != null
                                      ? OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(16),
                                          borderSide: BorderSide(
                                            color: cs.error.withOpacity(0.5),
                                          ),
                                        )
                                      : null,
                              filled: true,
                              fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
                              errorText: _serverError,
                            ),
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
              ],
            ),
          ),
        ),
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
                color: cs.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.error.withOpacity(0.3)),
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
        TextFormField(
          controller: _usernameController,
          focusNode: _usernameFocus,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Username',
            prefixIcon: const Icon(Icons.person_outline_rounded),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            filled: true,
            fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
          ),
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Please enter your username';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),

        // Password
        TextFormField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _handleLogin(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () {
                setState(() => _obscurePassword = !_obscurePassword);
              },
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            filled: true,
            fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) {
              return 'Please enter your password';
            }
            return null;
          },
        ),
        const SizedBox(height: 28),

        // Sign In button
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton(
            onPressed: _isConnecting ? null : _handleLogin,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _isConnecting
                  ? SizedBox(
                      key: const ValueKey('loading'),
                      width: 24,
                      height: 24,
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
      ],
    );
  }
}
