import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/sensor_archive.dart';

void main() {
  const archive = ArchivedSensorSession(
    id: 'synthetic-archive',
    historyKey: 'synthetic-history',
    storageKey: 'synthetic-storage',
    driverId: 'synthetic-driver',
    deviceId: 'synthetic-device',
    displayName: 'Synthetic sensor',
    reason: SensorArchiveReason.disconnected,
    readingCount: 2,
    warmupMinutes: 17,
    sensorVariant: CgmSensorVariant(
      protocolFamily: 'synthetic-family',
      source: CgmSensorVariantSource.deviceInformation,
      model: 'Synthetic model',
      softwareRevision: 'next-version',
    ),
  );

  test(
    'archive preserves observed variant without changing reading identity',
    () {
      final restored = ArchivedSensorSession.fromJson(
        jsonDecode(jsonEncode(archive.toJson())) as Map<String, Object?>,
      );
      expect(restored.sensorVariant?.toJson(), archive.sensorVariant!.toJson());
      expect(restored.id, archive.id);
      expect(restored.historyKey, archive.historyKey);
      expect(restored.storageKey, archive.storageKey);
      expect(restored.driverId, archive.driverId);
      expect(restored.warmupMinutes, 17);
    },
  );

  test('old and malformed archives have no invented variant', () {
    for (final value in [null, 'unexpected', 1, <Object?>[]]) {
      final json = archive.toJson()..['sensorVariant'] = value;
      final restored = ArchivedSensorSession.fromJson(json);
      expect(restored.sensorVariant, isNull);
      expect(restored.toJson(), isNot(contains('sensorVariant')));
      expect(restored.historyKey, archive.historyKey);
    }
    final legacy = archive.toJson()..remove('sensorVariant');
    expect(ArchivedSensorSession.fromJson(legacy).sensorVariant, isNull);
  });
}
