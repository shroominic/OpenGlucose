import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dashboard freshness uses the existing ten-minute boundary', () {
    final now = DateTime.utc(2030, 1, 1, 12);
    CgmReading reading(DateTime? at, {double value = 100}) => CgmReading(
      valueMgdl: value,
      source: CgmRecordSource.vendor,
      recordedAt: at,
      isDisplayProvisional: true,
    );
    final boundary = reading(now.subtract(const Duration(minutes: 10)));
    expect(dashboardReadingIsRecent(boundary, now: now), isTrue);
    expect(
      dashboardReadingIsRecent(
        boundary,
        now: now.add(const Duration(microseconds: 1)),
      ),
      isFalse,
    );
    expect(dashboardReadingIsRecent(null, now: now), isFalse);
    expect(dashboardReadingIsRecent(reading(null), now: now), isFalse);
    expect(
      dashboardReadingIsRecent(
        reading(now.add(const Duration(minutes: 2))),
        now: now,
      ),
      isTrue,
    );
    expect(
      dashboardReadingIsRecent(
        reading(now.add(const Duration(minutes: 2, microseconds: 1))),
        now: now,
      ),
      isFalse,
    );
    for (final value in [double.nan, double.infinity, 0.0, -1.0]) {
      expect(
        dashboardReadingIsRecent(reading(now, value: value), now: now),
        isFalse,
      );
    }
    expect(
      dashboardReadingIsRecent(
        CgmReading(
          valueMgdl: 100,
          source: CgmRecordSource.raw,
          recordedAt: now,
        ),
        now: now,
      ),
      isFalse,
    );
    expect(boundary.isDisplayProvisional, isTrue);
    expect(boundary.recordedAt, now.subtract(const Duration(minutes: 10)));
    expect(readingsForWellness([boundary]), isEmpty);
  });

  group('Libre NFC history prompt', () {
    final now = DateTime.utc(2030, 1, 1, 12);
    final sensor = DiscoveredSensor(
      driverId: 'libre2-gen1',
      deviceId: 'synthetic-libre',
      displayName: 'FreeStyle Libre 2',
      storageKey: 'synthetic-libre',
      rssi: -40,
      capabilities: const CgmCapabilities(supportsDirectBle: true),
    );

    CgmSessionSnapshot snapshot({
      CgmSyncStage stage = CgmSyncStage.disconnected,
      DateTime? recordedAt,
      bool inProgress = false,
    }) {
      final reading = recordedAt == null
          ? null
          : CgmReading(
              valueMgdl: 100,
              source: CgmRecordSource.vendor,
              recordedAt: recordedAt,
            );
      return CgmSessionSnapshot(
        stage: stage,
        statusText: '',
        sensor: sensor,
        capabilities: sensor.capabilities,
        history: reading == null ? const [] : [reading],
        latestReading: reading,
        historySync: CgmHistorySyncState(inProgress: inProgress),
      );
    }

    test('offers a prompt after a meaningful retained-data gap', () {
      expect(
        shouldOfferLibreNfcHistorySync(
          snapshot(
            recordedAt: now.subtract(const Duration(minutes: 11)),
          ),
          now: now,
        ),
        isTrue,
      );
    });

    test('does not prompt for fresh data or a setup transition', () {
      expect(
        shouldOfferLibreNfcHistorySync(
          snapshot(recordedAt: now.subtract(const Duration(minutes: 9))),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldOfferLibreNfcHistorySync(
          snapshot(
            stage: CgmSyncStage.connecting,
            recordedAt: now.subtract(const Duration(minutes: 30)),
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('does not prompt while another history sync is active', () {
      expect(
        shouldOfferLibreNfcHistorySync(
          snapshot(
            recordedAt: now.subtract(const Duration(minutes: 30)),
            inProgress: true,
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('does not prompt when the receiver state is uncertain', () {
      for (final code in const [
        'libre2.cleanupUnconfirmed',
        'libre2.loginOutcomeUnknown',
        'libre2.observationStorageUnavailable',
      ]) {
        expect(
          shouldOfferLibreNfcHistorySync(
            snapshot(
              recordedAt: now.subtract(const Duration(minutes: 30)),
            ).copyWith(lastError: code),
            now: now,
          ),
          isFalse,
          reason: code,
        );
      }
    });

    CgmSessionSnapshot withAges(List<int> ages) =>
        snapshot(
          stage: CgmSyncStage.ready,
        ).copyWith(
          history: ages
              .map(
                (age) => CgmReading(
                  valueMgdl: 100,
                  source: CgmRecordSource.vendor,
                  recordedAt: now.subtract(Duration(minutes: age)),
                ),
              )
              .toList(),
        );

    test('new live readings do not conceal a recoverable history gap', () {
      expect(
        shouldOfferLibreNfcHistorySync(withAges([120, 119, 2, 1]), now: now),
        isTrue,
      );
    });

    test('15-minute history and two-minute jitter do not prompt', () {
      expect(
        shouldOfferLibreNfcHistorySync(withAges([61, 44, 30, 15, 0]), now: now),
        isFalse,
      );
      expect(
        shouldOfferLibreNfcHistorySync(withAges([61, 43, 30, 15, 0]), now: now),
        isTrue,
      );
    });

    test('old gaps outside the eight-hour window do not prompt', () {
      final recent = List.generate(33, (index) => index * 15);
      expect(
        shouldOfferLibreNfcHistorySync(
          withAges([900, 800, ...recent]),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldOfferLibreNfcHistorySync(withAges([900, 800, 1]), now: now),
        isTrue,
      );
    });

    test(
      'unsorted duplicates and future dates cannot hide missing history',
      () {
        expect(
          shouldOfferLibreNfcHistorySync(
            withAges([-60, 1, 120, 1, 119]),
            now: now,
          ),
          isTrue,
        );
        expect(
          shouldOfferLibreNfcHistorySync(withAges([-60, 30]), now: now),
          isTrue,
        );
        expect(
          shouldOfferLibreNfcHistorySync(withAges([-60]), now: now),
          isFalse,
        );
      },
    );

    test('history action stays available while waiting for sensor return', () {
      expect(
        shouldOfferLibreNfcHistorySync(
          withAges([120, 1]).copyWith(
            stage: CgmSyncStage.connecting,
            metadata: {'cgm.libre2.phase': 'awaitingAdvertisement'},
          ),
          now: now,
        ),
        isTrue,
      );
    });

    test('Bluetooth-off prompt preserves history sync for Libre only', () {
      final off = withAges([
        120,
        1,
      ]).copyWith(stage: CgmSyncStage.error, lastError: 'libre2.bluetoothOff');
      expect(snapshotNeedsBluetoothEnabled(off), isTrue);
      expect(primaryErrorTextForSnapshot(off), isNull);
      expect(shouldOfferLibreNfcHistorySync(off, now: now), isTrue);
      expect(
        snapshotNeedsBluetoothEnabled(off.copyWith(stage: CgmSyncStage.ready)),
        isFalse,
      );
      expect(
        snapshotNeedsBluetoothEnabled(
          off.copyWith(lastError: 'libre2.cleanupUnconfirmed'),
        ),
        isFalse,
      );
    });
  });

  test(
    'data quality labels describe readings without changing their flags',
    () {
      const stable = CgmReading(
        valueMgdl: 100,
        source: CgmRecordSource.standard,
      );
      const provisional = CgmReading(
        valueMgdl: 101,
        source: CgmRecordSource.vendor,
        isDisplayProvisional: true,
      );
      const raw = CgmReading(valueMgdl: 102, source: CgmRecordSource.raw);
      const provisionalRaw = CgmReading(
        valueMgdl: 103,
        source: CgmRecordSource.raw,
        isDisplayProvisional: true,
      );
      expect(readingQualityLabelFor(const []), isNull);
      expect(readingQualityLabelFor(const [stable]), isNull);
      expect(
        readingQualityLabelFor(const [stable, provisional]),
        'Provisional readings',
      );
      expect(readingQualityLabelFor(const [stable, raw]), 'Raw sensor data');
      final mixed = List<CgmReading>.unmodifiable([stable, provisional, raw]);
      expect(readingQualityLabelFor(mixed), 'Provisional and raw readings');
      expect(
        readingQualityLabelFor(const [provisionalRaw]),
        'Provisional and raw readings',
      );
      expect(mixed, [stable, provisional, raw]);
      expect(provisional.isDisplayProvisional, isTrue);
      expect(raw.source, CgmRecordSource.raw);
      expect(readingsForWellness(mixed), [stable]);
    },
  );

  test(
    'wellness inputs exclude provisional and raw values without mutation',
    () {
      const verified = CgmReading(
        valueMgdl: 100,
        source: CgmRecordSource.standard,
      );
      const provisional = CgmReading(
        valueMgdl: 101,
        source: CgmRecordSource.vendor,
        isDisplayProvisional: true,
      );
      const raw = CgmReading(valueMgdl: 102, source: CgmRecordSource.raw);
      final values = [
        verified,
        provisional,
        raw,
        const CgmReading(
          valueMgdl: double.nan,
          source: CgmRecordSource.standard,
        ),
        const CgmReading(valueMgdl: 0, source: CgmRecordSource.standard),
      ];
      final result = readingsForWellness(values);
      expect(result, [verified]);
      expect(values, hasLength(5));
      expect(() => result.add(verified), throwsUnsupportedError);
    },
  );

  const libreSensor = DiscoveredSensor(
    driverId: 'libre2-gen1',
    deviceId: 'synthetic-libre',
    displayName: 'FreeStyle Libre 2',
    storageKey: 'synthetic-libre',
    rssi: -50,
    capabilities: CgmCapabilities(supportsDirectBle: true),
  );
  CgmSessionSnapshot libreSnapshot({
    CgmSyncStage stage = CgmSyncStage.syncing,
    String phase = 'validatedPacket',
    String? error,
    CgmReading? reading,
    List<CgmDiagnosticItem> diagnostics = const [],
  }) => CgmSessionSnapshot(
    stage: stage,
    statusText: 'synthetic-private-status',
    sensor: libreSensor,
    capabilities: libreSensor.capabilities,
    metadata: {'cgm.libre2.phase': phase},
    lastError: error,
    latestReading: reading,
    history: [if (reading != null) reading],
    diagnostics: diagnostics,
  );

  CgmDiagnosticItem packets(String value, {String phase = 'failed'}) =>
      CgmDiagnosticItem(
        key: 'libre2.gen1.transport',
        title: 'Libre 2 connection',
        summary: 'synthetic-private-summary',
        fields: {'phase': phase, 'validatedPackets': value},
      );

  group('durable Libre reception', () {
    CgmSessionSnapshot observed({
      DiscoveredSensor sensor = libreSensor,
      CgmSyncStage stage = CgmSyncStage.syncing,
      int? elapsed = 600,
      String? error,
      Map<String, String> metadata = const {
        'cgm.libre2.observationCommitted': 'true',
        'cgm.libre2.phase': 'validatedPacket',
        'cgm.libre2.timing': 'observed',
      },
    }) => CgmSessionSnapshot(
      stage: stage,
      statusText: 'Synthetic status',
      sensor: sensor,
      capabilities: sensor.capabilities,
      sessionInfo: CgmSessionInfo(elapsedMinutes: elapsed),
      history: const [
        CgmReading(
          valueMgdl: 101,
          source: CgmRecordSource.vendor,
          sensorMinute: 585,
          isDisplayProvisional: true,
        ),
      ],
      metadata: metadata,
      lastError: error,
    );

    test('verified reception does not require or create current glucose', () {
      for (final elapsed in [0, 59, 60, 600, 65535]) {
        final snapshot = observed(elapsed: elapsed);
        expect(
          hasVerifiedLibreReception(snapshot, expectedSensor: libreSensor),
          isTrue,
        );
        expect(snapshot.stage, CgmSyncStage.syncing);
        expect(snapshot.latestReading, isNull);
        expect(
          currentReadingForSnapshot(snapshot, snapshot.history.single),
          isNull,
        );
        expect(readingsForWellness(snapshot.history), isEmpty);
      }
    });

    test(
      'retained, pending, replayed, stale, failed or untimed data is not reception',
      () {
        final baseline = observed();
        for (final snapshot in [
          observed(metadata: const {}),
          for (final committed in ['false', 'pending', 'TRUE'])
            observed(
              metadata: {
                ...baseline.metadata,
                'cgm.libre2.observationCommitted': committed,
              },
            ),
          for (final timing in ['stale', 'repeatedOrRegressed', 'unavailable'])
            observed(
              metadata: {...baseline.metadata, 'cgm.libre2.timing': timing},
            ),
          observed(
            metadata: {
              ...baseline.metadata,
              'cgm.libre2.phase': 'awaitingPacket',
            },
          ),
          for (final stage in CgmSyncStage.values)
            if (stage != CgmSyncStage.syncing && stage != CgmSyncStage.ready)
              observed(stage: stage),
          for (final age in <int?>[null, -1, 65536]) observed(elapsed: age),
          observed(error: 'libre2.observationStorageUnavailable'),
          observed(error: ''),
        ]) {
          expect(
            hasVerifiedLibreReception(snapshot, expectedSensor: libreSensor),
            isFalse,
          );
        }
      },
    );

    test('all three target identity fields must match', () {
      for (final sensor in [
        const DiscoveredSensor(
          driverId: 'aidex',
          deviceId: 'synthetic-libre',
          displayName: 'Same name',
          storageKey: 'synthetic-libre',
          rssi: -50,
          capabilities: CgmCapabilities(),
        ),
        const DiscoveredSensor(
          driverId: 'libre2-gen1',
          deviceId: 'other-device',
          displayName: 'Same name',
          storageKey: 'synthetic-libre',
          rssi: -50,
          capabilities: CgmCapabilities(),
        ),
        const DiscoveredSensor(
          driverId: 'libre2-gen1',
          deviceId: 'synthetic-libre',
          displayName: 'Same name',
          storageKey: 'other-storage',
          rssi: -50,
          capabilities: CgmCapabilities(),
        ),
      ]) {
        expect(
          hasVerifiedLibreReception(
            observed(sensor: sensor),
            expectedSensor: libreSensor,
          ),
          isFalse,
        );
        expect(
          hasVerifiedLibreReception(observed(), expectedSensor: sensor),
          isFalse,
        );
      }
    });

    test('post-warmup missing current is not first-reading warmup', () {
      for (final age in [60, 600, 14000]) {
        final snapshot = observed(elapsed: age);
        expect(computeWarmupStatus(snapshot), isNull);
        expect(stageLabelForSnapshot(snapshot), 'No current reading');
        expect(stageCodeForSnapshot(snapshot), 'progress');
        expect(snapshot.latestReading, isNull);
      }
      final warming = computeWarmupStatus(observed(elapsed: 59));
      expect(warming?.phase, WarmupPhase.warming);
      expect(warming?.remainingMinutes, 1);
    });

    test(
      'stale and replayed reception use closed status, not decoder readiness',
      () {
        for (final entry in [
          ('stale', 'No recent sensor update. Waiting for new data.'),
          ('repeatedOrRegressed', 'Waiting for a new sensor reading.'),
        ]) {
          final snapshot = observed(
            metadata: {
              ...observed().metadata,
              'cgm.libre2.timing': entry.$1,
              'cgm.libre2.decoder': 'synthetic-private-decoder-detail',
            },
          );
          expect(libreConnectionDetailForSnapshot(snapshot), entry.$2);
          expect(computeWarmupStatus(snapshot), isNull);
          expect(snapshot.latestReading, isNull);
        }
      },
    );
  });

  test('verified packets distinguish connection loss from initial failure', () {
    final snapshot = libreSnapshot(
      stage: CgmSyncStage.error,
      phase: 'failed',
      error: 'libre2.disconnected',
      diagnostics: [packets('6')],
    );
    expect(libreConnectionWasLost(snapshot), isTrue);
    expect(stageLabelForSnapshot(snapshot), 'Connection lost');
    expect(stageCodeForSnapshot(snapshot), 'error');
    expect(
      primaryErrorTextForSnapshot(snapshot),
      'The sensor was sending data, then the connection stopped. '
      'Keep it close and try again.',
    );
    expect(
      libreConnectionDetailForSnapshot(snapshot),
      primaryErrorTextForSnapshot(snapshot),
    );
    for (final code in ['libre2.cleanupUnconfirmed', 'libre2.invalidPacket']) {
      final failed = snapshot.copyWith(lastError: code);
      expect(libreConnectionWasLost(failed), isTrue);
      expect(primaryErrorTextForSnapshot(failed), isNot(contains('libre2.')));
      expect(
        primaryErrorTextForSnapshot(failed),
        isNot(contains('Could not connect')),
      );
    }
  });

  test('decoder and recovery details are closed and stage-consistent', () {
    expect(
      libreGlucoseWaitingDetail('warmingUp'),
      'Sensor warming up. Waiting for glucose readings.',
    );
    expect(
      libreGlucoseWaitingDetail('invalidData'),
      'Receiving sensor data. No usable glucose reading yet.',
    );
    expect(
      libreGlucoseWaitingDetail('synthetic-private-native-error'),
      'Receiving sensor data. Glucose decoding is not ready.',
    );
    final recovering = libreSnapshot(
      stage: CgmSyncStage.connecting,
      phase: 'reconnecting',
    );
    expect(
      libreConnectionDetailForSnapshot(recovering),
      'Connection lost. Reconnecting once to your sensor.',
    );
    final provisional = libreSnapshot(
      stage: CgmSyncStage.ready,
      reading: const CgmReading(
        valueMgdl: 100,
        source: CgmRecordSource.vendor,
        isDisplayProvisional: true,
      ),
    );
    expect(
      libreConnectionDetailForSnapshot(provisional),
      isNull,
    );
    expect(
      libreConnectionDetailForSnapshot(
        provisional.copyWith(stage: CgmSyncStage.disconnected),
      ),
      'Sensor disconnected. Connect again to receive data.',
    );
  });

  test(
    'cached or malformed evidence cannot turn failure into connection loss',
    () {
      for (final evidence in <List<CgmDiagnosticItem>>[
        [],
        [packets('0')],
        [packets('-1')],
        [packets(' 6')],
        [packets('6.0')],
        [packets('6 synthetic-private-field')],
        [packets('6', phase: 'validatedPacket')],
        [packets('6'), packets('6')],
      ]) {
        final snapshot = libreSnapshot(
          stage: CgmSyncStage.error,
          phase: 'failed',
          error: 'libre2.connectionFailed',
          diagnostics: evidence,
          reading: CgmReading(valueMgdl: 123, source: CgmRecordSource.standard),
        );
        expect(libreConnectionWasLost(snapshot), isFalse);
        expect(stageLabelForSnapshot(snapshot), 'Error');
        expect(
          primaryErrorTextForSnapshot(snapshot),
          startsWith('Could not connect'),
        );
      }
      for (final snapshot in [
        libreSnapshot(
          stage: CgmSyncStage.disconnected,
          phase: 'disconnected',
          diagnostics: [packets('6', phase: 'disconnected')],
        ),
        libreSnapshot(
          stage: CgmSyncStage.error,
          phase: 'failed',
          error: 'libre2.cancelled',
          diagnostics: [packets('6')],
        ),
        libreSnapshot(
          stage: CgmSyncStage.syncing,
          diagnostics: [packets('6', phase: 'validatedPacket')],
        ),
      ]) {
        expect(libreConnectionWasLost(snapshot), isFalse);
      }
    },
  );

  test('Libre progress uses closed stage-consistent labels and details', () {
    for (final entry in <(CgmSyncStage, String, String, String)>[
      (
        CgmSyncStage.connecting,
        'awaitingAdvertisement',
        'Searching',
        'Looking for your Libre 2 sensor',
      ),
      (
        CgmSyncStage.syncing,
        'awaitingPacket',
        'Waiting',
        'Connected. Waiting for sensor data.',
      ),
      (
        CgmSyncStage.syncing,
        'validatedPacket',
        'Waiting',
        'Receiving sensor data. Glucose decoding is not ready.',
      ),
      (
        CgmSyncStage.connecting,
        'synthetic-private-phase',
        'Connecting',
        'Connecting to FreeStyle Libre 2',
      ),
      (
        CgmSyncStage.connecting,
        'validatedPacket',
        'Connecting',
        'Connecting to FreeStyle Libre 2',
      ),
      (
        CgmSyncStage.disconnected,
        'validatedPacket',
        'Disconnected',
        'Sensor disconnected. Connect again to receive data.',
      ),
    ]) {
      final snapshot = libreSnapshot(stage: entry.$1, phase: entry.$2);
      expect(stageLabelForSnapshot(snapshot), entry.$3);
      expect(libreConnectionDetailForSnapshot(snapshot), entry.$4);
      expect(stageCodeForSnapshot(snapshot), isNot('live'));
    }
  });

  test(
    'Libre return wait is distinct from initial search and stale metadata',
    () {
      final waiting =
          libreSnapshot(
            stage: CgmSyncStage.connecting,
            phase: 'awaitingAdvertisement',
          ).copyWith(
            metadata: {
              'cgm.libre2.phase': 'awaitingAdvertisement',
              'cgm.libre2.waitingForReturn': 'true',
            },
          );
      expect(stageLabelForSnapshot(waiting), 'Waiting');
      expect(
        libreConnectionDetailForSnapshot(waiting),
        'Waiting for your sensor to return. Keep it close to the phone.',
      );
      for (final value in ['false', 'TRUE', 'synthetic-private-text']) {
        final initial = waiting.copyWith(
          metadata: {
            'cgm.libre2.phase': 'awaitingAdvertisement',
            'cgm.libre2.waitingForReturn': value,
          },
        );
        expect(stageLabelForSnapshot(initial), 'Searching');
        expect(
          libreConnectionDetailForSnapshot(initial),
          'Looking for your Libre 2 sensor',
        );
      }
      final disconnected = waiting.copyWith(stage: CgmSyncStage.disconnected);
      expect(stageLabelForSnapshot(disconnected), 'Disconnected');
      expect(
        libreConnectionDetailForSnapshot(disconnected),
        'Sensor disconnected. Connect again to receive data.',
      );
      final failed = waiting.copyWith(
        stage: CgmSyncStage.error,
        lastError: 'libre2.bluetoothOff',
      );
      expect(stageLabelForSnapshot(failed), 'Bluetooth off');
      expect(
        libreConnectionDetailForSnapshot(failed),
        startsWith('Bluetooth is off.'),
      );
    },
  );

  test('Libre raw or missing readings cannot make ready mean live glucose', () {
    for (final reading in <CgmReading?>[
      null,
      CgmReading(valueMgdl: 123, source: CgmRecordSource.raw),
    ]) {
      final snapshot = libreSnapshot(
        stage: CgmSyncStage.ready,
        reading: reading,
      );
      expect(stageLabelForSnapshot(snapshot), 'Waiting');
      expect(stageCodeForSnapshot(snapshot), 'progress');
      expect(currentReadingForSnapshot(snapshot, reading), isNull);
      expect(
        libreConnectionDetailForSnapshot(snapshot),
        'Waiting for a verified glucose reading.',
      );
    }
  });

  test('Libre cached readings stay history until normalized ready output', () {
    final reading = CgmReading(
      valueMgdl: 123,
      source: CgmRecordSource.standard,
    );
    for (final stage in CgmSyncStage.values) {
      final snapshot = libreSnapshot(stage: stage, reading: reading);
      expect(snapshot.history, [reading]);
      expect(
        currentReadingForSnapshot(snapshot, reading),
        stage == CgmSyncStage.ready ? same(reading) : isNull,
      );
      if (stage != CgmSyncStage.ready) {
        expect(stageCodeForSnapshot(snapshot), isNot('live'));
        expect(stageLabelForSnapshot(snapshot), isNot('Connected'));
      }
    }
  });

  test('all Libre failures use closed text instead of internal fields', () {
    for (final code in <String>[
      'invalidBootstrap',
      'bootstrapUnavailable',
      'targetMismatch',
      'sessionInUse',
      'advertisementUnavailable',
      'oneShotUnavailable',
      'topologyRejected',
      'counterUnavailable',
      'connectionFailed',
      'loginOutcomeUnknown',
      'subscriptionFailed',
      'invalidPacket',
      'observationStorageUnavailable',
      'observationQueueOverflow',
      'disconnected',
      'cancelled',
      'cleanupUnconfirmed',
      'bluetoothOff',
      'permissionRequired',
      'bluetoothUnavailable',
      'scanFailed',
    ]) {
      final snapshot = libreSnapshot(
        stage: CgmSyncStage.error,
        error: 'libre2.$code',
      );
      final message = primaryErrorTextForSnapshot(snapshot);
      if (code == 'bluetoothOff') {
        expect(message, isNull);
        expect(stageLabelForSnapshot(snapshot), 'Bluetooth off');
        expect(stageCodeForSnapshot(snapshot), 'progress');
        expect(shouldOfferPrivateBleSupportCode(snapshot), isFalse);
        continue;
      }
      expect(message, isNotNull);
      expect(message, isNot(contains('libre2.')));
      expect(libreConnectionDetailForSnapshot(snapshot), message);
    }
    for (final code in [
      'libre2.connectionFailed synthetic-private-field',
      'synthetic-private-error',
    ]) {
      expect(
        primaryErrorTextForSnapshot(
          libreSnapshot(stage: CgmSyncStage.error, error: code),
        ),
        'OpenGlucose could not connect to your Libre 2 sensor.',
      );
    }
    expect(
      primaryErrorTextForSnapshot(
        libreSnapshot(stage: CgmSyncStage.syncing, error: 'libre2.cancelled'),
      ),
      isNull,
    );
  });

  test('Libre scan failures show the adapter action, not sensor-not-found', () {
    for (final failure in {
      'bluetoothOff': 'Bluetooth is off.',
      'permissionRequired': 'OpenGlucose needs Bluetooth access.',
      'bluetoothUnavailable': 'Bluetooth is not available',
      'scanFailed': 'The Bluetooth search could not finish.',
    }.entries) {
      final snapshot = libreSnapshot(
        stage: CgmSyncStage.error,
        error: 'libre2.${failure.key}',
      ).copyWith(metadata: {cgmAutomaticReconnectAllowedMetadataKey: 'false'});
      expect(
        libreConnectionDetailForSnapshot(snapshot),
        startsWith(failure.value),
      );
      if (failure.key == 'bluetoothOff') {
        expect(primaryErrorTextForSnapshot(snapshot), isNull);
      } else {
        expect(
          primaryErrorTextForSnapshot(snapshot),
          startsWith(failure.value),
        );
      }
      expect(
        primaryErrorTextForSnapshot(snapshot),
        isNot(contains('sensor was not found')),
      );
      expect(snapshotAllowsAutomaticReconnect(snapshot), isFalse);
    }
    expect(
      userMessageForLibreConnectionFailure('libre2.advertisementUnavailable'),
      startsWith('Your Libre 2 sensor was not found.'),
    );
    expect(
      userMessageForLibreConnectionFailure(
        'libre2.bluetoothOff private-details',
      ),
      'OpenGlucose could not connect to your Libre 2 sensor.',
    );
  });

  const sensor = DiscoveredSensor(
    driverId: 'demo',
    deviceId: 'sensor-1',
    displayName: 'Demo Sensor',
    storageKey: 'sensor-1',
    rssi: -50,
    capabilities: CgmCapabilities(),
  );

  test('primary error remains visible when cached glucose data exists', () {
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.error,
      statusText: 'Error',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: CgmReading(
        valueMgdl: 112,
        source: CgmRecordSource.vendor,
        recordedAt: DateTime.parse('2026-04-14T08:53:00Z'),
      ),
      history: <CgmReading>[
        CgmReading(
          valueMgdl: 111,
          source: CgmRecordSource.vendor,
          recordedAt: DateTime.parse('2026-04-14T08:52:00Z'),
        ),
      ],
      lastError: 'Timed out after 10s',
    );

    expect(shouldShowPrimaryError(snapshot), isTrue);
  });

  test('cached glucose during reconnect is not labelled Connected', () {
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.connecting,
      statusText: 'Reconnecting',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: CgmReading(
        valueMgdl: 112,
        source: CgmRecordSource.vendor,
        recordedAt: DateTime.parse('2026-04-14T08:53:00Z'),
      ),
      history: <CgmReading>[
        CgmReading(
          valueMgdl: 111,
          source: CgmRecordSource.vendor,
          recordedAt: DateTime.parse('2026-04-14T08:52:00Z'),
        ),
      ],
    );

    expect(stageLabelForSnapshot(snapshot), 'Reconnecting');
    expect(stageLabelForSnapshot(snapshot), isNot('Connected'));
    expect(stageCodeForSnapshot(snapshot), 'progress');
  });

  test('primary error remains visible when no glucose data exists', () {
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.error,
      statusText: 'Error',
      sensor: sensor,
      capabilities: sensor.capabilities,
      lastError: 'Timed out after 10s',
    );

    expect(shouldShowPrimaryError(snapshot), isTrue);
  });

  group('BLE setup recovery', () {
    CgmSessionSnapshot snapshotFor(BleFailureKind kind) {
      final failure = BleFailure(
        kind: kind,
        operation: kind == BleFailureKind.permissionRequired
            ? BleOperation.scan
            : BleOperation.bond,
        diagnosticCode: 'test.${kind.name}',
      );
      return CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: failure.toMetadata(),
        lastError: 'Bluetooth setup could not be completed.',
      );
    }

    test('permission failure gives platform-neutral settings guidance', () {
      final snapshot = snapshotFor(BleFailureKind.permissionRequired);
      final message = primaryErrorTextForSnapshot(snapshot)!;

      expect(message, contains('phone settings'));
      expect(message, contains('Bluetooth'));
      expect(message, contains('Location'));
      expect(message, isNot(contains('Android')));
      expect(bleFailureRequiresUserAction(snapshot), isTrue);
      expect(snapshotAllowsAutomaticReconnect(snapshot), isFalse);
    });

    test('pairing failure cautiously explains possible other-phone use', () {
      final snapshot = snapshotFor(BleFailureKind.sensorPossiblyInUse);
      final message = primaryErrorTextForSnapshot(snapshot)!;

      expect(message, contains('may be'));
      expect(message, contains('another phone'));
      expect(message, contains('Do not reset'));
      expect(message, isNot(contains('test.sensorPossiblyInUse')));
    });

    test('transient disconnect remains eligible for automatic reconnect', () {
      final snapshot = snapshotFor(BleFailureKind.deviceDisconnected);

      expect(bleFailureRequiresUserAction(snapshot), isFalse);
      expect(snapshotAllowsAutomaticReconnect(snapshot), isTrue);
    });

    test('driver can explicitly prohibit automatic reconnect', () {
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Explicit action required',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: const <String, String>{
          cgmAutomaticReconnectAllowedMetadataKey: 'false',
        },
      );

      expect(snapshotAllowsAutomaticReconnect(snapshot), isFalse);
    });

    for (final transferState in const <String>[
      'unknown',
      'sensor-accepted',
      'complete',
    ]) {
      test('$transferState transfer state never reconnects automatically', () {
        final snapshot = CgmSessionSnapshot(
          stage: CgmSyncStage.disconnected,
          statusText: 'Sensor transfer stopped',
          sensor: sensor,
          capabilities: sensor.capabilities,
          metadata: <String, String>{
            cgmBondTransferStateMetadataKey: transferState,
          },
        );

        expect(snapshotAllowsAutomaticReconnect(snapshot), isFalse);
      });
    }
  });

  group('private BLE support code', () {
    test('contains only the closed phase and sanitized BLE failure', () {
      final failure = BleFailure(
        kind: BleFailureKind.deviceDisconnected,
        operation: BleOperation.connect,
        diagnosticCode: 'aidex.connection.disconnected',
      );
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.discovery,
          ...failure.toMetadata(),
          'deviceId': 'AA:BB:CC:DD:EE:FF',
          'serial': 'PRIVATE-SERIAL',
          'nativeError': 'secret native text',
          'rawHex': 'deadbeef',
          'reading': '112',
          'timestamp': '2026-08-15T12:34:56Z',
        },
        lastError: 'secret error text',
      );

      final code = privateBleSupportCodeForSnapshot(snapshot);

      expect(
        code,
        'OGSUP1 phase=P04 op=connect kind=deviceDisconnected '
        'code=aidex.connection.disconnected',
      );
      expect(
        code,
        isNot(
          anyOf(
            contains('AA:BB'),
            contains('PRIVATE-SERIAL'),
            contains('secret'),
            contains('deadbeef'),
            contains('112'),
            contains('2026-08-15'),
          ),
        ),
      );
      expect(shouldOfferPrivateBleSupportCode(snapshot), isTrue);
    });

    test('connecting code contains a phase without invented failure data', () {
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.connecting,
        statusText: 'Connecting',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: const <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.connect,
        },
      );

      expect(privateBleSupportCodeForSnapshot(snapshot), 'OGSUP1 phase=P01');
      expect(shouldOfferPrivateBleSupportCode(snapshot), isTrue);
    });

    test('malformed phase is rejected rather than copied', () {
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: const <String, String>{
          aidexSetupPhaseMetadataKey: 'P04 device=AA:BB:CC:DD:EE:FF',
        },
        lastError: 'Failed',
      );

      expect(privateBleSupportCodeForSnapshot(snapshot), isNull);
      expect(shouldOfferPrivateBleSupportCode(snapshot), isFalse);
    });

    test('malformed BLE diagnostic is redacted by BleFailure parser', () {
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: const <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.subscribe,
          bleFailureKindMetadataKey: 'bondRejected',
          bleFailureOperationMetadataKey: 'subscribe',
          bleFailureDiagnosticCodeMetadataKey:
              'native failure AA:BB:CC:DD:EE:FF',
        },
        lastError: 'Failed',
      );

      expect(
        privateBleSupportCodeForSnapshot(snapshot),
        'OGSUP1 phase=P05 op=subscribe kind=bondRejected '
        'code=ble.redacted',
      );
    });

    test('P05 code includes only closed notification progress values', () {
      final failure = BleFailure(
        kind: BleFailureKind.deviceDisconnected,
        operation: BleOperation.subscribe,
        diagnosticCode: 'fbp.fbp.subscribe.6.devicedisconnected',
      );
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.subscribe,
          aidexSubscribeStepMetadataKey: AidexSubscribeStep.specificOps,
          aidexSubscribeAttemptMetadataKey: AidexSubscribeAttempt.recovery,
          ...failure.toMetadata(),
        },
        lastError: 'Failed',
      );

      expect(
        privateBleSupportCodeForSnapshot(snapshot),
        'OGSUP1 phase=P05 step=N04 attempt=A02 op=subscribe '
        'kind=deviceDisconnected code=fbp.fbp.subscribe.6.devicedisconnected',
      );
    });

    test('malformed notification progress is omitted from support code', () {
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: const <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.subscribe,
          aidexSubscribeStepMetadataKey: 'N04 device=AA:BB:CC:DD:EE:FF',
          aidexSubscribeAttemptMetadataKey: 'A02 secret',
        },
        lastError: 'Failed',
      );

      final code = privateBleSupportCodeForSnapshot(snapshot);
      expect(code, 'OGSUP1 phase=P05');
      expect(code, isNot(contains('AA:BB')));
      expect(code, isNot(contains('secret')));
    });

    test('ready sessions never offer a copy action', () {
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Connected',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: const <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.finalization,
        },
      );

      expect(shouldOfferPrivateBleSupportCode(snapshot), isFalse);
    });
  });

  group('computeWarmupStatus', () {
    CgmSessionSnapshot snapshotWith({
      DateTime? sessionStart,
      int? elapsedMinutes,
      int warmupMinutes = 60,
      int expectedLifetimeMinutes = 15 * 24 * 60,
    }) {
      return CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Warming up',
        sensor: sensor,
        capabilities: sensor.capabilities,
        sessionInfo: CgmSessionInfo(
          sessionStart: sessionStart,
          elapsedMinutes: elapsedMinutes,
          warmupMinutes: warmupMinutes,
          expectedLifetimeMinutes: expectedLifetimeMinutes,
        ),
      );
    }

    test('returns null when session start is unknown', () {
      expect(computeWarmupStatus(snapshotWith()), isNull);
    });

    test('uses reported elapsed minutes when session start is unknown', () {
      final status = computeWarmupStatus(snapshotWith(elapsedMinutes: 17));

      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.warming);
      expect(status.elapsedMinutes, 17);
      expect(status.remainingMinutes, 43);
    });

    test('prefers reported elapsed minutes over a drifting phone clock', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(
          sessionStart: now.subtract(const Duration(minutes: 90)),
          elapsedMinutes: 17,
        ),
        now: now,
      );

      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.warming);
      expect(status.elapsedMinutes, 17);
      expect(status.remainingMinutes, 43);
    });

    test(
      'keeps warming phase when a reading arrives inside the warmup window',
      () {
        final now = DateTime.parse('2026-04-17T10:00:00Z');
        final status = computeWarmupStatus(
          snapshotWith(sessionStart: now.subtract(const Duration(minutes: 10))),
          latestReading: CgmReading(
            valueMgdl: 157,
            source: CgmRecordSource.broadcast,
            recordedAt: now,
          ),
          now: now,
        );
        expect(status, isNotNull);
        expect(status!.phase, WarmupPhase.warming);
        expect(status.remainingMinutes, 50);
      },
    );

    test('returns null once a reading exists past the warmup window', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 75))),
        latestReading: CgmReading(
          valueMgdl: 112,
          source: CgmRecordSource.vendor,
          recordedAt: now,
        ),
        now: now,
      );
      expect(status, isNull);
    });

    test('reports warming phase while elapsed < warmupMinutes', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 12))),
        now: now,
      );
      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.warming);
      expect(status.elapsedMinutes, 12);
      expect(status.remainingMinutes, 48);
      expect(status.totalMinutes, 60);
      expect(warmupBigValueText(status), '48');
      expect(warmupUnitText(status), 'min');
      expect(warmupSubtext(status), 'Warming up');
      expect(warmupStageLabel(status), 'Warmup');
    });

    test('reports waiting phase once elapsed >= warmupMinutes', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 63))),
        now: now,
      );
      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.waiting);
      expect(status.elapsedMinutes, 63);
      expect(status.remainingMinutes, 0);
      expect(warmupBigValueText(status), '…');
      expect(warmupUnitText(status), 'waiting for first reading');
      expect(warmupSubtext(status), 'Warmup complete');
      expect(warmupStageLabel(status), 'Waiting');
    });

    test('clamps negative elapsed (clock skew) to full warmup window', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.add(const Duration(minutes: 5))),
        now: now,
      );
      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.warming);
      expect(status.elapsedMinutes, 0);
      expect(status.remainingMinutes, 60);
    });
  });

  group('sensor life constant', () {
    test('Aidex X is a 15-day sensor (TASK-043)', () {
      expect(kSensorLifeDuration, const Duration(days: 15));
    });
  });

  group('readingsAfterWarmup', () {
    test('excludes minutes 0..<warmup and includes the boundary', () {
      final sessionStart = DateTime.utc(2026, 4, 17, 10);
      final readings = <CgmReading>[
        CgmReading(
          valueMgdl: 101,
          source: CgmRecordSource.vendor,
          sensorMinute: 0,
          recordedAt: sessionStart,
        ),
        CgmReading(
          valueMgdl: 102,
          source: CgmRecordSource.vendor,
          sensorMinute: 59,
          recordedAt: sessionStart.add(const Duration(hours: 2)),
        ),
        CgmReading(
          valueMgdl: 103,
          source: CgmRecordSource.vendor,
          sensorMinute: 60,
          recordedAt: sessionStart.add(const Duration(minutes: 60)),
        ),
        CgmReading(
          valueMgdl: 104,
          source: CgmRecordSource.standard,
          recordedAt: sessionStart.add(const Duration(minutes: 59)),
        ),
        CgmReading(
          valueMgdl: 105,
          source: CgmRecordSource.standard,
          recordedAt: sessionStart.add(const Duration(minutes: 60)),
        ),
        const CgmReading(valueMgdl: 106, source: CgmRecordSource.standard),
      ];

      final visible = readingsAfterWarmup(
        readings,
        sessionStart: sessionStart,
        warmupMinutes: 60,
      );

      expect(visible.map((reading) => reading.valueMgdl), <double>[
        103,
        105,
        106,
      ]);
    });
  });

  group('computeSensorLifecycle', () {
    final now = DateTime.parse('2026-06-23T12:00:00Z');

    CgmSessionSnapshot snapshotWith({
      DateTime? sessionStart,
      int? elapsedMinutes,
      bool sessionStopped = false,
      bool expired = false,
      DateTime? lastSyncAt,
      int warmupMinutes = 60,
      int expectedLifetimeMinutes = 15 * 24 * 60,
    }) {
      return CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: '',
        sensor: sensor,
        capabilities: sensor.capabilities,
        sessionInfo: CgmSessionInfo(
          sessionStart: sessionStart,
          elapsedMinutes: elapsedMinutes,
          sessionStopped: sessionStopped,
          warmupMinutes: warmupMinutes,
          expectedLifetimeMinutes: expectedLifetimeMinutes,
        ),
        health: CgmHealthSnapshot(expired: expired),
        historySync: CgmHistorySyncState(lastSyncAt: lastSyncAt),
      );
    }

    test('unknown when there is no session start', () {
      final lifecycle = computeSensorLifecycle(snapshotWith(), now: now);
      expect(lifecycle.phase, SensorLifecyclePhase.unknown);
    });

    test('sensor-relative age displays life without inventing UTC start', () {
      final snapshot = snapshotWith(
        elapsedMinutes: 6 * 24 * 60,
        expectedLifetimeMinutes: 14 * 24 * 60,
      );
      for (final clock in [now, now.add(const Duration(days: 30))]) {
        final lifecycle = computeSensorLifecycle(snapshot, now: clock);
        expect(lifecycle.phase, SensorLifecyclePhase.active);
        expect(lifecycle.sessionStart, isNull);
        expect(lifecycle.age, const Duration(days: 6));
        expect(lifecycle.remaining, const Duration(days: 8));
        expect(
          sensorLifeText(
            null,
            elapsedMinutes: snapshot.sessionInfo.elapsedMinutes,
            totalLife: const Duration(days: 14),
            now: clock,
          ),
          '8 days left',
        );
      }
      expect(snapshot.sessionInfo.sessionStart, isNull);
      expect(snapshot.health.expired, isFalse);
      expect(snapshot.sessionInfo.sessionStopped, isFalse);
    });

    test('reported age gives warmup and nominal lifetime boundaries', () {
      final warming = computeSensorLifecycle(
        snapshotWith(elapsedMinutes: 17),
        now: now,
      );
      expect(warming.phase, SensorLifecyclePhase.warmup);
      expect(warming.warmup?.remainingMinutes, 43);
      final atEnd = snapshotWith(
        elapsedMinutes: 14 * 24 * 60,
        expectedLifetimeMinutes: 14 * 24 * 60,
      );
      final ended = computeSensorLifecycle(atEnd, now: now);
      expect(ended.phase, SensorLifecyclePhase.expired);
      expect(ended.remaining, Duration.zero);
      expect(atEnd.health.expired, isFalse);
      expect(atEnd.sessionInfo.sessionStopped, isFalse);
    });

    test('withdrawn or negative relative age cannot infer life', () {
      for (final elapsed in <int?>[null, -1]) {
        final result = computeSensorLifecycle(
          snapshotWith(elapsedMinutes: elapsed),
          now: now,
        );
        expect(result.phase, SensorLifecyclePhase.unknown);
        expect(result.sessionStart, isNull);
        expect(
          sensorLifeText(null, elapsedMinutes: elapsed, now: now),
          'Life remaining unavailable',
        );
      }
    });

    test('warmup phase inside the first hour', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 20))),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.warmup);
      expect(lifecycle.isWarmingUp, isTrue);
      expect(lifecycle.warmup, isNotNull);
      expect(lifecycle.lifeUsedPercent, 0);
    });

    test('active mid-life reports the correct percent used', () {
      // 6 of 15 days used => 40%.
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(const Duration(days: 6)),
          lastSyncAt: now,
        ),
        latestReading: CgmReading(
          valueMgdl: 120,
          source: CgmRecordSource.vendor,
          recordedAt: now,
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.active);
      expect(lifecycle.lifeUsedPercent, 40);
      expect(lifecycle.age, const Duration(days: 6));
      expect(lifecycle.remaining, const Duration(days: 9));
    });

    test('expiringSoon within the threshold window', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(
            kSensorLifeDuration - const Duration(hours: 3),
          ),
        ),
        latestReading: CgmReading(
          valueMgdl: 120,
          source: CgmRecordSource.vendor,
          recordedAt: now,
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.expiringSoon);
      expect(lifecycle.isExpiringSoon, isTrue);
      expect(
        lifecycle.remaining,
        lessThanOrEqualTo(kSensorExpiringSoonThreshold),
      );
    });

    test('expired by elapsed time past 15 days', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(
            kSensorLifeDuration + const Duration(hours: 2),
          ),
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.expired);
      expect(lifecycle.isExpired, isTrue);
      expect(lifecycle.lifeUsedPercent, 100);
      expect(lifecycle.remaining, Duration.zero);
    });

    test('uses a driver-provided 16-day wear time', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(const Duration(days: 15, hours: 12)),
          expectedLifetimeMinutes: 16 * 24 * 60,
        ),
        now: now,
      );

      expect(lifecycle.phase, SensorLifecyclePhase.expiringSoon);
      expect(lifecycle.totalLife, const Duration(days: 16));
      expect(lifecycle.remaining, const Duration(hours: 12));
    });

    test('expired when the session is stopped even if clock is borderline', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(const Duration(days: 14, hours: 23)),
          sessionStopped: true,
          expired: true,
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.expired);
      expect(lifecycle.lifeUsedFraction, 1.0);
    });
  });

  group('compactDurationText', () {
    test('formats days, hours, and minutes', () {
      expect(compactDurationText(const Duration(days: 3, hours: 4)), '3d 4h');
      expect(compactDurationText(const Duration(days: 2)), '2d');
      expect(
        compactDurationText(const Duration(hours: 5, minutes: 30)),
        '5h 30m',
      );
      expect(compactDurationText(const Duration(minutes: 45)), '45m');
      expect(compactDurationText(Duration.zero), '0h');
    });
  });

  group('lastSyncText', () {
    final now = DateTime.parse('2026-06-23T12:00:00Z');
    test('handles missing, recent, minutes, hours, and days', () {
      expect(lastSyncText(null, now: now), 'Not synced yet');
      expect(
        lastSyncText(now.subtract(const Duration(seconds: 5)), now: now),
        'Synced just now',
      );
      expect(
        lastSyncText(now.subtract(const Duration(minutes: 8)), now: now),
        'Synced 8 min ago',
      );
      expect(
        lastSyncText(now.subtract(const Duration(hours: 2)), now: now),
        'Synced 2 hours ago',
      );
      expect(
        lastSyncText(now.subtract(const Duration(days: 1)), now: now),
        'Synced 1 day ago',
      );
    });
  });
}
