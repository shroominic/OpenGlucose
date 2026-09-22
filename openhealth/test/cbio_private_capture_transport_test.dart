import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/cbio_private_capture_support.dart';

const _deviceId = 'AA:BB:CC:DD:EE:FF';
const _runId = '0123456789abcdef0123456789abcdef';
const _serial = <int>[0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa];
const _allowedWrites = <List<int>>[
  <int>[1, 2, 3],
  <int>[4, 5, 6],
  <int>[7, 8, 9],
];

void main() {
  test('exact target uses one single-attempt connection', () async {
    final delegate = _FakeTransport(_FakeConnection());
    final transport = ExactCaptureTransport(
      delegate: delegate,
      expectedDeviceId: _deviceId,
      expectedSerial: _serial,
      allowedWrites: _allowedWrites,
    );

    await expectLater(
      transport.connect('11:22:33:44:55:66'),
      throwsA(isA<StateError>()),
    );
    expect(delegate.connectCalls, 0);

    await transport.connect(_deviceId);
    expect(delegate.connectOnceCalls, 1);
    expect(delegate.connectCalls, 0);
    await expectLater(
      transport.connect(_deviceId),
      throwsA(isA<StateError>()),
    );
    expect(delegate.connectOnceCalls, 1);
  });

  test('a pre-identity write poisons the exact command gate', () async {
    final connection = _FakeConnection();
    final transport = ExactCaptureTransport(
      delegate: _FakeTransport(connection),
      expectedDeviceId: _deviceId,
      expectedSerial: _serial,
      allowedWrites: _allowedWrites,
    );
    final guarded = await transport.connect(_deviceId);
    final services = await guarded.discoverServices();
    final command = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.command),
    );
    final serial = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.serial),
    );

    await expectLater(
      guarded.write(command, _allowedWrites.first),
      throwsA(isA<StateError>()),
    );
    expect(connection.writes, isEmpty);

    expect(await guarded.read(serial), _serial);
    await expectLater(
      guarded.write(command, _allowedWrites.first),
      throwsA(isA<StateError>()),
    );
    expect(connection.writes, isEmpty);
    expect(transport.identityMatched, isTrue);
    expect(transport.topologyMatched, isTrue);
    expect(transport.commandSequenceComplete, isFalse);
  });

  test('wrong serial blocks the first vendor write', () async {
    final connection = _FakeConnection(serial: const [0, 1, 2, 3, 4, 5]);
    final transport = ExactCaptureTransport(
      delegate: _FakeTransport(connection),
      expectedDeviceId: _deviceId,
      expectedSerial: _serial,
      allowedWrites: _allowedWrites,
    );
    final guarded = await transport.connect(_deviceId);
    final services = await guarded.discoverServices();
    final serial = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.serial),
    );

    await expectLater(guarded.read(serial), throwsA(isA<StateError>()));
    expect(connection.writes, isEmpty);
    expect(transport.identityMatched, isFalse);
  });

  test('only the exact three writes pass once and in order', () async {
    final connection = _FakeConnection();
    final transport = ExactCaptureTransport(
      delegate: _FakeTransport(connection),
      expectedDeviceId: _deviceId,
      expectedSerial: _serial,
      allowedWrites: _allowedWrites,
    );
    final guarded = await transport.connect(_deviceId);
    final services = await guarded.discoverServices();
    final command = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.command),
    );
    final serial = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.serial),
    );
    await guarded.read(serial);

    for (final value in _allowedWrites) {
      await guarded.write(command, value);
    }
    await expectLater(
      guarded.write(command, _allowedWrites.last),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      guarded.write(command, _allowedWrites.first),
      throwsA(isA<StateError>()),
    );

    expect(connection.writes, _allowedWrites);
    expect(transport.attemptedWrites, [
      ..._allowedWrites,
      _allowedWrites.last,
      _allowedWrites.first,
    ]);
    expect(transport.successfulWrites, _allowedWrites);
    expect(transport.commandSequenceComplete, isFalse);
  });

  test('out-of-order frame is rejected before the delegate', () async {
    final connection = _FakeConnection();
    final transport = ExactCaptureTransport(
      delegate: _FakeTransport(connection),
      expectedDeviceId: _deviceId,
      expectedSerial: _serial,
      allowedWrites: _allowedWrites,
    );
    final guarded = await transport.connect(_deviceId);
    final services = await guarded.discoverServices();
    final command = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.command),
    );
    final serial = services.single.characteristics.firstWhere(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.serial),
    );
    await guarded.read(serial);

    await expectLater(
      guarded.write(command, _allowedWrites[1]),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      guarded.write(command, _allowedWrites.first),
      throwsA(isA<StateError>()),
    );
    expect(connection.writes, isEmpty);
    expect(transport.attemptedWrites, [
      _allowedWrites[1],
      _allowedWrites.first,
    ]);
  });

  test(
    'command audit binds the exact attempted and successful order',
    () async {
      final connection = _FakeConnection();
      final transport = ExactCaptureTransport(
        delegate: _FakeTransport(connection),
        expectedDeviceId: _deviceId,
        expectedSerial: _serial,
        allowedWrites: _allowedWrites,
      );
      final guarded = await transport.connect(_deviceId);
      final services = await guarded.discoverServices();
      final command = services.single.characteristics.firstWhere(
        (value) =>
            CbioUuids.canonical(value.characteristicUuid) ==
            CbioUuids.canonical(CbioUuids.command),
      );
      final serial = services.single.characteristics.firstWhere(
        (value) =>
            CbioUuids.canonical(value.characteristicUuid) ==
            CbioUuids.canonical(CbioUuids.serial),
      );
      await guarded.read(serial);
      for (final value in _allowedWrites) {
        await guarded.write(command, value);
      }

      expect(jsonDecode(transport.encodeCommandAudit(runId: _runId)), {
        'schemaVersion': 1,
        'runId': _runId,
        'attemptedFrameSha256': [
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
          '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
          '66a6757151f8ee55db127716c7e3dce0be8074b64e20eda542e5c1e46ca9c41e',
        ],
        'successfulFrameSha256': [
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
          '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
          '66a6757151f8ee55db127716c7e3dce0be8074b64e20eda542e5c1e46ca9c41e',
        ],
        'writeGateFailed': false,
        'commandSequenceComplete': true,
      });
    },
  );

  test(
    'a failed delegate write permanently rejects every later write',
    () async {
      final connection = _FakeConnection(failFirstWrite: true);
      final transport = ExactCaptureTransport(
        delegate: _FakeTransport(connection),
        expectedDeviceId: _deviceId,
        expectedSerial: _serial,
        allowedWrites: _allowedWrites,
      );
      final guarded = await transport.connect(_deviceId);
      final services = await guarded.discoverServices();
      final command = services.single.characteristics.firstWhere(
        (value) =>
            CbioUuids.canonical(value.characteristicUuid) ==
            CbioUuids.canonical(CbioUuids.command),
      );
      final serial = services.single.characteristics.firstWhere(
        (value) =>
            CbioUuids.canonical(value.characteristicUuid) ==
            CbioUuids.canonical(CbioUuids.serial),
      );
      await guarded.read(serial);

      await expectLater(
        guarded.write(command, _allowedWrites.first),
        throwsA(isA<StateError>()),
      );
      expect(transport.commandSequenceComplete, isFalse);
      expect(transport.successfulWrites, isEmpty);

      await expectLater(
        guarded.write(command, _allowedWrites.first),
        throwsA(isA<StateError>()),
      );
      expect(connection.writeCalls, 1);
      expect(connection.writes, isEmpty);
      expect(transport.attemptedWrites, [
        _allowedWrites.first,
        _allowedWrites.first,
      ]);
      expect(transport.successfulWrites, isEmpty);
      expect(transport.commandSequenceComplete, isFalse);
    },
  );
}

final class _FakeTransport implements BleTransport, BleSingleAttemptTransport {
  _FakeTransport(this.connection);

  final _FakeConnection connection;
  int connectCalls = 0;
  int connectOnceCalls = 0;

  @override
  bool get supportsSingleAttemptConnect => true;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => const Stream<BleScanResult>.empty();

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connectCalls++;
    return connection;
  }

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connectOnceCalls++;
    return connection;
  }
}

final class _FakeConnection implements BleConnection, BleNegotiatedMtu {
  _FakeConnection({this.serial = _serial, this.failFirstWrite = false});

  final List<int> serial;
  final bool failFirstWrite;
  final writes = <List<int>>[];
  int writeCalls = 0;

  @override
  String get deviceId => _deviceId;

  @override
  int? get negotiatedMtu => 247;

  @override
  Stream<BleConnectionState> get connectionStates =>
      Stream<BleConnectionState>.value(BleConnectionState.connected);

  @override
  bool get supportsBondLifecycle => false;

  @override
  Future<BleBondState> currentBondState() async => BleBondState.unbonded;

  @override
  Future<void> ensureBonded() async {}

  @override
  Future<void> requestMtu(int mtu) async {}

  @override
  Future<List<BleService>> discoverServices() async => const [
    BleService(
      uuid: CbioUuids.service,
      characteristics: [
        BleCharacteristicRef(
          serviceUuid: CbioUuids.service,
          characteristicUuid: CbioUuids.receive,
          properties: BleCharacteristicProperties(notify: true),
        ),
        BleCharacteristicRef(
          serviceUuid: CbioUuids.service,
          characteristicUuid: CbioUuids.command,
          properties: BleCharacteristicProperties(write: true),
        ),
        BleCharacteristicRef(
          serviceUuid: CbioUuids.service,
          characteristicUuid: CbioUuids.serial,
          properties: BleCharacteristicProperties(read: true),
        ),
      ],
    ),
  ];

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async => serial;

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    writeCalls++;
    if (failFirstWrite && writeCalls == 1) {
      throw StateError('synthetic delegate write failure');
    }
    writes.add(List<int>.of(value));
  }

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
