import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../widgets/absorb_title.dart';
import '../widgets/absorb_slider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AutoRewindSettings _rewindSettings = const AutoRewindSettings();
  double _defaultSpeed = 1.0;
  bool _wifiOnlyDownloads = false;
  bool _showBookSlider = false;
  bool _speedAdjustedTime = true;
  int _forwardSkip = 30;
  int _backSkip = 10;
  bool _shakeToResetSleep = true;
  int _shakeAddMinutes = 5;
  bool _autoContinueSeries = true;
  bool _loaded = false;
  String _downloadLocationLabel = 'App Internal Storage (Default)';
  int _totalDownloadSizeBytes = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await AutoRewindSettings.load();
    final speed = await PlayerSettings.getDefaultSpeed();
    final wifiOnly = await PlayerSettings.getWifiOnlyDownloads();
    final bookSlider = await PlayerSettings.getShowBookSlider();
    final speedAdj = await PlayerSettings.getSpeedAdjustedTime();
    final fwd = await PlayerSettings.getForwardSkip();
    final bk = await PlayerSettings.getBackSkip();
    final shake = await PlayerSettings.getShakeToResetSleep();
    final shakeMins = await PlayerSettings.getShakeAddMinutes();
    final autoSeries = await PlayerSettings.getAutoContinueSeries();
    final dlLabel = await DownloadService().downloadLocationLabel;
    final dlSize = await DownloadService().totalDownloadSize;
    if (mounted) setState(() {
      _rewindSettings = s;
      _defaultSpeed = speed;
      _wifiOnlyDownloads = wifiOnly;
      _showBookSlider = bookSlider;
      _speedAdjustedTime = speedAdj;
      _forwardSkip = fwd;
      _backSkip = bk;
      _shakeToResetSleep = shake;
      _shakeAddMinutes = shakeMins;
      _autoContinueSeries = autoSeries;
      _downloadLocationLabel = dlLabel;
      _totalDownloadSizeBytes = dlSize;
      _loaded = true;
    });
  }

  Future<void> _saveRewind(AutoRewindSettings s) async {
    setState(() => _rewindSettings = s);
    await s.save();
  }

  void _showTips(BuildContext context, ColorScheme cs, TextTheme tt) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.75, maxChildSize: 0.95,
        builder: (_, sc) => Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: sc,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Center(child: Container(
                width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: cs.onSurfaceVariant.withOpacity(0.3), borderRadius: BorderRadius.circular(2)),
              )),
              Row(children: [
                Icon(Icons.auto_awesome_rounded, color: cs.primary, size: 24),
                const SizedBox(width: 10),
                Text('Tips & Hidden Features', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 20),
              _tipCard(cs, tt,
                icon: Icons.airplanemode_active_rounded,
                title: 'Offline Mode',
                desc: 'Tap the airplane button on the Absorbing screen to enter offline mode. This stops syncing, saves data, and only shows your downloaded books. Great for flights or low signal areas.',
              ),
              _tipCard(cs, tt,
                icon: Icons.stop_rounded,
                title: 'Stop & Sync',
                desc: 'The "Stop & Sync" button in the Absorbing header fully stops playback and syncs your progress to the server. Use it when you\'re done listening for the day.',
              ),
              _tipCard(cs, tt,
                icon: Icons.bookmark_added_rounded,
                title: 'Quick Bookmarks',
                desc: 'Long-press the bookmark button on any card to instantly drop a bookmark at your current position without opening the bookmark sheet.',
              ),
              _tipCard(cs, tt,
                icon: Icons.history_rounded,
                title: 'Playback History',
                desc: 'Tap the History button on any card to see a timeline of every play, pause, seek, and speed change. Tap any event to jump back to that position.',
              ),
              _tipCard(cs, tt,
                icon: Icons.speed_rounded,
                title: 'Speed-Adjusted Time',
                desc: 'Time remaining and chapter times automatically adjust based on your playback speed. Listening at 1.5x? The time shown reflects how long it\'ll actually take you.',
              ),
              _tipCard(cs, tt,
                icon: Icons.auto_stories_rounded,
                title: 'Series Navigation',
                desc: 'Tap the series name in any book\'s detail popup to see all books in the series, sorted in reading order with sequence badges on each cover.',
              ),
              _tipCard(cs, tt,
                icon: Icons.vibration_rounded,
                title: 'Shake to Extend Sleep',
                desc: 'If you have a sleep timer running and shake your phone, it\'ll add extra minutes. Configure the amount in Settings under Sleep Timer.',
              ),
              _tipCard(cs, tt,
                icon: Icons.swipe_rounded,
                title: 'Swipe Between Books',
                desc: 'On the Absorbing screen, swipe left and right to switch between your in-progress books. The dots at the top show which book you\'re viewing.',
              ),
              _tipCard(cs, tt,
                icon: Icons.touch_app_rounded,
                title: 'Tap to Seek',
                desc: 'Tap anywhere on the chapter or book progress bar to jump directly to that position. You can also drag the bars for fine-grained control.',
              ),
              _tipCard(cs, tt,
                icon: Icons.replay_rounded,
                title: 'Auto-Rewind',
                desc: 'When you resume after a pause, Absorb automatically rewinds a few seconds so you don\'t lose your place. The rewind amount scales with how long you were away. Configure it in Settings.',
              ),
              _tipCard(cs, tt,
                icon: Icons.skip_next_rounded,
                title: 'Auto-Continue Series',
                desc: 'When you finish a book that\'s part of a series, Absorb can automatically queue up the next book. Enable this in Settings under Playback.',
              ),
              _tipCard(cs, tt,
                icon: Icons.download_rounded,
                title: 'Download for Offline',
                desc: 'Tap the download button in any book\'s detail popup to save it for offline listening. Downloaded books are available in offline mode without any internet connection.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tipCard(ColorScheme cs, TextTheme tt, {required IconData icon, required String title, required String desc}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(desc, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.4)),
              ],
            )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final auth = context.watch<AuthProvider>();
    final lib = context.watch<LibraryProvider>();

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0.0, 0.4, 0.7, 1.0],
            colors: [
              cs.primary.withOpacity(0.12),
              cs.primary.withOpacity(0.04),
              cs.surface,
              cs.surface,
            ],
          ),
        ),
        child: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const AbsorbTitle(),
                const SizedBox(height: 8),
                Text('Settings',
                  style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 8),

                // ── Tips & Tricks ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: GestureDetector(
                    onTap: () => _showTips(context, cs, tt),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [cs.primaryContainer, cs.tertiaryContainer],
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome_rounded, color: cs.onPrimaryContainer, size: 22),
                          const SizedBox(width: 12),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Tips & Hidden Features', style: tt.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600, color: cs.onPrimaryContainer)),
                              const SizedBox(height: 2),
                              Text('Get the most out of Absorb', style: tt.bodySmall?.copyWith(
                                color: cs.onPrimaryContainer.withOpacity(0.7))),
                            ],
                          )),
                          Icon(Icons.chevron_right_rounded, color: cs.onPrimaryContainer.withOpacity(0.5)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // ── Account ──
                Card(
                  elevation: 0,
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  color: cs.surfaceContainerHigh,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: cs.primaryContainer,
                      child: Icon(Icons.person_rounded, color: cs.onPrimaryContainer),
                    ),
                    title: Text(auth.username ?? 'User'),
                    subtitle: Text(auth.serverUrl ?? '',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(height: 16),


                // ── Playback ──
                _CollapsibleSection(
                  icon: Icons.play_circle_outline_rounded,
                  title: 'Playback',
                  cs: cs,
                  children: [
                    // Default speed
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Default speed', style: tt.bodyMedium),
                          Text('${_defaultSpeed.toStringAsFixed(2)}x',
                            style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700, color: cs.primary)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: Text('New books start at this speed — each book remembers its own',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
                    ),
                    AbsorbSlider(
                      value: _defaultSpeed,
                      min: 0.5,
                      max: 3.0,
                      divisions: 25,
                      onChanged: _loaded ? (v) {
                        setState(() => _defaultSpeed = double.parse(v.toStringAsFixed(2)));
                        PlayerSettings.setDefaultSpeed(double.parse(v.toStringAsFixed(2)));
                      } : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Wrap(
                        spacing: 6, runSpacing: 4,
                        children: [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0].map((s) {
                          final isActive = (_defaultSpeed - s).abs() < 0.01;
                          return ActionChip(
                            label: Text('${s}x',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                                color: isActive ? cs.onPrimary : cs.onSurface,
                              )),
                            backgroundColor: isActive ? cs.primary : cs.surfaceContainerHighest,
                            side: BorderSide.none,
                            onPressed: () {
                              setState(() => _defaultSpeed = s);
                              PlayerSettings.setDefaultSpeed(s);
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    // Skip amounts
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Skip back', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                          Text('${_backSkip}s', style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600, color: cs.primary)),
                        ],
                      ),
                    ),
                    AbsorbSlider(
                      value: _backSkip.toDouble(),
                      min: 5, max: 60, divisions: 11,
                      onChanged: _loaded ? (v) {
                        setState(() => _backSkip = v.round());
                        PlayerSettings.setBackSkip(v.round());
                      } : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Skip forward', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                          Text('${_forwardSkip}s', style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600, color: cs.primary)),
                        ],
                      ),
                    ),
                    AbsorbSlider(
                      value: _forwardSkip.toDouble(),
                      min: 5, max: 60, divisions: 11,
                      onChanged: _loaded ? (v) {
                        setState(() => _forwardSkip = v.round());
                        PlayerSettings.setForwardSkip(v.round());
                      } : null,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    // Toggles
                    SwitchListTile(
                      title: const Text('Full book scrubber'),
                      subtitle: Text(
                        _showBookSlider ? 'On — seekable slider across entire book' : 'Off — progress bar only',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      value: _showBookSlider,
                      onChanged: _loaded ? (v) {
                        setState(() => _showBookSlider = v);
                        PlayerSettings.setShowBookSlider(v);
                      } : null,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      title: const Text('Speed-adjusted time'),
                      subtitle: Text(
                        _speedAdjustedTime ? 'On — remaining time reflects playback speed' : 'Off — showing raw audio duration',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      value: _speedAdjustedTime,
                      onChanged: _loaded ? (v) {
                        setState(() => _speedAdjustedTime = v);
                        PlayerSettings.setSpeedAdjustedTime(v);
                      } : null,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      title: const Text('Auto-absorb next in series'),
                      subtitle: Text(
                        _autoContinueSeries ? 'On — next book in series added to Absorbing' : 'Off',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      value: _autoContinueSeries,
                      onChanged: _loaded ? (v) {
                        setState(() => _autoContinueSeries = v);
                        PlayerSettings.setAutoContinueSeries(v);
                      } : null,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    // ── Auto-Rewind ──
                    SwitchListTile(
                      title: const Text('Auto-rewind on resume'),
                      subtitle: Text(
                        _rewindSettings.enabled
                            ? 'On — ${_rewindSettings.minRewind.round()}s to ${_rewindSettings.maxRewind.round()}s based on pause length'
                            : 'Off',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      value: _rewindSettings.enabled,
                      onChanged: _loaded ? (v) => _saveRewind(
                        AutoRewindSettings(
                          enabled: v,
                          minRewind: _rewindSettings.minRewind,
                          maxRewind: _rewindSettings.maxRewind,
                          activationDelay: _rewindSettings.activationDelay,
                        ),
                      ) : null,
                    ),
                    if (_rewindSettings.enabled) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Rewind range', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                            Text('${_rewindSettings.minRewind.round()}s – ${_rewindSettings.maxRewind.round()}s',
                              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.primary)),
                          ],
                        ),
                      ),
                      AbsorbRangeSlider(
                        values: RangeValues(_rewindSettings.minRewind, _rewindSettings.maxRewind),
                        min: 0, max: 60, divisions: 60,
                        onChanged: (v) => _saveRewind(AutoRewindSettings(
                          enabled: true, minRewind: v.start, maxRewind: v.end,
                          activationDelay: _rewindSettings.activationDelay,
                        )),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text('Rewind after paused for',
                              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                            Text(_rewindSettings.activationDelay == 0 ? 'Any pause' : '${_rewindSettings.activationDelay.round()}s+',
                              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.primary)),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Slider(
                          value: _rewindSettings.activationDelay, min: 0, max: 10, divisions: 10,
                          label: _rewindSettings.activationDelay == 0 ? 'Always' : '${_rewindSettings.activationDelay.round()}s',
                          onChanged: (v) => _saveRewind(AutoRewindSettings(
                            enabled: true, minRewind: _rewindSettings.minRewind,
                            maxRewind: _rewindSettings.maxRewind, activationDelay: v,
                          )),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Text(
                          _rewindSettings.activationDelay == 0
                            ? 'Rewinds every time you resume, even after quick interruptions'
                            : 'Only rewinds if paused for ${_rewindSettings.activationDelay.round()}+ seconds',
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Preview', style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                              const SizedBox(height: 4),
                              ..._buildRewindPreviews(cs, tt),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),

                // ── Sleep Timer ──
                _CollapsibleSection(
                  icon: Icons.bedtime_outlined,
                  title: 'Sleep Timer',
                  cs: cs,
                  children: [
                    SwitchListTile(
                      title: const Text('Shake to add time'),
                      subtitle: Text(
                        _shakeToResetSleep ? 'On — adds $_shakeAddMinutes min per shake' : 'Off',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      value: _shakeToResetSleep,
                      onChanged: _loaded ? (v) {
                        setState(() => _shakeToResetSleep = v);
                        PlayerSettings.setShakeToResetSleep(v);
                      } : null,
                    ),
                    if (_shakeToResetSleep) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Shake adds', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                            Text('$_shakeAddMinutes min',
                              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.primary)),
                          ],
                        ),
                      ),
                      AbsorbSlider(
                        value: _shakeAddMinutes.toDouble(),
                        min: 1, max: 30, divisions: 29,
                        onChanged: _loaded ? (v) {
                          setState(() => _shakeAddMinutes = v.round());
                          PlayerSettings.setShakeAddMinutes(v.round());
                        } : null,
                      ),
                      const SizedBox(height: 4),
                    ],
                  ],
                ),
                const SizedBox(height: 8),

                // ── Downloads & Storage ──
                _CollapsibleSection(
                  icon: Icons.download_outlined,
                  title: 'Downloads & Storage',
                  cs: cs,
                  children: [
                    SwitchListTile(
                      title: const Text('Download over Wi-Fi only'),
                      subtitle: Text(
                        _wifiOnlyDownloads ? 'On — mobile data blocked for downloads' : 'Off — downloads on any connection',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      value: _wifiOnlyDownloads,
                      onChanged: _loaded ? (v) {
                        setState(() => _wifiOnlyDownloads = v);
                        PlayerSettings.setWifiOnlyDownloads(v);
                      } : null,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(Icons.folder_outlined, color: cs.primary),
                      title: const Text('Download location'),
                      subtitle: Text(
                        _downloadLocationLabel,
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickDownloadLocation(context, cs, tt),
                    ),
                    if (_totalDownloadSizeBytes > 0) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        leading: Icon(Icons.data_usage_rounded, color: cs.onSurfaceVariant),
                        title: const Text('Storage used'),
                        subtitle: Text(
                          _formatBytes(_totalDownloadSizeBytes),
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ),
                    ],
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(Icons.storage_rounded, color: cs.primary),
                      title: const Text('Manage downloads'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showDownloadManager(context, cs, tt),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // ── Library ──
                if (lib.libraries.length > 1) ...[
                  _CollapsibleSection(
                    icon: Icons.auto_stories_outlined,
                    title: 'Library',
                    cs: cs,
                    children: lib.libraries.map((library) {
                      final id = library['id'] as String;
                      final name = library['name'] as String? ?? 'Library';
                      final mediaType = library['mediaType'] as String? ?? 'book';
                      final isSelected = id == lib.selectedLibraryId;
                      return ListTile(
                        leading: Icon(
                          mediaType == 'podcast' ? Icons.podcasts_rounded : Icons.auto_stories_rounded,
                          color: isSelected ? cs.primary : cs.onSurfaceVariant),
                        title: Text(name),
                        trailing: isSelected ? Icon(Icons.check_circle_rounded, color: cs.primary) : null,
                        onTap: () { if (!isSelected) lib.selectLibrary(id); },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                ],

                // ── Permissions ──
                _CollapsibleSection(
                  icon: Icons.shield_outlined,
                  title: 'Permissions',
                  cs: cs,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('Notifications'),
                      subtitle: Text('For download progress and playback controls',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                      onTap: () async {
                        final status = await Permission.notification.status;
                        if (status.isGranted) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              duration: const Duration(seconds: 2),
                              content: const Text('Notifications already enabled'),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ));
                          }
                        } else {
                          final result = await Permission.notification.request();
                          if (result.isPermanentlyDenied && mounted) await openAppSettings();
                        }
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.battery_saver_outlined),
                      title: const Text('Unrestricted battery'),
                      subtitle: Text('Prevents Android from killing background playback',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                      onTap: () async {
                        if (Platform.isAndroid) {
                          final status = await Permission.ignoreBatteryOptimizations.status;
                          if (status.isGranted) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                duration: const Duration(seconds: 2),
                                content: const Text('Battery already unrestricted'),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ));
                            }
                          } else {
                            final result = await Permission.ignoreBatteryOptimizations.request();
                            if (result.isPermanentlyDenied && mounted) await openAppSettings();
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // ── About ──
                _CollapsibleSection(
                  icon: Icons.info_outline_rounded,
                  title: 'About',
                  cs: cs,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: const Text('App Version'),
                      trailing: Text('1.2.1', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                    if (auth.serverSettings != null)
                      ListTile(
                        leading: const Icon(Icons.dns_outlined),
                        title: const Text('Server Version'),
                        trailing: Text(
                          (auth.serverSettings!['version'] as String?) ?? '—',
                          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                      ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Sign out ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _confirmLogout(context),
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Peace out'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: cs.error,
                        side: BorderSide(color: cs.error.withOpacity(0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  List<Widget> _buildRewindPreviews(ColorScheme cs, TextTheme tt) {
    final s = _rewindSettings;
    final delay = s.activationDelay.round();
    final rows = <Widget>[];

    final durations = <int, String>{
      3: '3s pause',
      5: '5s pause',
      30: '30s pause',
      120: '2 min pause',
      600: '10 min pause',
      3600: '1 hr pause',
    };

    for (final entry in durations.entries) {
      final rewind = AudioPlayerService.calculateAutoRewind(
        Duration(seconds: entry.key), s.minRewind, s.maxRewind,
        activationDelay: s.activationDelay);
      if (entry.key < delay) {
        rows.add(_rewindPreviewRow(entry.value, -1, cs, tt)); // -1 = "no rewind"
      } else {
        rows.add(_rewindPreviewRow(entry.value, rewind, cs, tt));
      }
    }

    return rows;
  }

  Widget _rewindPreviewRow(
      String label, double rewind, ColorScheme cs, TextTheme tt) {
    final isSkipped = rewind < 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: tt.bodySmall?.copyWith(
            color: isSkipped ? cs.onSurfaceVariant.withOpacity(0.4) : cs.onSurfaceVariant)),
          Text(isSkipped ? '→ no rewind' : '→ ${rewind.toStringAsFixed(1)}s rewind',
            style: tt.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isSkipped ? cs.onSurfaceVariant.withOpacity(0.3) : cs.primary)),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _pickDownloadLocation(BuildContext context, ColorScheme cs, TextTheme tt) async {
    final dl = DownloadService();
    final hasExistingDownloads = dl.downloadedItems.isNotEmpty;

    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text('Download Location',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Choose where audiobooks are saved',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 20),

            // Current location display
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.primary.withOpacity(0.2)),
              ),
              child: Row(children: [
                Icon(Icons.folder_rounded, color: cs.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Current location',
                        style: tt.labelSmall?.copyWith(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(_downloadLocationLabel,
                        style: tt.bodySmall?.copyWith(color: cs.onSurface),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),

            if (hasExistingDownloads)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.error.withOpacity(0.2)),
                  ),
                  child: Row(children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: cs.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Existing downloads stay in their current location. Only new downloads use the new path.',
                        style: tt.bodySmall?.copyWith(
                          color: cs.error.withOpacity(0.8), fontSize: 11),
                      ),
                    ),
                  ]),
                ),
              ),

            // Choose folder button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Choose folder'),
                onPressed: () async {
                  Navigator.pop(ctx);
                  final result = await FilePicker.platform.getDirectoryPath(
                    dialogTitle: 'Choose download folder',
                  );
                  if (result != null) {
                    await dl.setCustomDownloadPath(result);
                    final label = await dl.downloadLocationLabel;
                    if (mounted) {
                      setState(() => _downloadLocationLabel = label);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Download location set to $label'),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      ));
                    }
                  }
                },
              ),
            ),
            const SizedBox(height: 8),

            // Reset to default button
            if (dl.customDownloadPath != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset to default'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await dl.setCustomDownloadPath(null);
                    final label = await dl.downloadLocationLabel;
                    if (mounted) {
                      setState(() => _downloadLocationLabel = label);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Reset to default storage'),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      ));
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showDownloadManager(BuildContext context, ColorScheme cs, TextTheme tt) {
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: DownloadService(),
        builder: (ctx, _) {
          final items = DownloadService().downloadedItems;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                Text('Downloaded Books',
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No downloads',
                      style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  )
                else
                  ...items.map((info) => ListTile(
                    leading: Icon(Icons.headphones_rounded, color: cs.primary),
                    title: Text(info.title ?? 'Unknown',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(info.author ?? '',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    trailing: IconButton(
                      icon: Icon(Icons.delete_outline, color: cs.error),
                      onPressed: () {
                        showDialog(
                          context: ctx,
                          builder: (d) => AlertDialog(
                            title: const Text('Remove download?'),
                            content: Text('Delete "${info.title}" from device?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(d),
                                child: const Text('Cancel')),
                              FilledButton(
                                onPressed: () {
                                  DownloadService().deleteDownload(info.itemId);
                                  Navigator.pop(d);
                                },
                                child: const Text('Remove')),
                            ],
                          ),
                        );
                      },
                    ),
                  )),
              ],
            ),
          );
        },
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.logout_rounded),
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to access your library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<AuthProvider>().logout();
            },
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final ColorScheme cs;
  final List<Widget> children;

  const _CollapsibleSection({
    required this.icon,
    required this.title,
    required this.cs,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon, color: cs.primary, size: 22),
          title: Text(title, style: TextStyle(fontWeight: FontWeight.w600)),
          childrenPadding: EdgeInsets.zero,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          children: children,
        ),
      ),
    );
  }
}
