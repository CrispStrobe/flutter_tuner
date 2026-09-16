import 'package:flutter/material.dart';

/// CrispTuner's palette.
///
/// The app used to be near-black with saturated neon accents. That reads well
/// enough on its own, but it is also the single most common look in the app
/// stores, and it made the app hard to tell apart at a glance from anything
/// else drawn on a #0A0A0A ground. The palette here is deliberately warm and
/// material — aged paper and workshop brass in the light theme, stained walnut
/// in the dark one — so the app looks like the instruments it tunes.
///
/// Both themes are supplied: a musician tuning on a dark stage should not be
/// handed a white screen, and one tuning by a window should not be handed a
/// black one.
class TunerPalette {
  final Color backgroundTop;
  final Color backgroundBottom;
  final Color surface;
  final Color surfaceStrong;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;

  /// Accent for controls and the pitch-history trace.
  final Color accent;

  /// Within tolerance of the target pitch.
  final Color inTune;

  /// Sharp or flat.
  final Color offPitch;

  /// A reference tone is sounding.
  final Color tone;

  /// The spectrum trace.
  final Color spectrum;

  final Brightness brightness;

  const TunerPalette({
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.surface,
    required this.surfaceStrong,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.accent,
    required this.inTune,
    required this.offPitch,
    required this.tone,
    required this.spectrum,
    required this.brightness,
  });

  /// Aged paper and brass.
  static const light = TunerPalette(
    backgroundTop: Color(0xFFFBF7F0),
    backgroundBottom: Color(0xFFEFE3D0),
    surface: Color(0x14000000),
    surfaceStrong: Color(0xFFFFFFFF),
    outline: Color(0xFFD8C9B2),
    textPrimary: Color(0xFF2E2921),
    textSecondary: Color(0xFF6B5E4B),
    textFaint: Color(0xFF9C8E79),
    accent: Color(0xFF9A6413),
    inTune: Color(0xFF2F7D4F),
    offPitch: Color(0xFFB4541B),
    tone: Color(0xFF166B72),
    spectrum: Color(0xFF166B72),
    brightness: Brightness.light,
  );

  /// Stained walnut — dark, but brown rather than black, and with no neon.
  static const dark = TunerPalette(
    backgroundTop: Color(0xFF221B14),
    backgroundBottom: Color(0xFF15100B),
    surface: Color(0x14FFFFFF),
    surfaceStrong: Color(0xFF2A2119),
    outline: Color(0xFF4A3C2D),
    textPrimary: Color(0xFFF3E9D8),
    textSecondary: Color(0xFFC0AE93),
    textFaint: Color(0xFF8A7A63),
    accent: Color(0xFFD9A441),
    inTune: Color(0xFF6FC08A),
    offPitch: Color(0xFFE0955A),
    tone: Color(0xFF63BFC6),
    spectrum: Color(0xFF63BFC6),
    brightness: Brightness.dark,
  );

  static TunerPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  ThemeData get themeData {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      surface: backgroundTop,
      onSurface: textPrimary,
      primary: accent,
      outline: outline,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: backgroundTop,
      textTheme: (brightness == Brightness.dark
              ? Typography.material2021(platform: TargetPlatform.iOS).white
              : Typography.material2021(platform: TargetPlatform.iOS).black)
          .apply(bodyColor: textPrimary, displayColor: textPrimary),
      dividerColor: outline,
    );
  }
}
