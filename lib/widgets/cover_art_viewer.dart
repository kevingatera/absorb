import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

void showCoverArtViewer(
  BuildContext context, {
  required String title,
  required String? coverUrl,
  String? hiResCoverUrl,
  Map<String, String> httpHeaders = const {},
}) {
  if (coverUrl == null || coverUrl.isEmpty) return;

  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      pageBuilder: (_, __, ___) => _CoverArtViewerPage(
        title: title,
        coverUrl: hiResCoverUrl?.isNotEmpty == true ? hiResCoverUrl! : coverUrl,
        httpHeaders: httpHeaders,
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: child,
      ),
    ),
  );
}

class _CoverArtViewerPage extends StatefulWidget {
  final String title;
  final String coverUrl;
  final Map<String, String> httpHeaders;

  const _CoverArtViewerPage({
    required this.title,
    required this.coverUrl,
    required this.httpHeaders,
  });

  @override
  State<_CoverArtViewerPage> createState() => _CoverArtViewerPageState();
}

class _CoverArtViewerPageState extends State<_CoverArtViewerPage> {
  final TransformationController _transformController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  bool get _isZoomed => _transformController.value.getMaxScaleOnAxis() > 1.02;

  void _close() {
    if (mounted) Navigator.pop(context);
  }

  void _handleDoubleTap() {
    final details = _doubleTapDetails;
    if (details == null) return;

    if (_isZoomed) {
      _transformController.value = Matrix4.identity();
      return;
    }

    const targetScale = 2.5;
    final position = details.localPosition;
    _transformController.value = Matrix4.identity()
      ..translate(
        -position.dx * (targetScale - 1),
        -position.dy * (targetScale - 1),
      )
      ..scale(targetScale);
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isLocal = widget.coverUrl.startsWith('/');

    Widget image;
    if (isLocal) {
      image = Image.file(
        File(widget.coverUrl),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => const _ViewerPlaceholder(),
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: widget.coverUrl,
        httpHeaders: widget.httpHeaders,
        fit: BoxFit.contain,
        fadeInDuration: const Duration(milliseconds: 120),
        memCacheWidth: 2400,
        maxWidthDiskCache: 2400,
        placeholder: (_, __) => const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        errorWidget: (_, __, ___) => const _ViewerPlaceholder(),
      );
    }

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final artSize = math.min(
              constraints.maxWidth - 40,
              constraints.maxHeight - 160,
            );

            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: const SizedBox.expand(),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 72, 20, 44),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      onDoubleTapDown: (details) => _doubleTapDetails = details,
                      onDoubleTap: _handleDoubleTap,
                      child: SizedBox(
                        width: artSize,
                        height: artSize,
                        child: InteractiveViewer(
                          transformationController: _transformController,
                          minScale: 1,
                          maxScale: 5,
                          panEnabled: true,
                          clipBehavior: Clip.none,
                          boundaryMargin: const EdgeInsets.all(96),
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
                        onPressed: _close,
                        icon: const Icon(Icons.close_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.title,
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color:
                            cs.surfaceContainerHighest.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Text(
                        'Double tap or pinch to zoom, drag to inspect',
                        style: tt.labelMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
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
