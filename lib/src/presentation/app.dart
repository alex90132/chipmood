import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'screens/studio_screen.dart';

class ChiptuneApp extends StatelessWidget {
  const ChiptuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB87333), // copper/bronze accent
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFFC98A5E),
      secondary: const Color(0xFFE0B080),
      tertiary: const Color(0xFF22D3EE), // cyan needle/highlights
      surface: const Color(0xFF0E0B1A),
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0B0814),
    );

    return MaterialApp(
      title: 'ChipMood',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        // Sleek techy type for the whole app, matching the chip/space vibe.
        textTheme: GoogleFonts.rajdhaniTextTheme(base.textTheme),
        chipTheme: ChipThemeData(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: GoogleFonts.rajdhani(fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const StudioScreen(),
    );
  }
}
