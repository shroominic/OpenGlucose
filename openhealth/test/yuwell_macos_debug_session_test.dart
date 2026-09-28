import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/yuwell_macos_debug_session.dart';

const _capabilities = CgmCapabilities(
  supportsDirectBle: true,
  supportsVendorPairing: true,
  supportsHistory: true,
  supportsRawHistory: false,
  supportsDiagnostics: true,
);

DiscoveredSensor _sensor() => const DiscoveredSensor(
  driverId: 'fake-yuwell',
  deviceId: 'fake-device-id',
  displayName: 'Yuwell Anytime 5P',
  storageKey: 'yuwell:fake',
  rssi: -50,
  capabilities: _capabilities,
);

CgmSessionSnapshot _snapshot(
  DiscoveredSensor sensor,
  CgmSyncStage stage, {
  CgmReading? reading,
}) => CgmSessionSnapshot(
  stage: stage,
  statusText: stage.name,
  sensor: sensor,
  capabilities: sensor.capabilities,
  latestReading: reading,
);

void main() {
  test(
    'GRAB and RELEASE always bracket the attempt, even with no sensor',
    () async {
      final log = <String>[];
      final driver = _FakeDriver(scanResults: const []);

      final outcome = await runYuwellMacosDebugAttempt(
        driver: driver,
        log: log.add,
        scanTimeout: const Duration(milliseconds: 20),
        observeWindow: const Duration(milliseconds: 20),
      );

      expect(outcome.sensorFound, isFalse);
      expect(log.first, 'BLE GRAB @Claude — Anytime 5P');
      expect(log.last, 'BLE RELEASE @Claude');
    },
  );

  test('a provisional reading completes the attempt early', () async {
    final log = <String>[];
    final sensor = _sensor();
    final session = _FakeSession(
      sensor: sensor,
      initial: _snapshot(sensor, CgmSyncStage.connecting),
    );
    final driver = _FakeDriver(scanResults: [sensor], session: session);

    Timer.run(
      () => session.emit(
        _snapshot(
          sensor,
          CgmSyncStage.ready,
          reading: const CgmReading(
            valueMgdl: 118,
            source: CgmRecordSource.vendor,
          ),
        ),
      ),
    );

    final outcome = await runYuwellMacosDebugAttempt(
      driver: driver,
      log: log.add,
      observeWindow: const Duration(seconds: 5),
      showValue: true,
    );

    expect(outcome.sensorFound, isTrue);
    expect(outcome.gotProvisionalReading, isTrue);
    expect(outcome.provisionalValueMgdl, 118);
    expect(outcome.finalStage, CgmSyncStage.ready);
    expect(session.disconnected, isTrue);
    expect(log, contains('BLE GRAB @Claude — Anytime 5P'));
    expect(log.last, 'BLE RELEASE @Claude');
    expect(
      log.any((line) => line.contains('118 mg/dL')),
      isTrue,
      reason: 'showValue was explicitly requested',
    );
  });

  test('an observe-window timeout still disconnects and releases', () async {
    final log = <String>[];
    final sensor = _sensor();
    final session = _FakeSession(
      sensor: sensor,
      initial: _snapshot(sensor, CgmSyncStage.connecting),
    );
    final driver = _FakeDriver(scanResults: [sensor], session: session);

    final outcome = await runYuwellMacosDebugAttempt(
      driver: driver,
      log: log.add,
      observeWindow: const Duration(milliseconds: 30),
    );

    expect(outcome.sensorFound, isTrue);
    expect(outcome.gotProvisionalReading, isFalse);
    expect(session.disconnected, isTrue);
    expect(log.last, 'BLE RELEASE @Claude');
  });

  test(
    'the session reaching its own error stage ends the observe window '
    'early, without a reading',
    () async {
      // Distinct from both the timeout above and the stream-error test
      // below: here nothing is wrong with the stream itself -- the session
      // emits a perfectly normal snapshot, whose stage happens to be
      // CgmSyncStage.error. That must end the observe window immediately
      // rather than waiting out the timeout, and without ever setting
      // gotProvisionalReading.
      final log = <String>[];
      final sensor = _sensor();
      final session = _FakeSession(
        sensor: sensor,
        initial: _snapshot(sensor, CgmSyncStage.connecting),
      );
      final driver = _FakeDriver(scanResults: [sensor], session: session);

      Timer.run(() => session.emit(_snapshot(sensor, CgmSyncStage.error)));

      final stopwatch = Stopwatch()..start();
      final outcome = await runYuwellMacosDebugAttempt(
        driver: driver,
        log: log.add,
        observeWindow: const Duration(seconds: 5),
      );
      stopwatch.stop();

      expect(outcome.sensorFound, isTrue);
      expect(outcome.finalStage, CgmSyncStage.error);
      expect(outcome.gotProvisionalReading, isFalse);
      expect(session.disconnected, isTrue);
      expect(log.last, 'BLE RELEASE @Claude');
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason: 'reaching the error stage must not wait out observeWindow',
      );
    },
  );

  test(
    'a session snapshot-stream error still disconnects and releases',
    () async {
      // Distinct from the observe-window timeout above: here the observe
      // phase ends because the session's own snapshot stream errors, not
      // because nothing arrived in time. The finally block's cleanup
      // (cancel the listener, disconnect) must still run either way.
      final log = <String>[];
      final sensor = _sensor();
      final session = _FakeSession(
        sensor: sensor,
        initial: _snapshot(sensor, CgmSyncStage.connecting),
      );
      final driver = _FakeDriver(scanResults: [sensor], session: session);

      Timer.run(() => session.emitError(StateError('snapshot stream broke')));

      final outcome = await runYuwellMacosDebugAttempt(
        driver: driver,
        log: log.add,
        observeWindow: const Duration(seconds: 5),
      );

      expect(outcome.error, isNotNull);
      expect(session.disconnected, isTrue);
      expect(log.last, 'BLE RELEASE @Claude');
    },
  );

  test('a connect failure still releases and reports the error', () async {
    final log = <String>[];
    final sensor = _sensor();
    final driver = _FakeDriver(
      scanResults: [sensor],
      connectError: StateError('no route to sensor'),
    );

    final outcome = await runYuwellMacosDebugAttempt(
      driver: driver,
      log: log.add,
    );

    expect(outcome.error, isNotNull);
    expect(log.first, 'BLE GRAB @Claude — Anytime 5P');
    expect(log.last, 'BLE RELEASE @Claude');
  });

  test('a scan stream error still releases and reports the error', () async {
    // Distinct from a timeout (no advertisement observed) or a connect
    // failure (a candidate was found, connecting to it failed): here the
    // scan stream itself errors before any candidate arrives.
    final log = <String>[];
    final driver = _FakeDriver(
      scanStream: () =>
          Stream<DiscoveredSensor>.error(StateError('scan stream broke')),
    );

    final outcome = await runYuwellMacosDebugAttempt(
      driver: driver,
      log: log.add,
      scanTimeout: const Duration(milliseconds: 20),
    );

    // The outer catch's YuwellMacosDebugOutcome(sensorFound: true, ...) is
    // unconditional -- it does not distinguish a scan-stage error from a
    // later one. sensorFound is true here despite no candidate ever having
    // arrived; the log (asserted below) carries the real cause. Recorded
    // as observed behavior, not amended -- changing it is a driver-logic
    // decision this dig is not making.
    expect(outcome.sensorFound, isTrue);
    expect(outcome.error, isNotNull);
    expect(log.first, 'BLE GRAB @Claude — Anytime 5P');
    expect(log.any((line) => line.contains('attempt failed')), isTrue);
    expect(log.last, 'BLE RELEASE @Claude');
  });

  test(
    'a scan cancel that completes cleanly is logged and does not delay '
    'the attempt',
    () async {
      final log = <String>[];
      final driver = _FakeDriver(
        scanStream: () => _openEndedScan(onCancel: () async {}),
      );

      final stopwatch = Stopwatch()..start();
      final outcome = await runYuwellMacosDebugAttempt(
        driver: driver,
        log: log.add,
        scanTimeout: const Duration(milliseconds: 20),
      );
      stopwatch.stop();

      expect(outcome.sensorFound, isFalse);
      expect(log, contains('scan cancel completed cleanly.'));
      expect(log.last, 'BLE RELEASE @Claude');
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason: 'a clean cancel must not wait out the default cancel bound',
      );
    },
  );

  test(
    'a scan cancel that never completes still releases within the '
    'cancel bound, not by hanging',
    () async {
      final log = <String>[];
      final driver = _FakeDriver(
        scanStream: () =>
            _openEndedScan(onCancel: () => Completer<void>().future),
      );

      final outcome = await runYuwellMacosDebugAttempt(
        driver: driver,
        log: log.add,
        scanTimeout: const Duration(milliseconds: 20),
        scanCancelBound: const Duration(milliseconds: 30),
      );

      expect(outcome.sensorFound, isFalse);
      expect(
        log.any((line) => line.contains('did not complete within')),
        isTrue,
      );
      expect(log.last, 'BLE RELEASE @Claude');
    },
  );

  test(
    'a scan cancel that throws outright (not a timeout) still releases',
    () async {
      // Distinct from the two cancel-bound cases above: onCancel itself
      // rejects immediately, rather than never resolving. The generic
      // catch at the bottom of the cancel block, not the TimeoutException
      // branch, must handle this -- and the attempt still has to reach
      // BLE RELEASE.
      final log = <String>[];
      final driver = _FakeDriver(
        scanStream: () => _openEndedScan(
          onCancel: () async => throw StateError('cancel exploded'),
        ),
      );

      final outcome = await runYuwellMacosDebugAttempt(
        driver: driver,
        log: log.add,
        scanTimeout: const Duration(milliseconds: 20),
      );

      expect(outcome.sensorFound, isFalse);
      expect(log, contains('scan cancel failed: Bad state: cancel exploded'));
      expect(log.last, 'BLE RELEASE @Claude');
    },
  );

  test('showValue defaults to false and never echoes the number', () async {
    final log = <String>[];
    final sensor = _sensor();
    final session = _FakeSession(
      sensor: sensor,
      initial: _snapshot(sensor, CgmSyncStage.connecting),
    );
    final driver = _FakeDriver(scanResults: [sensor], session: session);

    Timer.run(
      () => session.emit(
        _snapshot(
          sensor,
          CgmSyncStage.ready,
          reading: const CgmReading(
            valueMgdl: 251,
            source: CgmRecordSource.vendor,
          ),
        ),
      ),
    );

    final outcome = await runYuwellMacosDebugAttempt(
      driver: driver,
      log: log.add,
      observeWindow: const Duration(seconds: 5),
    );

    expect(outcome.gotProvisionalReading, isTrue);
    expect(outcome.provisionalValueMgdl, isNull);
    expect(log.any((line) => line.contains('251')), isFalse);
  });
}

class _FakeSession implements CgmSession {
  _FakeSession({required this.sensor, required CgmSessionSnapshot initial})
    : currentSnapshot = initial;

  @override
  final DiscoveredSensor sensor;

  @override
  CgmSessionSnapshot currentSnapshot;

  final StreamController<CgmSessionSnapshot> _controller =
      StreamController<CgmSessionSnapshot>.broadcast();
  bool disconnected = false;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _controller.stream;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  void emit(CgmSessionSnapshot snapshot) {
    currentSnapshot = snapshot;
    _controller.add(snapshot);
  }

  void emitError(Object error) {
    _controller.addError(error);
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
    await _controller.close();
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshLiveData() async {}

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];
}

/// A scan stream that stays open — like a real BLE scan — until its
/// subscription is cancelled, at which point [onCancel] decides whether
/// (and when) that cancel resolves. Exercises the bounded-cancel fallback
/// in [runYuwellMacosDebugAttempt] without a radio.
Stream<DiscoveredSensor> _openEndedScan({
  required Future<void> Function() onCancel,
  DiscoveredSensor? emit,
}) {
  late final StreamController<DiscoveredSensor> controller;
  controller = StreamController<DiscoveredSensor>(
    onListen: () {
      final candidate = emit;
      if (candidate != null) {
        Timer.run(() => controller.add(candidate));
      }
    },
    onCancel: onCancel,
  );
  return controller.stream;
}

class _FakeDriver implements CgmDriver {
  _FakeDriver({
    this.scanResults = const <DiscoveredSensor>[],
    this.connectError,
    _FakeSession? session,
    Stream<DiscoveredSensor> Function()? scanStream,
  }) : _session = session,
       _scanStream = scanStream;

  @override
  final String driverId = 'fake';

  final List<DiscoveredSensor> scanResults;
  final Error? connectError;
  final _FakeSession? _session;
  final Stream<DiscoveredSensor> Function()? _scanStream;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) =>
      _scanStream?.call() ?? Stream<DiscoveredSensor>.fromIterable(scanResults);

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    final error = connectError;
    if (error != null) {
      throw error;
    }
    return _session!;
  }
}
