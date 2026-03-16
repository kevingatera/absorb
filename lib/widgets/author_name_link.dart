import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import 'author_books_sheet.dart';
import 'narrator_books_sheet.dart';

enum _PersonKind { author, narrator }

class _PersonTarget {
  final String label;
  final String? authorId;

  const _PersonTarget({required this.label, this.authorId});

  bool get hasResolvedAuthorId => authorId != null && authorId!.isNotEmpty;
}

Map<String, dynamic>? _asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : null;

Iterable<Map<String, dynamic>> _asMaps(dynamic value) sync* {
  if (value is List) {
    for (final entry in value) {
      final map = _asMap(entry);
      if (map != null) yield map;
    }
  }
}

List<String> _splitPeople(String value) {
  return value
      .split(RegExp(r',\s*|\s*&\s*|\s+and\s+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}

List<_PersonTarget> _extractAuthorTargets(
  Map<String, dynamic> item,
  String displayedAuthor,
) {
  final media = _asMap(item['media']) ?? const <String, dynamic>{};
  final metadata = _asMap(media['metadata']) ?? const <String, dynamic>{};
  final targets = <_PersonTarget>[];
  final seen = <String>{};

  void addTarget(String label, {String? authorId}) {
    final key = '${authorId ?? ''}|$label';
    if (label.isEmpty || seen.contains(key)) return;
    seen.add(key);
    targets.add(_PersonTarget(label: label, authorId: authorId));
  }

  for (final author in [
    ..._asMaps(metadata['authors']),
    ..._asMaps(item['authors']),
  ]) {
    final name = author['name'] as String? ?? author['authorName'] as String?;
    final id = author['id'] as String?;
    if (name != null && name.isNotEmpty) addTarget(name, authorId: id);
  }

  final directId =
      metadata['authorId'] as String? ?? item['authorId'] as String?;
  final normalizedDisplayed = displayedAuthor.trim();

  if (targets.isNotEmpty && directId != null && directId.isNotEmpty) {
    final resolved = <_PersonTarget>[];
    for (final target in targets) {
      if (target.hasResolvedAuthorId) {
        resolved.add(target);
        continue;
      }

      final shouldUseDirectId = targets.length == 1 ||
          target.label == normalizedDisplayed ||
          _splitPeople(normalizedDisplayed).length == 1;
      resolved.add(
        shouldUseDirectId
            ? _PersonTarget(label: target.label, authorId: directId)
            : target,
      );
    }
    targets
      ..clear()
      ..addAll(resolved);
  }

  if (targets.isEmpty && displayedAuthor.isNotEmpty) {
    for (final label in _splitPeople(displayedAuthor)) {
      addTarget(label, authorId: directId);
    }
  }

  return targets;
}

List<_PersonTarget> _extractNarratorTargets(
  Map<String, dynamic> item,
  String displayedNarrator,
) {
  final media = _asMap(item['media']) ?? const <String, dynamic>{};
  final metadata = _asMap(media['metadata']) ?? const <String, dynamic>{};
  final targets = <_PersonTarget>[];
  final seen = <String>{};

  void addTarget(String label) {
    if (label.isEmpty || seen.contains(label)) return;
    seen.add(label);
    targets.add(_PersonTarget(label: label));
  }

  final narrators = metadata['narrators'];
  if (narrators is List) {
    for (final narrator in narrators) {
      final label = narrator is String
          ? narrator
          : narrator is Map<String, dynamic>
              ? (narrator['name'] as String? ?? '')
              : '';
      addTarget(label.trim());
    }
  }

  if (targets.isEmpty && displayedNarrator.isNotEmpty) {
    for (final label in _splitPeople(displayedNarrator)) {
      addTarget(label);
    }
  }

  return targets;
}

class _PersonNameLink extends StatelessWidget {
  final Map<String, dynamic> item;
  final String displayedName;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final _PersonKind kind;

  const _PersonNameLink({
    required this.item,
    required this.displayedName,
    required this.kind,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  List<_PersonTarget> _targets() {
    switch (kind) {
      case _PersonKind.author:
        return _extractAuthorTargets(item, displayedName);
      case _PersonKind.narrator:
        return _extractNarratorTargets(item, displayedName);
    }
  }

  bool _isNavigable(_PersonTarget target) {
    switch (kind) {
      case _PersonKind.author:
        return target.label.isNotEmpty;
      case _PersonKind.narrator:
        return target.label.isNotEmpty;
    }
  }

  TextStyle? _interactiveStyle(BuildContext context, bool clickable) {
    if (!clickable) return style;
    final cs = Theme.of(context).colorScheme;
    final baseColor = style?.color;
    final linkColor = baseColor == null
        ? cs.primary.withValues(alpha: 0.92)
        : Color.lerp(baseColor, cs.primary, 0.55) ?? cs.primary;
    return style?.copyWith(
          color: linkColor,
          fontWeight: style?.fontWeight ?? FontWeight.w600,
        ) ??
        TextStyle(
          color: linkColor,
          fontWeight: FontWeight.w600,
        );
  }

  Future<String?> _resolveAuthorId(
      BuildContext context, _PersonTarget target) async {
    if (target.hasResolvedAuthorId) return target.authorId;
    final auth = context.read<AuthProvider>();
    final libraryId = context.read<LibraryProvider>().selectedLibraryId;
    final api = auth.apiService;
    if (api == null || libraryId == null || target.label.isEmpty) return null;

    final authors = await api.getLibraryAuthors(libraryId);
    final wanted = target.label.trim().toLowerCase();
    for (final author in authors) {
      final name = (author['name'] as String? ?? '').trim().toLowerCase();
      final id = author['id'] as String?;
      if (name == wanted && id != null && id.isNotEmpty) return id;
    }
    for (final author in authors) {
      final name = (author['name'] as String? ?? '').trim().toLowerCase();
      final id = author['id'] as String?;
      if (name.contains(wanted) && id != null && id.isNotEmpty) return id;
    }

    final search = await api.searchLibrary(libraryId, target.label, limit: 8);
    final searchAuthors = search?['authors'] as List<dynamic>? ?? const [];
    for (final result in searchAuthors) {
      if (result is! Map<String, dynamic>) continue;
      final name = (result['name'] as String? ?? '').trim().toLowerCase();
      final id = result['id'] as String?;
      if (name == wanted && id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  Future<void> _openTarget(BuildContext context, _PersonTarget target) async {
    FocusManager.instance.primaryFocus?.unfocus();
    switch (kind) {
      case _PersonKind.author:
        final authorId = await _resolveAuthorId(context, target);
        if (authorId == null || authorId.isEmpty) return;
        showAuthorBooksSheet(
          context,
          authorId: authorId,
          authorName: target.label,
        );
        break;
      case _PersonKind.narrator:
        showNarratorBooksSheet(context, narratorName: target.label);
        break;
    }
  }

  void _openChooser(BuildContext context, List<_PersonTarget> targets) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final tt = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              0,
              12,
              12 + MediaQuery.of(ctx).viewPadding.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  child: Row(
                    children: [
                      Icon(
                        kind == _PersonKind.author
                            ? Icons.person_rounded
                            : Icons.mic_rounded,
                        color: cs.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        kind == _PersonKind.author
                            ? 'Choose an author'
                            : 'Choose a narrator',
                        style: tt.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                ...targets.map(
                  (target) => ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    leading: Icon(
                      kind == _PersonKind.author
                          ? Icons.person_outline_rounded
                          : Icons.record_voice_over_rounded,
                      color: cs.onSurfaceVariant,
                    ),
                    title: Text(target.label),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _openTarget(context, target);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets();
    final navigableTargets = targets.where(_isNavigable).toList();
    final clickable = displayedName.isNotEmpty && navigableTargets.isNotEmpty;

    final textStyle = _interactiveStyle(context, clickable);
    final text = Text(
      displayedName,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: textStyle,
    );

    if (!clickable) return text;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          if (navigableTargets.length == 1) {
            await _openTarget(context, navigableTargets.first);
          } else {
            _openChooser(context, navigableTargets);
          }
        },
        borderRadius: BorderRadius.circular(6),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: text,
        ),
      ),
    );
  }
}

class AuthorNameLink extends StatelessWidget {
  final Map<String, dynamic> item;
  final String authorName;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const AuthorNameLink({
    super.key,
    required this.item,
    required this.authorName,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    return _PersonNameLink(
      item: item,
      displayedName: authorName,
      kind: _PersonKind.author,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

class NarratorNameLink extends StatelessWidget {
  final Map<String, dynamic> item;
  final String narratorName;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const NarratorNameLink({
    super.key,
    required this.item,
    required this.narratorName,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    return _PersonNameLink(
      item: item,
      displayedName: narratorName,
      kind: _PersonKind.narrator,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
