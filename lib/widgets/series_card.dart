import 'package:flutter/material.dart';

class SeriesCard extends StatelessWidget {
  final Map<String, dynamic> series;

  const SeriesCard({super.key, required this.series});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final name = series['name'] as String? ?? 'Unknown Series';
    final books = series['books'] as List<dynamic>? ?? [];
    final bookCount = books.length;

    return Card(
      elevation: 0,
      color: cs.tertiaryContainer.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Stacked book spines visual effect
            Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          cs.tertiaryContainer,
                          cs.tertiaryContainer.withValues(alpha: 0.6),
                        ],
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.library_books_rounded,
                        size: 40,
                        color: cs.onTertiaryContainer.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Info overlay at bottom
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      cs.surface.withValues(alpha: 0.9),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$bookCount book${bookCount != 1 ? 's' : ''}',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
