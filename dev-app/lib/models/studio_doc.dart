import 'dart:typed_data';

/// Herkunft einer Seite: Seite aus einer PDF-Datei oder gescanntes Bild (JPEG).
enum PageSource { pdf, image }

enum OverlayKind { text, signature }

/// Ein platziertes Element (Text oder Unterschrift) auf einer Seite.
///
/// Alle Maße sind relativ zur *angezeigten* Seite (inkl. Drehung):
/// [cx]/[cy] = Mittelpunkt (0..1), [widthFrac] = Breite / Seitenbreite.
/// Inhalt ist immer ein PNG mit Transparenz – so sieht der Export exakt aus
/// wie die Vorschau.
class PageOverlay {
  PageOverlay({
    required this.id,
    required this.kind,
    required this.png,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.cx,
    required this.cy,
    required this.widthFrac,
    this.text,
    this.colorValue,
    this.fontPt,
  });

  final String id;
  final OverlayKind kind;
  Uint8List png;
  int pixelWidth;
  int pixelHeight;
  double cx;
  double cy;
  double widthFrac;

  // Nur Text
  String? text;
  int? colorValue;
  double? fontPt;

  double get aspect => pixelWidth / pixelHeight;

  PageOverlay copy() => PageOverlay(
        id: id,
        kind: kind,
        png: png,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        cx: cx,
        cy: cy,
        widthFrac: widthFrac,
        text: text,
        colorValue: colorValue,
        fontPt: fontPt,
      );
}

/// Eine Seite im Dokument.
class PageItem {
  PageItem({
    required this.id,
    required this.source,
    required this.path,
    required this.baseWidth,
    required this.baseHeight,
    this.pdfIndex = 0,
    this.quarterTurns = 0,
    List<PageOverlay>? overlays,
  }) : overlays = overlays ?? [];

  final String id;
  final PageSource source;

  /// PDF-Datei bzw. JPEG-Datei (immer eine Kopie im App-Ordner).
  final String path;
  final int pdfIndex;

  /// Größe in Punkten (1/72 Zoll) ohne die in der App hinzugefügte Drehung.
  final double baseWidth;
  final double baseHeight;

  /// Zusätzliche Drehung im Uhrzeigersinn (0..3).
  int quarterTurns;

  final List<PageOverlay> overlays;

  double get width => quarterTurns.isOdd ? baseHeight : baseWidth;
  double get height => quarterTurns.isOdd ? baseWidth : baseHeight;
  double get aspect => width / height;

  /// Dreht die Seite um 90° (im Uhrzeigersinn, wenn [clockwise]).
  /// Platzierte Elemente wandern mit, bleiben aber aufrecht.
  void rotate({required bool clockwise}) {
    final oldW = width;
    final oldH = height;
    for (final o in overlays) {
      final x = o.cx, y = o.cy;
      if (clockwise) {
        o.cx = 1 - y;
        o.cy = x;
      } else {
        o.cx = y;
        o.cy = 1 - x;
      }
      // Gleiche absolute Breite behalten
      o.widthFrac = (o.widthFrac * oldW / oldH).clamp(0.03, 1.0);
    }
    quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4;
  }

  PageItem copy({String? newId}) => PageItem(
        id: newId ?? id,
        source: source,
        path: path,
        baseWidth: baseWidth,
        baseHeight: baseHeight,
        pdfIndex: pdfIndex,
        quarterTurns: quarterTurns,
        overlays: overlays.map((o) => o.copy()).toList(),
      );
}

/// Das gerade bearbeitete Dokument.
class StudioDoc {
  StudioDoc({required this.name, List<PageItem>? pages}) : pages = pages ?? [];

  String name;
  final List<PageItem> pages;
  bool dirty = false;
}

int _idCounter = 0;
String newId(String prefix) =>
    '$prefix${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';
