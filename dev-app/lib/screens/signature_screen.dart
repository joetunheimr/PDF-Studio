import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage.dart';
import '../theme.dart';

class SignatureResult {
  SignatureResult(this.png, this.width, this.height);
  final Uint8List png;
  final int width;
  final int height;
}

/// Auswahl gespeicherter Unterschriften oder neu zeichnen.
class SignaturePicker {
  static Future<SignatureResult?> pick(BuildContext context) async {
    final files = Storage.signatureFiles();
    if (files.isEmpty) return _draw(context);
    return showModalBottomSheet<SignatureResult>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _PickerSheet(initial: files),
    );
  }

  static Future<SignatureResult?> _draw(BuildContext context) =>
      Navigator.of(context).push<SignatureResult>(
        MaterialPageRoute(builder: (_) => const SignatureScreen(), fullscreenDialog: true),
      );
}

Future<SignatureResult> _fromFile(File f) async {
  final bytes = await f.readAsBytes();
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final d = await ui.ImageDescriptor.encoded(buf);
  final r = SignatureResult(bytes, d.width, d.height);
  d.dispose();
  buf.dispose();
  return r;
}

class _PickerSheet extends StatefulWidget {
  const _PickerSheet({required this.initial});
  final List<File> initial;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  late List<File> _files = widget.initial;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Unterschrift wählen', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 2.2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: _files.length,
                itemBuilder: (_, i) => Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () async {
                      final r = await _fromFile(_files[i]);
                      if (context.mounted) Navigator.pop(context, r);
                    },
                    onLongPress: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Unterschrift löschen?'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Abbrechen')),
                            FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Löschen')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        _files[i].deleteSync();
                        setState(() => _files = Storage.signatureFiles());
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Image.file(_files[i], fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('Lange drücken zum Löschen',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                final r = await SignaturePicker._draw(context);
                if (r != null && context.mounted) Navigator.pop(context, r);
              },
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Neue Unterschrift zeichnen'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stroke {
  _Stroke(this.color, this.width);
  final Color color;
  final double width;
  final points = <Offset>[];
}

/// Zeichenfläche für die Unterschrift.
class SignatureScreen extends StatefulWidget {
  const SignatureScreen({super.key});

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  final _strokes = <_Stroke>[];
  Color _color = StudioColors.penBlue;
  double _width = 3.2;
  bool _save = true;
  Size _canvas = Size.zero;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    super.dispose();
  }

  Future<void> _done() async {
    if (_strokes.isEmpty) return;
    // Begrenzungsrahmen der Striche
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final s in _strokes) {
      for (final p in s.points) {
        minX = math.min(minX, p.dx - s.width);
        minY = math.min(minY, p.dy - s.width);
        maxX = math.max(maxX, p.dx + s.width);
        maxY = math.max(maxY, p.dy + s.width);
      }
    }
    const scale = 4.0;
    const pad = 6.0;
    final w = ((maxX - minX + pad * 2) * scale).ceil();
    final h = ((maxY - minY + pad * 2) * scale).ceil();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(scale);
    canvas.translate(-minX + pad, -minY + pad);
    _paintStrokes(canvas, _strokes);
    final pic = rec.endRecording();
    final im = await pic.toImage(w, h);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    pic.dispose();
    im.dispose();
    final png = bd!.buffer.asUint8List();
    if (_save) await Storage.saveSignature(png);
    if (mounted) Navigator.pop(context, SignatureResult(png, w, h));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unterschreiben'),
        actions: [
          IconButton(
            tooltip: 'Rückgängig',
            icon: const Icon(Icons.undo),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
          ),
          IconButton(
            tooltip: 'Leeren',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _strokes.isEmpty ? null : _done,
              icon: const Icon(Icons.check),
              label: const Text('Übernehmen'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            // Werkzeuge
            SizedBox(
              width: 76,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in StudioColors.pens.take(3))
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: GestureDetector(
                        onTap: () => setState(() => _color = c),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _color == c ? StudioColors.coral : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  for (final w in const [2.2, 3.2, 4.6])
                    IconButton(
                      isSelected: _width == w,
                      onPressed: () => setState(() => _width = w),
                      icon: Container(
                        width: 26,
                        height: w * 1.6,
                        decoration: BoxDecoration(
                          color: _width == w ? StudioColors.coral : Colors.grey,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 16, 8),
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.black12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: LayoutBuilder(builder: (context, c) {
                          _canvas = c.biggest;
                          return GestureDetector(
                            onPanStart: (d) => setState(() {
                              _strokes.add(_Stroke(_color, _width)..points.add(d.localPosition));
                            }),
                            onPanUpdate: (d) => setState(() {
                              _strokes.last.points.add(d.localPosition);
                            }),
                            child: CustomPaint(
                              size: _canvas,
                              painter: _SigPainter(_strokes),
                              child: _strokes.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.gesture, size: 40, color: Colors.grey.shade400),
                                          const SizedBox(height: 6),
                                          Text('Hier unterschreiben',
                                              style: TextStyle(color: Colors.grey.shade500)),
                                        ],
                                      ),
                                    )
                                  : null,
                            ),
                          );
                        }),
                      ),
                    ),
                    Row(
                      children: [
                        Checkbox(value: _save, onChanged: (v) => setState(() => _save = v ?? true)),
                        const Text('Für später speichern'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _paintStrokes(Canvas canvas, List<_Stroke> strokes) {
  for (final s in strokes) {
    final paint = Paint()
      ..color = s.color
      ..strokeWidth = s.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final p = s.points;
    if (p.length == 1) {
      canvas.drawCircle(p.first, s.width / 2, paint..style = PaintingStyle.fill);
      continue;
    }
    // geglättete Linie durch die Mittelpunkte
    final path = Path()..moveTo(p.first.dx, p.first.dy);
    for (var i = 1; i < p.length - 1; i++) {
      final mid = (p[i] + p[i + 1]) / 2;
      path.quadraticBezierTo(p[i].dx, p[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(p.last.dx, p.last.dy);
    canvas.drawPath(path, paint);
  }
}

class _SigPainter extends CustomPainter {
  _SigPainter(this.strokes);
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    // Unterschriftslinie
    final y = size.height * 0.72;
    canvas.drawLine(
      Offset(size.width * 0.08, y),
      Offset(size.width * 0.92, y),
      Paint()
        ..color = Colors.black12
        ..strokeWidth = 1.5,
    );
    _paintStrokes(canvas, strokes);
  }

  @override
  bool shouldRepaint(covariant _SigPainter old) => true;
}

/// Text als transparentes PNG (4 px pro PDF-Punkt ≈ 288 dpi).
Future<SignatureResult> renderTextPng({
  required String text,
  required Color color,
  required double fontPt,
  bool bold = false,
}) async {
  const scale = 4.0;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontPt * scale,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        height: 1.2,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final pad = fontPt * scale * 0.15;
  final w = (tp.width + pad * 2).ceil();
  final h = (tp.height + pad * 2).ceil();
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  tp.paint(canvas, Offset(pad, pad));
  final pic = rec.endRecording();
  final im = await pic.toImage(w, h);
  final bd = await im.toByteData(format: ui.ImageByteFormat.png);
  pic.dispose();
  im.dispose();
  return SignatureResult(bd!.buffer.asUint8List(), w, h);
}
