import 'package:flutter/material.dart';

import 'data.dart';

// Цвета из макетов: бирюзовый акцент, красный SOS.
const accentLight = Color(0xFF0F766E);
const accentDark = Color(0xFF2BB3A3);
const sosLight = Color(0xFFC62828);
const sosDark = Color(0xFFFF6B6B);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: accentLight,
    brightness: b,
  ).copyWith(
    primary: dark ? accentDark : accentLight,
    onPrimary: dark ? const Color(0xFF04201C) : Colors.white,
    surface: dark ? const Color(0xFF18211E) : Colors.white,
    onSurface: dark ? const Color(0xFFE8EEEC) : const Color(0xFF121A17),
    onSurfaceVariant: dark ? const Color(0xFF97A7A1) : const Color(0xFF5B6762),
    surfaceContainerHighest: dark ? const Color(0xFF25322E) : const Color(0xFFF0F3F2),
    outlineVariant: dark ? const Color(0xFF26322E) : const Color(0xFFE1E6E4),
    error: dark ? sosDark : sosLight,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF0D1412) : const Color(0xFFF4F6F5),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0.5,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
  );
}

Color sosColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? sosDark : sosLight;

IconData tripIcon(TripType t) => switch (t) {
      TripType.hike => Icons.terrain_outlined,
      TripType.car => Icons.directions_car_outlined,
      TripType.yacht => Icons.sailing_outlined,
    };

Color tripColor(TripType t) => switch (t) {
      TripType.hike => const Color(0xFFB45309),
      TripType.car => const Color(0xFF3B5BA9),
      TripType.yacht => accentLight,
    };

/// Цвет аватара по имени — стабильный.
Color avatarColor(String name) {
  const palette = [
    Color(0xFFB45309),
    Color(0xFF3B5BA9),
    Color(0xFF7C3AED),
    Color(0xFF0F766E),
    Color(0xFFBE185D),
    Color(0xFF4D7C0F),
  ];
  return palette[name.hashCode.abs() % palette.length];
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
}

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: size / 2,
        backgroundColor: avatarColor(name),
        child: Text(initials(name),
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.36)),
      );
}
