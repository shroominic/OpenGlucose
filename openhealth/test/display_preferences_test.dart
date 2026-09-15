import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/display_preferences.dart';

void main() {
  test('experimental samples ignore a prior sensor display correction', () {
    const preferences = DisplayPreferences(
      calibrationScale: 2,
      calibrationOffset: 10,
    );
    final serialized = preferences.toJson();
    for (final source in CgmRecordSource.values) {
      for (final provisional in [false, true]) {
        final reading = CgmReading(
          valueMgdl: 180,
          source: source,
          isDisplayProvisional: provisional,
        );
        final expected = provisional || source == CgmRecordSource.raw
            ? 180.0
            : 370.0;
        expect(reading.displayValue(preferences), expected);
        expect(
          reading.displayValue(preferences.copyWith(unit: GlucoseUnit.mmolL)),
          GlucoseUnit.mmolL.convertFromMgdl(expected),
        );
      }
    }
    expect(preferences.toJson(), serialized);
  });
}
