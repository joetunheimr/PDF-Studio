import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/studio_doc.dart';
import '../services/importer.dart';
import '../services/scan_processing.dart';
import '../theme.dart';

const _previewSide = 1100;
const _fullSide = 3200;
const _outSide = 2600;

/// Lädt ein Foto (EXIF-Drehung wird von Flutter berücksichtigt) und
/// verkleinert es auf höchstens [maxSide] Pixel.
Future<RawRgba> loadRgba(String path, int maxSide) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final full = (await codec.getNextFrame()).image;
  codec.dispose();
  ui.Image im = full;
  final long = full.width > full.height ? full.width : full.height;
  if (long > maxSide) {
    final s = maxSide / long;
    final w = (full.width * s).round(), h = (full.height * s).round();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawImageRect(
      full,
      Rect.fromLTWH(0, 0, full.width.toDouble(), full.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final pic = rec.endRecording();
    im = await pic.toImage(w, h);
    pic.dispose();
    full.dispose();
  }
  final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
  final r = RawRgba(bd!.buffer.asUint8List(), im.width, im.height);
  im.dispose();
  return r;
}

Future<ui.Image> rgbaToImage(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class _Shot {
  _Shot(this.path);
  final String path;
  RawRgba? preview;
  ui.Image? previewImage;
  ui.Image? result;
  List<double> corners = List.of(defaultCorners);
  ScanFilter filter = ScanFilter.enhanced;
  double brightness = 0;
  double contrast = 0;
  int turns = 0;
  bool autoFound = false;
}

/// Zuschnitt (Ecken), Filter, Helligkeit/Kontrast und Drehung für Scans.
class ScanEditScreen extends StatefulWidget {
  const ScanEditScreen({super.key, required this.paths});
  final List<String> paths;

  static Future<List<PageItem>?> open(BuildContext context, List<String> paths) => Navigator.of(
    context,
  ).push<List<PageItem>>(MaterialPageRoute(builder: (_) => ScanEditScreen(paths: paths)));

  @override
  State<ScanEditScreen> createState() => _ScanEditScreenState();
}

class _ScanEditScreenState extends State<ScanEditScreen> {
  late final List<_Shot> _shots = widget.paths.map(_Shot.new).toList();
  int _index = 0;
  bool _cropMode = true;
  Timer? _debounce;
  int _job = 0;
  bool _processing = false;

  _Shot get _cur => _shots[_index];

  @override
  void initState() {
    super.initState();
    _prepare(_cur);
    // die übrigen im Hintergrund vorbereiten
    Future(() async {
      for (final s in _shots.skip(1)) {
        if (!mounted) return;
        await _prepare(s);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final s in _shots) {
      s.previewImage?.dispose();
      s.result?.dispose();
    }
    super.dispose();
  }

  Future<void> _prepare(_Shot s) async {
    if (s.preview != null) return;
    try {
      final raw = await loadRgba(s.path, _previewSide);
      s.preview = raw;
      s.previewImage = await rgbaToImage(raw.bytes, raw.width, raw.height);
      final found = await compute(detectDocument, raw);
      if (found != null) {
        s.corners = found;
        s.autoFound = true;
      }
      if (mounted) setState(() {});
      if (identical(s, _cur) && !_cropMode) _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Foto konnte nicht geladen werden: $e')));
      }
    }
  }

  void _refresh({bool now = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: now ? 0 : 110), _runPreview);
  }

  Future<void> _runPreview() async {
    final s = _cur;
    final raw = s.preview;
    if (raw == null) return;
    final id = ++_job;
    setState(() => _processing = true);
    final r = await compute(
      processScan,
      ScanJob(
        src: raw,
        corners: s.corners,
        filter: s.filter,
        brightness: s.brightness,
        contrast: s.contrast,
        quarterTurns: s.turns,
        maxSide: _previewSide,
      ),
    );
    final im = await rgbaToImage(r.rgba!, r.width, r.height);
    if (!mounted || id != _job) {
      im.dispose();
      return;
    }
    setState(() {
      s.result?.dispose();
      s.result = im;
      _processing = false;
    });
  }

  void _select(int i) {
    setState(() => _index = i);
    _prepare(_cur);
    if (!_cropMode) _refresh(now: true);
  }

  void _setMode(bool crop) {
    setState(() => _cropMode = crop);
    if (!crop) _refresh(now: true);
  }

  Future<void> _removeCurrent() async {
    if (_shots.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      final s = _shots.removeAt(_index);
      s.previewImage?.dispose();
      s.result?.dispose();
      if (_index >= _shots.length) _index = _shots.length - 1;
    });
    if (!_cropMode) _refresh(now: true);
  }

  void _applyToAll() {
    final c = _cur;
    for (final s in _shots) {
      s.filter = c.filter;
      s.brightness = c.brightness;
      s.contrast = c.contrast;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Filter für alle ${_shots.length} Seiten übernommen')));
  }

  Future<void> _finish() async {
    final progress = ValueNotifier<int>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, v, _) => Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(child: Text('Seite ${v + 1} von ${_shots.length} wird erstellt …')),
              ],
            ),
          ),
        ),
      ),
    );
    final pages = <PageItem>[];
    try {
      for (var i = 0; i < _shots.length; i++) {
        progress.value = i;
        final s = _shots[i];
        final raw = await loadRgba(s.path, _fullSide);
        final r = await compute(
          processScan,
          ScanJob(
            src: raw,
            corners: s.corners,
            filter: s.filter,
            brightness: s.brightness,
            contrast: s.contrast,
            quarterTurns: s.turns,
            maxSide: _outSide,
            encode: true,
          ),
        );
        pages.add(await Importer.scan(r.fileBytes!, r.width, r.height, png: r.isPng));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler beim Erstellen: $e')));
      }
      return;
    }
    if (!mounted) return;
    Navigator.pop(context); // Dialog
    Navigator.pop(context, pages);
  }

  @override
  Widget build(BuildContext context) {
    final s = _cur;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0F1018),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1018),
        foregroundColor: Colors.white,
        title: Text(
          _shots.length == 1 ? 'Scan bearbeiten' : 'Seite ${_index + 1} von ${_shots.length}',
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: 'Dieses Foto entfernen',
            icon: const Icon(Icons.delete_outline),
            onPressed: _removeCurrent,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: StudioColors.coral,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              onPressed: _shots.every((e) => e.preview != null) ? _finish : null,
              icon: const Icon(Icons.check, size: 20),
              label: const Text('Fertig'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SegmentedButton<bool>(
              style: SegmentedButton.styleFrom(
                foregroundColor: Colors.white70,
                selectedForegroundColor: Colors.white,
                selectedBackgroundColor: StudioColors.ink,
                side: const BorderSide(color: Colors.white24),
              ),
              segments: const [
                ButtonSegment(value: true, icon: Icon(Icons.crop_free), label: Text('Zuschneiden')),
                ButtonSegment(value: false, icon: Icon(Icons.tune), label: Text('Filter')),
              ],
              selected: {_cropMode},
              onSelectionChanged: (v) => _setMode(v.first),
            ),
          ),
          Expanded(
            child: s.previewImage == null
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : _cropMode
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: CornerEditor(
                      key: ValueKey(s.path),
                      image: s.previewImage!,
                      corners: s.corners,
                      onChanged: (c) => setState(() => s.corners = c),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (s.result != null)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20),
                                ],
                              ),
                              child: RawImage(image: s.result, fit: BoxFit.contain),
                            ),
                          if (_processing && s.result == null)
                            const CircularProgressIndicator(color: Colors.white),
                        ],
                      ),
                    ),
                  ),
          ),
          if (s.previewImage != null) (_cropMode ? _cropTools(s) : _filterTools(s, scheme)),
          if (_shots.length > 1) _strip(),
          SizedBox(height: MediaQuery.paddingOf(context).bottom + 6),
        ],
      ),
    );
  }

  Widget _cropTools(_Shot s) {
    Widget btn(IconData i, String l, VoidCallback f) => TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: Colors.white),
      onPressed: f,
      icon: Icon(i, size: 20),
      label: Text(l),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        children: [
          btn(Icons.auto_fix_high, 'Automatisch', () async {
            final f = await compute(detectDocument, s.preview!);
            if (!mounted) return;
            setState(() => s.corners = f ?? List.of(defaultCorners));
            if (f == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Kein Dokumentrand erkannt – bitte Ecken ziehen.')),
              );
            }
          }),
          btn(Icons.fullscreen, 'Ganzes Bild', () => setState(() => s.corners = List.of(fullCorners))),
          btn(Icons.arrow_forward, 'Weiter zu Filter', () => _setMode(false)),
        ],
      ),
    );
  }

  Widget _filterTools(_Shot s, ColorScheme scheme) {
    const white = TextStyle(color: Colors.white70, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final f in ScanFilter.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(f.label),
                      avatar: Icon(switch (f) {
                        ScanFilter.original => Icons.image_outlined,
                        ScanFilter.enhanced => Icons.auto_awesome,
                        ScanFilter.gray => Icons.gradient,
                        ScanFilter.bw => Icons.contrast,
                      }, size: 18),
                      selected: s.filter == f,
                      onSelected: (_) {
                        setState(() => s.filter = f);
                        _refresh(now: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 6),
              const Icon(Icons.light_mode_outlined, color: Colors.white70, size: 20),
              const SizedBox(width: 6),
              const SizedBox(width: 74, child: Text('Helligkeit', style: white)),
              Expanded(
                child: Slider(
                  value: s.brightness,
                  min: -1,
                  max: 1,
                  divisions: 40,
                  label: (s.brightness * 100).round().toString(),
                  onChanged: (v) {
                    setState(() => s.brightness = v);
                    _refresh();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 6),
              const Icon(Icons.contrast, color: Colors.white70, size: 20),
              const SizedBox(width: 6),
              const SizedBox(width: 74, child: Text('Kontrast', style: white)),
              Expanded(
                child: Slider(
                  value: s.contrast,
                  min: -1,
                  max: 1,
                  divisions: 40,
                  label: (s.contrast * 100).round().toString(),
                  onChanged: (v) {
                    setState(() => s.contrast = v);
                    _refresh();
                  },
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              IconButton(
                color: Colors.white,
                tooltip: 'Nach links drehen',
                icon: const Icon(Icons.rotate_left),
                onPressed: () {
                  setState(() => s.turns = (s.turns + 3) % 4);
                  _refresh(now: true);
                },
              ),
              IconButton(
                color: Colors.white,
                tooltip: 'Nach rechts drehen',
                icon: const Icon(Icons.rotate_right),
                onPressed: () {
                  setState(() => s.turns = (s.turns + 1) % 4);
                  _refresh(now: true);
                },
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                onPressed: () {
                  setState(() {
                    s.brightness = 0;
                    s.contrast = 0;
                  });
                  _refresh(now: true);
                },
                child: const Text('Zurücksetzen'),
              ),
              if (_shots.length > 1)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: _applyToAll,
                  child: const Text('Auf alle anwenden'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _strip() {
    return SizedBox(
      height: 74,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        scrollDirection: Axis.horizontal,
        itemCount: _shots.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final sel = i == _index;
          return GestureDetector(
            onTap: () => _select(i),
            child: Container(
              width: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: sel ? StudioColors.coral : Colors.white24, width: sel ? 3 : 1),
                image: DecorationImage(
                  image: ResizeImage(FileImage(File(_shots[i].path)), width: 120),
                  fit: BoxFit.cover,
                ),
              ),
              alignment: Alignment.bottomRight,
              child: Container(
                margin: const EdgeInsets.all(2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.black54,
                child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Bild mit vier verschiebbaren Ecken (und Kantenmitten) samt Lupe.
class CornerEditor extends StatefulWidget {
  const CornerEditor({super.key, required this.image, required this.corners, required this.onChanged});

  final ui.Image image;
  final List<double> corners;
  final ValueChanged<List<double>> onChanged;

  @override
  State<CornerEditor> createState() => _CornerEditorState();
}

class _CornerEditorState extends State<CornerEditor> {
  int? _drag; // 0..3 Ecke, 4..7 Kante
  Offset? _finger;
  Offset _grabOffset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
        final s = (c.maxWidth / iw) < (c.maxHeight / ih) ? c.maxWidth / iw : c.maxHeight / ih;
        final w = iw * s, h = ih * s;
        final ox = (c.maxWidth - w) / 2, oy = (c.maxHeight - h) / 2;
        final rect = Rect.fromLTWH(ox, oy, w, h);

        Offset pt(int i) => Offset(ox + widget.corners[i * 2] * w, oy + widget.corners[i * 2 + 1] * h);
        List<Offset> handles() {
          final p = [for (var i = 0; i < 4; i++) pt(i)];
          return [...p, for (var i = 0; i < 4; i++) (p[i] + p[(i + 1) % 4]) / 2];
        }

        void move(Offset pos) {
          final list = List.of(widget.corners);
          final target = pos - _grabOffset;
          double nx(double x) => ((x - ox) / w).clamp(0.0, 1.0);
          double ny(double y) => ((y - oy) / h).clamp(0.0, 1.0);
          final d = _drag!;
          if (d < 4) {
            list[d * 2] = nx(target.dx);
            list[d * 2 + 1] = ny(target.dy);
          } else {
            final a = d - 4, b = (d - 3) % 4;
            final mid = (pt(a) + pt(b)) / 2;
            final delta = target - mid;
            for (final k in [a, b]) {
              final p = pt(k) + delta;
              list[k * 2] = nx(p.dx);
              list[k * 2 + 1] = ny(p.dy);
            }
          }
          widget.onChanged(list);
        }

        final hs = handles();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            var best = -1;
            var bestDist = 46.0;
            for (var i = 0; i < hs.length; i++) {
              final dist = (hs[i] - d.localPosition).distance;
              if (dist < bestDist - (i < 4 ? 6 : 0)) {
                best = i;
                bestDist = dist;
              }
            }
            if (best < 0) return;
            HapticFeedback.selectionClick();
            setState(() {
              _drag = best;
              _grabOffset = d.localPosition - hs[best];
              _finger = d.localPosition;
            });
          },
          onPanUpdate: (d) {
            if (_drag == null) return;
            setState(() => _finger = d.localPosition);
            move(d.localPosition);
          },
          onPanEnd: (_) => setState(() {
            _drag = null;
            _finger = null;
          }),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fromRect(
                rect: rect,
                child: RawImage(image: widget.image, fit: BoxFit.fill),
              ),
              Positioned.fill(child: CustomPaint(painter: _QuadPainter(hs, rect, _drag))),
              if (_drag != null && _drag! < 4 && _finger != null) _loupe(hs[_drag!], c),
            ],
          ),
        );
      },
    );
  }

  static const _loupeSize = 130.0;

  /// Lupe in der gegenüberliegenden Ecke der Fläche: Finger links -> Lupe rechts,
  /// Finger oben -> Lupe unten. So verdeckt weder der Finger die Lupe noch die Lupe die Ecke.
  Widget _loupe(Offset p, BoxConstraints c) {
    const m = 12.0, d = _loupeSize;
    final left = p.dx < c.maxWidth / 2 ? c.maxWidth - d - m : m;
    final top = p.dy < c.maxHeight / 2 ? c.maxHeight - d - m : m;
    return Positioned(
      left: left,
      top: top,
      child: RawMagnifier(
        size: const Size(d, d),
        magnificationScale: 2.5,
        focalPointOffset: Offset(p.dx - (left + d / 2), p.dy - (top + d / 2)),
        decoration: MagnifierDecoration(
          shape: const CircleBorder(side: BorderSide(color: Colors.white, width: 3)),
          shadows: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 12)],
        ),
        child: const CustomPaint(size: Size(d, d), painter: _CrosshairPainter()),
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.h, this.img, this.active);
  final List<Offset> h;
  final Rect img;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final quad = Path()..addPolygon(h.sublist(0, 4), true);
    final outside = Path.combine(PathOperation.difference, Path()..addRect(img), quad);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
    // Beim Ziehen einer Ecke dünne Linien, damit die Lupe die Papierkante zeigt
    final cornerDrag = active != null && active! < 4;
    canvas.drawPath(
      quad,
      Paint()
        ..color = StudioColors.coral
        ..style = PaintingStyle.stroke
        ..strokeWidth = cornerDrag ? 1.0 : 2.5,
    );
    if (!cornerDrag) {
      canvas.drawPath(quad, Paint()..color = StudioColors.coral.withValues(alpha: 0.08));
    }
    for (var i = 0; i < h.length; i++) {
      final corner = i < 4;
      final on = active == i;
      // Die gezogene Ecke nicht zeichnen – sonst verdeckt der Greifer sie in der Lupe
      if (corner && on) continue;
      if (corner) {
        canvas.drawCircle(h[i], on ? 17 : 14, Paint()..color = Colors.white);
        canvas.drawCircle(
          h[i],
          on ? 17 : 14,
          Paint()
            ..color = StudioColors.coral
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      } else {
        final r = RRect.fromRectAndRadius(
          Rect.fromCenter(center: h[i], width: 22, height: 22),
          const Radius.circular(6),
        );
        canvas.drawRRect(r, Paint()..color = Colors.white.withValues(alpha: on ? 1 : 0.85));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) => true;
}

/// Feines Fadenkreuz in der Lupe: dünne Linien mit Lücke in der Mitte,
/// hell umrandet, damit es auf hellem und dunklem Grund sichtbar ist.
class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const gap = 4.0;
    const len = 16.0;
    final segs = [
      (c + const Offset(-gap - len, 0), c + const Offset(-gap, 0)),
      (c + const Offset(gap, 0), c + const Offset(gap + len, 0)),
      (c + const Offset(0, -gap - len), c + const Offset(0, -gap)),
      (c + const Offset(0, gap), c + const Offset(0, gap + len)),
    ];
    final halo = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = StudioColors.coral
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in segs) {
      canvas.drawLine(a, b, halo);
    }
    for (final (a, b) in segs) {
      canvas.drawLine(a, b, line);
    }
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter old) => false;
}
