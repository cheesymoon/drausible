// Riverpod wiring for app settings. No codegen, just plain providers.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_providers.dart';

const String _themeModeKey = 'theme_mode';

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // Rebuilds automatically once sharedPreferencesProvider resolves.
    final SharedPreferences? prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    return _fromStored(prefs?.getString(_themeModeKey));
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    // Wait for prefs rather than valueOrNull: right after startup the load may
    // still be in flight and the write would silently vanish. The resolve also
    // rebuilds this notifier with the old stored value, so reassert after.
    final SharedPreferences prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_themeModeKey, _toStored(mode));
    state = mode;
  }

  static ThemeMode _fromStored(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _toStored(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}

final NotifierProvider<ThemeModeNotifier, ThemeMode> themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
