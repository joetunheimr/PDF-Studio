import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Ordner der App:
///   work/        Kopien importierter PDFs und gescannter Seiten
///   work/out/    Kopien zum Anzeigen/Teilen (mit echtem Dateinamen)
///   saved/       nur noch Altbestand bis 1.0.2; wird nach Download/PDF-Studio übernommen
///   signatures/  gespeicherte Unterschriften (PNG)
class Storage {
  static late Directory _root;

  static Future<void> init() async {
    _root = await getApplicationDocumentsDirectory();
    for (final d in [work, signatures]) {
      if (!d.existsSync()) d.createSync(recursive: true);
    }
  }

  static Directory get work => Directory(p.join(_root.path, 'work'));
  static Directory get saved => Directory(p.join(_root.path, 'saved'));
  static Directory get signatures => Directory(p.join(_root.path, 'signatures'));

  static String newWorkPath(String ext) => p.join(
      work.path, 'w${DateTime.now().microsecondsSinceEpoch}.$ext');

  /// Kopiert eine fremde Datei in den Arbeitsordner (Quelle bleibt unberührt).
  static Future<String> importCopy(String sourcePath) async {
    final ext = p.extension(sourcePath).replaceFirst('.', '').toLowerCase();
    final dest = newWorkPath(ext.isEmpty ? 'pdf' : ext);
    await File(sourcePath).copy(dest);
    return dest;
  }

  static Future<String> writeWork(Uint8List bytes, String ext) async {
    final dest = newWorkPath(ext);
    await File(dest).writeAsBytes(bytes, flush: true);
    return dest;
  }

  /// Altbestand (bis 1.0.2 lag die Liste der Startseite in saved/).
  static List<File> legacySaved() {
    if (!saved.existsSync()) return const [];
    return saved
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList();
  }

  /// Datei mit echtem Namen in work/out; ältere Kopien (> 1 h) werden dabei aufgeräumt.
  static File outFile(String name) {
    final dir = Directory(p.join(work.path, 'out'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    try {
      for (final e in dir.listSync()) {
        if (e is File && DateTime.now().difference(e.lastModifiedSync()).inHours >= 1) e.deleteSync();
      }
    } catch (_) {}
    return File(p.join(dir.path, name));
  }

  /// „Name.pdf“, ggf. „Name (2).pdf“ …, das in [existing] (klein geschrieben) noch nicht vorkommt.
  static String uniqueName(String baseName, Set<String> existing) {
    final base = safeName(baseName);
    var n = '$base.pdf';
    var i = 2;
    while (existing.contains(n.toLowerCase())) {
      n = '$base ($i).pdf';
      i++;
    }
    return n;
  }

  static List<File> signatureFiles() {
    final files = signatures
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  static Future<File> saveSignature(Uint8List png) async {
    final f = File(p.join(
        signatures.path, 'sig${DateTime.now().millisecondsSinceEpoch}.png'));
    await f.writeAsBytes(png, flush: true);
    return f;
  }

  /// Arbeitsdateien aufräumen, die von keinem offenen Dokument mehr gebraucht werden.
  static Future<void> cleanWork({Set<String> keep = const {}}) async {
    try {
      for (final e in work.listSync()) {
        if (e is File && !keep.contains(e.path)) {
          final age = DateTime.now().difference(e.lastModifiedSync());
          if (age.inHours >= 12) e.deleteSync();
        }
      }
    } catch (_) {}
  }

  static String safeName(String s) {
    var n = s.trim();
    if (n.toLowerCase().endsWith('.pdf')) n = n.substring(0, n.length - 4);
    n = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    if (n.isEmpty) n = 'Dokument';
    if (n.length > 80) n = n.substring(0, 80);
    return n;
  }
}
