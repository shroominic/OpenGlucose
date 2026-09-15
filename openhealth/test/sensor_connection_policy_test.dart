import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/sensor_connection_policy.dart';

void main() {
  test('built-in policies retain each existing activation boundary', () {
    expect(
      builtInConnectionPolicyFor('aidex'),
      SensorConnectionPolicy.explicitConnect,
    );
    expect(
      builtInConnectionPolicyFor('yuwell-anytime'),
      SensorConnectionPolicy.separateConfirmation,
    );
    expect(
      builtInConnectionPolicyFor('libre2-gen1'),
      SensorConnectionPolicy.externalSetupOnly,
    );
  });

  test('unknown IDs cannot inherit another sensor activation policy', () {
    for (final driverId in ['', 'synthetic-future-sensor', 'AIDEX', 'aidex ']) {
      expect(
        builtInConnectionPolicyFor(driverId),
        SensorConnectionPolicy.externalSetupOnly,
        reason: driverId,
      );
    }
  });
}
