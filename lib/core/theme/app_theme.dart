import 'package:flutter/material.dart';

/// Application theme definitions for FoodLens AI.
class AppTheme {
  const AppTheme._();

  /// Dark theme configured for the FoodLens clinical design system.
  static final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C63FF),
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xFF0D0D1A),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
    ),
    useMaterial3: true,
  );
}

