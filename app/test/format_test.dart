import 'package:flutter_test/flutter_test.dart';
import 'package:superapp/core/format.dart';
import 'package:superapp/features/auth/auth_screens.dart';

void main() {
  test('formatXaf groupe les milliers', () {
    expect(formatXaf(13200), '13 200 FCFA');
    expect(formatXaf(476000), '476 000 FCFA');
    expect(formatXaf(950), '950 FCFA');
  });

  test('toE164 normalise les numéros camerounais', () {
    expect(toE164('6 90 00 00 01'), '+237690000001');
    expect(toE164('+237690000001'), '+237690000001');
    expect(toE164('00237690000001'), '+237690000001');
  });
}
