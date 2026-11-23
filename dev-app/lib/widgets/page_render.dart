import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/studio_doc.dart';

/// Hält geöffnete PDF-Dateien und gerenderte Seiten (LRU) vor.
class RenderCache {
  static final _docs = <String, Future<PdfDocument>>{};
  static final _images = <String, ui.Image>{};
  static int _bytes = 0;
  static const _maxBytes = 120 * 1024 * 1024;

  static Future<PdfDocument> doc(String path) =>
      _docs.putIfAbsent(path, () => PdfDocument.openFile(path));

  static Future<void> closeUnused(Set<String> keep) async {
    final drop = _docs.keys.where((k) => !keep.contains(k)).toList();
    for (final k in drop) {
      final f = _docs.remove(k);
      try {
        (await f!).dispose();
      } catch (_) {}
    }
  }

  static ui.Image? _get(String key) {
    final im = _images.remove(key);
    if (im != null) _images[key] = im;
    return im;
  }

  static void _put(String key, ui.Image im) {
    _images[key] = im;
    _bytes += im.width * im.height * 4;
    while (_bytes > _maxBytes && _images.length > 1) {
      final k = _images.keys.first;
      final old = _images.remove(k)!;
      _bytes -= old.width * old.height * 4;
      old.dispose();
    }
  }

  static void evictPath(String path) {
    final keys = _images.keys.where((k) => k.startsWith('$path#')).toList();
    for (final k in keys) {
      final im = _images.remove(k)!;
      _bytes -= im.width * im.height * 4;
      im.dispose();
    }
  }

  /// Rendert die Seite (ohne die App-Drehung) mit [pxWidth] Pixeln Breite.
  static Future<ui.Image?> render(PageItem p, int pxWidth) async {
    final bucket = _bucket(pxWidth);
    final key = '${p.path}#${p.pdfIndex}#$bucket';
    final hit = _get(key);
    if (hit != null) return hit;
    ui.Image? im;
    if (p.source == PageSource.pdf) {
      final d = await doc(p.path);
      if (p.pdfIndex >= d.pages.length) return null;
      final page = d.pages[p.pdfIndex];
      final w = bucket.toDouble();
      final h = w * page.height / page.width;
      final r = await page.render(
        fullWidth: w,
        fullHeight: h,
        backgroundColor: 0xFFFFFFFF,
        annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
      );
      if (r == null) return null;
      try {
        im = await r.createImage();
      } finally {
        r.dispose();
      }
    } else {
      final bytes = await File(p.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: bucket);
      im = (await codec.getNextFrame()).image;
      codec.dispose();
    }
    _put(key, im);
    return im;
  }

  static int _bucket(int w) {
    for (final b in const [240, 480, 800, 1200, 1700, 2400]) {
      if (w <= b) return b;
    }
    return 2400;
  }
}

/// Zeigt eine Seite inkl. App-Drehung, Seitenverhältnis bleibt erhalten.
class PageImage extends StatefulWidget {
  const PageImage({
    super.key,
    required this.page,
    this.showOverlays = true,
    this.quality = 1.0,
  });

  final PageItem page;
  final bool showOverlays;

  /// 1.0 = Bildschirmauflösung, <1 für Vorschaubilder.
  final double quality;

  @override
  State<PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<PageImage> {
  ui.Image? _img;
  int _requested = 0;
  String _key = '';

  void _load(int px) {
    final key = '${widget.page.path}#${widget.page.pdfIndex}';
    if (px <= _requested && key == _key) return;
    _requested = px;
    _key = key;
    RenderCache.render(widget.page, px).then((im) {
      if (mounted && im != null) setState(() => _img = im);
    });
  }

  @override
  void didUpdateWidget(covariant PageImage old) {
    super.didUpdateWidget(old);
    if (old.page.path != widget.page.path ||
        old.page.pdfIndex != widget.page.pdfIndex) {
      _img = null;
      _requested = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    return AspectRatio(
      aspectRatio: p.aspect,
      child: LayoutBuilder(builder: (context, c) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // Breite der *ungedrehten* Seite in Pixeln
        final baseW = p.quarterTurns.isOdd ? c.maxHeight : c.maxWidth;
        _load((baseW * dpr * widget.quality).ceil());
        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.white),
            if (_img != null)
              RotatedBox(
                quarterTurns: p.quarterTurns,
                child: RawImage(
                  image: _img,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
              )
            else
              const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (widget.showOverlays)
              for (final o in p.overlays)
                Positioned(
                  left: (o.cx - o.widthFrac / 2) * c.maxWidth,
                  top: o.cy * c.maxHeight - o.widthFrac * c.maxWidth / o.aspect / 2,
                  width: o.widthFrac * c.maxWidth,
                  height: o.widthFrac * c.maxWidth / o.aspect,
                  child: Image.memory(o.png, fit: BoxFit.fill, gaplessPlayback: true),
                ),
          ],
        );
      }),
    );
  }
}
