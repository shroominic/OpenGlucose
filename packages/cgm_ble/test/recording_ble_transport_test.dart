import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:test/test.dart';

void main() {
  test(
    'single-attempt capability fails closed for a legacy delegate',
    () async {
      final delegate = _FakeTransport(connection: _FakeConnection());
      final transport = RecordingBleTransport(
        delegate: delegate,
        sink: _CollectingSink(),
      );
      expect(transport.supportsSingleAttemptConnect, isFalse);
      await expectLater(
        transport.connectOnce('device-1'),
        throwsUnsupportedError,
      );
      expect(delegate.connectCalls, 0);
    },
  );

  test(
    'single-attempt trace forwards once and preserves connection recording',
    () async {
      final delegate = _SingleAttemptTransport();
      final sink = _CollectingSink();
      final transport = RecordingBleTransport(delegate: delegate, sink: sink);
      expect(transport.supportsSingleAttemptConnect, isTrue);
      final connection = await transport.connectOnce(
        'device-1',
        timeout: const Duration(seconds: 7),
      );
      expect(connection.deviceId, 'device-1');
      expect(delegate.singleCalls, 1);
      expect(delegate.singleTimeout, const Duration(seconds: 7));
      expect(delegate.connectCalls, 0);
      await connection.discoverServices();
      expect(
        sink.events
            .where((e) => e.operation == BleTraceOperation.connect)
            .map((e) => e.type),
        [
          BleTraceEventType.operationStarted,
          BleTraceEventType.operationSucceeded,
        ],
      );
      expect(
        sink.events.any(
          (e) => e.operation == BleTraceOperation.discoverServices,
        ),
        isTrue,
      );
    },
  );

  test(
    'single-attempt failure is recorded without retry or legacy fallback',
    () async {
      final delegate = _SingleAttemptTransport()
        ..singleError = StateError('synthetic failure');
      final sink = _CollectingSink();
      final transport = RecordingBleTransport(delegate: delegate, sink: sink);
      await expectLater(transport.connectOnce('device-1'), throwsStateError);
      expect(delegate.singleCalls, 1);
      expect(delegate.connectCalls, 0);
      expect(sink.events.last.type, BleTraceEventType.operationFailed);
    },
  );

  test(
    'wrapper preserves an explicitly disabled single-attempt capability',
    () async {
      final delegate = _SingleAttemptTransport()..supported = false;
      final transport = RecordingBleTransport(
        delegate: delegate,
        sink: _CollectingSink(),
      );
      expect(transport.supportsSingleAttemptConnect, isFalse);
      await expectLater(
        transport.connectOnce('device-1'),
        throwsUnsupportedError,
      );
      expect(delegate.singleCalls, 0);
      expect(delegate.connectCalls, 0);
      await transport.connect('device-1');
      expect(delegate.connectCalls, 1);
    },
  );

  const characteristic = BleCharacteristicRef(
    serviceUuid: 'service-a',
    characteristicUuid: 'characteristic-b',
    properties: BleCharacteristicProperties(
      read: true,
      write: true,
      notify: true,
    ),
  );

  test('scan records immutable, versioned advertisement events', () async {
    final manufacturerBytes = <int>[1, 2];
    final serviceBytes = <int>[3, 4];
    final scanResult = BleScanResult(
      deviceId: 'sensitive-device-id',
      deviceName: 'sensitive-sensor-name',
      rssi: -42,
      observedAt: DateTime.utc(2026, 8, 30, 23, 59),
      serviceUuids: const <String>['service-a'],
      manufacturerData: <BleManufacturerData>[
        BleManufacturerData(companyId: 123, bytes: manufacturerBytes),
      ],
      serviceData: <String, List<int>>{'service-a': serviceBytes},
    );
    final delegate = _FakeTransport(
      connection: _FakeConnection(),
      scanStream: Stream<BleScanResult>.value(scanResult),
    );
    final sink = _CollectingSink();
    final clock = _FakeClock();
    final transport = RecordingBleTransport(
      delegate: delegate,
      sink: sink,
      utcNow: clock.utcNow,
      monotonicNow: clock.monotonicNow,
    );

    final results = await transport
        .scan(
          timeout: const Duration(seconds: 2),
          allowDuplicates: false,
          withServices: const <String>['service-a'],
        )
        .toList();
    manufacturerBytes[0] = 99;
    serviceBytes[0] = 88;

    expect(results, <BleScanResult>[scanResult]);
    expect(delegate.scanTimeout, const Duration(seconds: 2));
    expect(delegate.scanAllowDuplicates, isFalse);
    expect(delegate.scanWithServices, const <String>['service-a']);
    expect(sink.events.map((event) => event.type), <BleTraceEventType>[
      BleTraceEventType.operationStarted,
      BleTraceEventType.advertisement,
      BleTraceEventType.streamCompleted,
    ]);
    expect(sink.events.map((event) => event.sequence), <int>[1, 2, 3]);
    expect(
      sink.events.map((event) => event.correlationId).toSet(),
      hasLength(1),
    );
    expect(sink.events.map((event) => event.recordedAtUtc), <DateTime>[
      DateTime.utc(2026, 8, 31),
      DateTime.utc(2026, 8, 31, 0, 0, 0, 0, 1),
      DateTime.utc(2026, 8, 31, 0, 0, 0, 0, 2),
    ]);
    expect(
      sink.events.map((event) => event.monotonicElapsed.inMicroseconds),
      <int>[0, 1, 2],
    );

    final advertisement = sink.events[1];
    expect(advertisement.data['observed_at_utc'], '2026-08-30T23:59:00.000Z');
    expect(results.single.observedAt, scanResult.observedAt);
    final manufacturerData =
        advertisement.data['manufacturer_data']! as List<Object?>;
    final firstManufacturer = manufacturerData.single! as Map<String, Object?>;
    expect(firstManufacturer['bytes'], <int>[1, 2]);
    final capturedServiceData =
        advertisement.data['service_data']! as Map<String, Object?>;
    expect(capturedServiceData['service-a'], <int>[3, 4]);
    expect(() => advertisement.data['rssi'] = 0, throwsUnsupportedError);

    final json = advertisement.toSensitiveJson();
    expect(json['schema_version'], bleTraceSchemaVersion);
    expect(json['event_type'], 'advertisement');
    expect(json['operation'], 'scan');
    expect(json['monotonic_elapsed_microseconds'], 1);
    expect(advertisement.toString(), contains('sensitiveData: <redacted>'));
    expect(advertisement.toString(), isNot(contains('sensitive-device-id')));
    expect(advertisement.toString(), isNot(contains('sensitive-sensor-name')));
  });

  test('connection records lifecycle, topology, bytes, and bonding', () async {
    final delegateConnection = _FakeConnection();
    final delegate = _FakeTransport(connection: delegateConnection);
    final sink = _CollectingSink();
    final clock = _FakeClock();
    final transport = RecordingBleTransport(
      delegate: delegate,
      sink: sink,
      utcNow: clock.utcNow,
      monotonicNow: clock.monotonicNow,
    );

    final connection = await transport.connect(
      'device-1',
      timeout: const Duration(seconds: 7),
    );
    final statesFuture = connection.connectionStates.toList();
    delegateConnection.connectionStateController
      ..add(BleConnectionState.connecting)
      ..add(BleConnectionState.connected);
    await delegateConnection.connectionStateController.close();
    expect(await statesFuture, <BleConnectionState>[
      BleConnectionState.connecting,
      BleConnectionState.connected,
    ]);

    await connection.ensureBonded();
    expect(await connection.currentBondState(), BleBondState.bonded);
    await connection.requestMtu(247);
    final services = await connection.discoverServices();
    final readValue = await connection.read(characteristic);
    final writeValue = <int>[20, 21];
    await connection.write(characteristic, writeValue, withoutResponse: true);
    await connection.setNotify(characteristic, true);
    final notificationsFuture = connection
        .notifications(characteristic)
        .toList();
    final notificationValue = <int>[30, 31];
    delegateConnection.notificationController.add(notificationValue);
    await delegateConnection.notificationController.close();
    expect(await notificationsFuture, <List<int>>[notificationValue]);
    await connection.removeBond();
    await connection.disconnect();

    expect(connection.deviceId, 'device-1');
    expect(connection.supportsBondLifecycle, isTrue);
    expect(delegate.connectDeviceId, 'device-1');
    expect(delegate.connectTimeout, const Duration(seconds: 7));
    expect(delegateConnection.requestedMtu, 247);
    expect((connection as BleNegotiatedMtu).negotiatedMtu, 247);
    expect(services, same(delegateConnection.services));
    expect(readValue, same(delegateConnection.readValue));
    expect(delegateConnection.writtenCharacteristic, same(characteristic));
    expect(delegateConnection.writtenValue, same(writeValue));
    expect(delegateConnection.wroteWithoutResponse, isTrue);
    expect(delegateConnection.notifyEnabled, isTrue);
    expect(delegateConnection.ensureBondedCalls, 1);
    expect(delegateConnection.removeBondCalls, 1);
    expect(delegateConnection.disconnectCalls, 1);

    expect(
      sink.events.map((event) => event.sequence),
      List<int>.generate(sink.events.length, (index) => index + 1),
    );

    final connectEvents = sink.events
        .where((event) => event.operation == BleTraceOperation.connect)
        .toList();
    expect(connectEvents.map((event) => event.type), <BleTraceEventType>[
      BleTraceEventType.operationStarted,
      BleTraceEventType.operationSucceeded,
    ]);
    expect(
      connectEvents.map((event) => event.correlationId).toSet(),
      hasLength(1),
    );

    final stateEvents = sink.events
        .where((event) => event.type == BleTraceEventType.connectionState)
        .toList();
    expect(stateEvents.map((event) => event.data['state']), <String>[
      'connecting',
      'connected',
    ]);
    expect(stateEvents.first.correlationId, connectEvents.first.correlationId);

    final topologyEvent = _succeededEvent(
      sink.events,
      BleTraceOperation.discoverServices,
    );
    final topology = topologyEvent.data['services']! as List<Object?>;
    final service = topology.single! as Map<String, Object?>;
    expect(service['uuid'], 'service-a');
    final characteristics = service['characteristics']! as List<Object?>;
    final capturedCharacteristic =
        characteristics.single! as Map<String, Object?>;
    expect(capturedCharacteristic['characteristic_uuid'], 'characteristic-b');

    final readEvent = _succeededEvent(sink.events, BleTraceOperation.read);
    expect(readEvent.data['bytes'], <int>[10, 11]);
    final writeEvent = _startedEvent(sink.events, BleTraceOperation.write);
    expect(writeEvent.data['bytes'], <int>[20, 21]);
    expect(writeEvent.data['without_response'], isTrue);
    final bondStateEvent = _succeededEvent(
      sink.events,
      BleTraceOperation.currentBondState,
    );
    expect(bondStateEvent.data['state'], 'bonded');

    final setNotifyEvent = _succeededEvent(
      sink.events,
      BleTraceOperation.setNotify,
    );
    final notificationEvent = sink.events.singleWhere(
      (event) => event.type == BleTraceEventType.notificationData,
    );
    expect(notificationEvent.data['bytes'], <int>[30, 31]);
    expect(notificationEvent.correlationId, setNotifyEvent.correlationId);
    expect(
      sink.events.any(
        (event) =>
            event.type == BleTraceEventType.streamCompleted &&
            event.operation == BleTraceOperation.notifications,
      ),
      isTrue,
    );
  });

  test('sink failures never change delegate values or errors', () async {
    final delegateConnection = _FakeConnection();
    final transport = RecordingBleTransport(
      delegate: _FakeTransport(connection: delegateConnection),
      sink: _ThrowingSink(),
    );
    final connection = await transport.connect('device-1');

    expect(
      await connection.read(characteristic),
      same(delegateConnection.readValue),
    );
    await connection.write(characteristic, <int>[1]);
    await connection.ensureBonded();

    final delegateError = StateError('delegate error must remain intact');
    delegateConnection.readError = delegateError;
    await expectLater(
      connection.read(characteristic),
      throwsA(same(delegateError)),
    );

    await Future<void>.delayed(Duration.zero);
  });

  test('capture heartbeat shares sequence and awaits sink commit', () async {
    final sink = _ControlledSink();
    final transport = RecordingBleTransport(
      delegate: _FakeTransport(connection: _FakeConnection()),
      sink: sink,
      utcNow: () => DateTime.utc(2026, 8, 31),
      monotonicNow: () => const Duration(milliseconds: 4),
    );

    final heartbeat = transport.recordCaptureHeartbeat();
    expect(sink.events, hasLength(1));
    expect(sink.events.single.sequence, 1);
    expect(sink.events.single.type, BleTraceEventType.captureHeartbeat);
    expect(sink.events.single.operation, BleTraceOperation.captureHeartbeat);
    var completed = false;
    heartbeat.then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    sink.commit.complete();
    await heartbeat;
    expect(completed, isTrue);
  });

  test(
    'failures are classified without retaining arbitrary error text',
    () async {
      final delegateConnection = _FakeConnection();
      final sink = _CollectingSink();
      final connection = RecordingBleConnection(
        delegate: delegateConnection,
        sink: sink,
        utcNow: () => DateTime.utc(2026),
        monotonicNow: () => Duration.zero,
      );
      delegateConnection.readError = StateError('secret native device text');

      await expectLater(connection.read(characteristic), throwsStateError);

      final failure = sink.events.singleWhere(
        (event) => event.type == BleTraceEventType.operationFailed,
      );
      expect(failure.data['failure'], const <String, Object?>{
        'classification': 'unclassified',
      });
      expect(failure.toSensitiveJson().toString(), isNot(contains('secret')));
    },
  );

  test(
    'scan preserves source stream errors and records safe failure',
    () async {
      final sourceError = BleFailure(
        kind: BleFailureKind.bluetoothOff,
        operation: BleOperation.scan,
        diagnosticCode: 'platform.scan.bluetooth-off',
      );
      final sink = _CollectingSink();
      final transport = RecordingBleTransport(
        delegate: _FakeTransport(
          connection: _FakeConnection(),
          scanStream: Stream<BleScanResult>.error(sourceError),
        ),
        sink: sink,
      );

      await expectLater(transport.scan(), emitsError(same(sourceError)));

      final failure = sink.events.singleWhere(
        (event) => event.type == BleTraceEventType.streamFailed,
      );
      expect(failure.data['failure'], <String, Object?>{
        'classification': 'ble_failure',
        'kind': 'bluetoothOff',
        'operation': 'scan',
        'diagnostic_code': 'platform.scan.bluetooth-off',
      });
    },
  );

  test('scan cancellation records one terminal event', () async {
    final source = StreamController<BleScanResult>();
    final sink = _CollectingSink();
    final transport = RecordingBleTransport(
      delegate: _FakeTransport(
        connection: _FakeConnection(),
        scanStream: source.stream,
      ),
      sink: sink,
    );

    final subscription = transport.scan().listen((_) {});
    await subscription.cancel();
    await subscription.cancel();

    expect(sink.events.map((event) => event.type), <BleTraceEventType>[
      BleTraceEventType.operationStarted,
      BleTraceEventType.streamCancelled,
    ]);
    expect(
      sink.events.map((event) => event.correlationId).toSet(),
      hasLength(1),
    );
  });

  test('scan cancellation failure is preserved and recorded once', () async {
    final cancellationError = StateError('cancel failure');
    final source = StreamController<BleScanResult>(
      onCancel: () => Future<void>.error(cancellationError),
    );
    final sink = _CollectingSink();
    final transport = RecordingBleTransport(
      delegate: _FakeTransport(
        connection: _FakeConnection(),
        scanStream: source.stream,
      ),
      sink: sink,
    );

    final subscription = transport.scan().listen((_) {});
    await expectLater(subscription.cancel(), throwsA(same(cancellationError)));

    final failure = sink.events.singleWhere(
      (event) => event.type == BleTraceEventType.streamCancellationFailed,
    );
    expect(failure.operation, BleTraceOperation.scan);
    expect(
      sink.events.where(
        (event) =>
            event.type == BleTraceEventType.streamCancelled ||
            event.type == BleTraceEventType.streamCancellationFailed,
      ),
      hasLength(1),
    );
  });

  test(
    'connection and notification cancellations close correlations',
    () async {
      final delegate = _FakeConnection();
      final sink = _CollectingSink();
      final connection = RecordingBleConnection(delegate: delegate, sink: sink);

      final stateSubscription = connection.connectionStates.listen((_) {});
      final notificationSubscription = connection
          .notifications(characteristic)
          .listen((_) {});
      await stateSubscription.cancel();
      await notificationSubscription.cancel();

      final cancellations = sink.events
          .where((event) => event.type == BleTraceEventType.streamCancelled)
          .toList(growable: false);
      expect(cancellations.map((event) => event.operation), <BleTraceOperation>[
        BleTraceOperation.connectionState,
        BleTraceOperation.notifications,
      ]);
      expect(
        cancellations.map((event) => event.correlationId).toSet(),
        hasLength(2),
      );
      expect(
        cancellations.every((event) => event.data['device_id'] == 'device-1'),
        isTrue,
      );
    },
  );
}

BleTraceEvent _startedEvent(
  List<BleTraceEvent> events,
  BleTraceOperation operation,
) => events.singleWhere(
  (event) =>
      event.type == BleTraceEventType.operationStarted &&
      event.operation == operation,
);

BleTraceEvent _succeededEvent(
  List<BleTraceEvent> events,
  BleTraceOperation operation,
) => events.singleWhere(
  (event) =>
      event.type == BleTraceEventType.operationSucceeded &&
      event.operation == operation,
);

final class _CollectingSink implements BleTraceSink {
  final List<BleTraceEvent> events = <BleTraceEvent>[];

  @override
  void append(BleTraceEvent event) {
    events.add(event);
  }
}

final class _ThrowingSink implements BleTraceSink {
  int appendCalls = 0;

  @override
  FutureOr<void> append(BleTraceEvent event) {
    appendCalls++;
    if (appendCalls.isOdd) {
      throw StateError('synchronous sink failure');
    }
    return Future<void>.error(StateError('asynchronous sink failure'));
  }
}

final class _ControlledSink implements BleTraceSink {
  final List<BleTraceEvent> events = <BleTraceEvent>[];
  final Completer<void> commit = Completer<void>();

  @override
  Future<void> append(BleTraceEvent event) {
    events.add(event);
    return commit.future;
  }
}

final class _FakeClock {
  final DateTime _origin = DateTime.utc(2026, 8, 31);
  int _tick = 0;

  DateTime utcNow() => _origin.add(Duration(microseconds: _tick));

  Duration monotonicNow() => Duration(microseconds: _tick++);
}

class _FakeTransport implements BleTransport {
  _FakeTransport({
    required this.connection,
    this.scanStream = const Stream<BleScanResult>.empty(),
  });

  final BleConnection connection;
  final Stream<BleScanResult> scanStream;

  Duration? scanTimeout;
  bool? scanAllowDuplicates;
  List<String>? scanWithServices;
  String? connectDeviceId;
  Duration? connectTimeout;
  int connectCalls = 0;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    scanTimeout = timeout;
    scanAllowDuplicates = allowDuplicates;
    scanWithServices = withServices;
    return scanStream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connectCalls += 1;
    connectDeviceId = deviceId;
    connectTimeout = timeout;
    return connection;
  }
}

final class _SingleAttemptTransport extends _FakeTransport
    implements BleSingleAttemptTransport {
  _SingleAttemptTransport() : super(connection: _FakeConnection());
  bool supported = true;
  int singleCalls = 0;
  Duration? singleTimeout;
  Object? singleError;

  @override
  bool get supportsSingleAttemptConnect => supported;

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    singleCalls += 1;
    singleTimeout = timeout;
    if (singleError case final error?) throw error;
    return connection;
  }
}

final class _FakeConnection implements BleConnection, BleNegotiatedMtu {
  _FakeConnection()
    : services = <BleService>[
        const BleService(
          uuid: 'service-a',
          characteristics: <BleCharacteristicRef>[
            BleCharacteristicRef(
              serviceUuid: 'service-a',
              characteristicUuid: 'characteristic-b',
              properties: BleCharacteristicProperties(
                read: true,
                write: true,
                notify: true,
              ),
            ),
          ],
        ),
      ];

  final StreamController<BleConnectionState> connectionStateController =
      StreamController<BleConnectionState>.broadcast(sync: true);
  final StreamController<List<int>> notificationController =
      StreamController<List<int>>.broadcast(sync: true);
  final List<BleService> services;
  final List<int> readValue = <int>[10, 11];

  Object? readError;
  int ensureBondedCalls = 0;
  int? requestedMtu;

  @override
  int? get negotiatedMtu => requestedMtu;
  BleCharacteristicRef? writtenCharacteristic;
  List<int>? writtenValue;
  bool? wroteWithoutResponse;
  bool? notifyEnabled;
  int removeBondCalls = 0;
  int disconnectCalls = 0;

  @override
  String get deviceId => 'device-1';

  @override
  Stream<BleConnectionState> get connectionStates =>
      connectionStateController.stream;

  @override
  bool get supportsBondLifecycle => true;

  @override
  Future<void> ensureBonded() async {
    ensureBondedCalls++;
  }

  @override
  Future<BleBondState> currentBondState() async => BleBondState.bonded;

  @override
  Future<void> requestMtu(int mtu) async {
    requestedMtu = mtu;
  }

  @override
  Future<List<BleService>> discoverServices() async => services;

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async {
    final error = readError;
    if (error != null) {
      throw error;
    }
    return readValue;
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    writtenCharacteristic = characteristic;
    writtenValue = value;
    wroteWithoutResponse = withoutResponse;
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    notifyEnabled = enabled;
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      notificationController.stream;

  @override
  Future<void> removeBond() async {
    removeBondCalls++;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }
}
