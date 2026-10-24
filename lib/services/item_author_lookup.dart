import 'api_service.dart';

/// An author as the server names it on one item.
typedef AuthorRef = ({String id, String name});

/// Resolves the authors of one item for list tiles whose data has only names.
///
/// Uses the single-item expanded fetch, never the library's author list. The
/// request is cached per server and item, and concurrent callers share it.
/// Failed lookups are dropped from the cache so a later tap retries.
class ItemAuthorLookup {
  ItemAuthorLookup._();

  static final Map<String, Future<List<AuthorRef>>> _lookups = {};

  static Future<List<AuthorRef>> authorsFor(
    ApiService api,
    String serverUrl,
    String itemId,
  ) {
    final key = '$serverUrl|$itemId';
    final existing = _lookups[key];
    if (existing != null) return existing;

    final lookup = _fetch(api, itemId);
    _lookups[key] = lookup;
    // Consume the error here so the cache drop does not leave it unhandled.
    // The caller still gets the error from [lookup].
    lookup.then<void>((_) {}, onError: (Object _) {
      _lookups.remove(key);
    });
    return lookup;
  }

  static Future<List<AuthorRef>> _fetch(ApiService api, String itemId) async {
    final item = await api.getLibraryItem(itemId);
    if (item == null) throw StateError('Item $itemId could not be loaded');
    final media = item['media'] as Map<String, dynamic>? ?? const {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? const {};
    final authors = metadata['authors'] as List<dynamic>? ?? const [];
    return [
      for (final a in authors)
        if (a is Map<String, dynamic> &&
            (a['id'] as String? ?? '').isNotEmpty &&
            (a['name'] as String? ?? '').isNotEmpty)
          (id: a['id'] as String, name: a['name'] as String),
    ];
  }
}
