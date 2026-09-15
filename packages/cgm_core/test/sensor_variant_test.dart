import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  const variant = CgmSensorVariant(
    protocolFamily: 'synthetic-family',
    source: CgmSensorVariantSource.deviceInformation,
    model: 'Synthetic model',
    softwareRevision: 'release-A/02',
  );

  test('unknown axes stay unknown and revisions remain opaque', () {
    final restored = CgmSensorVariant.fromJson(variant.toJson());
    expect(restored.toJson(), variant.toJson());
    expect(restored.region, isNull);
    expect(restored.hardwareRevision, isNull);
    expect(restored.firmwareRevision, isNull);
    expect(restored.securityGeneration, isNull);
    expect(restored.variantCode, isNull);
    expect(restored.softwareRevision, 'release-A/02');
    expect(restored.toJson(), isNot(contains('region')));
  });

  test('all descriptive axes survive an archive round trip', () {
    const complete = CgmSensorVariant(
      protocolFamily: 'synthetic-family',
      source: CgmSensorVariantSource.nfcPatchInfo,
      model: 'Synthetic model',
      variantCode: 'synthetic-variant',
      region: 'synthetic-region',
      hardwareRevision: 'hardware-A',
      firmwareRevision: 'firmware-B',
      softwareRevision: 'software-C',
      securityGeneration: 'synthetic-generation',
    );
    expect(
      CgmSensorVariant.fromJson(complete.toJson()).toJson(),
      complete.toJson(),
    );
  });

  test('unknown or malformed stored evidence does not gain authority', () {
    final restored = CgmSensorVariant.fromJson({
      'protocolFamily': 42,
      'source': 'verifiedAndAuthorized',
      'model': <String>['unexpected'],
      'variantCode': 'x' * 129,
      'region': '  ',
      'hardwareRevision': 'a\u0000b',
      'firmwareRevision': false,
      'softwareRevision': '  future-version  ',
    });
    expect(restored.protocolFamily, 'unknown');
    expect(restored.source, CgmSensorVariantSource.unknown);
    expect(restored.model, isNull);
    expect(restored.variantCode, isNull);
    expect(restored.region, isNull);
    expect(restored.hardwareRevision, isNull);
    expect(restored.firmwareRevision, isNull);
    expect(restored.softwareRevision, 'future-version');
    expect(restored.toString(), 'CgmSensorVariant(data: <redacted>)');
  });

  test('session updates preserve or explicitly clear identification', () {
    const info = CgmSessionInfo(sensorVariant: variant);
    final updated = info.copyWith(elapsedMinutes: 70);
    expect(updated.sensorVariant, same(variant));
    expect(updated.copyWith(clearSensorVariant: true).sensorVariant, isNull);
    expect(const CgmSessionInfo().sensorVariant, isNull);
    expect(updated.warmupMinutes, info.warmupMinutes);
    expect(updated.expectedLifetimeMinutes, info.expectedLifetimeMinutes);
  });
}
