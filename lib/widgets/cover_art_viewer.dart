import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

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
  void _close() {
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isLocal = widget.coverUrl.startsWith('/');
    final imageProvider = isLocal
        ? FileImage(File(widget.coverUrl)) as ImageProvider<Object>
        : CachedNetworkImageProvider(
            widget.coverUrl,
            headers: widget.httpHeaders,
          );

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewerWidth =
                (constraints.maxWidth - 24).clamp(0.0, double.infinity);
            final viewerHeight =
                (constraints.maxHeight - 156).clamp(0.0, double.infinity);
            final viewerSize = Size(viewerWidth, viewerHeight);

            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: const SizedBox.expand(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: _close,
                            icon: const Icon(Icons.close_rounded),
                            style: IconButton.styleFrom(
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.08),
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
                      const SizedBox(height: 12),
                      Expanded(
                        child: Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: SizedBox(
                              width: viewerWidth,
                              height: viewerHeight,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.02),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: PhotoView(
                                  imageProvider: imageProvider,
                                  backgroundDecoration: const BoxDecoration(
                                      color: Colors.transparent),
                                  filterQuality: FilterQuality.high,
                                  initialScale:
                                      PhotoViewComputedScale.contained,
                                  minScale: PhotoViewComputedScale.contained,
                                  maxScale: PhotoViewComputedScale.covered * 5,
                                  enablePanAlways: true,
                                  strictScale: true,
                                  gestureDetectorBehavior:
                                      HitTestBehavior.opaque,
                                  customSize: viewerSize,
                                  loadingBuilder: (_, __) => const Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  errorBuilder: (_, __, ___) =>
                                      const _ViewerPlaceholder(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest
                                .withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Text(
                            'Pinch, double tap, or drag to inspect. Tap outside to close.',
                            style: tt.labelMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
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
