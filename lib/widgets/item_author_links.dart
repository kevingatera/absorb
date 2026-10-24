import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/item_author_lookup.dart';
import 'author_books_sheet.dart';
import 'name_links.dart';
import 'overlay_toast.dart';
import 'stackable_sheet.dart';

/// Author line on a grid or series tile.
///
/// Structured authors link straight to their sheet. Name-only metadata (the
/// minified library list) links the whole line, and the authors are looked up
/// when it is tapped.
class ItemAuthorLine extends StatefulWidget {
  const ItemAuthorLine({
    super.key,
    required this.itemId,
    required this.metadata,
    required this.style,
    this.enabled = true,
  });

  final String itemId;
  final Map<String, dynamic> metadata;
  final TextStyle? style;

  /// False during selection mode, so taps reach the tile.
  final bool enabled;

  @override
  State<ItemAuthorLine> createState() => _ItemAuthorLineState();
}

class _ItemAuthorLineState extends State<ItemAuthorLine> {
  // Bumped when the tile stops being the visible page (tab switch, pushed
  // route) or selection mode starts, and when the tile is handed a different
  // item. A lookup that began under an older value is dropped rather than
  // opening a sheet over the new screen or reusing the previous book's authors.
  int _generation = 0;
  bool _pageVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _pageVisible) {
      _pageVisible = visible;
      _generation++;
    }
  }

  @override
  void didUpdateWidget(ItemAuthorLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId) _generation++;
    if (oldWidget.enabled && !widget.enabled) _generation++;
  }

  /// Read live, so a lookup that finishes between a tab switch and the next
  /// frame still sees the tile as hidden.
  bool get _isCurrent =>
      mounted &&
      _pageVisible &&
      TickerMode.getValuesNotifier(context).value.enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final structured = [
      for (final a in authorTargets(widget.metadata))
        if (a.hasId && a.name.isNotEmpty) a,
    ];
    final targets = structured.isNotEmpty
        ? structured
        : [NameLinkTarget(name: widget.metadata['authorName'] as String? ?? '')];
    return NameLinkText(
      targets: targets,
      style: widget.style,
      accent: cs.primary,
      mutedColor: cs.onSurfaceVariant,
      enabled: widget.enabled,
      onTap: (a) {
        if (a.hasId) {
          showAuthorDetailSheet(context, authorId: a.id, authorName: a.name);
        } else if (widget.itemId.isNotEmpty) {
          final generation = _generation;
          openItemAuthors(
            context,
            itemId: widget.itemId,
            stillCurrent: () => _isCurrent && generation == _generation,
          );
        }
      },
    );
  }
}

// Keys of lookups currently running, so repeated taps do not stack sheets.
final Set<String> _lookupsInFlight = {};

/// Opens the author for a name-only item.
///
/// One author opens its sheet directly. Several open a chooser. Every outcome
/// gives a toast, but nothing opens unless [stillCurrent] holds and the server
/// and library are still the ones selected when the tap happened.
Future<void> openItemAuthors(
  BuildContext context, {
  required String itemId,
  required bool Function() stillCurrent,
}) async {
  final auth = context.read<AuthProvider>();
  final lib = context.read<LibraryProvider>();
  final l = AppLocalizations.of(context)!;
  final api = auth.apiService;
  final serverUrl = auth.serverUrl;
  if (api == null || serverUrl == null || lib.isOffline) {
    showOverlayToast(context, l.authorLookupFailed, icon: Icons.cloud_off_rounded);
    return;
  }

  final key = '$serverUrl|$itemId';
  if (!_lookupsInFlight.add(key)) return;
  final libraryId = lib.selectedLibraryId;
  bool stale() =>
      !context.mounted ||
      !stillCurrent() ||
      auth.serverUrl != serverUrl ||
      lib.selectedLibraryId != libraryId;
  showOverlayToast(context, l.loadingAuthors, icon: Icons.person_search_rounded);
  try {
    final authors = await ItemAuthorLookup.authorsFor(api, serverUrl, itemId);
    if (stale()) return;
    if (authors.isEmpty) {
      showOverlayToast(context, l.authorLookupNone, icon: Icons.person_off_outlined);
    } else if (authors.length == 1) {
      showAuthorDetailSheet(context,
          authorId: authors.first.id, authorName: authors.first.name);
    } else {
      _showAuthorChooser(context, authors);
    }
  } catch (_) {
    if (!stale()) {
      showOverlayToast(context, l.authorLookupFailed, icon: Icons.error_outline_rounded);
    }
  } finally {
    _lookupsInFlight.remove(key);
  }
}

void _showAuthorChooser(BuildContext context, List<AuthorRef> authors) {
  final l = AppLocalizations.of(context)!;
  showStackableSheet<void>(
    context: context,
    showHandle: true,
    builder: (sheetContext, scrollController) => ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(l.chooseAuthor,
              style: Theme.of(sheetContext).textTheme.titleMedium),
        ),
        for (final a in authors)
          ListTile(
            title: Text(a.name),
            onTap: () {
              Navigator.of(sheetContext).pop();
              if (context.mounted) {
                showAuthorDetailSheet(context, authorId: a.id, authorName: a.name);
              }
            },
          ),
      ],
    ),
  );
}
