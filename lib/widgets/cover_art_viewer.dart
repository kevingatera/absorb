import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

void showCoverArtViewer(
  BuildContext context, {
  required String title,
  required String? coverUrl,
  Map<String, String> httpHeaders = const {},
}) {
  if (coverUrl == null || coverUrl.isEmpty) return;

  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      pageBuilder: (_, __, ___) => _CoverArtViewerPage(
        title: title,
        coverUrl: coverUrl,
        httpHeaders: httpHeaders,
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: child,
      ),
    ),
  );
}

class _CoverArtViewerPage extends StatelessWidget {
  final String title;
  final String coverUrl;
  final Map<String, String> httpHeaders;

  const _CoverArtViewerPage({
    required this.title,
    required this.coverUrl,
    required this.httpHeaders,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isLocal = coverUrl.startsWith('/');

    Widget image;
    if (isLocal) {
      image = Image.file(
        File(coverUrl),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const _ViewerPlaceholder(),
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: coverUrl,
        httpHeaders: httpHeaders,
        fit: BoxFit.contain,
        placeholder: (_, __) => const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        errorWidget: (_, __, ___) => const _ViewerPlaceholder(),
      );
    }

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                panEnabled: true,
                clipBehavior: Clip.none,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 72, 20, 44),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: image,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 12,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Text(
                    'Pinch to zoom and drag to inspect',
                    style: tt.labelMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewerPlaceholder extends StatelessWidget {
  const _ViewerPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.album_rounded,
        size: 72,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
