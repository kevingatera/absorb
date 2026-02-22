import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'providers/auth_provider.dart';
import 'providers/library_provider.dart';
import 'services/audio_player_service.dart';
import 'services/api_service.dart';
import 'services/download_service.dart';
import 'services/download_notification_service.dart';
import 'services/progress_sync_service.dart';
import 'services/equalizer_service.dart';
import 'services/sleep_timer_service.dart';
import 'services/user_account_service.dart';
import 'services/android_auto_service.dart';
import 'screens/login_screen.dart';
import 'screens/app_shell.dart';
import 'widgets/absorb_wave_icon.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait — no landscape support
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Dark status bar to match Absorb theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Load device info for server identification
  await ApiService.initDeviceId();
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    ApiService.deviceManufacturer = info.manufacturer;
    ApiService.deviceModel = info.model;
  } catch (_) {}

  // Initialize download notification service
  await DownloadNotificationService().init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProxyProvider<AuthProvider, LibraryProvider>(
          create: (_) => LibraryProvider(),
          update: (_, auth, lib) => lib!..updateAuth(auth),
        ),
      ],
      child: const AbsorbApp(),
    ),
  );
}

class AbsorbApp extends StatelessWidget {
  const AbsorbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        // Absorb is dark-first — use dynamic dark colors or our custom palette
        ColorScheme darkScheme;
        if (darkDynamic != null) {
          darkScheme = darkDynamic.harmonized();
        } else {
          darkScheme = ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C6FBF), // deep muted purple
            brightness: Brightness.dark,
          );
        }

        // Light scheme for users who prefer it
        ColorScheme lightScheme;
        if (lightDynamic != null) {
          lightScheme = lightDynamic.harmonized();
        } else {
          lightScheme = ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C6FBF),
            brightness: Brightness.light,
          );
        }

        // Smooth page transition theme
        const pageTransition = PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        );

        return MaterialApp(
          title: 'Absorb',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark, // Absorb: dark by default
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: lightScheme,
            pageTransitionsTheme: pageTransition,
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: darkScheme,
            scaffoldBackgroundColor: const Color(0xFF0E0E0E),
            cardTheme: CardThemeData(
              color: darkScheme.surfaceContainerHigh,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: const Color(0xFF0E0E0E),
              indicatorColor: darkScheme.primary.withValues(alpha: 0.15),
              labelTextStyle: WidgetStatePropertyAll(
                TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: darkScheme.onSurfaceVariant,
                ),
              ),
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: const Color(0xFF0E0E0E),
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
            ),
            searchBarTheme: SearchBarThemeData(
              backgroundColor: WidgetStatePropertyAll(
                darkScheme.surfaceContainerHigh,
              ),
              elevation: const WidgetStatePropertyAll(0),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            bottomSheetTheme: const BottomSheetThemeData(
              backgroundColor: Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: darkScheme.surfaceContainerHighest,
              contentTextStyle: TextStyle(color: darkScheme.onSurface),
              actionTextColor: darkScheme.primary,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            pageTransitionsTheme: pageTransition,
          ),
          home: const AuthGate(),
        );
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    try {
      await Permission.notification.request();
    } catch (e) {
      debugPrint('Permission request failed: $e');
    }

    try {
      await AudioPlayerService.init();
    } catch (e) {
      debugPrint('AudioService init failed: $e');
    }

    // Initialize download tracker and progress sync
    try {
      await UserAccountService().init();
      await DownloadService().init();
      await ProgressSyncService().init();
      await EqualizerService().init();
      await SleepTimerService().loadAutoSleepSettings();
      // Pre-populate Android Auto browse tree
      AndroidAutoService().refresh();
    } catch (e) {
      debugPrint('Service init failed: $e');
    }

    if (mounted) {
      context.read<AuthProvider>().tryRestoreSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbsorbWaveIcon(
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                'A B S O R B',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: 6,
                      fontWeight: FontWeight.w300,
                    ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color:
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (auth.isAuthenticated) {
      return const AppShell();
    }

    return const LoginScreen();
  }
}
