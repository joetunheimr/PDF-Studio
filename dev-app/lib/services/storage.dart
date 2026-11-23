import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Ordner der App:
///   work/        Kopien importierter PDFs und gescannter Seiten
///   saved/       gespeicherte Ergebnisse (Liste „Zuletzt gespeichert“)
///   signatures/  gespeicherte Unterschriften (PNG)
class Storage {
  static late Directory _root;

  static Future<void> init() async {
    _root = await getApplicationDocumentsDirectory();
    for (final d in [work, saved, signatures]) {
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

  /// Gespeicherte PDFs, neueste zuerst.
  static List<File> savedFiles() {
    final files = saved
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  static File uniqueSaved(String baseName) {
    final base = safeName(baseName);
    var f = File(p.join(saved.path, '$base.pdf'));
    var i = 2;
    while (f.existsSync()) {
      f = File(p.join(saved.path, '$base ($i).pdf'));
      i++;
    }
    return f;
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
