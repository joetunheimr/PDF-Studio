import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/studio_doc.dart';
import '../services/importer.dart';
import 'camera_screen.dart';
import 'scan_edit_screen.dart';

/// Gemeinsame Abläufe: scannen, Fotos holen, PDFs wählen.
class Flows {
  static Future<List<PageItem>?> scan(BuildContext context) async {
    final shots = await CameraScreen.open(context);
    if (shots == null || shots.isEmpty || !context.mounted) return null;
    return ScanEditScreen.open(context, shots);
  }

  static Future<List<PageItem>?> photos(BuildContext context) async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: 100);
    if (picked.isEmpty || !context.mounted) return null;
    return ScanEditScreen.open(context, picked.map((e) => e.path).toList());
  }

  /// Ein oder mehrere PDFs wählen; Seiten in Auswahlreihenfolge.
  static Future<(List<PageItem>, String?)?> pdfs(BuildContext context,
      {bool multiple = true}) async {
    final List<PlatformFile> files;
    if (multiple) {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
    } else {
      final f = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      files = [?f];
    }
    if (files.isEmpty || !context.mounted) return null;
    final picked = [for (final f in files) if (f.path != null) f];
    return importPaths(
      context,
      [for (final f in picked) f.path!],
      names: [for (final f in picked) f.name],
    );
  }

  static Future<(List<PageItem>, String?)?> importPaths(
    BuildContext context,
    List<String> paths, {
    List<String>? names,
  }) async {
    final pages = <PageItem>[];
    final errors = <String>[];
    for (var i = 0; i < paths.length; i++) {
      try {
        pages.addAll(await Importer.pdf(paths[i]));
      } catch (e) {
        errors.add('${names?[i] ?? paths[i].split('/').last}: $e');
      }
    }
    if (errors.isNotEmpty && context.mounted) {
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Nicht alles konnte geöffnet werden'),
          content: Text(errors.join('\n\n')),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      );
    }
    if (pages.isEmpty) return null;
    String? name;
    if (names != null && names.isNotEmpty) {
      name = names.first.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      if (names.length > 1) name = '$name + ${names.length - 1}';
    }
    return (pages, name);
  }

  static String scanName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Scan ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}.${two(n.minute)}';
  }
}
