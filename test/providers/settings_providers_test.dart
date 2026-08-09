import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/providers/settings_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default is system', () {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('setMode persists and a second container reads it back', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    // setMode writes via valueOrNull too (same as the dashboard's range
    // persistence), so wait for prefs to load first or the write is a no-op.
    await container.read(sharedPreferencesProvider.future);

    await container.read(themeModeProvider.notifier).setMode(ThemeMode.dark);
    expect(container.read(themeModeProvider), ThemeMode.dark);

    final ProviderContainer container2 = ProviderContainer();
    addTearDown(container2.dispose);
    // build() reads prefs via valueOrNull, which is only populated once the
    // future resolves, so wait for it before reading the notifier's state.
    await container2.read(sharedPreferencesProvider.future);

    expect(container2.read(themeModeProvider), ThemeMode.dark);
  });
}
