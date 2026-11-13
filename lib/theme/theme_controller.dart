import 'package:flutter/material.dart';

/// Controller for managing application [ThemeMode] on the fly.
class ThemeNotifier extends ValueNotifier<ThemeMode> {
  ThemeNotifier([super.mode = ThemeMode.system]);

  /// Determines effective dark mode state (evaluating system preference when mode is [ThemeMode.system]).
  bool isDarkMode(BuildContext context) {
    if (value == ThemeMode.system) {
      return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    }
    return value == ThemeMode.dark;
  }

  /// Toggles theme to the opposite of the current effective theme.
  void toggleTheme(BuildContext context) {
    final currentlyDark = isDarkMode(context);
    value = currentlyDark ? ThemeMode.light : ThemeMode.dark;
  }

  void setThemeMode(ThemeMode mode) {
    value = mode;
  }
}

/// Inherited widget for providing [ThemeNotifier] down the widget tree.
class ThemeScope extends InheritedNotifier<ThemeNotifier> {
  const ThemeScope({
    super.key,
    required ThemeNotifier controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeNotifier of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'No ThemeScope found in context');
    return scope!.notifier!;
  }

  static ThemeNotifier? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    return scope?.notifier;
  }
}
