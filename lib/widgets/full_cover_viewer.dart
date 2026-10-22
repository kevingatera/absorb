import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../utils/share_origin.dart';
import 'overlay_toast.dart';

/// Where a full-screen cover comes from. A file is a downloaded copy or a
/// local metadata override; a network image needs the library's auth headers.
class CoverImageSource {
  const CoverImageSource.network(this.url, {this.headers = const {}})
      : filePath = null;
  const CoverImageSource.file(this.filePath)
      : url = null,
        headers = const {};

  /// Chooses the source for a URL from `LibraryProvider.getCoverUrl`, which
  /// returns a local path for downloaded and overridden covers.
  factory CoverImageSource.fromUrl(String url, Map<String, String> headers) =>
      url.startsWith('/')
          ? CoverImageSource.file(url)
          : CoverImageSource.network(url, headers: headers);

  final String? url;
  final String? filePath;
  final Map<String, String> headers;
}

/// Opens the full-screen cover viewer over the current route.
void showFullCoverViewer(
  BuildContext context, {
  required CoverImageSource source,
  required String title,
}) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black87,
    pageBuilder: (_, __, ___) => FullCoverViewer(source: source, title: title),
    transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
  ));
}

class FullCoverViewer extends StatefulWidget {
  final CoverImageSource source;
  final String title;
  const FullCoverViewer({super.key, required this.source, required this.title});
  @override State<FullCoverViewer> createState() => _FullCoverViewerState();
}

class _FullCoverViewerState extends State<FullCoverViewer> {
  bool _saving = false;
  final _transform = TransformationController();

  // How far a one-finger drag has pulled the (unzoomed) cover, so it follows
  // the finger and a flick dismisses like every other sheet in the app.
  double _dragY = 0;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.05;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _saveAndShare() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final source = widget.source;
      final File file;
      if (source.filePath != null) {
        // Already on disk; share it in place.
        file = File(source.filePath!);
      } else {
        final url = source.url!;
        final response = await http.get(Uri.parse(url), headers: source.headers);
        if (response.statusCode != 200) throw Exception('Download failed');
        final ext = url.contains('.png') ? '.png' : '.jpg';
        final safeTitle = widget.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
        final dir = await getTemporaryDirectory();
        file = File('${dir.path}/$safeTitle$ext');
        await file.writeAsBytes(response.bodyBytes);
      }
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        sharePositionOrigin: shareOriginFor(context),
      );
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        showOverlayToast(
          context,
          l.failedToSaveError(e.toString()),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _cover() {
    final source = widget.source;
    final path = source.filePath;
    if (path != null) {
      return Image.file(File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.broken_image_rounded, size: 48, color: Colors.white54));
    }
    return CachedNetworkImage(
      imageUrl: source.url!,
      httpHeaders: source.headers,
      fit: BoxFit.contain,
      placeholder: (_, __) => const CircularProgressIndicator(strokeWidth: 2),
      errorWidget: (_, __, ___) => const Icon(Icons.broken_image_rounded, size: 48, color: Colors.white54),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        // Tap closes (a tap on a zoomed cover just zooms it back out first).
        // A one-finger swipe drags the unzoomed cover along and dismisses -
        // tracked through the viewer's own callbacks, because the viewer
        // claims every gesture and a competing detector would never win.
        Positioned.fill(
          child: GestureDetector(
            onTap: () {
              if (_zoomed) {
                setState(() => _transform.value = Matrix4.identity());
              } else {
                Navigator.pop(context);
              }
            },
            child: Transform.translate(
              offset: Offset(0, _dragY),
              child: InteractiveViewer(
                transformationController: _transform,
                clipBehavior: Clip.none,
                minScale: 1.0,
                maxScale: 5.0,
                onInteractionUpdate: (d) {
                  if (!_zoomed && d.pointerCount == 1) {
                    setState(() => _dragY += d.focalPointDelta.dy);
                  }
                },
                onInteractionEnd: (d) {
                  if (_zoomed) return;
                  if (_dragY.abs() > 120 ||
                      d.velocity.pixelsPerSecond.dy.abs() > 800) {
                    Navigator.pop(context);
                  } else if (_dragY != 0) {
                    setState(() => _dragY = 0);
                  }
                },
                child: Center(child: _cover()),
              ),
            ),
          ),
        ),
        // Close button
        Positioned(
          top: MediaQuery.of(context).viewPadding.top + 8,
          left: 8,
          child: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
          ),
        ),
        // Save/share button
        Positioned(
          top: MediaQuery.of(context).viewPadding.top + 8,
          right: 8,
          child: IconButton(
            onPressed: _saving ? null : _saveAndShare,
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_alt_rounded, color: Colors.white),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
          ),
        ),
      ]),
    );
  }
}
