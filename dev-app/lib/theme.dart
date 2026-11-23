import 'package:flutter/material.dart';

/// Farbwelt „Tinte & Koralle“ – passend zum Logo.
class StudioColors {
  static const ink = Color(0xFF2E3A9E); // Indigo
  static const violet = Color(0xFF6D3FE0);
  static const coral = Color(0xFFFF6B57);
  static const mint = Color(0xFF1BB38A);
  static const paper = Color(0xFFF6F5FB);
  static const night = Color(0xFF12131C);

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ink, violet],
  );

  // Stiftfarben für Text und Unterschrift
  static const penBlue = Color(0xFF1A3FA8);
  static const penBlack = Color(0xFF111111);
  static const penRed = Color(0xFFC62828);
  static const penGreen = Color(0xFF1B7F3A);
  static const pens = [penBlue, penBlack, penRed, penGreen];
}

class StudioTheme {
  static ThemeData _base(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: StudioColors.ink,
      brightness: b,
      primary: dark ? const Color(0xFFB9C0FF) : StudioColors.ink,
      secondary: StudioColors.coral,
      tertiary: StudioColors.violet,
      surface: dark ? StudioColors.night : StudioColors.paper,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1C1E2B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.onDrag),
    );
  }

  static final light = _base(Brightness.light);
  static final dark = _base(Brightness.dark);
}
