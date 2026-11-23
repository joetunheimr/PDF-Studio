import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  /// Seitengrößen in Punkt (Drehung der Datei schon berücksichtigt).
  static Future<List<(double, double)>> pdfPageSizes(String path) async {
    final r = await _ch.invokeMethod<Float64List>('pdfInfo', {'path': path});
    if (r == null) return const [];
    return [for (var i = 0; i + 1 < r.length; i += 2) (r[i], r[i + 1])];
  }

  /// Rendert eine PDF-Seite auf weißem Grund; Pixel in RGBA.
  static Future<(int, int, Uint8List)?> pdfRender(
      String path, int index, int width) async {
    final r = await _ch.invokeMapMethod<String, Object?>(
        'pdfRender', {'path': path, 'index': index, 'width': width});
    if (r == null) return null;
    return (r['w'] as int, r['h'] as int, r['px'] as Uint8List);
  }

  /// Schließt geöffnete PDFs im Renderer (ohne Pfad: alle).
  static Future<void> pdfClose([String? path]) async {
    try {
      await _ch.invokeMethod('pdfClose', {'path': path});
    } catch (_) {}
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

  /// Kopie in den Arbeitsordner unter [name]. Liefert den tatsächlich vergebenen Namen.
  static Future<String> saveToDownloads(File file, {String? name}) async {
    try {
      final r = await _ch.invokeMethod<String>('saveToDownloads', {
        'path': file.path,
        'name': name ?? p.basename(file.path),
      });
      return r ?? name ?? p.basename(file.path);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  /// Inhalt des Arbeitsordners, neueste zuerst.
  static Future<List<SavedPdf>> listSaved() async {
    final List<Map<dynamic, dynamic>> r;
    try {
      r = await _ch.invokeListMethod<Map<dynamic, dynamic>>('listSaved') ?? const [];
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
    return [
      for (final m in r)
        SavedPdf(
          id: m['id'] as String,
          name: m['name'] as String,
          size: (m['size'] as num).toInt(),
          modified: DateTime.fromMillisecondsSinceEpoch((m['modified'] as num).toInt()),
        ),
    ];
  }

  /// Kopiert die Datei aus dem Ordner nach [dest] (zum Bearbeiten, Anzeigen, Teilen).
  static Future<File> copySaved(SavedPdf f, String dest) async {
    try {
      await _ch.invokeMethod('copySaved', {'id': f.id, 'dest': dest});
      return File(dest);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  static Future<String> renameSaved(SavedPdf f, String name) async {
    try {
      return await _ch.invokeMethod<String>('renameSaved', {'id': f.id, 'name': name}) ?? name;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  static Future<bool> deleteSaved(SavedPdf f) async {
    try {
      return await _ch.invokeMethod<bool>('deleteSaved', {'id': f.id}) ?? false;
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

/// Eine Datei im Arbeitsordner; [id] ist ihre content://-URI.
class SavedPdf {
  const SavedPdf({required this.id, required this.name, required this.size, required this.modified});
  final String id;
  final String name;
  final int size;
  final DateTime modified;
}

/// Arbeitsordner: Standard „Download/PDF-Studio“ oder ein frei gewählter Ordner.
class WorkFolder {
  const WorkFolder({required this.custom, required this.label, this.lost = false});
  final bool custom;
  final String label;

  /// Ein gewählter Ordner ist nicht mehr erreichbar (Freigabe weg) – es gilt wieder der Standard.
  final bool lost;

  static const standard = WorkFolder(custom: false, label: 'Download/PDF-Studio');

  static WorkFolder _from(Map<dynamic, dynamic>? m) => m == null
      ? standard
      : WorkFolder(custom: m['custom'] == true, label: m['label'] as String, lost: m['lost'] == true);

  /// Aktueller Ordner; Änderungen bekommt die Oberfläche über [current] mit.
  static final current = ValueNotifier<WorkFolder>(standard);

  static Future<WorkFolder> refresh() async {
    try {
      current.value = _from(await NativeBridge._ch.invokeMapMethod('folderInfo'));
    } catch (_) {}
    return current.value;
  }

  /// Öffnet die Ordnerauswahl von Android. null = abgebrochen.
  static Future<WorkFolder?> pick() async {
    try {
      final m = await NativeBridge._ch.invokeMapMethod('pickFolder');
      if (m == null) return null;
      return current.value = _from(m);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  static Future<WorkFolder> reset() async {
    current.value = _from(await NativeBridge._ch.invokeMapMethod('resetFolder'));
    return current.value;
  }
}
