import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/debug_shared_scan_transport.dart';

void main() {
  const fde3 = '0000fde3-0000-1000-8000-00805f9b34fb';
  const cgm = '0000181f-0000-1000-8000-00805f9b34fb';

  test('logical scans share one fixed physical service union', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();

    expect(transport.state, DebugSharedScanState.running);
    expect(delegate.scanCalls, 1);
    expect(delegate.requestedServices.single, <String>[fde3, cgm]);

    final cgmResults = <BleScanResult>[];
    final cgmSubscription = transport
        .scan(withServices: const <String>['181F'], allowDuplicates: false)
        .listen(cgmResults.add);
    final allResults = <BleScanResult>[];
    final allSubscription = transport.scan().listen(allResults.add);
    expect(delegate.scanCalls, 1);

    final libre = _result('libre', const <String>[fde3], rssi: -40);
    final aidex = _result('aidex', const <String>['181F'], rssi: -50);
    delegate
      ..emit(libre)
      ..emit(aidex)
      ..emit(aidex);

    expect(cgmResults, <BleScanResult>[aidex]);
    expect(allResults, <BleScanResult>[libre, aidex, aidex]);
    await cgmSubscription.cancel();
    await allSubscription.cancel();
    expect(delegate.active, isTrue);
    expect(delegate.scanCalls, 1);

    await transport.stop();
    expect(delegate.active, isFalse);
    expect(transport.state, DebugSharedScanState.stopped);
  });

  test('logical timeout does not stop persistent physical capture', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();

    expect(
      await transport
          .scan(
            timeout: const Duration(milliseconds: 1),
            withServices: const <String>['181F'],
          )
          .toList(),
      isEmpty,
    );

    expect(delegate.active, isTrue);
    expect(delegate.scanCalls, 1);
    expect(transport.state, DebugSharedScanState.running);
    await transport.stop();
  });

  test('connect pauses and resumes capture on success and failure', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();

    final connection = await transport.connect('device-1');
    expect(connection.deviceId, 'device-1');
    expect(delegate.scanWasActiveAtConnect, isFalse);
    expect(delegate.scanCalls, 2);
    expect(delegate.active, isTrue);
    expect(transport.state, DebugSharedScanState.running);

    final failure = StateError('connect failure');
    delegate.connectError = failure;
    await expectLater(
      transport.connect('device-1'),
      throwsA(same(failure)),
    );
    expect(delegate.scanWasActiveAtConnect, isFalse);
    expect(delegate.scanCalls, 3);
    expect(delegate.active, isTrue);
    expect(transport.state, DebugSharedScanState.running);
    await transport.stop();
  });

  test('single-attempt connect forwards once with scanning stopped', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();
    expect(transport.supportsSingleAttemptConnect, isTrue);
    final connection = await transport.connectOnce('device-1');
    expect(delegate.singleAttemptCalls, 1);
    expect(delegate.defaultConnectCalls, 0);
    expect(delegate.scanWasActiveAtConnect, isFalse);
    expect(transport.state, DebugSharedScanState.suspended);
    expect(delegate.scanCalls, 1);
    await connection.discoverServices();
    await transport.start();
    expect(delegate.scanCalls, 1);
    await expectLater(transport.connectOnce('device-2'), throwsStateError);
    await expectLater(transport.connect('device-2'), throwsStateError);
    await connection.disconnect();
    expect(delegate.scanCalls, 2);
    expect(transport.state, DebugSharedScanState.running);
    await transport.stop();
  });

  test(
    'uncertain session close keeps exact owner and blocks all restarts',
    () async {
      final delegate = _FakePhysicalTransport();
      final transport = _transport(delegate);
      await transport.start();
      final connection = await transport.connectOnce('device-1');
      delegate.connections.single.disconnectError = StateError(
        'synthetic close',
      );
      await expectLater(connection.disconnect(), throwsStateError);
      await expectLater(connection.disconnect(), throwsStateError);
      await expectLater(transport.start(), throwsStateError);
      await expectLater(transport.connectOnce('device-1'), throwsStateError);
      await expectLater(transport.connect('device-1'), throwsStateError);
      expect(delegate.connections.single.disconnectCalls, 1);
      expect(delegate.connectCalls, 1);
      expect(delegate.scanCalls, 1);
      expect(transport.state, DebugSharedScanState.error);
      await expectLater(transport.stop(), throwsStateError);
    },
  );

  test('session close timeout cannot be cleared by late success', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();
    final connection = await transport.connectOnce('device-1');
    final gate = Completer<void>();
    delegate.connections.single.disconnectGate = gate;
    await runZoned(
      () async {
        final close = expectLater(connection.disconnect(), throwsStateError);
        await close;
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(seconds: 15)) {
            return parent.createTimer(
              zone,
              const Duration(milliseconds: 1),
              callback,
            );
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    gate.complete();
    await pumpEventQueue();
    await expectLater(connection.disconnect(), throwsStateError);
    await expectLater(transport.connectOnce('device-1'), throwsStateError);
    expect(delegate.connections.single.disconnectCalls, 1);
    expect(delegate.scanCalls, 1);
    await expectLater(transport.stop(), throwsStateError);
  });

  test('single-attempt failure never uses default connect or retry', () async {
    final delegate = _FakePhysicalTransport()
      ..connectError = StateError('synthetic connect failure');
    final transport = _transport(delegate);
    await transport.start();
    await expectLater(transport.connectOnce('device-1'), throwsStateError);
    expect(delegate.singleAttemptCalls, 1);
    expect(delegate.defaultConnectCalls, 0);
    expect(delegate.connectCalls, 1);
    expect(delegate.scanWasActiveAtConnect, isFalse);
    expect(transport.state, DebugSharedScanState.running);
    await transport.stop();
  });

  test('unsupported single-attempt connection never falls back', () async {
    final delegate = _FakePhysicalTransport()
      ..supportsSingleAttemptConnect = false;
    final transport = _transport(delegate);
    await transport.start();
    expect(transport.supportsSingleAttemptConnect, isFalse);
    await expectLater(
      transport.connectOnce('device-1'),
      throwsUnsupportedError,
    );
    expect(delegate.connectCalls, 0);
    expect(delegate.scanCalls, 1);
    await transport.stop();
  });

  test('unexpected physical completion fails closed then restarts', () async {
    final retryGate = Completer<void>();
    final delegate = _FakePhysicalTransport();
    final transport = _transport(
      delegate,
      retryDelay: (_) => retryGate.future,
      retryBackoff: const <Duration>[Duration.zero],
    );
    final states = <DebugSharedScanState>[];
    final stateSubscription = transport.states.listen(states.add);
    await transport.start();
    final results = <BleScanResult>[];
    final errors = <Object>[];
    var logicalDone = false;
    final logicalSubscription = transport.scan().listen(
      results.add,
      onError: errors.add,
      onDone: () => logicalDone = true,
    );

    await delegate.completeCurrentScan();
    await pumpEventQueue();
    expect(transport.state, DebugSharedScanState.error);
    expect(delegate.scanCalls, 1);
    expect(errors, isEmpty);
    expect(logicalDone, isFalse);

    retryGate.complete();
    await pumpEventQueue(times: 20);
    expect(delegate.scanCalls, 2);
    expect(delegate.active, isTrue);
    expect(transport.state, DebugSharedScanState.running);
    expect(states, contains(DebugSharedScanState.error));
    final result = _result('synthetic-target', const [fde3], rssi: -50);
    delegate.emit(result);
    expect(results, [result]);
    expect(errors, isEmpty);
    expect(logicalDone, isFalse);

    await logicalSubscription.cancel();
    await stateSubscription.cancel();
    await transport.stop();
  });

  test(
    'exhausted scan recovery promptly fails current and new scans',
    () async {
      final retryGate = Completer<void>();
      final delegate = _FakePhysicalTransport()
        ..autoAcknowledgeScanStart = false;
      final transport = _transport(
        delegate,
        retryDelay: (_) => retryGate.future,
        retryBackoff: const [Duration.zero],
      );
      await transport.start();
      final errors = <Object>[];
      final done = [Completer<void>(), Completer<void>()];
      for (final completion in done) {
        transport
            .scan(timeout: const Duration(seconds: 150))
            .listen(
              (_) {},
              onError: errors.add,
              onDone: completion.complete,
            );
      }

      await delegate.completeCurrentScan();
      await pumpEventQueue(times: 20);
      expect(errors, isEmpty);
      expect(done.every((completion) => !completion.isCompleted), isTrue);
      expect(delegate.scanCalls, 1);

      retryGate.complete();
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 2);
      await delegate.completeCurrentScan();
      await Future.wait(
        done.map((completion) => completion.future),
      ).timeout(const Duration(seconds: 1));
      final terminalFailure = isA<BleFailure>()
          .having((failure) => failure.kind, 'kind', BleFailureKind.unexpected)
          .having(
            (failure) => failure.operation,
            'operation',
            BleOperation.scan,
          )
          .having(
            (failure) => failure.diagnosticCode,
            'code',
            'debug.shared_scan.recovery_exhausted',
          );
      expect(errors, everyElement(terminalFailure));
      expect(errors, hasLength(2));
      await expectLater(
        transport.scan(timeout: const Duration(seconds: 150)),
        emitsInOrder([emitsError(terminalFailure), emitsDone]),
      );
      await expectLater(transport.start(), throwsA(terminalFailure));
      delegate
        ..reportPhysicalScanStarted()
        ..acknowledgeCurrentScanStart();
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 2);
      expect(transport.state, DebugSharedScanState.error);
      await transport.stop();
    },
  );

  test('terminal scan error retains the typed Bluetooth failure', () async {
    final delegate = _FakePhysicalTransport()..autoAcknowledgeScanStart = false;
    final transport = _transport(delegate, retryBackoff: const []);
    await transport.start();
    final failure = BleFailure(
      kind: BleFailureKind.bluetoothOff,
      operation: BleOperation.adapter,
      diagnosticCode: 'synthetic.adapter.bluetooth_off',
    );
    final logical = transport.scan(timeout: const Duration(seconds: 150));
    final expected = expectLater(
      logical,
      emitsInOrder([emitsError(same(failure)), emitsDone]),
    );
    delegate.reportPhysicalStateError(failure);
    await expected.timeout(const Duration(seconds: 1));
    await expectLater(transport.start(), throwsA(same(failure)));
    expect(delegate.scanCalls, 1);
    await transport.stop();
  });

  test(
    'new scan rearms Bluetooth-off only after cleanup and a fresh ack',
    () async {
      final delegate = _FakePhysicalTransport()
        ..autoAcknowledgeScanStart = false;
      final transport = _transport(delegate, retryBackoff: const []);
      await transport.start();
      final oldResults = <BleScanResult>[];
      final oldErrors = <Object>[];
      final oldDone = Completer<void>();
      transport.scan().listen(
        oldResults.add,
        onError: oldErrors.add,
        onDone: oldDone.complete,
      );
      final failure = _bluetoothOff();
      delegate.reportPhysicalStateError(failure);
      await oldDone.future.timeout(const Duration(seconds: 1));
      expect(oldErrors, [same(failure)]);
      expect(delegate.cancelCalls, 1);
      expect(delegate.active, isFalse);
      await expectLater(transport.start(), throwsA(same(failure)));

      final firstResults = <BleScanResult>[];
      final secondResults = <BleScanResult>[];
      final first = transport
          .scan(withServices: const [fde3])
          .listen(firstResults.add);
      final second = transport
          .scan(withServices: const [fde3])
          .listen(secondResults.add);
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 2);
      expect(delegate.connectCalls, 0);
      expect(transport.state, DebugSharedScanState.starting);
      delegate.acknowledgeScanAttempt(1);
      expect(transport.state, DebugSharedScanState.starting);
      delegate.acknowledgeCurrentScanStart();
      expect(transport.state, DebugSharedScanState.running);
      final result = _result('synthetic-new-advertisement', const [
        fde3,
      ], rssi: -50);
      delegate.emit(result);
      expect(firstResults, [result]);
      expect(secondResults, [result]);
      expect(oldResults, isEmpty);
      expect(oldErrors, hasLength(1));
      await first.cancel();
      await second.cancel();
      await transport.stop();
    },
  );

  test('each fresh Bluetooth-off attempt remains bounded', () async {
    final delegate = _FakePhysicalTransport()..autoAcknowledgeScanStart = false;
    final transport = _transport(delegate, retryBackoff: const []);
    await transport.start();
    for (var attempt = 1; attempt <= 3; attempt++) {
      final failure = _bluetoothOff();
      final done = expectLater(
        transport.scan(),
        emitsInOrder([emitsError(same(failure)), emitsDone]),
      );
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, attempt);
      delegate.reportPhysicalStateError(failure);
      await done.timeout(const Duration(seconds: 1));
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, attempt);
      expect(delegate.cancelCalls, attempt);
      expect(transport.state, DebugSharedScanState.error);
      await expectLater(transport.start(), throwsA(same(failure)));
    }
    expect(delegate.connectCalls, 0);
    await transport.stop();
  });

  test(
    'invalid services and external activity cannot rearm exhausted scan',
    () async {
      final delegate = _FakePhysicalTransport()
        ..autoAcknowledgeScanStart = false;
      final transport = _transport(delegate, retryBackoff: const []);
      await transport.start();
      final failure = _bluetoothOff();
      final done = expectLater(
        transport.scan(),
        emitsInOrder([emitsError(same(failure)), emitsDone]),
      );
      delegate.reportPhysicalStateError(failure);
      await done;
      await expectLater(
        transport.scan(withServices: const ['180D']),
        emitsError(isArgumentError),
      );
      await expectLater(transport.start(), throwsA(same(failure)));
      delegate.reportPhysicalScanStarted();
      await expectLater(transport.scan(), emitsError(same(failure)));
      expect(delegate.scanCalls, 1);
      delegate.reportPhysicalScanStopped();
      final subscription = transport.scan().listen((_) {});
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 2);
      await subscription.cancel();
      await transport.stop();
    },
  );

  for (final newerFailure in [
    'untyped',
    'typed',
    'done',
    'synchronous',
    'delay',
  ]) {
    test(
      'newer $newerFailure failure cannot inherit Bluetooth-off recovery',
      () async {
        final retryGate = Completer<void>();
        final delegate = _FakePhysicalTransport()
          ..autoAcknowledgeScanStart = false;
        final transport = _transport(
          delegate,
          retryBackoff: const [Duration.zero],
          retryDelay: (_) => retryGate.future,
        );
        await transport.start();
        final errors = <Object>[];
        final done = Completer<void>();
        transport.scan().listen(
          (_) {},
          onError: errors.add,
          onDone: done.complete,
        );
        delegate.reportPhysicalStateError(_bluetoothOff());
        await pumpEventQueue(times: 20);
        if (newerFailure == 'synchronous') {
          delegate.scanError = StateError('synthetic scan start failure');
        }
        if (newerFailure == 'delay') {
          retryGate.completeError(StateError('synthetic delay failure'));
        } else {
          retryGate.complete();
        }
        await pumpEventQueue(times: 20);
        if (newerFailure == 'untyped') {
          delegate.reportPhysicalStateError(
            StateError('synthetic unknown failure'),
          );
        } else if (newerFailure == 'typed') {
          delegate.reportPhysicalStateError(
            BleFailure(
              kind: BleFailureKind.unexpected,
              operation: BleOperation.scan,
              diagnosticCode: 'synthetic.scan.failure',
            ),
          );
        } else if (newerFailure == 'done') {
          await delegate.completeCurrentScan();
        }
        await done.future.timeout(const Duration(seconds: 1));
        final terminal = isA<BleFailure>().having(
          (failure) => failure.kind,
          'kind',
          BleFailureKind.unexpected,
        );
        expect(errors.last, terminal);
        final previousScanCalls = delegate.scanCalls;
        await expectLater(transport.scan(), emitsError(terminal));
        await expectLater(transport.start(), throwsA(terminal));
        expect(delegate.scanCalls, previousScanCalls);
        await transport.stop();
      },
    );
  }

  test(
    'Bluetooth-off cancellation failure cannot rearm through a new scan',
    () async {
      final gate = Completer<void>();
      final delegate = _FakePhysicalTransport()
        ..autoAcknowledgeScanStart = false
        ..cancelGate = gate
        ..cancelError = StateError('synthetic cleanup failure');
      final transport = _transport(delegate, retryBackoff: const []);
      await transport.start();
      delegate.reportPhysicalStateError(_bluetoothOff());
      await pumpEventQueue(times: 20);
      final pending = transport.scan().listen((_) {});
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 1);
      gate.complete();
      await pumpEventQueue(times: 20);
      await expectLater(transport.scan(), emitsError(isStateError));
      await expectLater(
        transport.connectOnce('synthetic-target'),
        throwsStateError,
      );
      expect(delegate.scanCalls, 1);
      expect(delegate.connectCalls, 0);
      await pending.cancel();
      await expectLater(transport.stop(), throwsStateError);
    },
  );

  test('a pending final retry is not mistaken for exhaustion', () async {
    final retryGate = Completer<void>();
    final delegate = _FakePhysicalTransport()..autoAcknowledgeScanStart = false;
    final transport = _transport(
      delegate,
      retryDelay: (_) => retryGate.future,
      retryBackoff: const [Duration.zero],
    );
    await transport.start();
    final errors = <Object>[];
    var done = false;
    final subscription = transport.scan().listen(
      (_) {},
      onError: errors.add,
      onDone: () => done = true,
    );
    await delegate.completeCurrentScan();
    await pumpEventQueue(times: 20);
    delegate.reportPhysicalStateError(StateError('synthetic state failure'));
    await pumpEventQueue(times: 20);
    expect(errors, isEmpty);
    expect(done, isFalse);
    retryGate.complete();
    await pumpEventQueue(times: 20);
    expect(delegate.scanCalls, 2);
    delegate.acknowledgeCurrentScanStart();
    expect(transport.state, DebugSharedScanState.running);
    expect(errors, isEmpty);
    expect(done, isFalse);
    await subscription.cancel();
    await transport.stop();
  });

  for (final singleAttempt in [false, true]) {
    test(
      'exhausted scanner blocks ${singleAttempt ? 'connectOnce' : 'connect'} '
      'before RF or pause ownership changes',
      () async {
        final delegate = _FakePhysicalTransport()
          ..autoAcknowledgeScanStart = false;
        final transport = _transport(delegate, retryBackoff: const []);
        await transport.start();
        final failure = BleFailure(
          kind: BleFailureKind.bluetoothOff,
          operation: BleOperation.adapter,
          diagnosticCode: 'synthetic.adapter.bluetooth_off',
        );
        final failedScan = expectLater(
          transport.scan(),
          emitsInOrder([
            emitsError(same(failure)),
            emitsDone,
          ]),
        );
        delegate.reportPhysicalStateError(failure);
        await failedScan.timeout(const Duration(seconds: 1));
        final states = <DebugSharedScanState>[];
        final stateSubscription = transport.states.listen(states.add);
        final previousCancelCalls = delegate.cancelCalls;

        await expectLater(
          singleAttempt
              ? transport.connectOnce('synthetic-target')
              : transport.connect('synthetic-target'),
          throwsA(same(failure)),
        );

        expect(delegate.connectCalls, 0);
        expect(delegate.singleAttemptCalls, 0);
        expect(delegate.defaultConnectCalls, 0);
        expect(delegate.cancelCalls, previousCancelCalls);
        expect(delegate.scanCalls, 1);
        expect(states, isEmpty);
        expect(transport.state, DebugSharedScanState.error);
        await stateSubscription.cancel();
        await transport.stop();
      },
    );
  }

  test('retry delay exhaustion emits only a closed scan failure', () async {
    final delegate = _FakePhysicalTransport();
    var delayCalls = 0;
    final transport = _transport(
      delegate,
      retryBackoff: const [Duration.zero, Duration.zero],
      retryDelay: (_) async {
        delayCalls += 1;
        throw StateError('synthetic private platform message');
      },
    );
    await transport.start();
    final expected = expectLater(
      transport.scan(),
      emitsInOrder([
        emitsError(
          isA<BleFailure>().having(
            (failure) => failure.diagnosticCode,
            'code',
            'debug.shared_scan.recovery_exhausted',
          ),
        ),
        emitsDone,
      ]),
    );
    delegate.reportPhysicalScanStopped();
    await expected.timeout(const Duration(seconds: 1));
    expect(delayCalls, 2);
    expect(delegate.scanCalls, 1);
    await transport.stop();
  });

  test('a session-owned scan pause does not exhaust recovery', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate, retryBackoff: const []);
    await transport.start();
    final connection = await transport.connectOnce('synthetic-target');
    final results = <BleScanResult>[];
    final errors = <Object>[];
    var done = false;
    final subscription = transport.scan().listen(
      results.add,
      onError: errors.add,
      onDone: () => done = true,
    );
    await pumpEventQueue(times: 20);
    expect(transport.state, DebugSharedScanState.suspended);
    expect(delegate.scanCalls, 1);
    expect(errors, isEmpty);
    expect(done, isFalse);
    await connection.disconnect();
    expect(transport.state, DebugSharedScanState.running);
    expect(delegate.scanCalls, 2);
    final result = _result('synthetic-target', const [fde3], rssi: -50);
    delegate.emit(result);
    expect(results, [result]);
    expect(errors, isEmpty);
    expect(done, isFalse);
    await subscription.cancel();
    await transport.stop();
  });

  test('global scan activity cannot prove union-scan readiness', () async {
    final delegate = _FakePhysicalTransport()
      ..active = true
      ..autoAcknowledgeScanStart = false;
    final transport = _transport(delegate);

    await transport.start();
    expect(transport.state, DebugSharedScanState.starting);

    delegate.acknowledgeCurrentScanStart();
    expect(transport.state, DebugSharedScanState.running);

    await transport.stop();
  });

  test('failed physical starts never publish running before an ack', () async {
    final retryGate = Completer<void>();
    final delegate = _FakePhysicalTransport()..autoAcknowledgeScanStart = false;
    final transport = _transport(
      delegate,
      retryDelay: (_) => retryGate.future,
      retryBackoff: const <Duration>[Duration.zero],
    );
    final states = <DebugSharedScanState>[];
    final subscription = transport.states.listen(states.add);

    await transport.start();
    expect(transport.state, DebugSharedScanState.starting);
    await delegate.completeCurrentScan();
    await pumpEventQueue(times: 10);
    expect(transport.state, DebugSharedScanState.error);
    expect(states, isNot(contains(DebugSharedScanState.running)));

    retryGate.complete();
    await pumpEventQueue(times: 20);
    expect(delegate.scanCalls, 2);
    expect(transport.state, DebugSharedScanState.starting);
    expect(states, isNot(contains(DebugSharedScanState.running)));

    delegate.acknowledgeCurrentScanStart();
    expect(transport.state, DebugSharedScanState.running);
    await subscription.cancel();
    await transport.stop();
  });

  test(
    'failed subscription cancellation cannot retain running state',
    () async {
      final retryGate = Completer<void>();
      final delegate = _FakePhysicalTransport()
        ..cancelError = StateError('cancel failure');
      final transport = _transport(
        delegate,
        retryDelay: (_) => retryGate.future,
        retryBackoff: const <Duration>[Duration.zero],
      );
      await transport.start();

      delegate.reportPhysicalScanStopped();
      await pumpEventQueue(times: 20);

      expect(transport.state, DebugSharedScanState.error);
      expect(delegate.scanCalls, 1);

      retryGate.complete();
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 1);
      expect(transport.state, DebugSharedScanState.error);

      await expectLater(transport.stop(), throwsStateError);
      expect(delegate.cancelCalls, 1);
    },
  );

  test('retry-delay failures stay bounded and fail closed', () async {
    final delegate = _FakePhysicalTransport();
    var delayCalls = 0;
    final transport = _transport(
      delegate,
      retryDelay: (_) async {
        delayCalls += 1;
        if (delayCalls == 1) {
          throw StateError('retry delay failure');
        }
      },
      retryBackoff: const <Duration>[Duration.zero, Duration.zero],
    );
    await transport.start();

    delegate.reportPhysicalScanStopped();
    await pumpEventQueue(times: 30);

    expect(delayCalls, 2);
    expect(delegate.scanCalls, 2);
    expect(transport.state, DebugSharedScanState.running);
    await transport.stop();
  });

  test(
    'uncertain physical stop blocks every later scan and connection',
    () async {
      final delegate = _FakePhysicalTransport()
        ..cancelError = StateError('synthetic physical stop failure');
      final transport = _transport(delegate);
      await transport.start();
      await expectLater(transport.connectOnce('device-1'), throwsStateError);
      await pumpEventQueue(times: 20);
      expect(delegate.scanCalls, 1);
      expect(delegate.connectCalls, 0);
      expect(delegate.cancelCalls, 1);
      expect(transport.state, DebugSharedScanState.error);

      delegate.reportPhysicalScanStarted();
      delegate.acknowledgeCurrentScanStart();
      expect(transport.state, DebugSharedScanState.error);
      await expectLater(transport.connectOnce('device-1'), throwsStateError);
      await expectLater(transport.connect('device-1'), throwsStateError);
      await expectLater(transport.start(), throwsStateError);
      await expectLater(transport.scan(), emitsError(isStateError));
      await expectLater(transport.stop(), throwsStateError);
      await expectLater(transport.stop(), throwsStateError);
      expect(delegate.scanCalls, 1);
      expect(delegate.connectCalls, 0);
      expect(delegate.cancelCalls, 1);
    },
  );

  test('stop completes cleanup when physical cancellation fails', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();
    final logicalDone = Completer<void>();
    transport.scan().listen((_) {}, onDone: logicalDone.complete);
    delegate.cancelError = StateError('cancel failure');

    await expectLater(transport.stop(), throwsStateError);

    expect(transport.state, DebugSharedScanState.stopped);
    await expectLater(logicalDone.future, completes);
    delegate
      ..reportPhysicalScanStarted()
      ..acknowledgeCurrentScanStart();
    expect(transport.state, DebugSharedScanState.stopped);
    await expectLater(transport.scan(), emitsError(isStateError));
    await expectLater(transport.connect('device-1'), throwsStateError);
  });

  test('late physical stop completion cannot clear a timeout fault', () async {
    final gate = Completer<void>();
    final delegate = _FakePhysicalTransport()..cancelGate = gate;
    final transport = _transport(delegate);
    await transport.start();
    final failed = expectLater(
      transport.connectOnce('device-1'),
      throwsStateError,
    );
    await failed;
    expect(delegate.cancelCalls, 1);
    expect(delegate.connectCalls, 0);
    expect(transport.state, DebugSharedScanState.error);

    gate.complete();
    await pumpEventQueue(times: 10);
    delegate.reportPhysicalScanStarted();
    delegate.acknowledgeCurrentScanStart();
    await pumpEventQueue(times: 10);
    await expectLater(transport.connectOnce('device-1'), throwsStateError);
    await expectLater(transport.start(), throwsStateError);
    await expectLater(transport.stop(), throwsStateError);
    expect(delegate.scanCalls, 1);
    expect(delegate.connectCalls, 0);
    expect(delegate.cancelCalls, 1);
  });

  test('concurrent connects are serialized across scan recovery', () async {
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final delegate = _FakePhysicalTransport()
      ..connectGates.addAll(<Completer<void>>[firstGate, secondGate]);
    final transport = _transport(delegate);
    await transport.start();

    final first = transport.connect('device-1');
    final second = transport.connect('device-2');
    await pumpEventQueue(times: 20);
    expect(delegate.connectCalls, 1);

    firstGate.complete();
    await first;
    await pumpEventQueue(times: 20);
    expect(delegate.connectCalls, 2);

    secondGate.complete();
    await second;
    expect(delegate.maxConcurrentConnects, 1);
    expect(transport.state, DebugSharedScanState.running);
    await transport.stop();
  });

  test('a connect queued after stop cannot reach the delegate', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();

    final stop = transport.stop();
    final connect = transport.connect('device-1');

    await stop;
    await expectLater(connect, throwsStateError);
    expect(delegate.connectCalls, 0);
  });

  test('rejects a logical service outside the physical union', () async {
    final delegate = _FakePhysicalTransport();
    final transport = _transport(delegate);
    await transport.start();

    await expectLater(
      transport.scan(withServices: const <String>['180D']),
      emitsError(isArgumentError),
    );
    expect(delegate.scanCalls, 1);
    expect(delegate.active, isTrue);
    await transport.stop();
  });
}

DebugSharedScanTransport _transport(
  _FakePhysicalTransport delegate, {
  DebugScanRetryDelay? retryDelay,
  List<Duration> retryBackoff = const <Duration>[
    Duration(milliseconds: 1),
  ],
}) {
  return DebugSharedScanTransport(
    delegate: delegate,
    physicalServiceUuids: const <String>[
      '0000fde3-0000-1000-8000-00805f9b34fb',
      '181F',
    ],
    physicalScanStates: delegate.scanStates,
    physicalScanIsActive: () => delegate.active,
    physicalScanStartAcknowledgements: delegate.scanStartAcknowledgements,
    physicalScanAttempt: () => delegate.latestScanAttempt,
    retryDelay: retryDelay,
    retryBackoff: retryBackoff,
  );
}

BleFailure _bluetoothOff() => BleFailure(
  kind: BleFailureKind.bluetoothOff,
  operation: BleOperation.adapter,
  diagnosticCode: 'synthetic.adapter.bluetooth_off',
);

BleScanResult _result(
  String deviceId,
  List<String> serviceUuids, {
  required int rssi,
}) {
  return BleScanResult(
    deviceId: deviceId,
    deviceName: deviceId,
    rssi: rssi,
    serviceUuids: serviceUuids,
  );
}

final class _FakePhysicalTransport implements BleSingleAttemptTransport {
  final StreamController<bool> _scanStates = StreamController<bool>.broadcast(
    sync: true,
  );
  final List<StreamController<BleScanResult>> _scanControllers =
      <StreamController<BleScanResult>>[];
  final List<List<String>> requestedServices = <List<String>>[];
  final StreamController<int> _scanStartAcknowledgements =
      StreamController<int>.broadcast(sync: true);

  int scanCalls = 0;
  int latestScanAttempt = 0;
  bool active = false;
  bool autoAcknowledgeScanStart = true;
  bool? scanWasActiveAtConnect;
  Error? connectError;
  Error? scanError;
  Error? cancelError;
  Completer<void>? cancelGate;
  int cancelCalls = 0;
  final List<Completer<void>> connectGates = <Completer<void>>[];
  int connectCalls = 0;
  int singleAttemptCalls = 0;
  int defaultConnectCalls = 0;
  final List<_FakeConnection> connections = [];
  @override
  bool supportsSingleAttemptConnect = true;
  int concurrentConnects = 0;
  int maxConcurrentConnects = 0;

  Stream<bool> get scanStates => _scanStates.stream;
  Stream<int> get scanStartAcknowledgements =>
      _scanStartAcknowledgements.stream;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    scanCalls += 1;
    latestScanAttempt += 1;
    if (scanError != null) throw scanError!;
    requestedServices.add(List<String>.of(withServices ?? const <String>[]));
    late final StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>(
      sync: true,
      onListen: () {
        active = true;
        _scanStates.add(true);
        if (autoAcknowledgeScanStart) {
          _scanStartAcknowledgements.add(latestScanAttempt);
        }
      },
      onCancel: () async {
        cancelCalls += 1;
        if (_scanControllers.isNotEmpty &&
            identical(_scanControllers.last, controller)) {
          active = false;
          _scanStates.add(false);
        }
        await cancelGate?.future;
        final failure = cancelError;
        cancelError = null;
        if (failure != null) {
          throw failure;
        }
      },
    );
    _scanControllers.add(controller);
    return controller.stream;
  }

  void emit(BleScanResult result) {
    _scanControllers.last.add(result);
  }

  Future<void> completeCurrentScan() async {
    active = false;
    _scanStates.add(false);
    await _scanControllers.last.close();
  }

  void reportPhysicalScanStopped() {
    active = false;
    _scanStates.add(false);
  }

  void reportPhysicalStateError(Object error) {
    _scanStates.addError(error);
  }

  void reportPhysicalScanStarted() {
    active = true;
    _scanStates.add(true);
  }

  void acknowledgeCurrentScanStart() {
    _scanStartAcknowledgements.add(latestScanAttempt);
  }

  void acknowledgeScanAttempt(int attempt) {
    _scanStartAcknowledgements.add(attempt);
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    defaultConnectCalls += 1;
    return _connect(deviceId);
  }

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    singleAttemptCalls += 1;
    return _connect(deviceId);
  }

  Future<BleConnection> _connect(String deviceId) async {
    scanWasActiveAtConnect = active;
    final call = connectCalls++;
    concurrentConnects += 1;
    if (concurrentConnects > maxConcurrentConnects) {
      maxConcurrentConnects = concurrentConnects;
    }
    try {
      if (call < connectGates.length) {
        await connectGates[call].future;
      }
      final failure = connectError;
      if (failure != null) {
        throw failure;
      }
      final connection = _FakeConnection(deviceId);
      connections.add(connection);
      return connection;
    } finally {
      concurrentConnects -= 1;
    }
  }
}

final class _FakeConnection implements BleConnection {
  _FakeConnection(this.deviceId);

  @override
  final String deviceId;
  int disconnectCalls = 0;
  Error? disconnectError;
  Completer<void>? disconnectGate;

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
  Future<void> disconnect() async {
    disconnectCalls += 1;
    await disconnectGate?.future;
    if (disconnectError != null) throw disconnectError!;
  }
}
