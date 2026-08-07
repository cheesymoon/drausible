import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/util/countries.dart';

void main() {
  group('countryName', () {
    test('resolves a known code', () {
      expect(countryName('DE'), 'Germany');
    });

    test('passes an unknown code through unchanged', () {
      expect(countryName('ZZ'), 'ZZ');
    });
  });

  group('countryFlag', () {
    test('builds the regional-indicator emoji for a known code', () {
      expect(countryFlag('DE'), '🇩🇪');
    });

    test('returns empty for junk input', () {
      expect(countryFlag('123'), ''); // wrong length
      expect(countryFlag(''), ''); // empty
      expect(countryFlag('deu'), ''); // wrong length
      expect(countryFlag('de'), ''); // right length, not A-Z
    });
  });
}
