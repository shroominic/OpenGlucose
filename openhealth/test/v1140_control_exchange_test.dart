import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/v1140_control_exchange.dart';

const _short = Duration(milliseconds: 25);
const _long = Duration(seconds: 1);
const String _service = yuwellCt5ServiceUuid;
const String _writeUuid = yuwellCt5WriteCharacteristicUuid;
const String _notifyUuid = yuwellCt5NotifyCharacteristicUuid;
final List<int> _version = <int>[1, 0, 0, 0, 0, 0, 1, 1, 4, 0, 0, 0, 0, 0];
final List<int> _unbound = appendYuwellSum8(<int>[
  0x11,
  ...List<int>.filled(12, 0),
]);
final List<int> _setId = appendYuwellSum8(<int>[0x30, 1, 2, 3, 4, 5, 6, 7, 8]);
final List<int> _setIdResponse = appendYuwellSum8(<int>[
  0x30,
  ...List<int>.filled(8, 0),
]);

BleCharacteristicRef _writeRef({
  String service = _service,
  String uuid = _writeUuid,
  bool write = true,
  bool wnr = false,
}) => BleCharacteristicRef(
  serviceUuid: service,
  characteristicUuid: uuid,
  properties: BleCharacteristicProperties(
    write: write,
    writeWithoutResponse: wnr,
  ),
);

BleCharacteristicRef _notifyRef({
  String service = _service,
  String uuid = _notifyUuid,
  bool notify = true,
  bool indicate = false,
}) => BleCharacteristicRef(
  serviceUuid: service,
  characteristicUuid: uuid,
  properties: BleCharacteristicProperties(notify: notify, indicate: indicate),
);

Future<V1140ControlExchange> _open(
  _Connection connection, {
  V1140ExchangeCapability capability = V1140ExchangeCapability.pairOnce,
  BleCharacteristicRef? write,
  BleCharacteristicRef? notify,
  Duration setup = _long,
  Duration request = _short,
  Duration cleanup = _short,
}) => V1140ControlExchange.open(
  connection: connection,
  writeCharacteristic: write ?? _writeRef(),
  notifyCharacteristic: notify ?? _notifyRef(),
  capability: capability,
  setupDeadline: setup,
  requestDeadline: request,
  cleanupDeadline: cleanup,
);

Future<void> _expectFailure(
  Future<Object?> future,
  V1140ExchangeFailureKind kind,
) async {
  await expectLater(
    future,
    throwsA(isA<V1140ExchangeException>().having((e) => e.kind, 'kind', kind)),
  );
}

Future<void> _readPrefix(
  V1140ControlExchange exchange,
  _Connection connection,
) async {
  connection.onWrite = (bytes) {
    connection.emit(bytes.first == 1 ? _version : _unbound);
  };
  expect(await exchange.exchange(YuwellCt5Commands.readVersion()), _version);
  expect(
    await exchange.exchange(YuwellCt5Commands.readBindingStatus()),
    _unbound,
  );
}

void main() {
  test(
    'invalid deadline retains caller ownership without touching connection',
    () async {
      for (final deadlines in <(Duration, Duration, Duration)>[
        (Duration.zero, _short, _short),
        (_short, Duration.zero, _short),
        (_short, _short, Duration.zero),
        (const Duration(microseconds: -1), _short, _short),
      ]) {
        final connection = _Connection();
        await _expectFailure(
          _open(
            connection,
            setup: deadlines.$1,
            request: deadlines.$2,
            cleanup: deadlines.$3,
          ),
          V1140ExchangeFailureKind.rejected,
        );
        expect(connection.events, isEmpty);
        await connection.dispose();
      }
    },
  );

  test('invalid topology disconnects without a write', () async {
    for (final refs in <(BleCharacteristicRef, BleCharacteristicRef)>[
      (_writeRef(service: 'wrong'), _notifyRef()),
      (_writeRef(uuid: 'wrong'), _notifyRef()),
      (_writeRef(), _notifyRef(service: 'wrong')),
      (_writeRef(), _notifyRef(uuid: 'wrong')),
      (_writeRef(write: false, wnr: true), _notifyRef()),
      (_writeRef(), _notifyRef(notify: false)),
    ]) {
      final connection = _Connection();
      await _expectFailure(
        _open(connection, write: refs.$1, notify: refs.$2),
        V1140ExchangeFailureKind.rejected,
      );
      expect(connection.events, contains('disconnect'));
      expect(connection.writes, isEmpty);
      await connection.dispose();
    }
  });

  test(
    'subscriptions precede notify and uppercase UUIDs and indicate work',
    () async {
      final connection = _Connection();
      final exchange = await _open(
        connection,
        write: _writeRef(
          service: _service.toUpperCase(),
          uuid: _writeUuid.toUpperCase(),
        ),
        notify: _notifyRef(
          service: _service.toUpperCase(),
          uuid: _notifyUuid.toUpperCase(),
          notify: false,
          indicate: true,
        ),
      );
      expect(connection.events.take(3), [
        'states:listen',
        'notifications:listen',
        'notify:true',
      ]);
      await exchange.close();
      await connection.dispose();
    },
  );

  test('setup timeout and error clean up without command write', () async {
    for (final hang in [true, false]) {
      final connection = _Connection();
      connection.notifyFuture = hang
          ? Completer<void>().future
          : Future<void>.error(StateError('private setup'));
      await _expectFailure(
        _open(connection, setup: _short),
        hang
            ? V1140ExchangeFailureKind.deadlineExceeded
            : V1140ExchangeFailureKind.rejected,
      );
      expect(connection.writes, isEmpty);
      expect(connection.events, contains('disconnect'));
      expect(connection.events, contains('notify:false'));
      expect(connection.events, contains('notifications:cancel'));
      await connection.dispose();
    }
  });

  test('repeating the first opcode is terminal before another write', () async {
    final connection = _Connection();
    final exchange = await _open(connection);
    connection.onWrite = (_) => connection.emit(_version);
    expect(await exchange.exchange(YuwellCt5Commands.readVersion()), _version);
    await _expectFailure(
      exchange.exchange(YuwellCt5Commands.readVersion()),
      V1140ExchangeFailureKind.rejected,
    );
    await _expectFailure(
      exchange.exchange(YuwellCt5Commands.readBindingStatus()),
      V1140ExchangeFailureKind.rejected,
    );
    expect(connection.writes.length, 1);
    await connection.dispose();
  });

  test(
    'ordered rehearsal reads use write response and reject pair command',
    () async {
      final connection = _Connection();
      final exchange = await _open(
        connection,
        capability: V1140ExchangeCapability.readOnlyRehearsal,
      );
      await _readPrefix(exchange, connection);
      await _expectFailure(
        exchange.exchange(_setId),
        V1140ExchangeFailureKind.rejected,
      );
      expect(connection.writes, [
        YuwellCt5Commands.readVersion(),
        YuwellCt5Commands.readBindingStatus(),
      ]);
      expect(connection.withoutResponse, [false, false]);
      await _expectFailure(
        exchange.exchange(_setId),
        V1140ExchangeFailureKind.rejected,
      );
      await connection.dispose();
    },
  );

  test('pairOnce accepts one supplied set-ID and immutable response', () async {
    final connection = _Connection();
    final exchange = await _open(connection);
    await _readPrefix(exchange, connection);
    connection.onWrite = (_) => connection.emit(_setIdResponse);
    final response = await exchange.exchange(_setId);
    expect(response, _setIdResponse);
    expect(() => response[0] = 4, throwsUnsupportedError);
    await _expectFailure(
      exchange.exchange(_setId),
      V1140ExchangeFailureKind.rejected,
    );
    expect(connection.writes.map((bytes) => bytes.first), [1, 0x11, 0x30]);
    expect(connection.withoutResponse, [false, false, false]);
    await connection.dispose();
  });

  test(
    'out-of-order unsupported and malformed requests become terminal before write',
    () async {
      final requests = <List<int>>[
        YuwellCt5Commands.readBindingStatus(),
        const [0x03],
        const [0x31],
        const [0x35],
        const [0x37],
        const [0x38],
        const [0x3f],
        const [0x30],
        const [0x30, -1, 2],
        const [0x30, 1, 2, 3, 4, 0],
        const [0x30, -1, 2, 3, 4, 5, 6, 7, 8, 0],
      ];
      for (final request in requests) {
        final connection = _Connection();
        final exchange = await _open(connection);
        await _expectFailure(
          exchange.exchange(request),
          V1140ExchangeFailureKind.rejected,
        );
        await _expectFailure(
          exchange.exchange(YuwellCt5Commands.readVersion()),
          V1140ExchangeFailureKind.rejected,
        );
        expect(connection.writes, isEmpty);
        await connection.dispose();
      }
    },
  );

  for (final (name, malformed) in <(String, List<int>)>[
    ('truncated', const <int>[0x30, 1, 2, 3, 4, 5, 6, 7, 0x4c]),
    ('overlong', const <int>[0x30, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x5d]),
    ('bad checksum', const <int>[0x30, 1, 2, 3, 4, 5, 6, 7, 8, 0]),
    ('negative byte', const <int>[0x30, -1, 2, 3, 4, 5, 6, 7, 8, 0x52]),
    ('byte above 255', const <int>[0x30, 256, 2, 3, 4, 5, 6, 7, 8, 0x53]),
  ]) {
    test('pairOnce rejects $name set-ID after valid read prefix', () async {
      final connection = _Connection();
      final exchange = await _open(connection);
      await _readPrefix(exchange, connection);
      connection.onWrite = (_) => connection.emit(_setIdResponse);

      await _expectFailure(
        exchange.exchange(malformed),
        V1140ExchangeFailureKind.rejected,
      );
      expect(connection.writes.map((bytes) => bytes.first), [0x01, 0x11]);
      expect(connection.events, contains('disconnect'));

      await _expectFailure(
        exchange.exchange(_setId),
        V1140ExchangeFailureKind.rejected,
      );
      expect(connection.writes.map((bytes) => bytes.first), [0x01, 0x11]);
      await connection.dispose();
    });
  }

  test(
    'invalid overlap fails pending request and never queues another write',
    () async {
      final connection = _Connection();
      final exchange = await _open(connection);
      connection.writeFuture = Completer<void>().future;
      final first = exchange.exchange(YuwellCt5Commands.readVersion());
      final firstExpectation = _expectFailure(
        first,
        V1140ExchangeFailureKind.rejected,
      );
      await _expectFailure(
        exchange.exchange(YuwellCt5Commands.readBindingStatus()),
        V1140ExchangeFailureKind.rejected,
      );
      await firstExpectation;
      expect(connection.writes.length, 1);
      await connection.dispose();
    },
  );

  test('malformed version and bound status are terminal', () async {
    for (final response in <List<int>>[
      const [1],
      <int>[..._version]..[6] = 2,
      appendYuwellSum8(<int>[0x11, 0, 1, ...List<int>.filled(10, 0)]),
      const [0x11, 0],
      <int>[..._unbound]..[1] = 1,
    ]) {
      final connection = _Connection();
      final exchange = await _open(connection);
      if (response.first == 0x11) {
        connection.onWrite = (bytes) =>
            connection.emit(bytes.first == 1 ? _version : response);
        await exchange.exchange(YuwellCt5Commands.readVersion());
        await _expectFailure(
          exchange.exchange(YuwellCt5Commands.readBindingStatus()),
          V1140ExchangeFailureKind.malformedResponse,
        );
      } else {
        connection.onWrite = (_) => connection.emit(response);
        await _expectFailure(
          exchange.exchange(YuwellCt5Commands.readVersion()),
          V1140ExchangeFailureKind.malformedResponse,
        );
      }
      expect(connection.events, contains('disconnect'));
      await connection.dispose();
    }
  });

  test(
    'unsolicited empty wrong and duplicate notifications terminate exchange',
    () async {
      for (final response in <List<int>>[
        const [],
        _unbound,
        const [1, 0],
      ]) {
        final connection = _Connection();
        final exchange = await _open(connection);
        connection.emit(response);
        await _expectFailure(
          exchange.exchange(YuwellCt5Commands.readVersion()),
          V1140ExchangeFailureKind.rejected,
        );
        expect(connection.writes, isEmpty);
        await connection.dispose();
      }
      final connection = _Connection();
      final exchange = await _open(connection);
      connection.onWrite = (_) {
        connection.emit(_version);
        connection.emit(_version);
      };
      await _expectFailure(
        exchange.exchange(YuwellCt5Commands.readVersion()),
        V1140ExchangeFailureKind.malformedResponse,
      );
      await connection.dispose();
    },
  );

  test(
    'hung write and missing response hit the whole request deadline',
    () async {
      for (final hang in [true, false]) {
        final connection = _Connection();
        final exchange = await _open(connection);
        if (hang) connection.writeFuture = Completer<void>().future;
        final elapsed = Stopwatch()..start();
        await _expectFailure(
          exchange.exchange(YuwellCt5Commands.readVersion()),
          V1140ExchangeFailureKind.deadlineExceeded,
        );
        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 20)),
        );
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
        expect(connection.events, contains('disconnect'));
        expect(connection.writes.length, 1);
        await connection.dispose();
      }
    },
  );

  test('stream error and connection disconnect stop a pending read', () async {
    for (final streamError in [true, false]) {
      final connection = _Connection();
      final exchange = await _open(connection);
      final pending = exchange.exchange(YuwellCt5Commands.readVersion());
      final expectation = _expectFailure(
        pending,
        streamError
            ? V1140ExchangeFailureKind.malformedResponse
            : V1140ExchangeFailureKind.disconnected,
      );
      if (streamError) {
        connection.notificationError();
      } else {
        connection.disconnectState();
      }
      await expectation;
      await _expectFailure(
        exchange.exchange(YuwellCt5Commands.readBindingStatus()),
        V1140ExchangeFailureKind.rejected,
      );
      expect(connection.writes.length, 1);
      await connection.dispose();
    }
  });

  test(
    'late write completion and notification cannot revive a timed-out exchange',
    () async {
      final connection = _Connection();
      final exchange = await _open(connection);
      final lateWrite = Completer<void>();
      connection.writeFuture = lateWrite.future;
      await _expectFailure(
        exchange.exchange(YuwellCt5Commands.readVersion()),
        V1140ExchangeFailureKind.deadlineExceeded,
      );
      lateWrite.complete();
      connection.emit(_version);
      await _expectFailure(
        exchange.exchange(YuwellCt5Commands.readVersion()),
        V1140ExchangeFailureKind.rejected,
      );
      expect(connection.writes.length, 1);
      await connection.dispose();
    },
  );

  test(
    'after set-ID enters write every failed outcome remains unknown',
    () async {
      for (final outcome in [
        'timeout',
        'writeError',
        'badResponse',
        'shortResponse',
      ]) {
        final connection = _Connection();
        final exchange = await _open(connection);
        await _readPrefix(exchange, connection);
        connection.disconnectFuture = Completer<void>().future;
        connection.onWrite = null;
        switch (outcome) {
          case 'timeout':
            connection.writeFuture = Completer<void>().future;
          case 'writeError':
            connection.writeFuture = Future<void>.error(
              StateError('private-identity-material'),
            );
          case 'badResponse':
            connection.onWrite = (_) => connection.emit(const [0x30, 0]);
          case 'shortResponse':
            connection.onWrite = (_) => connection.emit(
              appendYuwellSum8(<int>[0x30, ...List<int>.filled(7, 0)]),
            );
        }
        await _expectFailure(
          exchange.exchange(_setId),
          V1140ExchangeFailureKind.writeOutcomeUnknown,
        );
        expect(connection.writes.last.first, 0x30);
        await _expectFailure(
          exchange.exchange(_setId),
          V1140ExchangeFailureKind.rejected,
        );
        await connection.dispose();
      }
    },
  );

  test(
    'cleanup failure after validated response is separate and redacted',
    () async {
      final connection = _Connection();
      final exchange = await _open(connection);
      await _readPrefix(exchange, connection);
      connection.onWrite = (_) => connection.emit(_setIdResponse);
      final accepted = await exchange.exchange(_setId);
      connection.disconnectFuture = Completer<void>().future;
      await _expectFailure(
        exchange.close(),
        V1140ExchangeFailureKind.cleanupFailed,
      );
      expect(accepted, _setIdResponse);
      final rendered = V1140ExchangeException(
        V1140ExchangeFailureKind.cleanupFailed,
      ).toString();
      expect(rendered, isNot(contains(connection.deviceId)));
      expect(rendered, isNot(contains('private-identity-material')));
      expect(rendered, isNot(contains(_setId.toString())));
      await connection.dispose();
    },
  );

  test('post-response duplicate prevents the next command', () async {
    final connection = _Connection();
    final exchange = await _open(connection);
    connection.onWrite = (_) => connection.emit(_version);
    expect(await exchange.exchange(YuwellCt5Commands.readVersion()), _version);
    connection.emit(_version);
    await _expectFailure(
      exchange.exchange(YuwellCt5Commands.readBindingStatus()),
      V1140ExchangeFailureKind.rejected,
    );
    expect(connection.writes.length, 1);
    await connection.dispose();
  });

  test(
    'a hung notification disable still starts disconnect and bounds close',
    () async {
      final connection = _Connection();
      final exchange = await _open(connection);
      connection.disableFuture = Completer<void>().future;
      await _expectFailure(
        exchange.close(),
        V1140ExchangeFailureKind.cleanupFailed,
      );
      expect(connection.events, contains('disconnect'));
      expect(connection.events, contains('states:cancel'));
      expect(connection.events, contains('notifications:cancel'));
      await connection.dispose();
    },
  );

  test(
    'post set-ID write uncertainty dominates disconnect and cleanup failure',
    () async {
      final connection = _Connection();
      final exchange = await _open(connection);
      await _readPrefix(exchange, connection);
      connection.writeFuture = Completer<void>().future;
      connection.disconnectFuture = Completer<void>().future;
      final pending = exchange.exchange(_setId);
      connection.disconnectState();
      await _expectFailure(
        pending,
        V1140ExchangeFailureKind.writeOutcomeUnknown,
      );
      expect(connection.writes.last.first, 0x30);
      await connection.dispose();
    },
  );

  test('explicit close is idempotent and terminal', () async {
    final connection = _Connection();
    final exchange = await _open(connection);
    await exchange.close();
    await exchange.close();
    expect(connection.events.where((e) => e == 'disconnect').length, 1);
    expect(connection.events, contains('notify:false'));
    await _expectFailure(
      exchange.exchange(YuwellCt5Commands.readVersion()),
      V1140ExchangeFailureKind.rejected,
    );
    await connection.dispose();
  });
}

final class _Connection implements BleConnection {
  final events = <String>[];
  final writes = <List<int>>[];
  final withoutResponse = <bool>[];
  late final _states = StreamController<BleConnectionState>.broadcast(
    sync: true,
    onListen: () => events.add('states:listen'),
    onCancel: () => events.add('states:cancel'),
  );
  late final _notifications = StreamController<List<int>>.broadcast(
    sync: true,
    onListen: () => events.add('notifications:listen'),
    onCancel: () => events.add('notifications:cancel'),
  );
  Future<void>? notifyFuture;
  Future<void>? disableFuture;
  Future<void>? writeFuture;
  Future<void>? disconnectFuture;
  void Function(List<int>)? onWrite;

  void emit(List<int> bytes) => _notifications.add(bytes);
  void notificationError() =>
      _notifications.addError(StateError('private notification'));
  void disconnectState() => _states.add(BleConnectionState.disconnected);
  Future<void> dispose() async {
    await _states.close();
    await _notifications.close();
  }

  @override
  String get deviceId => 'private-device-marker';
  @override
  Stream<BleConnectionState> get connectionStates => _states.stream;
  @override
  bool get supportsBondLifecycle => false;
  @override
  Future<void> ensureBonded() => throw UnimplementedError();
  @override
  Future<BleBondState> currentBondState() => throw UnimplementedError();
  @override
  Future<void> requestMtu(int mtu) => throw UnimplementedError();
  @override
  Future<List<BleService>> discoverServices() => throw UnimplementedError();
  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) =>
      throw UnimplementedError();
  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    events.add('write');
    writes.add(List<int>.of(value));
    this.withoutResponse.add(withoutResponse);
    onWrite?.call(value);
    if (writeFuture != null) await writeFuture;
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    events.add('notify:$enabled');
    if (enabled && notifyFuture != null) await notifyFuture;
    if (!enabled && disableFuture != null) await disableFuture;
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;
  @override
  Future<void> removeBond() => throw UnimplementedError();
  @override
  Future<void> disconnect() async {
    events.add('disconnect');
    if (disconnectFuture != null) await disconnectFuture;
  }
}
