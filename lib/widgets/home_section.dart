import 'package:flutter/material.dart';
import 'book_card.dart';
import 'author_card.dart';
import 'series_card.dart';

class HomeSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<dynamic> entities;
  final String sectionType;
  final String sectionId;

  const HomeSection({
    super.key,
    required this.title,
    required this.icon,
    required this.entities,
    required this.sectionType,
    required this.sectionId,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final isContinueListening = sectionId == 'continue-listening';
    final isAuthorSection = sectionType == 'author';
    final isSeriesSection = sectionType == 'series';

    final double cardWidth =
        isContinueListening ? 300 : (isAuthorSection ? 120 : 140);
    final double cardHeight =
        isContinueListening ? 120 : (isAuthorSection ? 170 : 200);

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(icon, size: 16, color: cs.primary.withValues(alpha: 0.7)),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: tt.titleSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface.withValues(alpha: 0.8),
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 0.5,
                    color: cs.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Snap-scrolling horizontal list
          SizedBox(
            height: cardHeight,
            child: _SnapScrollList(
              cardWidth: cardWidth,
              itemCount: entities.length,
              itemBuilder: (context, index) {
                final entity = entities[index];

                if (isAuthorSection) {
                  return SizedBox(
                    width: cardWidth,
                    child: AuthorCard(author: entity),
                  );
                }

                if (isSeriesSection) {
                  return SizedBox(
                    width: cardWidth,
                    child: SeriesCard(series: entity),
                  );
                }

                return SizedBox(
                  width: cardWidth,
                  child: BookCard(
                    item: entity,
                    showProgress: isContinueListening,
                    isWide: isContinueListening,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A horizontal scrolling list with smooth snap-to-card behavior.
class _SnapScrollList extends StatefulWidget {
  final double cardWidth;
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;

  const _SnapScrollList({
    required this.cardWidth,
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  State<_SnapScrollList> createState() => _SnapScrollListState();
}

class _SnapScrollListState extends State<_SnapScrollList> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final itemExtent = widget.cardWidth + 12;

    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        final offset = _controller.offset;
        final targetIndex = (offset / itemExtent).round();
        final targetOffset =
            (targetIndex * itemExtent).clamp(0.0, _controller.position.maxScrollExtent);
        if ((offset - targetOffset).abs() > 1) {
          Future.microtask(() {
            if (_controller.hasClients) {
              _controller.animateTo(
                targetOffset,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
              );
            }
          });
        }
        return false;
      },
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        physics: const BouncingScrollPhysics(),
        itemCount: widget.itemCount,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: widget.itemBuilder,
      ),
    );
  }
}
