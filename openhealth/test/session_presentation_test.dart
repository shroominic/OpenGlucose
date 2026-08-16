import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      bool sessionStopped = false,
      bool expired = false,
      DateTime? lastSyncAt,
      int warmupMinutes = 60,
    }) {
      return CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: '',
        sensor: sensor,
        capabilities: sensor.capabilities,
        sessionInfo: CgmSessionInfo(
          sessionStart: sessionStart,
          sessionStopped: sessionStopped,
          warmupMinutes: warmupMinutes,
        ),
        health: CgmHealthSnapshot(expired: expired),
        historySync: CgmHistorySyncState(lastSyncAt: lastSyncAt),
      );
    }

    test('unknown when there is no session start', () {
      final lifecycle = computeSensorLifecycle(snapshotWith(), now: now);
      expect(lifecycle.phase, SensorLifecyclePhase.unknown);
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
