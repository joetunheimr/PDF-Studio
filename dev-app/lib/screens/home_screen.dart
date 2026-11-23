import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../models/studio_doc.dart';
import '../services/native.dart';
import '../services/storage.dart';
import '../theme.dart';
import 'document_screen.dart';
import 'flows.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<File> _recent = [];
  StreamSubscription<List<String>>? _sub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = NativeBridge.incoming.stream.listen(_openIncoming);
    NativeBridge.takeInitialPdfs().then((l) {
      if (l.isNotEmpty) _openIncoming(l);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _recent = Storage.savedFiles());

  Future<void> _openDoc(StudioDoc doc) async {
    await DocumentScreen.open(context, doc);
    _reload();
  }

  Future<void> _openIncoming(List<String> paths) async {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    final r = await Flows.importPaths(context, paths,
        names: paths.map((e) => p.basename(e)).toList());
    if (r == null || !mounted) return;
    _openDoc(StudioDoc(name: Storage.safeName(r.$2 ?? 'Dokument'), pages: r.$1));
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() => _guard(() async {
        final pages = await Flows.scan(context);
        if (pages == null || pages.isEmpty || !mounted) return;
        await _openDoc(StudioDoc(name: Flows.scanName(), pages: pages)..dirty = true);
      });

  Future<void> _openPdf() => _guard(() async {
        final r = await Flows.pdfs(context, multiple: false);
        if (r == null || !mounted) return;
        await _openDoc(StudioDoc(name: Storage.safeName(r.$2 ?? 'Dokument'), pages: r.$1));
      });

  Future<void> _merge() => _guard(() async {
        final r = await Flows.pdfs(context, multiple: true);
        if (r == null || !mounted) return;
        await _openDoc(StudioDoc(
          name: Storage.safeName(r.$2 ?? 'Zusammengefügt'),
          pages: r.$1,
        )..dirty = true);
      });

  Future<void> _photos() => _guard(() async {
        final pages = await Flows.photos(context);
        if (pages == null || pages.isEmpty || !mounted) return;
        await _openDoc(StudioDoc(name: Flows.scanName(), pages: pages)..dirty = true);
      });

  Future<void> _about() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        icon: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.asset('assets/app_icon.png', width: 72, height: 72),
        ),
        title: const Text('PDF-Studio'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Version ${info.version} (Build ${info.buildNumber})'),
            const SizedBox(height: 12),
            const Text(
              'Scannen, zuschneiden, verbessern, unterschreiben, zusammenfügen – '
              'alles auf dem Gerät, ohne Cloud.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text('© InLAB Consulting LLC',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const Text('Open Source', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Schließen'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                children: [
                  _BigAction(
                    icon: Icons.document_scanner_outlined,
                    title: 'Dokument scannen',
                    subtitle: 'Kamera · Ecken justieren · Filter',
                    gradient: StudioColors.gradient,
                    onTap: _scan,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _SmallAction(
                          icon: Icons.picture_as_pdf_outlined,
                          title: 'PDF öffnen',
                          subtitle: 'Bearbeiten & unterschreiben',
                          color: StudioColors.coral,
                          onTap: _openPdf,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _SmallAction(
                          icon: Icons.merge_type,
                          title: 'Zusammenfügen',
                          subtitle: 'Mehrere PDFs zu einem',
                          color: StudioColors.mint,
                          onTap: _merge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SmallAction(
                    icon: Icons.photo_library_outlined,
                    title: 'Fotos in PDF umwandeln',
                    subtitle: 'Bilder aus der Galerie zuschneiden und verbessern',
                    color: StudioColors.violet,
                    onTap: _photos,
                    wide: true,
                  ),
                  const SizedBox(height: 26),
                  Row(
                    children: [
                      Text('Zuletzt gespeichert',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      const Spacer(),
                      if (_recent.isNotEmpty)
                        Text('${_recent.length}',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          if (_recent.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 36, color: scheme.outline),
                      const SizedBox(height: 8),
                      Text('Noch nichts gespeichert.\nGespeicherte PDFs erscheinen hier und im Ordner „Download/PDF-Studio“.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList.separated(
                itemCount: _recent.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _RecentTile(
                  file: _recent[i],
                  onOpen: () => _guard(() async {
                    final r = await Flows.importPaths(context, [_recent[i].path],
                        names: [p.basename(_recent[i].path)]);
                    if (r == null || !mounted) return;
                    await _openDoc(StudioDoc(name: Storage.safeName(r.$2 ?? 'Dokument'), pages: r.$1));
                  }),
                  onChanged: _reload,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.fromLTRB(20, top + 14, 8, 26),
      decoration: const BoxDecoration(
        gradient: StudioColors.gradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 16)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset('assets/app_icon.png', width: 62, height: 62),
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PDF-Studio',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5)),
                SizedBox(height: 2),
                Text('Scannen. Bearbeiten. Unterschreiben.',
                    style: TextStyle(color: Color(0xFFDCDDFF), fontSize: 14)),
              ],
            ),
          ),
          IconButton(
            color: Colors.white,
            tooltip: 'Info',
            icon: const Icon(Icons.info_outline),
            onPressed: _about,
          ),
        ],
      ),
    );
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Gradient gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(colors: [StudioColors.coral, Color(0xFFFF8A4C)]),
        boxShadow: [
          BoxShadow(
              color: StudioColors.coral.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8)),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.wide = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconBox = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, color: color),
    );
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
      ],
    );
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: wide
              ? Row(children: [iconBox, const SizedBox(width: 14), Expanded(child: texts)])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [iconBox, const SizedBox(height: 12), texts],
                ),
        ),
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.file, required this.onOpen, required this.onChanged});
  final File file;
  final VoidCallback onOpen;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final st = file.statSync();
    final d = st.modified;
    String two(int v) => v.toString().padLeft(2, '0');
    final kb = st.size / 1024;
    final size = kb > 1024 ? '${(kb / 1024).toStringAsFixed(1)} MB' : '${kb.round()} KB';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.description_outlined, color: scheme.primary),
        ),
        title: Text(p.basenameWithoutExtension(file.path),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${two(d.day)}.${two(d.month)}.${d.year}, ${two(d.hour)}:${two(d.minute)} · $size'),
        onTap: onOpen,
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'share':
                await NativeBridge.share(file);
              case 'view':
                await NativeBridge.openExternal(file);
              case 'edit':
                onOpen();
              case 'del':
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Aus der Liste löschen?'),
                    content: const Text(
                        'Die Kopie in der App wird entfernt. Die Datei im Ordner „Download/PDF-Studio“ bleibt erhalten.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Löschen')),
                    ],
                  ),
                );
                if (ok == true) {
                  file.deleteSync();
                  onChanged();
                }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
            PopupMenuItem(value: 'view', child: Text('Anzeigen')),
            PopupMenuItem(value: 'share', child: Text('Teilen')),
            PopupMenuItem(value: 'del', child: Text('Löschen')),
          ],
        ),
      ),
    );
  }
}
