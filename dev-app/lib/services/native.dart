import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../models/studio_doc.dart';
import 'storage.dart';

/// Brücke zum Kotlin-Teil (PDFBox): Export, Downloads, geteilte PDFs.
class NativeBridge {
  static const _ch = MethodChannel('de.w3dk.pdf_studio/native');

  /// PDFs, die per „Öffnen mit“ / „Teilen“ an die App geschickt wurden.
  static final incoming = StreamController<List<String>>.broadcast();

  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'incoming') {
        final paths = (call.arguments as List).cast<String>();
        if (paths.isNotEmpty) incoming.add(paths);
      }
      return null;
    });
  }

  /// PDF-Pfade, mit denen die App gestartet wurde (einmalig).
  static Future<List<String>> takeInitialPdfs() async {
    try {
      final r = await _ch.invokeMethod<List<dynamic>>('takeIncoming');
      return (r ?? const []).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Baut das fertige PDF. Original-PDF-Seiten bleiben dabei Vektor/Text –
  /// sie werden nur übernommen, gedreht und mit den Elementen beschriftet.
  static Future<File> exportPdf(StudioDoc doc, File out) async {
    final tmpFiles = <File>[];
    try {
      final pages = <Map<String, Object?>>[];
      for (final pg in doc.pages) {
        final overlays = <Map<String, Object?>>[];
        for (final o in pg.overlays) {
          final f = File(Storage.newWorkPath('png'));
          await f.writeAsBytes(o.png, flush: true);
          tmpFiles.add(f);
          final hFrac = o.widthFrac * pg.width / o.aspect / pg.height;
          overlays.add({
            'png': f.path,
            'x': o.cx - o.widthFrac / 2,
            'y': o.cy - hFrac / 2,
            'w': o.widthFrac,
            'h': hFrac,
          });
        }
        pages.add({
          'type': pg.source == PageSource.pdf ? 'pdf' : 'image',
          'path': pg.path,
          'index': pg.pdfIndex,
          'wPt': pg.baseWidth,
          'hPt': pg.baseHeight,
          'rotate': pg.quarterTurns * 90,
          'overlays': overlays,
        });
      }
      final spec = jsonEncode({
        'title': doc.name,
        'pages': pages,
      });
      final tmpOut = '${out.path}.part';
      await _ch.invokeMethod<String>('export', {
        'spec': spec,
        'out': tmpOut,
      });
      final f = File(tmpOut);
      if (!f.existsSync() || f.lengthSync() == 0) {
        throw StateError('Das PDF konnte nicht erstellt werden.');
      }
      return f.renameSync(out.path);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    } finally {
      for (final f in tmpFiles) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Kopie in „Download/PDF-Studio“. Liefert den sichtbaren Pfad.
  static Future<String?> saveToDownloads(File file) async {
    try {
      return await _ch.invokeMethod<String>('saveToDownloads', {
        'path': file.path,
        'name': p.basename(file.path),
      });
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  static Future<void> share(File file) async {
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf')],
      subject: p.basenameWithoutExtension(file.path),
    ));
  }

  /// Öffnet das PDF in einer anderen App (Ansicht).
  static Future<bool> openExternal(File file) async {
    try {
      return await _ch.invokeMethod<bool>('openExternal', {'path': file.path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
