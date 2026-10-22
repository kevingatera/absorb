import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// One name in an author or narrator list. [id] is empty when only the
/// display name is known.
class NameLinkTarget {
  const NameLinkTarget({required this.name, this.id = ''});

  final String name;
  final String id;

  bool get hasId => id.isNotEmpty;
}

/// Authors from an item's structured `authors` array, in server order.
List<NameLinkTarget> authorTargets(Map<String, dynamic> metadata) {
  final authors = metadata['authors'] as List<dynamic>? ?? const [];
  return [
    for (final a in authors)
      if (a is Map<String, dynamic>)
        NameLinkTarget(
          name: a['name'] as String? ?? '',
          id: a['id'] as String? ?? '',
        ),
  ];
}

/// Narrators from `narrators` (strings or `{name}` maps). Falls back to the
/// comma-separated `narratorName` when the array is missing.
List<NameLinkTarget> narratorTargets(Map<String, dynamic> metadata) {
  final raw = metadata['narrators'] as List<dynamic>? ?? [];
  final names = <String>[
    for (final n in raw)
      if (n is String && n.trim().isNotEmpty)
        n.trim()
      else if (n is Map<String, dynamic>)
        (n['name'] as String? ?? '').trim()
  ].where((s) => s.isNotEmpty).toList();

  if (names.isEmpty) {
    final fallback = (metadata['narratorName'] as String? ?? '').trim();
    names.addAll(fallback
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty));
  }
  return [for (final n in names) NameLinkTarget(name: n)];
}

/// Wrapped, tappable names for the book sheet. Each name has a padded touch
/// target, and the list collapses to [collapseAfter] names until [expanded].
class NameLinks extends StatelessWidget {
  const NameLinks({
    super.key,
    required this.targets,
    required this.onTap,
    required this.style,
    required this.accent,
    required this.mutedColor,
    this.prefix,
    this.suffix,
    this.collapseAfter = 3,
    this.expanded = false,
    this.onExpand,
  });

  final List<NameLinkTarget> targets;
  final ValueChanged<NameLinkTarget> onTap;
  final TextStyle? style;
  final Color accent;
  final Color mutedColor;
  final String? prefix;
  final String? suffix;
  final int collapseAfter;
  final bool expanded;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final showAll = expanded || targets.length <= collapseAfter;
    final visible = showAll ? targets : targets.sublist(0, collapseAfter);
    final remaining = targets.length - collapseAfter;

    final linkStyle = style?.copyWith(
      color: accent,
      decoration: TextDecoration.underline,
      decorationColor: accent.withValues(alpha: 0.4),
    );
    final commaStyle = style?.copyWith(color: accent);
    final baseStyle = style?.copyWith(color: mutedColor);

    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        if (prefix != null && prefix!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(prefix!, style: baseStyle),
          ),
        for (int i = 0; i < visible.length; i++)
          _link(
            visible[i],
            linkStyle,
            commaStyle,
            comma: i < visible.length - 1 || (!showAll && remaining > 0),
          ),
        if (!showAll)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onExpand,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Text(l.andCountMore(remaining), style: style?.copyWith(
                color: accent.withValues(alpha: 0.7),
              )),
            ),
          ),
        if (suffix != null && suffix!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(suffix!, style: baseStyle),
          ),
      ],
    );
  }

  // The name and its comma are one Wrap child so the comma can never start
  // the next line. Padding makes the tap target the full line height.
  Widget _link(NameLinkTarget target, TextStyle? linkStyle, TextStyle? commaStyle,
      {required bool comma}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(target),
            child: Padding(
              padding: EdgeInsets.fromLTRB(2, 6, comma ? 0 : 2, 6),
              child: Text(target.name, style: linkStyle),
            ),
          ),
        ),
        if (comma)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(', ', style: commaStyle),
          ),
      ],
    );
  }
}

/// One line of links for list tiles. When [enabled] is false (selection
/// mode) it is plain text, so the tile keeps the tap.
class NameLinkText extends StatefulWidget {
  const NameLinkText({
    super.key,
    required this.targets,
    required this.onTap,
    required this.style,
    required this.accent,
    required this.mutedColor,
    this.enabled = true,
  });

  final List<NameLinkTarget> targets;
  final ValueChanged<NameLinkTarget> onTap;
  final TextStyle? style;
  final Color accent;
  final Color mutedColor;
  final bool enabled;

  @override
  State<NameLinkText> createState() => _NameLinkTextState();
}

class _NameLinkTextState extends State<NameLinkText> {
  // Reused across builds and disposed with the state, so spans never hold a
  // recognizer that was already disposed.
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targets = widget.targets;
    if (!widget.enabled) {
      return Text(
        targets.map((t) => t.name).join(', '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style?.copyWith(color: widget.mutedColor),
      );
    }

    final linkStyle = widget.style?.copyWith(
      color: widget.accent,
      decoration: TextDecoration.underline,
      decorationColor: widget.accent.withValues(alpha: 0.4),
    );
    final commaStyle = widget.style?.copyWith(color: widget.accent);
    final spans = <InlineSpan>[];
    for (int i = 0; i < targets.length; i++) {
      if (i > 0) spans.add(TextSpan(text: ', ', style: commaStyle));
      while (_recognizers.length <= i) {
        _recognizers.add(TapGestureRecognizer());
      }
      final target = targets[i];
      final recognizer = _recognizers[i]..onTap = () => widget.onTap(target);
      spans.add(TextSpan(
        text: target.name,
        style: linkStyle,
        recognizer: recognizer,
      ));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
