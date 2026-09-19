import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

void main() {
  const sensorKey = 'synthetic-checkpoint-sensor';
  const valid = <String, Object>{
    'version': 1,
    'sensorKey': sensorKey,
    'index': 2,
    'rawTime': 1000,
  };
  final anchored = <String, Object>{
    ...valid,
    'rawTime': 1767225660,
    'anchor': <String, String>{
      cbioAnchorIndexMetadataKey: '1',
      cbioAnchorCoveredFromMetadataKey: '1',
      cbioAnchorEpochMetadataKey: '1767225600',
      cbioAnchorObservedAtMetadataKey: '2026-01-01T00:00:00.000Z',
      cbioClockReferenceEpochMetadataKey: '1767225600',
      cbioAnchorSourceMetadataKey: CbioAnchorSource.appSetSensorClock,
    },
  };

  test('decode retains bound witness without inventing wall time', () {
    final state = CbioSessionCheckpoint.decode(jsonEncode(valid), sensorKey)!;
    expect(state.index, 2);
    expect(state.rawTime, 1000);
    expect(state.anchor, isNull);
    expect(jsonDecode(state.encode()), valid);
  });

  test('restores earlier anchor only when it agrees with witness', () {
    final state = CbioSessionCheckpoint.decode(
      jsonEncode(anchored),
      sensorKey,
    )!;
    expect(state.anchor!.timeForIndex(2), DateTime.utc(2026, 1, 1, 0, 1));
    expect(jsonDecode(state.encode()), anchored);
  });

  for (final mutation in <Map<String, Object>>[
    {'version': 1.0},
    {'version': 2},
    {'sensorKey': 'another-sensor'},
    {'index': 0},
    {'index': -1},
    {'index': 65536},
    {'index': '2'},
    {'rawTime': -1},
    {'rawTime': 4294967296},
    {'rawTime': 1000.0},
    {'anchor': {}},
    {'anchor': 'invalid'},
  ]) {
    test('rejects incompatible or invalid checkpoint $mutation', () {
      expect(
        CbioSessionCheckpoint.decode(
          jsonEncode({...valid, ...mutation}),
          sensorKey,
        ),
        isNull,
      );
    });
  }

  for (final mutation in <Map<String, String>>[
    {cbioAnchorSourceMetadataKey: 'inferred-from-counter'},
    {cbioAnchorEpochMetadataKey: '1767225500'},
    {cbioAnchorIndexMetadataKey: '3'},
    {cbioAnchorCoveredFromMetadataKey: '2'},
    {cbioAnchorObservedAtMetadataKey: '2026-01-01T00:10:00.000Z'},
    {cbioClockReferenceEpochMetadataKey: ''},
  ]) {
    test('rejects inconsistent anchor provenance $mutation', () {
      final value = {
        ...anchored,
        'anchor': {...anchored['anchor']! as Map<String, String>, ...mutation},
      };
      expect(
        CbioSessionCheckpoint.decode(jsonEncode(value), sensorKey),
        isNull,
      );
    });
  }

  test('unknown fields do not prevent reading a supported schema', () {
    final state = CbioSessionCheckpoint.decode(
      jsonEncode({...valid, 'futureAnnotation': 'ignored'}),
      sensorKey,
    );
    expect(state?.index, 2);
  });
}
