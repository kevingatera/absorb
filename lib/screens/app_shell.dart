import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import 'absorbing_screen.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'stats_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Navigate to the Absorbing tab using BuildContext (ancestor lookup).
  static void goToAbsorbing(BuildContext context) {
    final state = context.findAncestorStateOfType<_AppShellState>();
    state?._switchToAbsorbing();
  }

  /// Navigate to the Absorbing tab without needing a context.
  static void goToAbsorbingGlobal() {
    _AppShellState._instance?._switchToAbsorbing();
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static _AppShellState? _instance;

  // Tabs: 0=Library, 1=Search, 2=Absorbing (default), 3=Stats, 4=Settings
  int _currentIndex = 2;
  final _searchKey = GlobalKey<SearchScreenState>();

  void _switchToAbsorbing() {
    if (mounted) setState(() => _currentIndex = 2);
  }

  late final _pages = [
    const HomeScreen(),
    SearchScreen(key: _searchKey),
    const AbsorbingScreen(),
    const StatsScreen(),
    const SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _instance = this;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshData();
    } else if (state == AppLifecycleState.detached) {
      _stopAndSync();
    }
  }

  Future<void> _stopAndSync() async {
    final player = AudioPlayerService();
    if (player.hasBook) {
      debugPrint('[AppShell] App detached — stopping playback and syncing');
      await player.pause();
      await player.stop();
    }
  }

  DateTime? _lastRefresh;
  static const _refreshCooldown = Duration(minutes: 5);

  void _refreshData() {
    final now = DateTime.now();
    final lib = context.read<LibraryProvider>();
    
    // Always sync local progress (cheap, no network)
    lib.refreshLocalProgress();
    
    // Only do a full server refresh if enough time has passed
    if (_lastRefresh == null || now.difference(_lastRefresh!) > _refreshCooldown) {
      _lastRefresh = now;
      lib.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (i) {
              setState(() => _currentIndex = i);
              // Refresh data on switching to Library, Absorbing, or Stats (not Search/Settings)
              if (i == 0 || i == 2 || i == 3) _refreshData();
              if (i == 1) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _searchKey.currentState?.requestSearchFocus();
                });
              }
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_books_outlined),
                selectedIcon: Icon(Icons.library_books_rounded),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_rounded),
                selectedIcon: Icon(Icons.search_rounded),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.waves_outlined),
                selectedIcon: Icon(Icons.waves_rounded),
                label: 'Absorbing',
              ),
              NavigationDestination(
                icon: Icon(Icons.bar_chart_rounded),
                selectedIcon: Icon(Icons.bar_chart_rounded),
                label: 'Stats',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
