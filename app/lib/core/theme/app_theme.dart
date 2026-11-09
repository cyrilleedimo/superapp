// Thème Material 3 entièrement personnalisé : on garde l'accessibilité de
// Material mais avec l'apparence sobre et européenne du design system.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

ThemeData buildLumoTheme() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
  final body = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: LumoColors.ink,
    displayColor: LumoColors.ink,
  );
  TextStyle display(double size) {
    final style = TextStyle(
        fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.03 * size, color: LumoColors.ink, height: 1.05);
    try {
      return GoogleFonts.getFont('Bricolage Grotesque', textStyle: style);
    } catch (_) {
      return GoogleFonts.inter(textStyle: style); // repli si la police n'est pas dans le catalogue
    }
  }

  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(LumoRadius.pill));

  return base.copyWith(
    scaffoldBackgroundColor: LumoColors.surface,
    colorScheme: const ColorScheme.light(
      primary: LumoColors.action,
      onPrimary: Colors.white,
      secondary: LumoColors.lime,
      onSecondary: LumoColors.ink,
      surface: LumoColors.surface,
      onSurface: LumoColors.ink,
      error: LumoColors.danger,
      outline: LumoColors.line,
    ),
    textTheme: body.copyWith(
      displaySmall: display(34),
      headlineMedium: display(30),
      headlineSmall: display(24),
      titleMedium: body.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
      bodyLarge: body.bodyLarge?.copyWith(fontSize: 15, height: 1.45),
      bodyMedium: body.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: body.bodySmall?.copyWith(fontSize: 13, color: LumoColors.slate),
      labelLarge: body.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LumoColors.surface,
      foregroundColor: LumoColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LumoColors.action,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: pill,
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LumoColors.action,
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: LumoColors.action, width: 1.5),
        shape: pill,
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LumoColors.mist,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(LumoRadius.field), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LumoRadius.field),
        borderSide: const BorderSide(color: LumoColors.action, width: 1.5),
      ),
      hintStyle: GoogleFonts.inter(color: LumoColors.slate, fontSize: 15),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: LumoColors.surface,
      indicatorColor: LumoColors.actionSoft,
      height: 72,
      labelTextStyle: WidgetStatePropertyAll(GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600)),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: LumoColors.surface,
      indicatorColor: LumoColors.actionSoft,
    ),
    dividerTheme: const DividerThemeData(color: LumoColors.line, thickness: 1, space: 1),
    // Focus visible au clavier (Windows) : exigence d'accessibilité.
    focusColor: LumoColors.actionSoft,
  );
}
