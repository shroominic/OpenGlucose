import 'dart:async';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/debug_shared_scan_transport.dart';
import 'package:openglucose/src/local_ble_trace_sink.dart';
import 'package:openglucose/src/protocol_capture_status.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'openglucose-capture-status-test-',
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('new capture starts receive different process session identities', () {
    final first = newProtocolCaptureProcessSessionId();
    final second = newProtocolCaptureProcessSessionId();

    expect(first, isNot(second));
    expect(first, matches(r'^[A-Za-z0-9_-]{8,120}$'));
    expect(second, matches(r'^[A-Za-z0-9_-]{8,120}$'));
  });

  test(
    'publishes exact fail-closed schema and advancing health proofs',
    () async {
      final delegate = _StatusFakeTransport();
      final sink = LocalBleTraceSink(
        directoryProvider: () async => temporaryDirectory,
        sessionToken: 'ble-session',
      );
      var recorderTick = 0;
      final recorder = RecordingBleTransport(
        delegate: delegate,
        sink: sink,
        utcNow: () => DateTime.utc(
          2026,
          8,
          31,
        ).add(Duration(milliseconds: recorderTick)),
        monotonicNow: () => Duration(milliseconds: recorderTick++),
      );
      final scanner = DebugSharedScanTransport(
        delegate: recorder,
        physicalServiceUuids: const <String>[
          '0000fde3-0000-1000-8000-00805f9b34fb',
          '181F',
        ],
        physicalScanStates: delegate.scanStates,
        physicalScanIsActive: () => delegate.active,
        physicalScanStartAcknowledgements: delegate.scanStartAcknowledgements,
        physicalScanAttempt: () => delegate.latestScanAttempt,
      );
      final statuses = <Map<String, Object?>>[];
      final suspendedProof = Completer<void>();
      var suspendedProofCount = 0;
      final timers = <_ManualTimer>[];
      final publisher = ProtocolCaptureStatusPublisher(
        processSessionId: 'process-session',
        scanner: scanner,
        sink: sink,
        writer: (status) async {
          await Future<void>.delayed(Duration.zero);
          statuses.add(Map<String, Object?>.of(status));
          if (status['scannerState'] == 'suspended' &&
              ++suspendedProofCount >= 3 &&
              !suspendedProof.isCompleted) {
            suspendedProof.complete();
          }
        },
        commitHeartbeat: recorder.recordCaptureHeartbeat,
        utcNow: () => DateTime.utc(2026, 8, 31, 1),
        monotonicNow: () => Duration.zero,
        timerFactory: (interval, callback) {
          final timer = _ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
      );

      await publisher.start();
      expect(statuses, hasLength(1));
      expect(statuses.single.keys.toSet(), _statusKeys);
      expect(statuses.single['sinkState'], 'not_started');
      expect(statuses.single['scannerState'], 'not_started');
      expect(statuses.single['stopping'], isFalse);
      expect(statuses.single['heartbeatMonotonicMicroseconds'], 1);

      final healthyFuture = sink.healthChanges.firstWhere(
        (health) => health.state == LocalBleTraceSinkState.healthy,
      );
      await scanner.start();
      await healthyFuture;
      await pumpEventQueue(times: 30);

      expect(publisher.isReady, isTrue);
      expect(timers, isNotEmpty);
      expect(timers.last.isActive, isTrue);
      expect(
        scanner.physicalServiceUuids,
        const <String>[
          '0000fde3-0000-1000-8000-00805f9b34fb',
          '0000181f-0000-1000-8000-00805f9b34fb',
        ],
      );

      timers.last
        ..fire()
        ..fire();
      await _pumpUntil(() => _healthyStatuses(statuses).length >= 3);

      final healthyBeforeConnect = _healthyStatuses(statuses);
      expect(healthyBeforeConnect.length, greaterThanOrEqualTo(3));
      _expectStrictlyAdvancing(healthyBeforeConnect);

      final connectGate = Completer<void>();
      delegate.connectGate = connectGate;
      final connectFuture = scanner.connect('device-1');
      await pumpEventQueue(times: 20);
      expect(scanner.state, DebugSharedScanState.suspended);
      expect(timers.last.isActive, isTrue);
      expect(publisher.isReady, isFalse);
      timers.last
        ..fire()
        ..fire();
      await suspendedProof.future.timeout(const Duration(seconds: 5));
      await pumpEventQueue(times: 20);
      final suspended = statuses.lastWhere(
        (status) => status['scannerState'] == 'suspended',
      );
      expect(suspended['sinkState'], 'healthy');
      expect(suspended['scannerState'], 'suspended');
      _expectStrictlyAdvancing(
        statuses
            .where((status) => status['scannerState'] == 'suspended')
            .toList(),
      );

      connectGate.complete();
      await connectFuture;
      await pumpEventQueue(times: 20);
      expect(scanner.state, DebugSharedScanState.running);

      await publisher.markStopping();
      expect(timers.last.isActive, isFalse);
      final stopping = statuses.last;
      expect(stopping['stopping'], isTrue);
      expect(stopping['sinkState'], 'healthy');

      final allHealthy = _healthyStatuses(statuses);
      _expectStrictlyAdvancing(allHealthy);
      expect(
        allHealthy.every(
          (status) => status.keys.toSet().containsAll(_statusKeys),
        ),
        isTrue,
      );
      expect(
        allHealthy.every(
          (status) => (status['heartbeatMonotonicMicroseconds']! as int) > 0,
        ),
        isTrue,
      );

      await scanner.stop();
      await sink.close();
      await publisher.stop();
    },
  );

  test(
    'publishes the exact new BLE segment immediately after rotation',
    () async {
      final delegate = _StatusFakeTransport();
      final sink = LocalBleTraceSink(
        directoryProvider: () async => temporaryDirectory,
        sessionToken: 'rotation-session',
        maxSegmentBytes: 2048,
        maxSegmentCount: 4,
      );
      var recorderTick = 0;
      final recorder = RecordingBleTransport(
        delegate: delegate,
        sink: sink,
        utcNow: () => DateTime.utc(
          2026,
          8,
          31,
        ).add(Duration(milliseconds: recorderTick)),
        monotonicNow: () => Duration(milliseconds: recorderTick++),
      );
      final scanner = DebugSharedScanTransport(
        delegate: recorder,
        physicalServiceUuids: const <String>[
          '0000fde3-0000-1000-8000-00805f9b34fb',
          '0000181f-0000-1000-8000-00805f9b34fb',
        ],
        physicalScanStates: delegate.scanStates,
        physicalScanIsActive: () => delegate.active,
        physicalScanStartAcknowledgements: delegate.scanStartAcknowledgements,
        physicalScanAttempt: () => delegate.latestScanAttempt,
      );
      final statuses = <Map<String, Object?>>[];
      final initialHealthyStatus = Completer<Map<String, Object?>>();
      final rotatedHealthyStatus = Completer<Map<String, Object?>>();
      String? originalSegment;
      final publisher = ProtocolCaptureStatusPublisher(
        processSessionId: 'rotation-process',
        scanner: scanner,
        sink: sink,
        writer: (status) async {
          final published = Map<String, Object?>.of(status);
          statuses.add(published);
          if (published['sinkState'] == 'healthy' &&
              published['scannerState'] == 'running' &&
              published['bleTraceFileName'] != null) {
            if (!initialHealthyStatus.isCompleted) {
              initialHealthyStatus.complete(published);
            }
            if (originalSegment != null &&
                published['bleTraceFileName'] != originalSegment &&
                !rotatedHealthyStatus.isCompleted) {
              rotatedHealthyStatus.complete(published);
            }
          }
        },
        commitHeartbeat: recorder.recordCaptureHeartbeat,
        timerFactory: (_, callback) => _ManualTimer(callback),
      );
      addTearDown(() async {
        await publisher.markStopping();
        await scanner.stop();
        await publisher.stop();
        await sink.close();
      });

      await publisher.start();
      await scanner.start();
      // Scanner startup schedules real file I/O. Event-loop turns cannot prove
      // that file creation/fsync and the queued status write have completed.
      await initialHealthyStatus.future.timeout(const Duration(seconds: 5));

      originalSegment = sink.health.segmentFileName;
      expect(originalSegment, isNotNull);
      final statusCountBeforeRotation = statuses.length;

      for (
        var attempt = 0;
        attempt < 20 && sink.health.segmentFileName == originalSegment;
        attempt += 1
      ) {
        await recorder.recordCaptureHeartbeat();
      }
      expect(sink.health.segmentFileName, isNot(originalSegment));
      final rotatedSegment = sink.health.segmentFileName;

      final rotatedStatus = await rotatedHealthyStatus.future.timeout(
        const Duration(seconds: 5),
      );
      expect(rotatedStatus['bleTraceFileName'], rotatedSegment);

      final statusesAfterRotation = statuses.skip(statusCountBeforeRotation);
      expect(
        statusesAfterRotation.any(
          (status) =>
              status['sinkState'] == 'healthy' &&
              status['bleTraceFileName'] == rotatedSegment,
        ),
        isTrue,
      );
      expect(statuses.last['bleTraceFileName'], rotatedSegment);
    },
  );

  test('queued transitions never republish a stale running state', () async {
    final delegate = _StatusFakeTransport();
    final sink = LocalBleTraceSink(
      directoryProvider: () async => temporaryDirectory,
      sessionToken: 'transition-session',
    );
    final recorder = RecordingBleTransport(delegate: delegate, sink: sink);
    final scanner = DebugSharedScanTransport(
      delegate: recorder,
      physicalServiceUuids: const <String>[
        '0000fde3-0000-1000-8000-00805f9b34fb',
      ],
      physicalScanStates: delegate.scanStates,
      physicalScanIsActive: () => delegate.active,
      physicalScanStartAcknowledgements: delegate.scanStartAcknowledgements,
      physicalScanAttempt: () => delegate.latestScanAttempt,
    );
    final statuses = <Map<String, Object?>>[];
    final delayedWriter = Completer<void>();
    final writerEntered = Completer<void>();
    var delayNextWrite = false;
    final publisher = ProtocolCaptureStatusPublisher(
      processSessionId: 'transition-process',
      scanner: scanner,
      sink: sink,
      writer: (status) async {
        if (delayNextWrite) {
          delayNextWrite = false;
          writerEntered.complete();
          await delayedWriter.future;
        }
        statuses.add(Map<String, Object?>.of(status));
      },
      commitHeartbeat: recorder.recordCaptureHeartbeat,
      timerFactory: (_, callback) => _ManualTimer(callback),
    );

    await publisher.start();
    final baselineCount = statuses.length;
    delayNextWrite = true;
    await scanner.start();
    await writerEntered.future;
    expect(scanner.state, DebugSharedScanState.running);

    await scanner.stop();
    expect(scanner.state, DebugSharedScanState.stopped);
    delayedWriter.complete();
    await pumpEventQueue(times: 50);

    final laterHealthyStatuses = statuses
        .skip(baselineCount)
        .where(
          (status) => status['sinkState'] == 'healthy',
        );
    expect(
      laterHealthyStatuses.any(
        (status) => status['scannerState'] == 'running',
      ),
      isFalse,
    );
    expect(statuses.last['scannerState'], 'stopped');

    await publisher.stop();
    await sink.close();
  });
}

const Set<String> _statusKeys = <String>{
  'processSessionId',
  'bleTraceSessionId',
  'bleTraceFileName',
  'scannerState',
  'scannerServiceUuids',
  'sinkState',
  'lastCommittedBleSequence',
  'lastCommittedBleRecordedAtUtc',
  'capacityReached',
  'sinkErrorCode',
  'heartbeatAtUtc',
  'heartbeatMonotonicMicroseconds',
  'stopping',
};

/// Pumps the event loop until [condition] holds, or [timeout] elapses.
///
/// The status writer commits through real asynchronous work, so a fixed number
/// of event-loop turns is not a bound the runner honours under load: a loaded
/// host can leave the list short of the count the assertions below expect. This
/// waits on the condition instead and gives up after [timeout], so a real hang
/// still fails on the assertion that follows with the real evidence.
Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    // Always give the writer at least one turn, then stop as soon as the
    // condition holds instead of spending a fixed budget.
    await pumpEventQueue(times: 5);
    if (condition() || DateTime.now().isAfter(deadline)) {
      return;
    }
  }
}

List<Map<String, Object?>> _healthyStatuses(
  List<Map<String, Object?>> statuses,
) => statuses
    .where((status) => status['sinkState'] == 'healthy')
    .toList(growable: false);

void _expectStrictlyAdvancing(List<Map<String, Object?>> statuses) {
  for (var index = 1; index < statuses.length; index += 1) {
    expect(
      statuses[index]['lastCommittedBleSequence']! as int,
      greaterThan(statuses[index - 1]['lastCommittedBleSequence']! as int),
    );
    expect(
      statuses[index]['heartbeatMonotonicMicroseconds']! as int,
      greaterThan(
        statuses[index - 1]['heartbeatMonotonicMicroseconds']! as int,
      ),
    );
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  var _active = true;
  var _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  void fire() {
    if (!_active) {
      return;
    }
    _tick += 1;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }
}

final class _StatusFakeTransport implements BleTransport {
  final StreamController<bool> _scanStates = StreamController<bool>.broadcast(
    sync: true,
  );
  final List<StreamController<BleScanResult>> _scans =
      <StreamController<BleScanResult>>[];
  final StreamController<int> _scanStartAcknowledgements =
      StreamController<int>.broadcast(sync: true);

  bool active = false;
  int latestScanAttempt = 0;
  Completer<void>? connectGate;

  Stream<bool> get scanStates => _scanStates.stream;
  Stream<int> get scanStartAcknowledgements =>
      _scanStartAcknowledgements.stream;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    latestScanAttempt += 1;
    late final StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>(
      sync: true,
      onListen: () {
        active = true;
        _scanStates.add(true);
        _scanStartAcknowledgements.add(latestScanAttempt);
      },
      onCancel: () {
        if (_scans.isNotEmpty && identical(_scans.last, controller)) {
          active = false;
          _scanStates.add(false);
        }
      },
    );
    _scans.add(controller);
    return controller.stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final gate = connectGate;
    if (gate != null) {
      await gate.future;
      connectGate = null;
    }
    return _StatusFakeConnection(deviceId);
  }
}

final class _StatusFakeConnection implements BleConnection {
  _StatusFakeConnection(this.deviceId);

  @override
  final String deviceId;

  @override
  Stream<BleConnectionState> get connectionStates =>
      const Stream<BleConnectionState>.empty();

  @override
  bool get supportsBondLifecycle => false;

  @override
  Future<void> ensureBonded() async {}

  @override
  Future<BleBondState> currentBondState() async => BleBondState.unknown;

  @override
  Future<void> requestMtu(int mtu) async {}

  @override
  Future<List<BleService>> discoverServices() async => const <BleService>[];

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async =>
      const <int>[];

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {}

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {}

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      const Stream<List<int>>.empty();

  @override
  Future<void> removeBond() async {}

  @override
  Future<void> disconnect() async {}
}
