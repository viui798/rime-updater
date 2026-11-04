import 'package:flutter/material.dart';

/// 设计 token，见仓库根目录 DESIGN.md（v3「静序」）。
/// 改界面前先读 DESIGN.md，不要在这里之外硬编码颜色。
class AppColors {
  const AppColors._();

  // Light
  static const paper = Color(0xFFF6F6F9);
  static const surface = Color(0xFFFFFFFF);
  static const sunken = Color(0xFFF0F0F5);
  static const ink = Color(0xFF24252D);
  static const inkSecondary = Color(0xFF60616F);
  static const inkMuted = Color(0xFF70717F);
  static const hairline = Color(0xFFE4E4EC);
  static const accent = Color(0xFF5E6AD2);
  static const accentSoft = Color(0xFFEEEFFD);
  static const success = Color(0xFF15803D);
  static const danger = Color(0xFFB42318);

  // Dark
  static const paperDark = Color(0xFF111113);
  static const surfaceDark = Color(0xFF19191D);
  static const sunkenDark = Color(0xFF222228);
  static const inkDark = Color(0xFFF1F1F4);
  static const inkSecondaryDark = Color(0xFFAEAEBB);
  static const inkMutedDark = Color(0xFF9292A3);
  static const hairlineDark = Color(0xFF303038);
  static const accentDark = Color(0xFFA5ADFF);
  static const accentSoftDark = Color(0xFF2A2C48);
  static const successDark = Color(0xFF4ADE80);
  static const dangerDark = Color(0xFFFCA5A5);

  // Console（日志始终是深色）
  static const consoleBg = Color(0xFF202129);
  static const consoleBgDark = Color(0xFF15151B);
  static const consoleText = Color(0xFFDDDDE7);
  static const consoleMuted = Color(0xFFA4A5B7);
  static const consoleAccent = Color(0xFFA5ADFF);
  static const consoleGreen = Color(0xFF4ADE80);
  static const consoleRed = Color(0xFFFCA5A5);
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final canvas = dark ? AppColors.paperDark : AppColors.paper;
  final surface = dark ? AppColors.surfaceDark : AppColors.surface;
  final sunken = dark ? AppColors.sunkenDark : AppColors.sunken;
  final ink = dark ? AppColors.inkDark : AppColors.ink;
  final inkSecondary =
      dark ? AppColors.inkSecondaryDark : AppColors.inkSecondary;
  final inkMuted = dark ? AppColors.inkMutedDark : AppColors.inkMuted;
  final hairline = dark ? AppColors.hairlineDark : AppColors.hairline;
  final accent = dark ? AppColors.accentDark : AppColors.accent;
  final accentSoft = dark ? AppColors.accentSoftDark : AppColors.accentSoft;

  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: brightness,
  ).copyWith(
    primary: accent,
    onPrimary: dark ? const Color(0xFF20234A) : Colors.white,
    primaryContainer: accentSoft,
    onPrimaryContainer: accent,
    surface: surface,
    onSurface: ink,
    onSurfaceVariant: inkSecondary,
    surfaceContainerHighest: sunken,
    surfaceContainerLow: canvas,
    outline: inkMuted,
    outlineVariant: hairline,
    error: dark ? AppColors.dangerDark : AppColors.danger,
  );

  final base = ThemeData(brightness: brightness, useMaterial3: true).textTheme;
  final textTheme = base.copyWith(
    titleLarge: base.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: ink,
    ),
    titleMedium: base.titleMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
      color: ink,
    ),
    bodyLarge: base.bodyLarge?.copyWith(fontSize: 14, color: ink),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 13, color: inkSecondary),
    bodySmall: base.bodySmall?.copyWith(fontSize: 12, color: inkMuted),
    labelLarge: base.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: ink,
    ),
    labelMedium: base.labelMedium?.copyWith(
      fontSize: 9,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.0,
      color: inkMuted,
    ),
    labelSmall: base.labelSmall?.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: inkMuted,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    textTheme: textTheme,
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: hairline),
      ),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: dark ? const Color(0xFF20234A) : Colors.white,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        elevation: 0,
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        side: BorderSide(color: hairline),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: inkSecondary,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: inkSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: BorderSide(color: hairline, width: 1.2),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : null,
      ),
      checkColor: WidgetStateProperty.all(
        dark ? const Color(0xFF20234A) : Colors.white,
      ),
      visualDensity: VisualDensity.compact,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: sunken,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(fontSize: 12.5, color: inkMuted),
      labelStyle: TextStyle(fontSize: 12.5, color: inkSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide(color: accent, width: 1.2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .18),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: hairline),
      ),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: ink,
      ),
      contentTextStyle:
          TextStyle(fontSize: 13, height: 1.5, color: inkSecondary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: .18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: hairline),
      ),
      textStyle: TextStyle(fontSize: 12.5, color: ink),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      iconColor: inkMuted,
      textColor: ink,
      minVerticalPadding: 6,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: sunken,
      linearMinHeight: 4,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1B232C) : ink,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(fontSize: 11.5, color: Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xFF1B232C) : ink,
      contentTextStyle: const TextStyle(fontSize: 12.5, color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    ),
  );
}
