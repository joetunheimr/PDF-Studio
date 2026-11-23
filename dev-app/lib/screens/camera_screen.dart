import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../theme.dart';

/// Kamera für Mehrfach-Scans. Liefert die Pfade der aufgenommenen Fotos.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  static Future<List<String>?> open(BuildContext context) =>
      Navigator.of(context).push<List<String>>(
        MaterialPageRoute(builder: (_) => const CameraScreen(), fullscreenDialog: true),
      );

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _ctl;
  String? _error;
  final _shots = <String>[];
  FlashMode _flash = FlashMode.off;
  bool _busy = false;
  bool _flashAnim = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = 'Keine Kamera gefunden.');
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final ctl = CameraController(
        back,
        ResolutionPreset.ultraHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctl.initialize();
      await ctl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      try {
        await ctl.setFlashMode(_flash);
        await ctl.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() {
        _ctl = ctl;
        _error = null;
      });
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied'
          ? 'Kein Zugriff auf die Kamera. Bitte in den Android-Einstellungen erlauben.'
          : 'Kamera-Fehler: ${e.description ?? e.code}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _ctl;
    if (state == AppLifecycleState.inactive) {
      if (c != null) {
        _ctl = null;
        c.dispose();
        if (mounted) setState(() {});
      }
    } else if (state == AppLifecycleState.resumed && _ctl == null) {
      _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctl?.dispose();
    super.dispose();
  }

  Future<void> _shoot() async {
    final c = _ctl;
    if (c == null || _busy || c.value.isTakingPicture) return;
    setState(() {
      _busy = true;
      _flashAnim = true;
    });
    HapticFeedback.lightImpact();
    try {
      final f = await c.takePicture();
      setState(() => _shots.add(f.path));
    } on CameraException catch (e) {
      _snack('Foto fehlgeschlagen: ${e.description ?? e.code}');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) setState(() => _flashAnim = false);
        });
      }
    }
  }

  Future<void> _gallery() async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: 100);
    if (picked.isEmpty) return;
    setState(() => _shots.addAll(picked.map((e) => e.path)));
  }

  Future<void> _toggleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    try {
      await _ctl?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {}
  }

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<bool> _confirmDiscard() async {
    if (_shots.isEmpty) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Aufnahmen verwerfen?'),
        content: Text('${_shots.length} Foto(s) gehen verloren.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Verwerfen')),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctl;
    return PopScope(
      canPop: _shots.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Kopfzeile
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                      tooltip: 'Schließen',
                      onPressed: () async {
                        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
                      },
                    ),
                    const Spacer(),
                    const Text('Dokument scannen',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      color: Colors.white,
                      tooltip: 'Blitz',
                      icon: Icon(switch (_flash) {
                        FlashMode.off => Icons.flash_off,
                        FlashMode.auto => Icons.flash_auto,
                        _ => Icons.flashlight_on,
                      }),
                      onPressed: c == null ? null : _toggleFlash,
                    ),
                  ],
                ),
              ),
              // Vorschau
              Expanded(
                child: Center(
                  child: _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70)),
                        )
                      : c == null || !c.value.isInitialized
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: AspectRatio(
                                  aspectRatio: 1 / c.value.aspectRatio,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      LayoutBuilder(
                                        builder: (_, box) => GestureDetector(
                                          onTapUp: (d) {
                                            try {
                                              c.setFocusPoint(Offset(
                                                (d.localPosition.dx / box.maxWidth).clamp(0, 1),
                                                (d.localPosition.dy / box.maxHeight).clamp(0, 1),
                                              ));
                                            } catch (_) {}
                                          },
                                          child: CameraPreview(c),
                                        ),
                                      ),
                                      IgnorePointer(child: CustomPaint(painter: _GuidePainter())),
                                      IgnorePointer(
                                        child: AnimatedOpacity(
                                          duration: const Duration(milliseconds: 120),
                                          opacity: _flashAnim ? 0.7 : 0,
                                          child: const ColoredBox(color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                ),
              ),
              // Bedienleiste
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Row(
                  children: [
                    SizedBox(
                      width: 76,
                      child: _shots.isEmpty
                          ? IconButton(
                              iconSize: 30,
                              color: Colors.white,
                              tooltip: 'Aus Galerie',
                              icon: const Icon(Icons.photo_library_outlined),
                              onPressed: _gallery,
                            )
                          : _ThumbStack(paths: _shots, onTap: () => Navigator.pop(context, _shots)),
                    ),
                    const Spacer(),
                    _Shutter(onTap: c == null ? null : _shoot, busy: _busy),
                    const Spacer(),
                    SizedBox(
                      width: 76,
                      child: _shots.isEmpty
                          ? const SizedBox()
                          : FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: StudioColors.coral,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                              ),
                              onPressed: () => Navigator.pop(context, _shots),
                              child: const Text('Weiter'),
                            ),
                    ),
                  ],
                ),
              ),
              if (_shots.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextButton.icon(
                    onPressed: _gallery,
                    icon: const Icon(Icons.add_photo_alternate_outlined, color: Colors.white70),
                    label: const Text('Aus Galerie hinzufügen',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.onTap, required this.busy});
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 82,
        height: 82,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        padding: const EdgeInsets.all(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy ? Colors.white54 : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _ThumbStack extends StatelessWidget {
  const _ThumbStack({required this.paths, required this.onTap});
  final List<String> paths;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        height: 76,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 56,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 2),
                image: DecorationImage(
                  image: ResizeImage(FileImage(File(paths.last)), width: 160),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Positioned(
              right: -2,
              top: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: StudioColors.coral,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${paths.length}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dezente Eckmarken als Hilfe zum Ausrichten.
class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final r = Rect.fromLTWH(size.width * 0.08, size.height * 0.08,
        size.width * 0.84, size.height * 0.84);
    const l = 28.0;
    for (final c in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]) {
      final dx = c.dx < size.width / 2 ? l : -l;
      final dy = c.dy < size.height / 2 ? l : -l;
      canvas.drawLine(c, c + Offset(dx, 0), p);
      canvas.drawLine(c, c + Offset(0, dy), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
