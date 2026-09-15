import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_gen1_receiver_store.dart';
import 'package:openglucose/src/libre_gen1_receiver_transport.dart';

const _deviceId = '02:00:00:00:00:01';
const _bootstrapId = 'synthetic_bootstrap_1';
const _sessionId = 'synthetic_receiver_owner_1';
const _lease = 'synthetic_native_lease_1';
const Map<String, Object?> _capabilities = {
  'schemaVersion': 1,
  'backend': 'receiver',
  'restoreAvailable': true,
  'enrollmentAvailable': false,
  'rawCapture': false,
};

Map<String, Object?> _bootstrap() => {
  'bootstrapId': _bootstrapId,
  'deviceId': _deviceId,
  'uid': [1, 2, 3, 4, 5, 6, 7, 0xe0],
  'initialPatchInfo': [0x9d, 8, 0x30, 1, 0, 0],
  'streamingBase': 0,
  'lifecycle': 'active',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(LibreGen1ReceiverStore.channelName);
  const captureChannel = MethodChannel('com.openglucose/protocol_capture');
  late LibreGen1ReceiverStore store;
  late _Transport transport;
  late LibreGen1ReceiverTransport wrapped;
  late List<MethodCall> calls;
  late List<String> order;
  late Future<Object?> Function(MethodCall) handler;
  var captureCalls = 0;

  setUp(() {
    calls = [];
    order = [];
    captureCalls = 0;
    store = LibreGen1ReceiverStore(
      channel: channel,
      supported: true,
      sessionIdFactory: () => _sessionId,
    );
    transport = _Transport(order);
    wrapped = LibreGen1ReceiverTransport(delegate: transport, store: store);
    handler = (call) async => switch (call.method) {
      'capabilities' => _capabilities,
      'readLibreGen1StreamingBootstrap' => _bootstrap(),
      'acquireLibreGen1Receiver' => _lease,
      'reserveLibreGen1UnlockCount' => 1,
      _ => null,
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      order.add(call.method);
      return handler(call);
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      captureCalls++;
      return _bootstrap();
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    expect(captureCalls, 0);
  });

  test(
    'capability must be exact; no fallback and no RF for discovery',
    () async {
      for (final value in <Object?>[
        null,
        {..._capabilities, 'rawCapture': true},
        {..._capabilities, 'enrollmentAvailable': true},
        {..._capabilities, 'schemaVersion': 1.0},
        {..._capabilities, 'backend': 'readOnly'},
        {..._capabilities, 'extra': true},
      ]) {
        handler = (_) async => value;
        expect(await store.isAvailable(), isFalse);
        await expectLater(
          store.readBootstrap(),
          throwsA(isA<LibreGen1LiveException>()),
        );
      }
      expect(calls.every((call) => call.method == 'capabilities'), isTrue);
      expect(transport.connects, 0);
    },
  );

  test(
    'read-only restore does not acquire a lease or reserve a counter',
    () async {
      final bootstrap = await store.readBootstrap();
      expect(bootstrap?.bootstrapId, _bootstrapId);
      expect(calls.map((c) => c.method), [
        'capabilities',
        'readLibreGen1StreamingBootstrap',
      ]);
      expect(calls.last.arguments, isNull);
      await expectLater(
        store.reserveNextUnlockCount(_bootstrapId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(calls, hasLength(2));
      expect(store.toString(), isNot(contains(_bootstrapId)));
    },
  );

  test(
    'native ownership precedes one exact-target connect and binds counters',
    () async {
      final connection = await wrapped.connectOnce(_deviceId);
      expect(
        order.indexOf('acquireLibreGen1Receiver'),
        lessThan(order.indexOf('connectOnce')),
      );
      expect(transport.connects, 1);
      expect(await store.reserveNextUnlockCount(_bootstrapId), 1);
      expect(calls.last.arguments, {
        'sessionId': _sessionId,
        'bootstrapId': _bootstrapId,
        'leaseToken': _lease,
      });
      await store.markLoginOutcome(
        _bootstrapId,
        1,
        LibreGen1LoginOutcome.acknowledged,
      );
      expect(calls.last.arguments, {
        'sessionId': _sessionId,
        'bootstrapId': _bootstrapId,
        'leaseToken': _lease,
        'unlockCount': 1,
        'outcome': 'acknowledged',
      });
      await expectLater(
        wrapped.connectOnce(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(transport.connects, 1);
      expect(connection.supportsBondLifecycle, isFalse);
      await expectLater(connection.removeBond(), throwsUnsupportedError);
      await expectLater(connection.ensureBonded(), throwsUnsupportedError);
      await connection.disconnect();
      expect(calls.last.method, 'releaseLibreGen1Receiver');
      expect(calls.last.arguments, {
        'sessionId': _sessionId,
        'bootstrapId': _bootstrapId,
        'leaseToken': _lease,
        'transportClosed': true,
      });
      await connection.disconnect();
      expect(transport.connection.closes, 1);
      expect(
        calls.where((c) => c.method == 'releaseLibreGen1Receiver'),
        hasLength(1),
      );
    },
  );

  test(
    'unsupported single attempt and wrong target never acquire or connect',
    () async {
      transport.singleAttempt = false;
      expect(wrapped.supportsSingleAttemptConnect, isFalse);
      await expectLater(
        wrapped.connect(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(calls, isEmpty);
      transport.singleAttempt = true;
      await expectLater(
        wrapped.connectOnce('02:00:00:00:00:02'),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(transport.connects, 0);
      expect(calls.any((c) => c.method == 'acquireLibreGen1Receiver'), isFalse);
    },
  );

  test(
    'connect error without a close handle retains ownership and blocks retry',
    () async {
      transport.failConnect = true;
      await expectLater(
        wrapped.connectOnce(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      await expectLater(
        wrapped.connectOnce(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(transport.connects, 1);
      expect(calls.any((c) => c.method == 'releaseLibreGen1Receiver'), isFalse);
      await expectLater(
        store.reserveNextUnlockCount(_bootstrapId),
        throwsA(isA<LibreGen1LiveException>()),
      );
    },
  );

  test(
    'close barrier holds lease until physical delegate completion',
    () async {
      final closed = Completer<void>();
      transport.connection.closeBarrier = closed.future;
      final connection = await wrapped.connectOnce(_deviceId);
      final closing = connection.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(calls.any((c) => c.method == 'releaseLibreGen1Receiver'), isFalse);
      closed.complete();
      await closing;
      expect(
        order.indexOf('transportClosed'),
        lessThan(order.indexOf('releaseLibreGen1Receiver')),
      );
    },
  );

  test(
    'failed close cannot release, retry RF, or expose platform text',
    () async {
      transport.connection.failClose = true;
      final connection = await wrapped.connectOnce(_deviceId);
      await expectLater(
        connection.disconnect(),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (e) => e.kind,
            'kind',
            LibreGen1LiveFailure.cleanupUnconfirmed,
          ),
        ),
      );
      await expectLater(
        wrapped.connectOnce(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(transport.connects, 1);
      expect(calls.any((c) => c.method == 'releaseLibreGen1Receiver'), isFalse);
    },
  );

  test(
    'failed native release blocks reacquisition even after transport close',
    () async {
      final connection = await wrapped.connectOnce(_deviceId);
      handler = (_) async => throw PlatformException(
        code: 'failure',
        message: 'private-native-sentinel',
      );
      await expectLater(
        connection.disconnect(),
        throwsA(isA<LibreGen1LiveException>()),
      );
      await expectLater(
        wrapped.connectOnce(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(transport.connects, 1);
    },
  );

  testWidgets('late physical close cannot release a quarantined owner', (
    tester,
  ) async {
    final lateClose = Completer<void>();
    transport.connection.closeBarrier = lateClose.future;
    final connecting = wrapped.connectOnce(_deviceId);
    await tester.pump();
    final connection = await connecting;
    final closing = connection.disconnect();
    final failed = expectLater(closing, throwsA(isA<LibreGen1LiveException>()));
    await tester.pump(const Duration(seconds: 6));
    await failed;
    lateClose.complete();
    await tester.pump();
    expect(
      calls.any((call) => call.method == 'releaseLibreGen1Receiver'),
      isFalse,
    );
    await expectLater(
      wrapped.connectOnce(_deviceId),
      throwsA(isA<LibreGen1LiveException>()),
    );
    expect(transport.connects, 1);
  });

  test(
    'malformed outcome acknowledgement is not successful login proof',
    () async {
      final connection = await wrapped.connectOnce(_deviceId);
      await store.reserveNextUnlockCount(_bootstrapId);
      final previous = handler;
      handler = (call) => call.method == 'markLibreGen1LoginOutcome'
          ? Future<Object?>.value({'unexpected': true})
          : previous(call);
      await expectLater(
        store.markLoginOutcome(
          _bootstrapId,
          1,
          LibreGen1LoginOutcome.acknowledged,
        ),
        throwsA(isA<LibreGen1LiveException>()),
      );
      await connection.disconnect();
    },
  );

  testWidgets('late native release reply cannot reopen a timed-out owner', (
    tester,
  ) async {
    final physicalClose = Completer<void>();
    final nativeRelease = Completer<Object?>();
    transport.connection.closeBarrier = physicalClose.future;
    final previous = handler;
    handler = (call) => call.method == 'releaseLibreGen1Receiver'
        ? nativeRelease.future
        : previous(call);
    final connecting = wrapped.connectOnce(_deviceId);
    await tester.pump();
    final connection = await connecting;
    final closing = connection.disconnect();
    final failed = expectLater(
      closing.timeout(const Duration(seconds: 15)),
      throwsA(
        isA<LibreGen1LiveException>().having(
          (error) => error.kind,
          'kind',
          LibreGen1LiveFailure.cleanupUnconfirmed,
        ),
      ),
    );
    var settled = false;
    unawaited(
      closing.then<void>(
        (_) => settled = true,
        onError: (Object _, StackTrace _) {
          settled = true;
        },
      ),
    );
    // Consume most of the five-second physical-close budget, then start the
    // independently bounded native release. The whole result must settle
    // before the driver's fifteen-second outer timeout.
    await tester.pump(const Duration(seconds: 4));
    expect(
      calls.any((call) => call.method == 'releaseLibreGen1Receiver'),
      isFalse,
    );
    physicalClose.complete();
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'releaseLibreGen1Receiver'),
      hasLength(1),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(settled, isTrue);
    await failed;
    nativeRelease.complete(null);
    await tester.pump();
    expect(await store.isAvailable(), isFalse);
    await expectLater(
      wrapped.connectOnce(_deviceId),
      throwsA(isA<LibreGen1LiveException>()),
    );
    await expectLater(
      connection.disconnect(),
      throwsA(isA<LibreGen1LiveException>()),
    );
    expect(transport.connects, 1);
    expect(transport.connection.closes, 1);
    expect(
      calls.where((call) => call.method == 'releaseLibreGen1Receiver'),
      hasLength(1),
    );
  });

  testWidgets(
    'lost acquire reply never opens transport or grants a late lease',
    (tester) async {
      final lateReply = Completer<Object?>();
      final previous = handler;
      handler = (call) => call.method == 'acquireLibreGen1Receiver'
          ? lateReply.future
          : previous(call);
      final connecting = wrapped.connectOnce(_deviceId);
      final failed = expectLater(
        connecting,
        throwsA(isA<LibreGen1LiveException>()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await failed;
      lateReply.complete(_lease);
      await tester.pump();
      await expectLater(
        wrapped.connectOnce(_deviceId),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(transport.connects, 0);
      expect(
        calls.where((c) => c.method == 'acquireLibreGen1Receiver'),
        hasLength(1),
      );
      expect(calls.any((c) => c.method == 'releaseLibreGen1Receiver'), isFalse);
    },
  );
}

final class _Transport implements BleSingleAttemptTransport {
  _Transport(this.order) : connection = _Connection(order);
  final List<String> order;
  final _Connection connection;
  bool singleAttempt = true;
  bool failConnect = false;
  int connects = 0;
  @override
  bool get supportsSingleAttemptConnect => singleAttempt;
  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connects++;
    order.add('connectOnce');
    if (failConnect) throw StateError('private-native-sentinel');
    return connection;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw StateError('must not fall back');
  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => const Stream.empty();
}

final class _Connection implements BleConnection {
  _Connection(this.order);
  final List<String> order;
  Future<void>? closeBarrier;
  bool failClose = false;
  int closes = 0;
  @override
  String get deviceId => _deviceId;
  @override
  Future<void> disconnect() async {
    closes++;
    await closeBarrier;
    if (failClose) throw StateError('private-native-sentinel');
    order.add('transportClosed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
