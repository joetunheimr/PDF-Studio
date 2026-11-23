import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/studio_doc.dart';
import '../theme.dart';
import '../widgets/page_render.dart';
import 'signature_screen.dart';

/// Einzelne Seite bearbeiten: Text, Unterschrift und Datum platzieren.
class PageEditScreen extends StatefulWidget {
  const PageEditScreen({super.key, required this.doc, required this.initialIndex});
  final StudioDoc doc;
  final int initialIndex;

  static Future<void> open(BuildContext context, StudioDoc doc, int index) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PageEditScreen(doc: doc, initialIndex: index)),
      );

  @override
  State<PageEditScreen> createState() => _PageEditScreenState();
}

class _PageEditScreenState extends State<PageEditScreen> {
  late int _index = widget.initialIndex;
  String? _selected;

  // Gesten
  Offset? _startFocal;
  double _startCx = 0, _startCy = 0, _startW = 0;
  bool _manipulating = false;

  PageItem get _page => widget.doc.pages[_index];

  PageOverlay? get _sel {
    for (final o in _page.overlays) {
      if (o.id == _selected) return o;
    }
    return null;
  }

  void _changed() {
    widget.doc.dirty = true;
    setState(() {});
  }

  // ---------------------------------------------------------------- Hinzufügen

  Future<void> _addText({PageOverlay? edit}) async {
    final r = await showModalBottomSheet<_TextSpec>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TextSheet(
        initial: edit == null
            ? null
            : _TextSpec(
                edit.text ?? '',
                Color(edit.colorValue ?? StudioColors.penBlack.toARGB32()),
                _effectiveFont(edit),
                false,
              ),
      ),
    );
    if (r == null || r.text.trim().isEmpty) return;
    await _placeText(r, edit: edit);
  }

  double _effectiveFont(PageOverlay o) {
    // Schriftgröße inkl. späterer Größenänderung per Zwei-Finger-Geste
    final natW = o.pixelWidth / 4.0;
    final shown = o.widthFrac * _page.width;
    return ((o.fontPt ?? 14) * shown / natW).clamp(4, 200).toDouble();
  }

  Future<void> _placeText(_TextSpec r, {PageOverlay? edit}) async {
    final png = await renderTextPng(text: r.text, color: r.color, fontPt: r.fontPt, bold: r.bold);
    var wf = (png.width / 4.0) / _page.width;
    if (wf > 0.95) wf = 0.95;
    if (edit != null) {
      edit
        ..png = png.png
        ..pixelWidth = png.width
        ..pixelHeight = png.height
        ..widthFrac = wf
        ..text = r.text
        ..colorValue = r.color.toARGB32()
        ..fontPt = r.fontPt;
      _clampInside(edit);
    } else {
      final o = PageOverlay(
        id: newId('o'),
        kind: OverlayKind.text,
        png: png.png,
        pixelWidth: png.width,
        pixelHeight: png.height,
        cx: 0.5,
        cy: 0.4,
        widthFrac: wf,
        text: r.text,
        colorValue: r.color.toARGB32(),
        fontPt: r.fontPt,
      );
      _page.overlays.add(o);
      _selected = o.id;
      _clampInside(o);
    }
    _changed();
  }

  Future<void> _addDate() async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    await _placeText(_TextSpec('${two(now.day)}.${two(now.month)}.${now.year}',
        StudioColors.penBlack, 12, false));
  }

  Future<void> _addSignature() async {
    final r = await SignaturePicker.pick(context);
    if (r == null || !mounted) return;
    final o = PageOverlay(
      id: newId('o'),
      kind: OverlayKind.signature,
      png: r.png,
      pixelWidth: r.width,
      pixelHeight: r.height,
      cx: 0.5,
      cy: 0.78,
      widthFrac: 0.34,
    );
    _page.overlays.add(o);
    _selected = o.id;
    _clampInside(o);
    _changed();
  }

  void _clampInside(PageOverlay o) {
    final hf = o.widthFrac * _page.width / o.aspect / _page.height;
    if (hf > 0.9) o.widthFrac *= 0.9 / hf;
    final hf2 = o.widthFrac * _page.width / o.aspect / _page.height;
    o.cx = o.cx.clamp(o.widthFrac / 2, 1 - o.widthFrac / 2);
    o.cy = o.cy.clamp(hf2 / 2, 1 - hf2 / 2);
  }

  // ---------------------------------------------------------------- Gesten

  Rect _rectOf(PageOverlay o, Size s) {
    final w = o.widthFrac * s.width;
    final h = w / o.aspect;
    return Rect.fromCenter(center: Offset(o.cx * s.width, o.cy * s.height), width: w, height: h);
  }

  PageOverlay? _hit(Offset p, Size s) {
    for (final o in _page.overlays.reversed) {
      if (_rectOf(o, s).inflate(14).contains(p)) return o;
    }
    return null;
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final pages = widget.doc.pages;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0C0D14)
          : const Color(0xFFE9E8F2),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Seite ${_index + 1} von ${pages.length}'),
        actions: [
          IconButton(
            tooltip: 'Vorherige Seite',
            onPressed: _index > 0
                ? () => setState(() {
                      _index--;
                      _selected = null;
                    })
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Nächste Seite',
            onPressed: _index < pages.length - 1
                ? () => setState(() {
                      _index++;
                      _selected = null;
                    })
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: LayoutBuilder(builder: (context, c) {
                final p = _page;
                var w = c.maxWidth, h = w / p.aspect;
                if (h > c.maxHeight) {
                  h = c.maxHeight;
                  w = h * p.aspect;
                }
                final size = Size(w, h);
                return Center(
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) {
                        final o = _hit(d.localPosition, size);
                        setState(() => _selected = o?.id);
                      },
                      onDoubleTapDown: (d) {
                        final o = _hit(d.localPosition, size);
                        if (o != null && o.kind == OverlayKind.text) _addText(edit: o);
                      },
                      onScaleStart: (d) {
                        var o = _sel;
                        final hit = _hit(d.localFocalPoint, size);
                        if (d.pointerCount == 1) o = hit;
                        if (o == null) {
                          _manipulating = false;
                          return;
                        }
                        _selected = o.id;
                        _manipulating = true;
                        _startFocal = d.localFocalPoint;
                        _startCx = o.cx;
                        _startCy = o.cy;
                        _startW = o.widthFrac;
                        setState(() {});
                      },
                      onScaleUpdate: (d) {
                        final o = _sel;
                        if (!_manipulating || o == null || _startFocal == null) return;
                        final delta = d.localFocalPoint - _startFocal!;
                        o.widthFrac = (_startW * d.scale).clamp(0.04, 1.0);
                        o.cx = _startCx + delta.dx / size.width;
                        o.cy = _startCy + delta.dy / size.height;
                        _clampInside(o);
                        _changed();
                      },
                      onScaleEnd: (_) => _manipulating = false,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 18),
                          ],
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: PageImage(page: p, showOverlays: false, quality: 1.2),
                            ),
                            for (final o in p.overlays) _overlayWidget(o, size),
                            _selToolbar(size),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          _toolbar(scheme),
        ],
      ),
    );
  }

  Widget _overlayWidget(PageOverlay o, Size s) {
    final r = _rectOf(o, s);
    final sel = o.id == _selected;
    return Positioned.fromRect(
      rect: r,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: Image.memory(o.png, fit: BoxFit.fill, gaplessPlayback: true)),
          if (sel)
            Positioned(
              left: -5,
              top: -5,
              right: -5,
              bottom: -5,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: StudioColors.coral, width: 2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _selToolbar(Size s) {
    final o = _sel;
    if (o == null) return const SizedBox.shrink();
    final r = _rectOf(o, s);
    final tw = o.kind == OverlayKind.text ? 132.0 : 92.0;
    final top = r.top - 52 >= 0 ? r.top - 52 : (r.bottom + 8).clamp(0.0, s.height - 44);
    final left = (r.center.dx - tw / 2).clamp(0.0, (s.width - tw).clamp(0.0, double.infinity));
    return Positioned(
      top: top,
      left: left,
      child: Material(
        elevation: 4,
        color: StudioColors.night,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (o.kind == OverlayKind.text)
              _miniBtn(Icons.edit_outlined, 'Bearbeiten', () => _addText(edit: o)),
            _miniBtn(Icons.copy_outlined, 'Duplizieren', () {
              final copy = PageOverlay(
                id: newId('o'),
                kind: o.kind,
                png: o.png,
                pixelWidth: o.pixelWidth,
                pixelHeight: o.pixelHeight,
                cx: o.cx + 0.04,
                cy: o.cy + 0.05,
                widthFrac: o.widthFrac,
                text: o.text,
                colorValue: o.colorValue,
                fontPt: o.fontPt,
              );
              _clampInside(copy);
              _page.overlays.add(copy);
              _selected = copy.id;
              _changed();
            }),
            _miniBtn(Icons.delete_outline, 'Entfernen', () {
              _page.overlays.remove(o);
              _selected = null;
              _changed();
            }),
          ],
        ),
      ),
    );
  }

  Widget _miniBtn(IconData i, String tip, VoidCallback f) => IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        color: Colors.white,
        icon: Icon(i, size: 20),
        onPressed: () {
          HapticFeedback.selectionClick();
          f();
        },
      );

  Widget _toolbar(ColorScheme scheme) {
    Widget tool(IconData i, String l, VoidCallback f, {Color? color}) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: f,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(i, color: color ?? scheme.primary),
                  const SizedBox(height: 4),
                  Text(l, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
    return Material(
      color: Theme.of(context).cardTheme.color,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              tool(Icons.text_fields, 'Text', () => _addText()),
              tool(Icons.draw_outlined, 'Unterschrift', _addSignature, color: StudioColors.coral),
              tool(Icons.event_outlined, 'Datum', _addDate),
              tool(Icons.rotate_right, 'Drehen', () {
                _page.rotate(clockwise: true);
                _changed();
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSpec {
  _TextSpec(this.text, this.color, this.fontPt, this.bold);
  final String text;
  final Color color;
  final double fontPt;
  final bool bold;
}

class _TextSheet extends StatefulWidget {
  const _TextSheet({this.initial});
  final _TextSpec? initial;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _ctl = TextEditingController(text: widget.initial?.text ?? '');
  late Color _color = widget.initial?.color ?? StudioColors.penBlack;
  late double _size = (widget.initial?.fontPt ?? 12).roundToDouble().clamp(6, 72);
  late bool _bold = widget.initial?.bold ?? false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, inset + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.initial == null ? 'Text einfügen' : 'Text bearbeiten',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            minLines: 1,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(
              color: _color,
              fontWeight: _bold ? FontWeight.w700 : FontWeight.w500,
              fontSize: 18,
            ),
            decoration: InputDecoration(
              hintText: 'z. B. Name, Ort, Anmerkung …',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final c in StudioColors.pens)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 32,
                      height: 32,
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
              const Spacer(),
              FilterChip(
                label: const Text('Fett'),
                selected: _bold,
                onSelected: (v) => setState(() => _bold = v),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Größe'),
              Expanded(
                child: Slider(
                  value: _size,
                  min: 6,
                  max: 72,
                  divisions: 66,
                  label: '${_size.round()} pt',
                  onChanged: (v) => setState(() => _size = v),
                ),
              ),
              SizedBox(width: 48, child: Text('${_size.round()} pt')),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _ctl.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, _TextSpec(_ctl.text, _color, _size, _bold)),
            child: Text(widget.initial == null ? 'Einfügen' : 'Übernehmen'),
          ),
        ],
      ),
    );
  }
}
