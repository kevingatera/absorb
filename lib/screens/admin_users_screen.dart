import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/absorb_page_header.dart';

class AdminUsersScreen extends StatefulWidget {
  final List<dynamic> users;
  final List<dynamic> onlineUsers;
  final List<dynamic> libraries;
  const AdminUsersScreen({super.key, required this.users, required this.onlineUsers, required this.libraries});
  @override State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  late List<dynamic> _users;
  late List<dynamic> _onlineUsers;

  @override
  void initState() { super.initState(); _users = List.from(widget.users); _onlineUsers = List.from(widget.onlineUsers); }

  Future<void> _reload() async {
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    final results = await Future.wait([api.getUsers(), api.getOnlineUsers()]);
    if (mounted) setState(() { _users = results[0] as List<dynamic>; _onlineUsers = results[1] as List<dynamic>; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      floatingActionButton: FloatingActionButton.small(
        backgroundColor: cs.primary,
        onPressed: () => _showEditor(null),
        child: Icon(Icons.person_add_rounded, color: cs.onPrimary),
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
            child: Row(children: [
              const Expanded(child: AbsorbPageHeader(title: 'Users', padding: EdgeInsets.zero)),
              IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white38), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: _users.length,
                itemBuilder: (_, i) => _userTile(cs, tt, _users[i]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _userTile(ColorScheme cs, TextTheme tt, dynamic user) {
    final username = user['username'] as String? ?? 'Unknown';
    final type = user['type'] as String? ?? 'user';
    final isActive = user['isActive'] as bool? ?? true;
    final isLocked = user['isLocked'] as bool? ?? false;
    final lastSeen = user['lastSeen'] as num?;
    final isOnline = _onlineUsers.any((o) {
      final ou = o is Map ? (o['username'] ?? o['user']?['username']) : null;
      return ou == username;
    });
    final lastSeenStr = lastSeen != null ? _timeAgo(DateTime.fromMillisecondsSinceEpoch(lastSeen.toInt())) : 'Never';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: GestureDetector(
        onTap: type == 'root' ? null : () => _showEditor(user as Map<String, dynamic>),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            CircleAvatar(radius: 18,
              backgroundColor: isOnline ? Colors.green.withValues(alpha: 0.15) : cs.primary.withValues(alpha: 0.1),
              child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?',
                style: TextStyle(color: isOnline ? Colors.green : cs.primary, fontWeight: FontWeight.w700, fontSize: 14))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(username, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                if (type == 'admin' || type == 'root') Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                  child: Text(type, style: tt.labelSmall?.copyWith(color: cs.primary, fontSize: 9, fontWeight: FontWeight.w600))),
                if (isLocked) ...[const SizedBox(width: 4), Icon(Icons.lock_rounded, size: 12, color: Colors.red.withValues(alpha: 0.6))],
                if (!isActive) ...[const SizedBox(width: 4), Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                  child: Text('disabled', style: tt.labelSmall?.copyWith(color: Colors.red.withValues(alpha: 0.7), fontSize: 9)))],
              ]),
              const SizedBox(height: 2),
              Text(isOnline ? 'Online now' : 'Last seen $lastSeenStr',
                style: tt.labelSmall?.copyWith(color: isOnline ? Colors.green.withValues(alpha: 0.7) : Colors.white30, fontSize: 11)),
            ])),
            if (type != 'root') Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white.withValues(alpha: 0.15))
            else Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: isOnline ? Colors.green : Colors.white.withValues(alpha: 0.1))),
          ]),
        ),
      ),
    );
  }

  void _showEditor(Map<String, dynamic>? user) {
    showModalBottomSheet(context: context, isScrollControlled: true, useSafeArea: true, backgroundColor: Colors.transparent,
      builder: (_) => _UserEditorSheet(user: user, libraries: widget.libraries, onSaved: _reload));
  }

  String _timeAgo(DateTime dt) { final d = DateTime.now().difference(dt);
    if (d.inSeconds < 60) return 'just now'; if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago'; if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).floor()}mo ago'; }
}

// ═══════════════════════════════════════════════════════════════
//  User Editor Sheet
// ═══════════════════════════════════════════════════════════════

class _UserEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? user;
  final List<dynamic> libraries;
  final VoidCallback onSaved;
  const _UserEditorSheet({this.user, required this.libraries, required this.onSaved});
  @override State<_UserEditorSheet> createState() => _UserEditorSheetState();
}

class _UserEditorSheetState extends State<_UserEditorSheet> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _saving = false, _deleting = false;
  bool get _isNew => widget.user == null;

  late String _type;
  late bool _isActive, _isLocked, _canDownload, _canUpdate, _canDelete, _canUpload, _accessExplicit, _accessAllLibraries;
  late Set<String> _selectedLibraries;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    final p = (u?['permissions'] as Map<String, dynamic>?) ?? {};
    _usernameCtrl.text = u?['username'] as String? ?? '';
    _type = u?['type'] as String? ?? 'user';
    _isActive = u?['isActive'] as bool? ?? true;
    _isLocked = u?['isLocked'] as bool? ?? false;
    _canDownload = p['download'] as bool? ?? true;
    _canUpdate = p['update'] as bool? ?? false;
    _canDelete = p['delete'] as bool? ?? false;
    _canUpload = p['upload'] as bool? ?? false;
    _accessExplicit = p['accessExplicitContent'] as bool? ?? false;
    _accessAllLibraries = p['accessAllLibraries'] as bool? ?? true;
    _selectedLibraries = Set<String>.from((u?['librariesAccessible'] as List?)?.map((e) => e.toString()) ?? []);
  }

  @override
  void dispose() { _usernameCtrl.dispose(); _passwordCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85, minChildSize: 0.5, maxChildSize: 0.95, expand: false,
        builder: (ctx, sc) => Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 8, 0), child: Row(children: [
            Expanded(child: Text(_isNew ? 'Create User' : 'Edit User', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.white))),
            if (!_isNew) IconButton(icon: Icon(Icons.delete_outline_rounded, color: Colors.red.withValues(alpha: 0.7), size: 20), onPressed: _deleting ? null : _deleteUser),
            IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 20), onPressed: () => Navigator.pop(context)),
          ])),
          const Divider(height: 1, color: Colors.white10),
          Expanded(child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
            _lbl(tt, 'Username'), const SizedBox(height: 6),
            TextField(controller: _usernameCtrl, enabled: _isNew, style: const TextStyle(color: Colors.white), decoration: _deco(cs, 'Enter username')),
            const SizedBox(height: 16),
            _lbl(tt, _isNew ? 'Password' : 'New Password'), const SizedBox(height: 6),
            TextField(controller: _passwordCtrl, obscureText: true, style: const TextStyle(color: Colors.white),
              decoration: _deco(cs, _isNew ? 'Enter password' : 'Leave blank to keep current')),
            const SizedBox(height: 20),
            _lbl(tt, 'Account Type'), const SizedBox(height: 8),
            Row(children: [
              _chip(cs, tt, 'guest', Icons.person_outline_rounded), const SizedBox(width: 8),
              _chip(cs, tt, 'user', Icons.person_rounded), const SizedBox(width: 8),
              _chip(cs, tt, 'admin', Icons.admin_panel_settings_rounded),
            ]),
            const SizedBox(height: 20),
            _lbl(tt, 'Status'), const SizedBox(height: 4),
            _sw('Account Active', _isActive, (v) => setState(() => _isActive = v), sub: 'Disabled accounts cannot log in'),
            _sw('Locked', _isLocked, (v) => setState(() => _isLocked = v), sub: 'Prevents password changes'),
            const SizedBox(height: 12),
            _lbl(tt, 'Permissions'), const SizedBox(height: 4),
            _sw('Download', _canDownload, (v) => setState(() => _canDownload = v)),
            _sw('Update', _canUpdate, (v) => setState(() => _canUpdate = v), sub: 'Edit metadata and library items'),
            _sw('Delete', _canDelete, (v) => setState(() => _canDelete = v)),
            _sw('Upload', _canUpload, (v) => setState(() => _canUpload = v)),
            _sw('Explicit Content', _accessExplicit, (v) => setState(() => _accessExplicit = v)),
            const SizedBox(height: 12),
            _lbl(tt, 'Library Access'), const SizedBox(height: 4),
            _sw('Access All Libraries', _accessAllLibraries, (v) => setState(() => _accessAllLibraries = v)),
            if (!_accessAllLibraries) ...[
              const SizedBox(height: 8),
              ...widget.libraries.map((lib) {
                final id = lib['id'] as String? ?? '';
                final name = lib['name'] as String? ?? 'Library';
                final sel = _selectedLibraries.contains(id);
                return Padding(padding: const EdgeInsets.only(bottom: 4), child: GestureDetector(
                  onTap: () => setState(() { if (sel) _selectedLibraries.remove(id); else _selectedLibraries.add(id); }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: sel ? cs.primary.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: sel ? cs.primary.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06))),
                    child: Row(children: [
                      Icon(sel ? Icons.check_circle_rounded : Icons.circle_outlined, size: 18, color: sel ? cs.primary : Colors.white24),
                      const SizedBox(width: 10),
                      Text(name, style: TextStyle(color: sel ? Colors.white : Colors.white54, fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
                    ]),
                  ),
                ));
              }),
            ],
          ])),
          Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, MediaQuery.of(context).padding.bottom + 12),
            child: SizedBox(width: double.infinity, height: 48, child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: cs.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(_isNew ? 'Create User' : 'Save Changes', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onPrimary)),
            ))),
        ])));
  }

  Widget _lbl(TextTheme tt, String t) => Text(t, style: tt.labelMedium?.copyWith(color: Colors.white54, fontWeight: FontWeight.w600));

  InputDecoration _deco(ColorScheme cs, String hint) => InputDecoration(
    hintText: hint, hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
    filled: true, fillColor: Colors.white.withValues(alpha: 0.04),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5))),
    disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.04))),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12));

  Widget _chip(ColorScheme cs, TextTheme tt, String type, IconData ic) {
    final on = _type == type;
    return Expanded(child: GestureDetector(onTap: () => setState(() => _type = type),
      child: AnimatedContainer(duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: on ? cs.primary.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? cs.primary.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.06))),
        child: Column(children: [
          Icon(ic, size: 20, color: on ? cs.primary : Colors.white30), const SizedBox(height: 4),
          Text(type[0].toUpperCase() + type.substring(1),
            style: tt.labelSmall?.copyWith(color: on ? cs.primary : Colors.white38, fontWeight: on ? FontWeight.w700 : FontWeight.w500, fontSize: 11)),
        ]))));
  }

  Widget _sw(String l, bool v, ValueChanged<bool> cb, {String? sub}) => SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
    title: Text(l, style: const TextStyle(color: Colors.white, fontSize: 14)),
    subtitle: sub != null ? Text(sub, style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)) : null,
    value: v, onChanged: cb);

  Future<void> _save() async {
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty) { _snk('Username is required'); return; }
    if (_isNew && _passwordCtrl.text.isEmpty) { _snk('Password is required'); return; }
    setState(() => _saving = true);
    final perms = {'download': _canDownload, 'update': _canUpdate, 'delete': _canDelete, 'upload': _canUpload,
      'accessExplicitContent': _accessExplicit, 'accessAllLibraries': _accessAllLibraries, 'accessAllTags': true};
    bool ok;
    if (_isNew) {
      final r = await api.createUser(username: username, password: _passwordCtrl.text, type: _type,
        permissions: perms, librariesAccessible: _accessAllLibraries ? [] : _selectedLibraries.toList());
      ok = r != null;
    } else {
      final up = <String, dynamic>{'type': _type, 'isActive': _isActive, 'isLocked': _isLocked,
        'permissions': perms, 'librariesAccessible': _accessAllLibraries ? [] : _selectedLibraries.toList()};
      if (_passwordCtrl.text.isNotEmpty) up['password'] = _passwordCtrl.text;
      ok = await api.updateUser(widget.user!['id'] as String, up);
    }
    if (mounted) { setState(() => _saving = false);
      if (ok) { widget.onSaved(); Navigator.pop(context); _snk(_isNew ? 'User created' : 'User updated'); }
      else { _snk(_isNew ? 'Failed to create user' : 'Failed to update user'); } }
  }

  Future<void> _deleteUser() async {
    final name = widget.user?['username'] ?? 'this user';
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text('Delete User?', style: TextStyle(color: Colors.white)),
      content: Text('Permanently delete $name?', style: const TextStyle(color: Colors.white70)),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: TextStyle(color: Colors.red.shade300)))],
    ));
    if (yes != true) return;
    final api = context.read<AuthProvider>().apiService; if (api == null) return;
    setState(() => _deleting = true);
    final ok = await api.deleteUser(widget.user!['id'] as String);
    if (mounted) { setState(() => _deleting = false);
      if (ok) { widget.onSaved(); Navigator.pop(context); _snk('$name deleted'); }
      else { _snk('Failed to delete user'); } }
  }

  void _snk(String s) => ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
    SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
}
