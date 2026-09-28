import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre2_nfc_setup.dart';

void main() {
  test('completed reads expire without another native operation', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final calls = <String>[];
    final states = <Libre2NfcSetupState>[];
    var attempt = 0;
    final session = PlatformLibre2NfcSetupSession(
      readValidity: const Duration(milliseconds: 30),
      platformEvents: events.stream,
      attemptIdFactory: () => 'synthetic_read_${++attempt}',
      invokeMethod: (method, _) async {
        calls.add(method);
        return null;
      },
    );
    final subscription = session.states.listen(states.add);
    await session.start();
    events.add({
      'attemptId': 'synthetic_read_1',
      'event': 'metadataRead',
      'model': 'libre2',
      'status': 'active',
    });
    expect(session.completedReadAttemptId, 'synthetic_read_1');
    expect(states.last.isReadExpired, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(session.completedReadAttemptId, isNull);
    expect(states.last.isReadExpired, isTrue);
    expect(states.last.sensorStatus, Libre2SensorStatus.active);
    expect(calls, ['startLibre2NfcSetup']);
    await session.retry();
    events.add({
      'attemptId': 'synthetic_read_1',
      'event': 'metadataRead',
      'model': 'libre2',
      'status': 'active',
    });
    expect(session.completedReadAttemptId, isNull);
    events.add({
      'attemptId': 'synthetic_read_2',
      'event': 'metadataRead',
      'model': 'libre2',
      'status': 'active',
    });
    expect(session.completedReadAttemptId, 'synthetic_read_2');
    await session.dispose();
    await subscription.cancel();
    await events.close();
  });

  test(
    'hung NFC start ends with same-attempt stop and no late result',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final start = Completer<Object?>();
      final calls = <String>[];
      final states = <Libre2NfcSetupState>[];
      final session = PlatformLibre2NfcSetupSession(
        methodTimeout: const Duration(milliseconds: 10),
        platformEvents: events.stream,
        attemptIdFactory: () => 'synthetic_read_1',
        invokeMethod: (method, args) async {
          expect(args, {'attemptId': 'synthetic_read_1'});
          calls.add(method);
          return method == 'startLibre2NfcSetup' ? start.future : null;
        },
      );
      final subscription = session.states.listen(states.add);
      final pending = session.start();
      await pending;
      expect(calls, ['startLibre2NfcSetup', 'stopLibre2NfcSetup']);
      expect(states.last.failure, Libre2NfcFailureKind.readFailed);
      start.complete(null);
      events.add({
        'attemptId': 'synthetic_read_1',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.completedReadAttemptId, isNull);
      expect(states.last.failure, Libre2NfcFailureKind.readFailed);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'unconfirmed stop releases listener but forbids a new NFC attempt',
    () async {
      for (final timeout in [false, true]) {
        final events = StreamController<Object?>.broadcast(sync: true);
        final pendingStop = Completer<Object?>();
        final states = <Libre2NfcSetupState>[];
        final calls = <String>[];
        final session = PlatformLibre2NfcSetupSession(
          methodTimeout: const Duration(milliseconds: 10),
          platformEvents: events.stream,
          attemptIdFactory: () => 'synthetic_read_1',
          invokeMethod: (method, _) async {
            calls.add(method);
            if (method == 'stopLibre2NfcSetup') {
              if (timeout) return pendingStop.future;
              throw PlatformException(code: 'private-value-sentinel');
            }
            return null;
          },
        );
        final subscription = session.states.listen(states.add);
        await session.start();
        final stopped = expectLater(session.stop(), throwsStateError);
        await stopped;
        expect(events.hasListener, isFalse);
        expect(states.last.failure, Libre2NfcFailureKind.cleanupUnconfirmed);
        await session.start();
        await session.retry();
        expect(calls, ['startLibre2NfcSetup', 'stopLibre2NfcSetup']);
        pendingStop.complete(null);
        await session.dispose();
        await subscription.cancel();
        await events.close();
      }
    },
  );

  test(
    'completed read correlation exists only for the exact live read',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      var attempt = 0;
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: events.stream,
        attemptIdFactory: () => 'synthetic_read_${++attempt}',
        invokeMethod: (_, _) async => null,
      );
      expect(session.completedReadAttemptId, isNull);
      await session.start();
      expect(session.completedReadAttemptId, isNull);
      events.add({
        'attemptId': 'stale_read',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      expect(session.completedReadAttemptId, isNull);
      events.add({
        'attemptId': 'synthetic_read_1',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      expect(session.completedReadAttemptId, 'synthetic_read_1');
      await session.stop();
      expect(session.completedReadAttemptId, isNull);
      await session.start();
      expect(session.completedReadAttemptId, isNull);
      events.add({
        'attemptId': 'synthetic_read_1',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      expect(session.completedReadAttemptId, isNull);
      await session.dispose();
      expect(session.completedReadAttemptId, isNull);
      await events.close();
    },
  );

  test(
    'historical activation query accepts only the exact closed proof',
    () async {
      for (final value in <Object?>[
        null,
        {},
        {'activation': 'unknown', 'lifecycleAtActivation': 'warmingUp'},
        {'activation': 'verified', 'lifecycleAtActivation': 'active'},
        {
          'activation': 'verified',
          'lifecycleAtActivation': 'warmingUp',
          'raw': 'synthetic',
        },
      ]) {
        expect(
          await readLastLibre2ActivationVerified(
            invokeMethod: (_, _) async => value,
          ),
          isFalse,
        );
      }
      expect(
        await readLastLibre2ActivationVerified(
          invokeMethod: (method, args) async {
            expect(method, 'readLastLibre2ActivationResult');
            expect(args, isEmpty);
            return {
              'activation': 'verified',
              'lifecycleAtActivation': 'warmingUp',
            };
          },
        ),
        isTrue,
      );
    },
  );

  test(
    'verified activation corrects only the same completed notActivated read',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: events.stream,
        attemptIdFactory: () => 'attempt_0001',
        invokeMethod: (_, _) async => null,
      );
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);
      final proof = <String, Object?>{
        'attemptId': 'attempt_0001',
        'event': 'activationVerified',
        'model': 'libre2',
        'status': 'warmingUp',
      };
      await session.start();
      events.add(proof);
      expect(states.last.phase, Libre2NfcSetupPhase.listening);
      events.add({
        'attemptId': 'attempt_0001',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'notActivated',
      });
      events.add({...proof, 'attemptId': 'stale_attempt'});
      events.add({...proof, 'raw': 'synthetic'});
      events.add({...proof, 'status': 'active'});
      expect(states.last.sensorStatus, Libre2SensorStatus.notActivated);
      events.add(proof);
      expect(states.last.sensorStatus, Libre2SensorStatus.warmingUp);
      expect(states.last.isActivationVerified, isTrue);
      events.add({
        'attemptId': 'attempt_0001',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'notActivated',
      });
      expect(states.last.isActivationVerified, isTrue);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'retained activation proof recovers the lost activation UI event',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final recovered = Completer<void>();
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: events.stream,
        attemptIdFactory: () => 'attempt_0001',
        invokeMethod: (method, args) async {
          if (method != 'readLibre2VerifiedActivation') return null;
          expect(args, {'attemptId': 'attempt_0001'});
          return {
            'attemptId': 'attempt_0001',
            'event': 'activationVerified',
            'model': 'libre2',
            'status': 'warmingUp',
          };
        },
      );
      final subscription = session.states.listen((state) {
        if (state.isActivationVerified) recovered.complete();
      });
      await session.start();
      events.add({
        'attemptId': 'attempt_0001',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'notActivated',
      });
      await recovered.future.timeout(const Duration(seconds: 1));
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'listening-only adapter never invents detection or setup success',
    () async {
      final session = ListeningOnlyLibre2NfcSetupSession();
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);

      await session.start();
      await session.retry();
      await session.stop();

      expect(
        states.map((state) => state.phase),
        <Libre2NfcSetupPhase>[
          Libre2NfcSetupPhase.listening,
          Libre2NfcSetupPhase.listening,
          Libre2NfcSetupPhase.idle,
        ],
      );
      expect(
        states,
        everyElement(
          isA<Libre2NfcSetupState>()
              .having((state) => state.model, 'model', isNull)
              .having((state) => state.sensorStatus, 'status', isNull),
        ),
      );

      await subscription.cancel();
      await session.dispose();
    },
  );

  test('safe model and status labels are fixed enum mappings', () {
    expect(
      Libre2SensorModel.values.map(libre2SensorModelLabel),
      <String>['FreeStyle Libre 2', 'FreeStyle Libre 2 Plus'],
    );
    expect(
      Libre2SensorStatus.values.map(libre2SensorStatusLabel),
      <String>[
        'Not activated',
        'Warming up',
        'Active',
        'Expired',
        'Shut down',
        'Sensor error',
        'State unavailable',
      ],
    );
  });

  test('explicit NFC attempt identifiers are safe opaque tokens', () {
    final first = newLibre2NfcSetupAttemptId();
    final second = newLibre2NfcSetupAttemptId();

    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{24}$')));
    expect(second, matches(RegExp(r'^[A-Za-z0-9_-]{24}$')));
    expect(second, isNot(first));
  });

  test('platform maps accept only closed redacted states', () {
    const activeAttemptId = 'attempt_0001';
    expect(
      libre2NfcSetupStateFromPlatformEvent(const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'tagDetected',
      }, activeAttemptId: activeAttemptId)?.phase,
      Libre2NfcSetupPhase.tagDetected,
    );
    expect(
      libre2NfcSetupStateFromPlatformEvent(const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'readingMetadata',
      }, activeAttemptId: activeAttemptId)?.phase,
      Libre2NfcSetupPhase.reading,
    );

    final metadata = libre2NfcSetupStateFromPlatformEvent(
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      },
      activeAttemptId: activeAttemptId,
    );
    expect(metadata?.phase, Libre2NfcSetupPhase.metadataRead);
    expect(metadata?.model, Libre2SensorModel.libre2);
    expect(metadata?.sensorStatus, Libre2SensorStatus.active);

    const statuses = <String, Libre2SensorStatus>{
      'notActivated': Libre2SensorStatus.notActivated,
      'warmingUp': Libre2SensorStatus.warmingUp,
      'active': Libre2SensorStatus.active,
      'expired': Libre2SensorStatus.expired,
      'shutdown': Libre2SensorStatus.shutdown,
      'failure': Libre2SensorStatus.failure,
      'unknown': Libre2SensorStatus.unknown,
    };
    for (final entry in statuses.entries) {
      final state = libre2NfcSetupStateFromPlatformEvent(
        <String, Object?>{
          'attemptId': activeAttemptId,
          'event': 'metadataRead',
          'model': 'libre2',
          'status': entry.key,
        },
        activeAttemptId: activeAttemptId,
      );
      expect(state?.sensorStatus, entry.value);
    }

    for (final malformed in <Object?>[
      'tagDetected',
      const <String, Object?>{'event': 'unknown'},
      const <String, Object?>{'event': 'listening'},
      const <String, Object?>{
        'attemptId': 'attempt_stale',
        'event': 'listening',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'unknown',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'tagDetected',
        'model': 'libre2',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'metadataRead',
        'model': 'libre2',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'metadataRead',
        'model': 'libre2Plus',
        'status': 'active',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'private-status',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
        'uid': 'private-tag-e007',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
        'hash': 'private-hash',
        'patchInfo': 'private-patch-bytes',
        'fram': 'private-fram-bytes',
        'nativeError': 'private-native-error',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'failed',
      },
      const <String, Object?>{
        'attemptId': activeAttemptId,
        'event': 'failed',
        'reason': 'private-native-error',
      },
    ]) {
      expect(
        libre2NfcSetupStateFromPlatformEvent(
          malformed,
          activeAttemptId: activeAttemptId,
        ),
        isNull,
      );
    }
  });

  test(
    'platform session starts and stops one explicit redacted attempt',
    () async {
      final platformEvents = StreamController<Object?>.broadcast(sync: true);
      final calls = <(String, Map<String, Object?>)>[];
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: platformEvents.stream,
        attemptIdFactory: () => 'attempt_0001',
        invokeMethod: (method, arguments) async {
          calls.add((method, Map<String, Object?>.of(arguments)));
          return null;
        },
      );
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);

      await session.start();
      expect(states.single.phase, Libre2NfcSetupPhase.listening);
      expect(calls.map((call) => call.$1), <String>[
        'startLibre2NfcSetup',
      ]);
      expect(calls.single.$2.keys, <String>['attemptId']);
      expect(calls.single.$2['attemptId'], 'attempt_0001');
      platformEvents.add(const <String, Object?>{
        'attemptId': 'attempt_0001',
        'event': 'listening',
      });
      platformEvents.add(const <String, Object?>{
        'attemptId': 'attempt_0001',
        'event': 'tagDetected',
      });
      platformEvents.add(const <String, Object?>{
        'attemptId': 'attempt_0001',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'warmingUp',
      });

      expect(
        states.map((state) => state.phase),
        <Libre2NfcSetupPhase>[
          Libre2NfcSetupPhase.listening,
          Libre2NfcSetupPhase.tagDetected,
          Libre2NfcSetupPhase.metadataRead,
        ],
      );
      expect(states.last.model, Libre2SensorModel.libre2);
      expect(states.last.sensorStatus, Libre2SensorStatus.warmingUp);

      await session.stop();
      expect(calls.last.$1, 'stopLibre2NfcSetup');
      expect(calls.last.$2.keys, <String>['attemptId']);
      expect(calls.last.$2['attemptId'], 'attempt_0001');
      expect(states.last.phase, Libre2NfcSetupPhase.idle);
      await subscription.cancel();
      await session.dispose();
      await platformEvents.close();
    },
  );

  test(
    'bound failure before delayed start return is not overwritten',
    () async {
      final platformEvents = StreamController<Object?>.broadcast(sync: true);
      final startCompleter = Completer<Object?>();
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: platformEvents.stream,
        attemptIdFactory: () => 'attempt_0001',
        invokeMethod: (method, _) {
          if (method == 'startLibre2NfcSetup') {
            return startCompleter.future;
          }
          return Future<Object?>.value();
        },
      );
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);

      final startFuture = session.start();
      platformEvents.add(const <String, Object?>{
        'attemptId': 'attempt_0001',
        'event': 'failed',
        'reason': 'tagMoved',
      });
      expect(states, hasLength(1));
      expect(states.single.phase, Libre2NfcSetupPhase.failed);
      expect(states.single.failure, Libre2NfcFailureKind.tagMoved);

      startCompleter.complete();
      await startFuture;

      expect(states, hasLength(1));
      expect(states.single.phase, Libre2NfcSetupPhase.failed);
      await subscription.cancel();
      await session.dispose();
      await platformEvents.close();
    },
  );

  test('terminal lifecycle result cannot regress within one attempt', () async {
    final platformEvents = StreamController<Object?>.broadcast(sync: true);
    final session = PlatformLibre2NfcSetupSession(
      platformEvents: platformEvents.stream,
      attemptIdFactory: () => 'attempt_0001',
      invokeMethod: (_, _) async => null,
    );
    final states = <Libre2NfcSetupState>[];
    final subscription = session.states.listen(states.add);

    await session.start();
    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0001',
      'event': 'metadataRead',
      'model': 'libre2',
      'status': 'notActivated',
    });
    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0001',
      'event': 'readingMetadata',
    });
    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0001',
      'event': 'failed',
      'reason': 'readFailed',
    });

    expect(states, hasLength(2));
    expect(states.last.phase, Libre2NfcSetupPhase.metadataRead);
    expect(states.last.sensorStatus, Libre2SensorStatus.notActivated);

    await session.stop();
    await subscription.cancel();
    await session.dispose();
    await platformEvents.close();
  });

  test(
    'reopening waits for confirmed stop and stale stop cannot cancel new read',
    () async {
      var listens = 0;
      final oldStopCompleter = Completer<Object?>();
      final attemptIds = <String>['attempt_0001', 'attempt_0002'].iterator;
      final platformEvents = StreamController<Object?>.broadcast(
        sync: true,
        onListen: () => listens += 1,
      );
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: platformEvents.stream,
        attemptIdFactory: () {
          attemptIds.moveNext();
          return attemptIds.current;
        },
        invokeMethod: (method, arguments) {
          if (method == 'stopLibre2NfcSetup' &&
              arguments['attemptId'] == 'attempt_0001') {
            return oldStopCompleter.future;
          }
          return Future<Object?>.value();
        },
      );
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);

      await session.start();
      expect(states.single.phase, Libre2NfcSetupPhase.listening);
      final delayedStop = session.stop();
      final reopened = session.start();
      await Future<void>.delayed(Duration.zero);
      expect(states, hasLength(1));
      oldStopCompleter.complete();
      await delayedStop;
      await reopened;
      expect(
        states.where(
          (state) => state.phase == Libre2NfcSetupPhase.listening,
        ),
        hasLength(2),
      );
      platformEvents.add(const <String, Object?>{
        'attemptId': 'attempt_0002',
        'event': 'tagDetected',
      });
      expect(states.last.phase, Libre2NfcSetupPhase.tagDetected);

      expect(
        states.map((state) => state.phase),
        isNot(contains(Libre2NfcSetupPhase.idle)),
      );
      platformEvents.add(const <String, Object?>{
        'attemptId': 'attempt_0002',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'expired',
      });
      expect(states.last.phase, Libre2NfcSetupPhase.metadataRead);
      expect(listens, 1);

      await session.stop();
      await subscription.cancel();
      await session.dispose();
      await platformEvents.close();
    },
  );

  test('platform retry waits for a fresh native reader state', () async {
    var listens = 0;
    final calls = <(String, Map<String, Object?>)>[];
    final attemptIds = <String>['attempt_0001', 'attempt_0002'].iterator;
    final platformEvents = StreamController<Object?>.broadcast(
      sync: true,
      onListen: () => listens += 1,
    );
    final session = PlatformLibre2NfcSetupSession(
      platformEvents: platformEvents.stream,
      attemptIdFactory: () {
        attemptIds.moveNext();
        return attemptIds.current;
      },
      invokeMethod: (method, arguments) async {
        calls.add((method, Map<String, Object?>.of(arguments)));
        return null;
      },
    );
    final states = <Libre2NfcSetupState>[];
    final subscription = session.states.listen(states.add);

    await session.start();
    expect(listens, 1);
    expect(states.single.phase, Libre2NfcSetupPhase.listening);

    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0001',
      'event': 'failed',
      'reason': 'disabled',
    });
    await session.retry();

    expect(listens, 1);
    expect(calls.map((call) => call.$1), <String>[
      'startLibre2NfcSetup',
      'stopLibre2NfcSetup',
      'startLibre2NfcSetup',
    ]);
    expect(calls.map((call) => call.$2.keys.toList()), <List<String>>[
      <String>['attemptId'],
      <String>['attemptId'],
      <String>['attemptId'],
    ]);
    expect(calls.map((call) => call.$2['attemptId']), <String>[
      'attempt_0001',
      'attempt_0001',
      'attempt_0002',
    ]);
    expect(states[1].failure, Libre2NfcFailureKind.disabled);
    expect(states.last.phase, Libre2NfcSetupPhase.listening);
    final statesBeforeRejectedEvents = states.length;
    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0001',
      'event': 'metadataRead',
      'model': 'libre2',
      'status': 'active',
    });
    platformEvents.add(const <String, Object?>{'event': 'tagDetected'});
    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0002',
      'event': 'tagDetected',
      'hostGrant': 'private-host-state',
    });
    expect(states, hasLength(statesBeforeRejectedEvents));
    platformEvents.add(const <String, Object?>{
      'attemptId': 'attempt_0002',
      'event': 'tagDetected',
    });
    expect(states, hasLength(statesBeforeRejectedEvents + 1));
    expect(states.last.phase, Libre2NfcSetupPhase.tagDetected);

    await session.stop();
    await subscription.cancel();
    await session.dispose();
    await platformEvents.close();
  });

  test('platform method failures expose only a closed failure kind', () async {
    final platformEvents = StreamController<Object?>.broadcast(sync: true);
    final session = PlatformLibre2NfcSetupSession(
      platformEvents: platformEvents.stream,
      attemptIdFactory: () => 'attempt_0001',
      invokeMethod: (_, _) => throw PlatformException(
        code: 'nfc_disabled',
        message: 'private native diagnostic',
      ),
    );
    final states = <Libre2NfcSetupState>[];
    final subscription = session.states.listen(states.add);

    await session.start();

    expect(states.single.phase, Libre2NfcSetupPhase.failed);
    expect(states.single.failure, Libre2NfcFailureKind.disabled);
    expect(states.single.model, isNull);
    expect(states.single.sensorStatus, isNull);

    await subscription.cancel();
    await session.dispose();
    await platformEvents.close();
  });
}
