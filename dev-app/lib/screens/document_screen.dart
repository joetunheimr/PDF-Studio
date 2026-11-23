import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/studio_doc.dart';
import '../services/native.dart';
import '../services/storage.dart';
import '../theme.dart';
import '../widgets/page_render.dart';
import 'flows.dart';
import 'page_edit_screen.dart';

/// Übersicht eines Dokuments: Seiten ordnen, drehen, löschen, ergänzen, speichern.
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.doc});
  final StudioDoc doc;

  static Future<void> open(BuildContext context, StudioDoc doc) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => DocumentScreen(doc: doc)));

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  StudioDoc get doc => widget.doc;
  final _selected = <String>{};
  bool _selecting = false;
  int? _hover;
  bool _saving = false;

  void _changed() {
    doc.dirty = true;
    setState(() {});
  }

  @override
  void dispose() {
    RenderCache.closeAll();
    super.dispose();
  }

  // ------------------------------------------------------------ Aktionen

  Future<void> _add() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('Seiten scannen'),
              onTap: () => Navigator.pop(c, 0),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF anhängen (zusammenfügen)'),
              onTap: () => Navigator.pop(c, 1),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Fotos aus der Galerie'),
              onTap: () => Navigator.pop(c, 2),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    List<PageItem>? pages;
    switch (choice) {
      case 0:
        pages = await Flows.scan(context);
      case 1:
        pages = (await Flows.pdfs(context))?.$1;
      case 2:
        pages = await Flows.photos(context);
    }
    if (pages == null || pages.isEmpty) return;
    doc.pages.addAll(pages);
    _changed();
    _snack('${pages.length} Seite(n) hinzugefügt');
  }

  void _rotateSelected(bool cw) {
    for (final pg in doc.pages) {
      if (_selected.contains(pg.id)) pg.rotate(clockwise: cw);
    }
    HapticFeedback.selectionClick();
    _changed();
  }

  void _deletePages(Set<String> ids) {
    if (ids.isEmpty) return;
    if (ids.length >= doc.pages.length) {
      _snack('Mindestens eine Seite muss bleiben.');
      return;
    }
    final backup = List.of(doc.pages);
    doc.pages.removeWhere((pg) => ids.contains(pg.id));
    _selected.removeAll(ids);
    if (_selected.isEmpty) _selecting = false;
    _changed();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${ids.length} Seite(n) gelöscht'),
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () {
          doc.pages
            ..clear()
            ..addAll(backup);
          _changed();
        },
      ),
    ));
  }

  void _duplicate(PageItem pg) {
    final i = doc.pages.indexOf(pg);
    doc.pages.insert(i + 1, pg.copy(newId: newId('p')));
    _changed();
  }

  void _move(int from, int to) {
    if (from == to) return;
    final pg = doc.pages.removeAt(from);
    doc.pages.insert(to > from ? to - 1 : to, pg);
    HapticFeedback.lightImpact();
    _changed();
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: doc.name);
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Dokumentname'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(suffixText: '.pdf'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('OK')),
        ],
      ),
    );
    if (r != null && r.trim().isNotEmpty) {
      doc.name = Storage.safeName(r);
      _changed();
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final existing = {for (final f in await NativeBridge.listSaved()) f.name.toLowerCase()};
      final name = Storage.uniqueName(doc.name, existing);
      final file = await NativeBridge.exportPdf(doc, Storage.outFile(name));
      final dl = await NativeBridge.saveToDownloads(file, name: name);
      doc.dirty = false;
      if (!mounted) return;
      setState(() => _saving = false);
      await _savedSheet(file, dl);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Speichern fehlgeschlagen'),
          content: Text('$e'),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    }
  }

  Future<void> _savedSheet(File file, String dl) async {
    final kb = file.lengthSync() / 1024;
    final size = kb > 1024 ? '${(kb / 1024).toStringAsFixed(1)} MB' : '${kb.round()} KB';
    await showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.check_circle, color: StudioColors.mint, size: 52),
              const SizedBox(height: 8),
              Text('Gespeichert',
                  textAlign: TextAlign.center, style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                '$dl · ${doc.pages.length} Seite(n) · $size\n'
                'Im Ordner „Download/PDF-Studio“',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await NativeBridge.openExternal(file);
                        if (!ok && c.mounted) {
                          ScaffoldMessenger.of(c).showSnackBar(
                              const SnackBar(content: Text('Keine App zum Anzeigen gefunden')));
                        }
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Öffnen'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => NativeBridge.share(file),
                      icon: const Icon(Icons.share),
                      label: const Text('Teilen'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  Navigator.pop(c);
                  Navigator.pop(context);
                },
                child: const Text('Fertig – zur Startseite'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmLeave() async {
    if (!doc.dirty) return true;
    final r = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Änderungen speichern?'),
        content: const Text('Das Dokument wurde noch nicht gespeichert.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 2), child: const Text('Verwerfen')),
          TextButton(onPressed: () => Navigator.pop(c, 0), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, 1), child: const Text('Speichern')),
        ],
      ),
    );
    if (r == 1) {
      await _save();
      return false;
    }
    return r == 2;
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final cols = width > 900 ? 5 : (width > 600 ? 4 : 2);
    return PopScope(
      canPop: !doc.dirty && !_selecting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_selecting) {
          setState(() {
            _selecting = false;
            _selected.clear();
          });
          return;
        }
        if (await _confirmLeave() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _selecting = false;
                    _selected.clear();
                  }),
                ),
                title: Text('${_selected.length} ausgewählt'),
                actions: [
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == doc.pages.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(doc.pages.map((e) => e.id));
                      }
                    }),
                    child: Text(_selected.length == doc.pages.length ? 'Keine' : 'Alle'),
                  ),
                ],
              )
            : AppBar(
                title: InkWell(
                  onTap: _rename,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text(doc.name, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 6),
                        Icon(Icons.edit, size: 16, color: scheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
                actions: [
                  IconButton(
                    tooltip: 'Seiten auswählen',
                    icon: const Icon(Icons.checklist),
                    onPressed: () => setState(() => _selecting = true),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_alt, size: 20),
                      label: const Text('Speichern'),
                    ),
                  ),
                ],
              ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(
                children: [
                  Text('${doc.pages.length} Seite(n)',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(
                    _selecting ? 'Antippen zum Auswählen' : 'Gedrückt halten zum Verschieben',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 110),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.72,
                ),
                itemCount: doc.pages.length,
                itemBuilder: (context, i) => _tile(i, scheme),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _selecting ? _selectionBar(scheme) : null,
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
                backgroundColor: StudioColors.coral,
                foregroundColor: Colors.white,
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Seiten hinzufügen'),
              ),
      ),
    );
  }

  Widget _selectionBar(ColorScheme scheme) {
    final none = _selected.isEmpty;
    Widget b(IconData i, String l, VoidCallback? f, {Color? c}) => Expanded(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: c ?? scheme.primary),
            onPressed: none ? null : f,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Icon(i), const SizedBox(height: 4), Text(l, style: const TextStyle(fontSize: 12))],
            ),
          ),
        );
    return Material(
      elevation: 8,
      color: Theme.of(context).cardTheme.color,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              b(Icons.rotate_left, 'Links drehen', () => _rotateSelected(false)),
              b(Icons.rotate_right, 'Rechts drehen', () => _rotateSelected(true)),
              b(Icons.delete_outline, 'Löschen', () => _deletePages(Set.of(_selected)),
                  c: scheme.error),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(int i, ColorScheme scheme) {
    final pg = doc.pages[i];
    final sel = _selected.contains(pg.id);
    final card = _PageCard(
      page: pg,
      number: i + 1,
      selected: sel,
      selecting: _selecting,
      highlight: _hover == i,
      onTap: () {
        if (_selecting) {
          setState(() => sel ? _selected.remove(pg.id) : _selected.add(pg.id));
        } else {
          PageEditScreen.open(context, doc, i).then((_) => setState(() {}));
        }
      },
      onMenu: (v) {
        switch (v) {
          case 'edit':
            PageEditScreen.open(context, doc, i).then((_) => setState(() {}));
          case 'cw':
            pg.rotate(clockwise: true);
            _changed();
          case 'ccw':
            pg.rotate(clockwise: false);
            _changed();
          case 'dup':
            _duplicate(pg);
          case 'del':
            _deletePages({pg.id});
        }
      },
    );
    if (_selecting) return card;
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) {
        setState(() => _hover = i);
        return d.data != i;
      },
      onLeave: (_) => setState(() => _hover = null),
      onAcceptWithDetails: (d) {
        setState(() => _hover = null);
        final from = d.data;
        _move(from, from < i ? i + 1 : i);
      },
      builder: (context, cand, rej) => LayoutBuilder(
        builder: (context, c) => LongPressDraggable<int>(
          data: i,
          hapticFeedbackOnStart: true,
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: c.maxWidth * 1.05,
              height: c.maxHeight * 1.05,
              child: Opacity(opacity: 0.9, child: card),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: card),
          child: card,
        ),
      ),
    );
  }
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.page,
    required this.number,
    required this.selected,
    required this.selecting,
    required this.highlight,
    required this.onTap,
    required this.onMenu,
  });

  final PageItem page;
  final int number;
  final bool selected;
  final bool selecting;
  final bool highlight;
  final VoidCallback onTap;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected
              ? StudioColors.coral
              : highlight
                  ? scheme.primary
                  : Colors.transparent,
          width: 2.5,
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 4),
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                        ),
                        child: PageImage(page: page, quality: 0.9),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    if (selecting)
                      Icon(
                        selected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: selected ? StudioColors.coral : scheme.outline,
                        size: 20,
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$number',
                            style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
                      ),
                    const SizedBox(width: 6),
                    if (page.overlays.isNotEmpty)
                      Icon(Icons.draw_outlined, size: 16, color: scheme.onSurfaceVariant),
                    if (page.source == PageSource.image)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.document_scanner_outlined,
                            size: 16, color: scheme.onSurfaceVariant),
                      ),
                    const Spacer(),
                    if (!selecting)
                      PopupMenuButton<String>(
                        tooltip: 'Seitenmenü',
                        icon: const Icon(Icons.more_vert, size: 20),
                        onSelected: onMenu,
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: _MI(Icons.draw_outlined, 'Text & Unterschrift')),
                          PopupMenuItem(value: 'cw', child: _MI(Icons.rotate_right, 'Rechts drehen')),
                          PopupMenuItem(value: 'ccw', child: _MI(Icons.rotate_left, 'Links drehen')),
                          PopupMenuItem(value: 'dup', child: _MI(Icons.copy_outlined, 'Duplizieren')),
                          PopupMenuItem(value: 'del', child: _MI(Icons.delete_outline, 'Löschen')),
                        ],
                      )
                    else
                      const SizedBox(height: 40),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MI extends StatelessWidget {
  const _MI(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) =>
      Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]);
}
