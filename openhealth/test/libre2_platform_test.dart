import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre2_nfc_setup.dart';
import 'package:openglucose/src/libre2_platform.dart';

const _capabilities = <String, Object?>{
  'schemaVersion': 1,
  'backend': 'readOnly',
  'readAvailable': true,
  'activationAvailable': false,
  'streamingAvailable': false,
  'receiverAvailable': false,
  'rawCapture': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synthetic/libre-read-only');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('accepts only the exact read-only native capability contract', () async {
    final platform = Libre2Platform(channel: channel, supported: true);
    final rejected = <Object?>[
      null,
      <String, Object?>{},
      {..._capabilities, 'schemaVersion': 1.0},
      {..._capabilities, 'schemaVersion': 2},
      {..._capabilities, 'backend': 'capture'},
      {..._capabilities, 'readAvailable': false},
      {..._capabilities, 'readAvailable': 'true'},
      {..._capabilities, 'activationAvailable': true},
      {..._capabilities, 'streamingAvailable': true},
      {..._capabilities, 'receiverAvailable': true},
      {..._capabilities, 'rawCapture': true},
      {..._capabilities, 'extra': 'synthetic-private-value'},
      Map<String, Object?>.of(_capabilities)..remove('receiverAvailable'),
    ];
    for (final value in rejected) {
      messenger.setMockMethodCallHandler(channel, (_) async => value);
      expect(await platform.readAvailable(), isFalse, reason: '$value');
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'capabilities');
      expect(call.arguments, isEmpty);
      return _capabilities;
    });
    expect(await platform.readAvailable(), isTrue);
  });

  test('unsupported platform makes no native call', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls += 1;
      return _capabilities;
    });
    final platform = Libre2Platform(channel: channel, supported: false);
    expect(await platform.readAvailable(), isFalse);
    expect(calls, 0);
  });

  testWidgets('disposing platform cancels pending capability timers', (
    tester,
  ) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) => response.future);
    final platform = Libre2Platform(channel: channel, supported: true);
    final lookup = platform.readAvailable();
    await tester.pump();
    platform.dispose();
    expect(await lookup, isFalse);
    expect(await platform.readAvailable(), isFalse);
    response.complete(_capabilities);
    await tester.pump();
    expect(await platform.readAvailable(), isFalse);
  });

  test(
    'disposal after a successful capability reply still prevents native start',
    () async {
      final channel = _DisposeAfterCapabilityChannel();
      final events = StreamController<Object?>.broadcast(sync: true);
      final platform = Libre2Platform(
        channel: channel,
        events: events.stream,
        supported: true,
      );
      channel.afterCapability = platform.dispose;
      final session = platform.createReadSession();
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);

      await session.start();
      expect(channel.calls, ['capabilities']);
      expect(states.last.failure, Libre2NfcFailureKind.unavailable);
      await session.dispose();
      expect(channel.calls, ['capabilities']);
      await subscription.cancel();
      await events.close();
    },
  );

  test('disposed platform cannot create a normal or debug read owner', () {
    for (final useDebugCapture in [false, true]) {
      final platform = Libre2Platform(
        supported: true,
        useDebugCapture: useDebugCapture,
      );
      platform.dispose();
      expect(platform.createReadSession, throwsStateError);
    }
  });

  test(
    'missing or stalled bridge fails closed without recorder fallback',
    () async {
      final platform = Libre2Platform(
        channel: channel,
        supported: true,
        capabilityTimeout: const Duration(milliseconds: 5),
      );
      expect(await platform.readAvailable(), isFalse);
      final pending = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => pending.future);
      expect(await platform.readAvailable(), isFalse);
      pending.complete(_capabilities);
    },
  );

  test('read result cannot poll or accept activation proof', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final calls = <String>[];
    String? attempt;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'capabilities') return _capabilities;
      attempt ??= (call.arguments as Map)['attemptId'] as String;
      return null;
    });
    final session = Libre2Platform(
      channel: channel,
      events: events.stream,
      supported: true,
    ).createReadSession();
    final states = <Libre2NfcSetupState>[];
    final subscription = session.states.listen(states.add);
    await session.start();
    events.add({
      'attemptId': attempt,
      'event': 'metadataRead',
      'model': 'libre2',
      'status': 'notActivated',
    });
    events.add({
      'attemptId': attempt,
      'event': 'activationVerified',
      'model': 'libre2',
      'status': 'warmingUp',
    });
    await Future<void>.delayed(Duration.zero);
    expect(states.last.sensorStatus, Libre2SensorStatus.notActivated);
    expect(states.last.isActivationVerified, isFalse);
    expect(
      (session as Libre2NfcCompletedReadAttemptProvider).completedReadAttemptId,
      isNull,
    );
    expect(calls, ['capabilities', 'startLibre2NfcSetup']);
    await session.dispose();
    expect(calls.last, 'stopLibre2NfcSetup');
    await subscription.cancel();
    await events.close();
  });

  test(
    'read-only active result has no handoff and can be revoked on pause',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      String? attempt;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capabilities') return _capabilities;
        attempt ??= (call.arguments as Map)['attemptId'] as String;
        return null;
      });
      final session = Libre2Platform(
        channel: channel,
        events: events.stream,
        supported: true,
      ).createReadSession();
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);
      await session.start();
      events.add({
        'attemptId': attempt,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      expect(states.last.sensorStatus, Libre2SensorStatus.active);
      expect(
        (session as Libre2NfcCompletedReadAttemptProvider)
            .completedReadAttemptId,
        isNull,
      );
      events.add({
        'attemptId': attempt,
        'event': 'failed',
        'reason': 'readFailed',
      });
      expect(states.last.failure, Libre2NfcFailureKind.readFailed);
      events.add({
        'attemptId': attempt,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      expect(states.last.failure, Libre2NfcFailureKind.readFailed);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'read revocation cancels expiry instead of reviving old metadata',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      final states = <Libre2NfcSetupState>[];
      final session = PlatformLibre2NfcSetupSession(
        platformEvents: events.stream,
        invokeMethod: (_, _) async => null,
        attemptIdFactory: () => 'synthetic_read_attempt',
        allowActivationProof: false,
        allowCompletedReadHandoff: false,
        allowTerminalReadRevocation: true,
        readValidity: const Duration(milliseconds: 5),
      );
      final subscription = session.states.listen(states.add);
      await session.start();
      events.add({
        'attemptId': 'synthetic_read_attempt',
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'active',
      });
      events.add({
        'attemptId': 'synthetic_read_attempt',
        'event': 'failed',
        'reason': 'readFailed',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(states.last.failure, Libre2NfcFailureKind.readFailed);
      expect(states.last.isReadExpired, isFalse);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'legacy native state maps to setup review, not a proximity failure',
    () async {
      final events = StreamController<Object?>.broadcast(sync: true);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capabilities') return _capabilities;
        if (call.method == 'startLibre2NfcSetup') {
          throw PlatformException(code: 'nfc_state_blocked');
        }
        return null;
      });
      final session = Libre2Platform(
        channel: channel,
        events: events.stream,
        supported: true,
      ).createReadSession();
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);
      await session.start();
      expect(states.last.failure, Libre2NfcFailureKind.setupBlocked);
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'cancel during capability lookup prevents a late native start',
    () async {
      for (final dispose in [false, true]) {
        final pending = Completer<Object?>();
        final queried = Completer<void>();
        final calls = <String>[];
        final events = StreamController<Object?>.broadcast(sync: true);
        messenger.setMockMethodCallHandler(channel, (call) {
          calls.add(call.method);
          queried.complete();
          return pending.future;
        });
        final session = Libre2Platform(
          channel: channel,
          events: events.stream,
          supported: true,
        ).createReadSession();
        final start = session.start();
        await queried.future;
        if (dispose) {
          await session.dispose();
        } else {
          await session.stop();
        }
        pending.complete(_capabilities);
        await start;
        expect(calls, ['capabilities']);
        await session.dispose();
        await events.close();
      }
    },
  );

  test(
    'capability loss after dispatch still sends exact native stop',
    () async {
      final calls = <MethodCall>[];
      var available = true;
      final events = StreamController<Object?>.broadcast(sync: true);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'capabilities'
            ? {..._capabilities, 'readAvailable': available}
            : null;
      });
      final session = Libre2Platform(
        channel: channel,
        events: events.stream,
        supported: true,
      ).createReadSession();
      await session.start();
      available = false;
      await session.stop();
      expect(calls.map((call) => call.method), [
        'capabilities',
        'startLibre2NfcSetup',
        'stopLibre2NfcSetup',
      ]);
      expect(calls[1].arguments, calls[2].arguments);
      await session.dispose();
      await events.close();
    },
  );

  test(
    'method cleanup uncertainty cannot be cleared by a later stop',
    () async {
      for (final code in ['cleanup_unconfirmed', 'nfc_cleanup_unconfirmed']) {
        final calls = <String>[];
        final events = StreamController<Object?>.broadcast(sync: true);
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'capabilities') return _capabilities;
          if (call.method == 'startLibre2NfcSetup') {
            throw PlatformException(code: code);
          }
          return null;
        });
        final session = Libre2Platform(
          channel: channel,
          events: events.stream,
          supported: true,
        ).createReadSession();
        final states = <Libre2NfcSetupState>[];
        final subscription = session.states.listen(states.add);
        await session.start();
        expect(states.last.failure, Libre2NfcFailureKind.cleanupUnconfirmed);
        await session.start();
        await session.retry();
        await expectLater(session.stop(), throwsStateError);
        expect(calls, [
          'capabilities',
          'startLibre2NfcSetup',
          'stopLibre2NfcSetup',
        ]);
        await session.dispose();
        await subscription.cancel();
        await events.close();
      }
    },
  );

  test(
    'post-acquisition native start failure stops its exact owner and quarantines failed cleanup',
    () async {
      final calls = <MethodCall>[];
      final events = StreamController<Object?>.broadcast(sync: true);
      var stopFails = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'capabilities') return _capabilities;
        if (call.method == 'startLibre2NfcSetup') {
          throw PlatformException(code: 'nfc_start_failed');
        }
        if (call.method == 'stopLibre2NfcSetup' && stopFails) {
          throw PlatformException(code: 'nfc_cleanup_unconfirmed');
        }
        return null;
      });
      final session = Libre2Platform(
        channel: channel,
        events: events.stream,
        supported: true,
      ).createReadSession();
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);

      await expectLater(session.start(), throwsStateError);
      expect(calls.map((call) => call.method), [
        'capabilities',
        'startLibre2NfcSetup',
        'stopLibre2NfcSetup',
      ]);
      final startArguments = calls[1].arguments as Map;
      expect(startArguments.keys, ['attemptId']);
      expect(startArguments['attemptId'], isA<String>());
      expect(calls[2].arguments, startArguments);
      expect(states.map((state) => state.failure), [
        Libre2NfcFailureKind.readFailed,
        Libre2NfcFailureKind.cleanupUnconfirmed,
      ]);
      expect(
        (session as Libre2NfcCompletedReadAttemptProvider)
            .completedReadAttemptId,
        isNull,
      );

      // A later healthy channel is not proof that the lost owner was stopped.
      stopFails = false;
      await session.start();
      await session.retry();
      await expectLater(session.stop(), throwsStateError);
      expect(states.last.failure, Libre2NfcFailureKind.cleanupUnconfirmed);
      expect(calls, hasLength(3));
      await session.dispose();
      expect(calls, hasLength(3));
      await subscription.cancel();
      await events.close();
    },
  );

  test('unconfirmed native stop quarantines the read session', () async {
    final calls = <String>[];
    final events = StreamController<Object?>.broadcast(sync: true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'capabilities') return _capabilities;
      if (call.method == 'stopLibre2NfcSetup') {
        throw PlatformException(code: 'synthetic-unconfirmed');
      }
      return null;
    });
    final session = Libre2Platform(
      channel: channel,
      events: events.stream,
      supported: true,
    ).createReadSession();
    final states = <Libre2NfcSetupState>[];
    final subscription = session.states.listen(states.add);
    await session.start();
    await expectLater(session.stop(), throwsStateError);
    expect(states.last.failure, Libre2NfcFailureKind.cleanupUnconfirmed);
    await session.start();
    await session.retry();
    expect(calls, [
      'capabilities',
      'startLibre2NfcSetup',
      'stopLibre2NfcSetup',
    ]);
    await session.dispose();
    await subscription.cancel();
    await events.close();
  });

  test(
    'native cleanup failure event blocks retry without another start',
    () async {
      final calls = <String>[];
      String? attempt;
      final events = StreamController<Object?>.broadcast(sync: true);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'capabilities') return _capabilities;
        attempt ??= (call.arguments as Map)['attemptId'] as String;
        return null;
      });
      final session = Libre2Platform(
        channel: channel,
        events: events.stream,
        supported: true,
      ).createReadSession();
      final states = <Libre2NfcSetupState>[];
      final subscription = session.states.listen(states.add);
      await session.start();
      events.add({
        'attemptId': attempt,
        'event': 'failed',
        'reason': 'cleanupUnconfirmed',
      });
      expect(states.last.failure, Libre2NfcFailureKind.cleanupUnconfirmed);
      await session.start();
      await session.retry();
      expect(calls, ['capabilities', 'startLibre2NfcSetup']);
      await expectLater(session.stop(), throwsStateError);
      expect(calls.last, 'stopLibre2NfcSetup');
      await session.dispose();
      await subscription.cancel();
      await events.close();
    },
  );
}

/// Completes the capability continuation, then disposes before its async
/// consumer can resume. This isolates the final pre-dispatch ownership fence.
final class _DisposeAfterCapabilityChannel extends MethodChannel {
  _DisposeAfterCapabilityChannel()
    : super('synthetic/dispose-after-capability');

  final calls = <String>[];
  late VoidCallback afterCapability;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    calls.add(method);
    if (method == 'capabilities') {
      return _AfterCapabilityFuture<T?>(
        _capabilities as T?,
        afterCapability,
      );
    }
    return SynchronousFuture<T?>(null);
  }
}

final class _AfterCapabilityFuture<T> extends SynchronousFuture<T> {
  // The superclass's positional parameter has a private name.
  // ignore: use_super_parameters
  _AfterCapabilityFuture(T value, this.afterValue) : super(value);

  final VoidCallback afterValue;

  @override
  Future<R> then<R>(
    FutureOr<R> Function(T value) onValue, {
    Function? onError,
  }) {
    final result = super.then(onValue, onError: onError);
    afterValue();
    return result;
  }
}
