import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  test(
    'BLE history stays separate from current and diagnostics are redacted',
    () {
      const currentOnly = LibreGen1GlucoseResult(sensorAgeMinutes: 121);
      expect(currentOnly.historySamples, isEmpty);
      expect(() => currentOnly.historySamples.clear(), throwsUnsupportedError);
      const sample = LibreGen1GlucoseHistorySample(
        sampleAgeMinutes: 119,
        kind: LibreGen1BleHistoryKind.trend,
        glucoseMgdl: 123,
      );
      const historical = LibreGen1HistoricalReading(
        reading: CgmReading(
          valueMgdl: 123,
          source: CgmRecordSource.vendor,
          sensorMinute: 119,
          isDisplayProvisional: true,
        ),
        kind: LibreGen1BleHistoryKind.trend,
      );
      expect(
        sample.toString(),
        'LibreGen1GlucoseHistorySample(data: <redacted>)',
      );
      expect(
        historical.toString(),
        'LibreGen1HistoricalReading(data: <redacted>)',
      );
      expect(sample.sampleAgeMinutes, historical.reading.sensorMinute);
      const historyOnly = LibreGen1GlucoseResult(
        sensorAgeMinutes: 121,
        historySamples: [sample],
      );
      expect(historyOnly.glucoseMgdl, isNull);
      expect(historyOnly.sampleAgeMinutes, isNull);
      expect(historyOnly.historySamples.single, sample);
    },
  );

  LibreGen1ObservationBinding binding({
    String bootstrapId = 'synthetic-bootstrap',
    int uidFirstByte = 1,
    int region = 1,
    int patchTail = 2,
  }) => LibreGen1ObservationBinding.forSensor(
    bootstrapId: bootstrapId,
    uid: LibreGen1Uid.algorithmOrder([uidFirstByte, 2, 3, 4, 5, 6, 7, 8]),
    initialPatchInfo: LibreGen1PatchInfo([0x9d, 8, 0x30, region, 1, patchTail]),
  );

  test(
    'binding is exact to UID/model context and saved bootstrap identity',
    () {
      final first = binding();
      expect(first.sensorBindingDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(binding().sensorBindingDigest, first.sensorBindingDigest);
      expect(
        binding(uidFirstByte: 2).sensorBindingDigest,
        isNot(first.sensorBindingDigest),
      );
      expect(
        binding(region: 2).sensorBindingDigest,
        isNot(first.sensorBindingDigest),
      );
      expect(
        binding(patchTail: 3).sensorBindingDigest,
        first.sensorBindingDigest,
      );
      final next = binding(bootstrapId: 'synthetic-new-bootstrap');
      expect(next.sensorBindingDigest, first.sensorBindingDigest);
      expect(next.storageKey, isNot(first.storageKey));
      expect(first.driverId, 'libre2-gen1');
      expect(first.storageKey, 'libre2-gen1:synthetic-bootstrap');
      expect(first.toString(), isNot(contains(first.sensorBindingDigest)));
      expect(first.toString(), isNot(contains(first.bootstrapId)));
    },
  );

  test('malformed bindings fail without including identifiers in errors', () {
    for (final digest in ['', 'A' * 64, '0' * 63, 'g' * 64]) {
      expect(
        () => LibreGen1ObservationBinding(
          bootstrapId: 'synthetic-bootstrap',
          sensorBindingDigest: digest,
        ),
        throwsArgumentError,
      );
    }
    for (final id in ['', 'x' * 129]) {
      expect(
        () => LibreGen1ObservationBinding(
          bootstrapId: id,
          sensorBindingDigest: 'a' * 64,
        ),
        throwsArgumentError,
      );
    }
  });

  test('state is immutable and frontier uses the complete wire domain', () {
    final history = <CgmReading>[
      CgmReading(
        valueMgdl: 101,
        source: CgmRecordSource.vendor,
        sensorMinute: 60,
        recordedAt: DateTime.utc(2026),
        isDisplayProvisional: true,
      ),
    ];
    final state = LibreGen1ObservationState(
      observedMinute: 60,
      history: history,
    );
    history.clear();
    expect(state.history, hasLength(1));
    expect(() => state.history.clear(), throwsUnsupportedError);
    for (final minute in [0, 65535]) {
      expect(
        LibreGen1ObservationState(observedMinute: minute).observedMinute,
        minute,
      );
    }
    for (final minute in [-1, 65536]) {
      expect(
        () => LibreGen1ObservationState(observedMinute: minute),
        throwsArgumentError,
      );
    }
    expect(state.toString(), isNot(contains('101')));
    expect(
      LibreGen1ObservationCommit(advanced: true, state: state).toString(),
      'LibreGen1ObservationCommit(data: <redacted>)',
    );
  });

  test('historical replay barrier is separate from live observation', () {
    final state = LibreGen1ObservationState(
      observedMinute: 60,
      replayBarrierMinute: 120,
    );
    expect(state.observedMinute, 60);
    expect(state.effectiveReplayBarrierMinute, 120);
    expect(
      LibreGen1ObservationState(
        observedMinute: 60,
      ).effectiveReplayBarrierMinute,
      60,
    );
    final nfcOnly = LibreGen1ObservationState(replayBarrierMinute: 120);
    expect(nfcOnly.observedMinute, isNull);
    expect(nfcOnly.effectiveReplayBarrierMinute, 120);
    for (final barrier in [-1, 59, 65536]) {
      expect(
        () => LibreGen1ObservationState(
          observedMinute: 60,
          replayBarrierMinute: barrier,
        ),
        throwsArgumentError,
      );
    }
  });
}
