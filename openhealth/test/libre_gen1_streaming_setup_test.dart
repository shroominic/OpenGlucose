import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre2_nfc_setup.dart';
import 'package:openglucose/src/libre_gen1_streaming_setup.dart';

const _attempt = 'synthetic_attempt';
Map<String, Object?> _reuseProof(String lifecycle) => {
  'attemptId': _attempt,
  'event': 'receiverReusable',
  'model': 'libre2',
  'lifecycle': lifecycle,
};
Map<String, Object?> _event(
  String name, {
  String attempt = _attempt,
  String? lifecycle,
  String? reason,
}) => {
  'operation': 'libreGen1Streaming',
  'attemptId': attempt,
  'event': name,
  if (lifecycle != null) 'lifecycle': lifecycle,
  if (reason != null) 'reason': reason,
};

void main() {
  for (final lifecycle in ['warmingUp', 'active']) {
    test(
      'same-sensor proof reuses receiver during $lifecycle without NFC',
      () async {
        final events = StreamController<Object?>.broadcast(sync: true);
        final calls = <String>[];
        final states = <LibreGen1StreamingState>[];
        final session = PlatformLibreGen1StreamingSession(
          sourceReadAttemptId: _attempt,
          platformEvents: events.stream,
          attemptIdFactory: () =>
              throw StateError('Must not create an NFC attempt'),
          invokeMethod: (method, arguments) async {
            calls.add(method);
            expect(arguments, {'attemptId': _attempt});
            return _reuseProof(lifecycle);
          },
        );
        final subscription = session.states.listen(states.add);
        await session.start();
        await session.start();
        await session.stop();
        expect(states, hasLength(1));
        expect(states.single.phase, LibreGen1StreamingPhase.streamingEnabled);
        expect(states.single.isSavedReceiver, isTrue);
        expect(states.single.lifecycle?.name, lifecycle);
        expect(events.hasListener, isFalse);
        await session.dispose();
        expect(calls, ['readLibreGen1ReceiverReuseProof']);
        await subscription.cancel();
        await events.close();
      },
    );
  }

  test('invalid or unavailable reuse proof never starts NFC', () async {
    for (final proof in <Object>[
      true,
      {},
      _reuseProof('active')..['attemptId'] = 'stale_read',
      _reuseProof('active')..['event'] = 'streamingEnabled',
      _reuseProof('active')..['model'] = 'libre2Plus',
      _reuseProof('expired'),
      _reuseProof('active')..['raw'] = 'synthetic-private',
      PlatformException(code: 'private', message: 'synthetic-private'),
    ]) {
      final events = StreamController<Object?>.broadcast(sync: true);
      final calls = <String>[];
      final states = <LibreGen1StreamingState>[];
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        invokeMethod: (method, _) async {
          calls.add(method);
          if (proof is Exception) throw proof;
          return proof;
        },
      );
      final subscription = session.states.listen(states.add);
      await session.start();
      await session.start();
      expect(states.single.failure, LibreGen1StreamingFailure.readFailed);
      expect(states.single.canRepeatReadOnlyCheck, isTrue);
      expect(events.hasListener, isFalse);
      await session.dispose();
      expect(calls, ['readLibreGen1ReceiverReuseProof']);
      await subscription.cancel();
      await events.close();
    }
  });

  test('stop during receiver proof discards late match without NFC', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final proof = Completer<Object?>();
    final calls = <String>[];
    final states = <LibreGen1StreamingState>[];
    final session = PlatformLibreGen1StreamingSession(
      sourceReadAttemptId: _attempt,
      platformEvents: events.stream,
      invokeMethod: (method, _) {
        calls.add(method);
        return proof.future;
      },
    );
    final subscription = session.states.listen(states.add);
    final started = session.start();
    await Future<void>.delayed(Duration.zero);
    final stopped = session.stop();
    proof.complete(_reuseProof('active'));
    await started;
    await stopped;
    expect(states, isEmpty);
    expect(events.hasListener, isFalse);
    await session.dispose();
    expect(calls, ['readLibreGen1ReceiverReuseProof']);
    await subscription.cancel();
    await events.close();
  });

  test(
    'reuse proof timeout ignores later success and cannot enable NFC',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final proof = Completer<Object?>();
      final calls = <String>[];
      final states = <LibreGen1StreamingState>[];
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        methodTimeout: const Duration(milliseconds: 10),
        invokeMethod: (method, _) {
          calls.add(method);
          return proof.future;
        },
      );
      final subscription = session.states.listen(states.add);
      await session.start();
      proof.complete(_reuseProof('active'));
      await session.start();
      await session.dispose();
      expect(states.single.failure, LibreGen1StreamingFailure.readFailed);
      expect(states.single.canRepeatReadOnlyCheck, isTrue);
      expect(calls, ['readLibreGen1ReceiverReuseProof']);
      expect(events.hasListener, isFalse);
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'hung start cancels the same attempt and ignores late completion',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final nativeStart = Completer<Object?>();
      final calls = <String>[];
      final states = <LibreGen1StreamingState>[];
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        attemptIdFactory: () => _attempt,
        methodTimeout: const Duration(milliseconds: 10),
        invokeMethod: (method, _) async {
          calls.add(method);
          if (method == 'startLibreGen1Streaming') return nativeStart.future;
          return null;
        },
      );
      final subscription = session.states.listen(states.add);
      await session.start();
      await session.stop();
      nativeStart.complete(null);
      events.add(_event('streamingEnabled', lifecycle: 'active'));
      await session.start();
      expect(states.last.failure, LibreGen1StreamingFailure.outcomeUnknown);
      expect(states.last.canRepeatReadOnlyCheck, isFalse);
      expect(calls, [
        'readLibreGen1ReceiverReuseProof',
        'startLibreGen1Streaming',
        'stopLibreGen1Streaming',
      ]);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'hung stop ends with unknown outcome and releases the UI listener',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final nativeStop = Completer<Object?>();
      final states = <LibreGen1StreamingState>[];
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        attemptIdFactory: () => _attempt,
        methodTimeout: const Duration(milliseconds: 10),
        invokeMethod: (method, _) async =>
            method == 'stopLibreGen1Streaming' ? nativeStop.future : null,
      );
      final subscription = session.states.listen(states.add);
      await session.start();
      await expectLater(session.stop(), throwsStateError);
      nativeStop.complete(null);
      expect(states.last.failure, LibreGen1StreamingFailure.outcomeUnknown);
      expect(states.last.canRepeatReadOnlyCheck, isFalse);
      expect(events.hasListener, isFalse);
      await expectLater(session.dispose(), throwsStateError);
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'hung retained-status read times out and a later poll recovers',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final hungPoll = Completer<Object?>();
      final recovered = Completer<void>();
      var polls = 0;
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        attemptIdFactory: () => _attempt,
        pollInterval: const Duration(milliseconds: 10),
        pollTimeout: const Duration(milliseconds: 5),
        invokeMethod: (method, _) async {
          if (method != 'readLibreGen1StreamingStatus') return null;
          if (++polls == 1) return hungPoll.future;
          return _event('streamingEnabled', lifecycle: 'active');
        },
      );
      final subscription = session.states.listen((state) {
        if (state.phase == LibreGen1StreamingPhase.streamingEnabled) {
          recovered.complete();
        }
      });
      await session.start();
      await recovered.future.timeout(const Duration(seconds: 1));
      expect(polls, 2);
      hungPoll.complete(_event('failed', reason: 'readFailed'));
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test('accepts only exact correlated closed streaming events', () {
    for (final lifecycle in ['warmingUp', 'active']) {
      final value = libreGen1StreamingStateFromPlatformEvent(
        _event('streamingEnabled', lifecycle: lifecycle),
        activeAttemptId: _attempt,
      );
      expect(value?.phase, LibreGen1StreamingPhase.streamingEnabled);
      expect(
        value?.lifecycle,
        lifecycle == 'active'
            ? Libre2SensorStatus.active
            : Libre2SensorStatus.warmingUp,
      );
    }
    for (final reason in LibreGen1StreamingFailure.values) {
      expect(
        libreGen1StreamingStateFromPlatformEvent(
          _event('failed', reason: reason.name),
          activeAttemptId: _attempt,
        )?.failure,
        reason,
      );
    }
    for (final value in <Object?>[
      null,
      'streamingEnabled',
      {},
      _event('streamingEnabled'),
      _event('streamingEnabled', lifecycle: 'notActivated'),
      _event('streamingEnabled', lifecycle: 'active', attempt: 'stale_attempt'),
      _event('streamingEnabled', lifecycle: 'active')
        ..['rawResponse'] = 'synthetic-private-data',
      _event('streamingEnabled', lifecycle: 'active')..['operation'] = 'other',
      _event('listening')..['lifecycle'] = 'active',
      _event('failed', reason: 'native error synthetic-private-data'),
      _event('unknown'),
    ]) {
      expect(
        libreGen1StreamingStateFromPlatformEvent(
          value,
          activeAttemptId: _attempt,
        ),
        isNull,
      );
    }
  });

  test(
    'retained status recovers a missed terminal event and latches it',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final calls = <String>[];
      final states = <LibreGen1StreamingState>[];
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        attemptIdFactory: () => _attempt,
        invokeMethod: (method, arguments) async {
          calls.add(method);
          expect(arguments, {'attemptId': _attempt});
          return method == 'readLibreGen1StreamingStatus'
              ? _event('streamingEnabled', lifecycle: 'warmingUp')
              : null;
        },
      );
      final subscription = session.states.listen(states.add);
      await session.start();
      events.add(_event('failed', reason: 'readFailed'));
      events.add(_event('listening'));
      await session.start();
      expect(states.last.phase, LibreGen1StreamingPhase.streamingEnabled);
      expect(calls.where((c) => c == 'startLibreGen1Streaming'), hasLength(1));
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test('unknown result is terminal and never causes another start', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final states = <LibreGen1StreamingState>[];
    var starts = 0;
    final session = PlatformLibreGen1StreamingSession(
      sourceReadAttemptId: _attempt,
      platformEvents: events.stream,
      attemptIdFactory: () => _attempt,
      invokeMethod: (method, _) async {
        if (method == 'startLibreGen1Streaming') starts++;
        return null;
      },
    );
    final subscription = session.states.listen(states.add);
    await session.start();
    events.add(_event('failed', reason: 'outcomeUnknown'));
    events.add(_event('streamingEnabled', lifecycle: 'active'));
    await session.start();
    expect(states.last.failure, LibreGen1StreamingFailure.outcomeUnknown);
    expect(starts, 1);
    await session.dispose();
    await subscription.cancel();
    await events.close();
  });

  test('drops stale, malformed and regressive progress', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final states = <LibreGen1StreamingState>[];
    final session = PlatformLibreGen1StreamingSession(
      sourceReadAttemptId: _attempt,
      platformEvents: events.stream,
      attemptIdFactory: () => _attempt,
      invokeMethod: (_, _) async => null,
    );
    final subscription = session.states.listen(states.add);
    await session.start();
    events.add(_event('enablingStreaming'));
    events.add(_event('listening'));
    events.add(
      _event('streamingEnabled', lifecycle: 'active', attempt: 'stale_attempt'),
    );
    events.add(
      _event('streamingEnabled', lifecycle: 'active')..['raw'] = 'synthetic',
    );
    expect(states.map((s) => s.phase), [
      LibreGen1StreamingPhase.listening,
      LibreGen1StreamingPhase.enablingStreaming,
    ]);
    await session.dispose();
    await subscription.cancel();
    await events.close();
  });

  test(
    'stop waits for pending start and closes before further events',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final started = Completer<void>();
      final calls = <String>[];
      final states = <LibreGen1StreamingState>[];
      final session = PlatformLibreGen1StreamingSession(
        sourceReadAttemptId: _attempt,
        platformEvents: events.stream,
        attemptIdFactory: () => _attempt,
        invokeMethod: (method, _) async {
          calls.add(method);
          if (method == 'startLibreGen1Streaming') await started.future;
          return null;
        },
      );
      final subscription = session.states.listen(states.add);
      final start = session.start();
      await Future<void>.delayed(Duration.zero);
      final stop = session.stop();
      events.add(_event('streamingEnabled', lifecycle: 'active'));
      expect(calls, [
        'readLibreGen1ReceiverReuseProof',
        'startLibreGen1Streaming',
      ]);
      started.complete();
      await start;
      await stop;
      expect(calls, [
        'readLibreGen1ReceiverReuseProof',
        'startLibreGen1Streaming',
        'stopLibreGen1Streaming',
      ]);
      expect(states, isEmpty);
      expect(events.hasListener, isFalse);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test('stop failure is closed, redacted and cannot retry', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final states = <LibreGen1StreamingState>[];
    var starts = 0;
    final session = PlatformLibreGen1StreamingSession(
      sourceReadAttemptId: _attempt,
      platformEvents: events.stream,
      attemptIdFactory: () => _attempt,
      invokeMethod: (method, _) async {
        if (method == 'startLibreGen1Streaming') starts++;
        if (method == 'stopLibreGen1Streaming') {
          throw PlatformException(code: 'private', message: 'synthetic-secret');
        }
        return null;
      },
    );
    final subscription = session.states.listen(states.add);
    await session.start();
    await expectLater(
      session.stop(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          isNot(contains('synthetic-secret')),
        ),
      ),
    );
    await session.start();
    expect(starts, 1);
    expect(states.last.failure, LibreGen1StreamingFailure.outcomeUnknown);
    expect(events.hasListener, isFalse);
    await expectLater(session.dispose(), throwsStateError);
    await subscription.cancel();
    await events.close();
  });
}
