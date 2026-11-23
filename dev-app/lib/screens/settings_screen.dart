import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/native.dart';
import '../theme.dart';

/// Einstellungen: Arbeitsordner wählen, Infos und Hinweise zur App.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PackageInfo? _info;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WorkFolder.refresh();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _info = i);
    });
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = await WorkFolder.pick();
      if (f != null) _snack('Arbeitsordner: ${f.label}');
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final f = await WorkFolder.reset();
    _snack('Arbeitsordner: ${f.label}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget heading(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(s, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          heading('Arbeitsordner'),
          ValueListenableBuilder<WorkFolder>(
            valueListenable: WorkFolder.current,
            builder: (_, f, _) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.folder_outlined, color: scheme.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(f.label,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(f.custom ? 'Selbst gewählt' : 'Standard',
                                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (f.lost) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Der zuvor gewählte Ordner ist nicht mehr erreichbar. Bis du einen neuen wählst, '
                        'speichert PDF-Studio wieder in „Download/PDF-Studio“.',
                        style: TextStyle(color: StudioColors.coral),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Hier speichert PDF-Studio, und die Liste auf der Startseite zeigt die PDFs aus '
                      'diesem Ordner. Vorhandene Dateien werden beim Wechsel nicht verschoben.',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _busy ? null : _pick,
                      icon: const Icon(Icons.drive_folder_upload_outlined),
                      label: const Text('Anderen Ordner wählen'),
                    ),
                    if (f.custom) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _reset,
                        child: const Text('Zurück zu „Download/PDF-Studio“'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          heading('Über PDF-Studio'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset('assets/app_icon.png', width: 72, height: 72),
                  ),
                  const SizedBox(height: 10),
                  Text('PDF-Studio', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  if (_info != null)
                    Text('Version ${_info!.version} (Build ${_info!.buildNumber})',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  const Text(
                    'Scannen, zuschneiden, verbessern, unterschreiben, zusammenfügen – '
                    'alles auf dem Gerät, ohne Cloud.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  const Text('© InLAB Consulting LLC', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text('Open Source · GPL-3.0-or-later',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 4),
                  SelectableText('github.com/joetunheimr/PDF-Studio',
                      style: TextStyle(color: scheme.primary, fontSize: 12)),
                ],
              ),
            ),
          ),
          heading('Hinweise'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _Note(Icons.lock_outline, 'Datenschutz',
                      'PDF-Studio hat keinen Internetzugriff. Scans, Dokumente und Unterschriften '
                          'bleiben auf deinem Gerät; es gibt keine Werbung, kein Konto und kein Tracking.'),
                  _Note(Icons.photo_camera_outlined, 'Berechtigungen',
                      'Die Kamera wird nur zum Scannen benutzt. Auf Ordner greift die App nur zu, '
                          'wenn du sie hier auswählst.'),
                  _Note(Icons.gavel_outlined, 'Haftungsausschluss',
                      'Die App wird ohne Gewähr bereitgestellt. Für die Richtigkeit, Vollständigkeit '
                          'und rechtliche Wirksamkeit erstellter Dokumente und Unterschriften wird keine '
                          'Haftung übernommen. Eine hier gesetzte Unterschrift ist ein Bild und keine '
                          'qualifizierte elektronische Signatur. Bitte bewahre wichtige Originale auf.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
