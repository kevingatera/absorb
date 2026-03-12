import 'package:flutter/material.dart';

import 'author_books_sheet.dart';

String? extractPrimaryAuthorId(Map<String, dynamic> item,
    {String? authorName}) {
  Map<String, dynamic>? asMap(dynamic value) =>
      value is Map<String, dynamic> ? value : null;

  Iterable<Map<String, dynamic>> asMaps(dynamic value) sync* {
    if (value is List) {
      for (final entry in value) {
        final map = asMap(entry);
        if (map != null) yield map;
      }
    }
  }

  final media = asMap(item['media']) ?? const <String, dynamic>{};
  final metadata = asMap(media['metadata']) ?? const <String, dynamic>{};
  final candidates = <Map<String, dynamic>>[
    ...asMaps(metadata['authors']),
    ...asMaps(item['authors']),
  ];

  String? idFromMap(Map<String, dynamic>? map) {
    final id = map?['id'] as String?;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  if (authorName != null && authorName.isNotEmpty) {
    for (final author in candidates) {
      final name = author['name'] as String? ?? author['authorName'] as String?;
      if (name == authorName) {
        final id = idFromMap(author);
        if (id != null) return id;
      }
    }
  }

  for (final author in candidates) {
    final id = idFromMap(author);
    if (id != null) return id;
  }

  final directId =
      metadata['authorId'] as String? ?? item['authorId'] as String?;
  if (directId != null && directId.isNotEmpty) return directId;

  return idFromMap(asMap(metadata['author'])) ??
      idFromMap(asMap(item['author']));
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
    final authorId = extractPrimaryAuthorId(item, authorName: authorName);
    final textStyle = authorId == null
        ? style
        : style?.copyWith(
            decoration: TextDecoration.underline,
            decorationThickness: 1.2,
          );

    final text = Text(
      authorName,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: textStyle,
    );

    if (authorId == null || authorName.isEmpty) return text;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        showAuthorBooksSheet(
          context,
          authorId: authorId,
          authorName: authorName,
        );
      },
      child: text,
    );
  }
}
