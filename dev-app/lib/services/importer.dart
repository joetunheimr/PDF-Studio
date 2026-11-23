import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../models/studio_doc.dart';
import 'native.dart';
import 'storage.dart';

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Importer {
  /// Kopiert das PDF in den Arbeitsordner und liefert alle Seiten.
  static Future<List<PageItem>> pdf(String sourcePath) async {
    final path = await Storage.importCopy(sourcePath);
    final List<(double, double)> sizes;
    try {
      sizes = await NativeBridge.pdfPageSizes(path);
    } catch (e) {
      throw ImportException(
          'Die Datei lässt sich nicht öffnen (beschädigt oder passwortgeschützt).');
    }
    if (sizes.isEmpty) throw ImportException('Das PDF enthält keine Seiten.');
    return [
      for (var i = 0; i < sizes.length; i++)
        PageItem(
          id: newId('p'),
          source: PageSource.pdf,
          path: path,
          pdfIndex: i,
          baseWidth: sizes[i].$1,
          baseHeight: sizes[i].$2,
        ),
    ];
  }

  /// Fertig bearbeiteter Scan (JPEG/PNG-Bytes) als Seite in A4-Breite.
  static Future<PageItem> scan(Uint8List bytes, int w, int h, {required bool png}) async {
    final path = await Storage.writeWork(bytes, png ? 'png' : 'jpg');
    const a4w = 595.28;
    return PageItem(
      id: newId('s'),
      source: PageSource.image,
      path: path,
      baseWidth: a4w,
      baseHeight: a4w * h / w,
    );
  }

  /// Bilddatei ohne Bearbeitung (z. B. Foto aus der Galerie, wenn übersprungen).
  static Future<(int, int)> imageSize(Uint8List bytes) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buf);
    final r = (desc.width, desc.height);
    desc.dispose();
    buf.dispose();
    return r;
  }
}
