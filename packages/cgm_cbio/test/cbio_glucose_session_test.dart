import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

/// Synthetic vendor material for this suite.
///
/// The package compiles no vendor material, so every session under test is
/// handed this obviously synthetic set through a credential source rather than
/// reading a compiled constant. The bytes are unrelated to the real link and
/// are never the values a build supplies.
final CbioCredentials _syntheticCredentials = CbioCredentials(
  streamKey: _ascii('CGMTESTKEY000000'),
  authMaterial: _ascii('CGMTESTMATERIAL1'),
  authenticationTrigger: const <int>[0x10, 0x20, 0x30, 0x40, 0x50],
);

final List<int> _syntheticKey = _syntheticCredentials.streamKey;

final CbioCredentialSource _syntheticSource = CbioStaticCredentialSource(
  _syntheticCredentials,
);

List<int> _ascii(String value) => value.codeUnits;

/// Reads one captured write back with the key this suite's sessions resolve.
List<int> _unmaskWrite(List<int> masked) =>
    unmaskCbioFrame(masked, key: _syntheticKey);

/// The vendor's accepted authentication reply, opcode 0x01 result 1.
const List<int> _authAccepted = <int>[0x04, 0x01, 0x01, 0x00, 0xfa];

/// The vendor's rejected authentication reply, opcode 0x01 result 0.
const List<int> _authRejected = <int>[0x04, 0x01, 0x00, 0x02, 0xf9];

// Synthetic serial octets: the real sensor serial is never committed.
const List<int> _serialOctets = <int>[0x11, 0x22, 0x33, 0x44, 0x55, 0x66];

List<int> _framed(List<int> body) {
  final head = <int>[body.length + 1, ...body];
  return <int>[...head, (-head.fold<int>(0, (sum, byte) => sum + byte)) & 0xff];
}

/// One plaintext `08` batch, index-major, in the vendor's raw layout.
List<int> _rawBatch({
  required int startIndex,
  required int baseEpochSeconds,
  required int baseReindex,
  required List<int> currents,
  int temperature = 315,
}) {
  final records = <int>[
    for (final current in currents) ...<int>[
      temperature & 0xff,
      (temperature >> 8) & 0xff,
      0x00,
      0x00,
      current & 0xff,
      (current >> 8) & 0xff,
      0x00,
      0x00,
    ],
  ];
  return _framed(<int>[
    0x08,
    currents.length,
    startIndex & 0xff,
    (startIndex >> 8) & 0xff,
    baseEpochSeconds & 0xff,
    (baseEpochSeconds >> 8) & 0xff,
    (baseEpochSeconds >> 16) & 0xff,
    (baseEpochSeconds >> 24) & 0xff,
    ...records,
    baseReindex & 0xff,
    (baseReindex >> 8) & 0xff,
  ]);
}

/// One plaintext `0A` packed batch. Values stay zero, as this firmware sends.
List<int> _packedBatch({required int startIndex, required int count}) {
  return _framed(<int>[
    0x0a,
    count,
    startIndex & 0xff,
    (startIndex >> 8) & 0xff,
    0x00,
    0x00,
    0x00,
    0x00,
    for (var index = 0; index < count * 2; index++) 0x00,
    0x00,
    0x00,
  ]);
}

final class _FakeConnection implements BleConnection {
  _FakeConnection({
    this.serial = _serialOctets,
    List<BleService>? services,
    List<int>? streamKey,
  }) : services = services ?? _defaultServices,
       streamKey = streamKey ?? _syntheticKey;

  static const List<BleService> _defaultServices = <BleService>[
    BleService(
      uuid: CbioUuids.service,
      characteristics: <BleCharacteristicRef>[
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
      ],
    ),
    BleService(
      uuid: '0000180a-0000-1000-8000-00805f9b34fb',
      characteristics: <BleCharacteristicRef>[
        BleCharacteristicRef(
          serviceUuid: '0000180a-0000-1000-8000-00805f9b34fb',
          characteristicUuid: '00002a25-0000-1000-8000-00805f9b34fb',
          properties: BleCharacteristicProperties(read: true),
        ),
      ],
    ),
  ];

  static const String serialUuid = '00002a25-0000-1000-8000-00805f9b34fb';

  final List<int> serial;
  final List<BleService> services;
  final List<int> streamKey;
  final StreamController<BleConnectionState> _states =
      StreamController<BleConnectionState>.broadcast();
  final StreamController<List<int>> _notifications =
      StreamController<List<int>>.broadcast();
  final List<List<int>> writes = <List<int>>[];
  final List<BleCharacteristicRef> serialReads = <BleCharacteristicRef>[];

  /// Invoked with each plaintext command the session writes.
  Future<void> Function(List<int> plaintext)? onWrite;
  bool notifySubscribed = false;
  bool disconnected = false;
  int mtuRequests = 0;

  @override
  String get deviceId => 'fake-cbio';

  @override
  Stream<BleConnectionState> get connectionStates => _states.stream;

  @override
  bool get supportsBondLifecycle => false;

  @override
  Future<void> ensureBonded() async {}

  @override
  Future<BleBondState> currentBondState() async => BleBondState.unbonded;

  @override
  Future<void> requestMtu(int mtu) async {
    mtuRequests += 1;
  }

  @override
  Future<List<BleService>> discoverServices() async => services;

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async {
    serialReads.add(characteristic);
    if (CbioUuids.canonical(characteristic.characteristicUuid) ==
        CbioUuids.canonical(serialUuid)) {
      return serial;
    }
    return <int>[];
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    writes.add(List<int>.from(value));
    final plaintext = unmaskCbioFrame(value, key: streamKey);
    await onWrite?.call(plaintext);
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    notifySubscribed = enabled;
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;

  void emitPlaintext(List<int> frame) =>
      _notifications.add(maskCbioFrame(frame, key: streamKey));

  /// Emits already-masked bytes, as one slice of a vended frame would arrive.
  void emitMasked(List<int> masked) => _notifications.add(masked);

  void dropLink() => _states.add(BleConnectionState.disconnected);

  @override
  Future<void> removeBond() async {}

  @override
  Future<void> disconnect() async {
    disconnected = true;
    await _states.close();
    await _notifications.close();
  }
}

final class _FakeTransport implements BleTransport {
  _FakeTransport(this.connection);

  final _FakeConnection connection;
  int connects = 0;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) async* {}

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connects += 1;
    return connection;
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this._onFire);

  final Duration duration;
  final void Function() _onFire;
  var _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _onFire();
  }

  /// Simulates a callback that was already queued when cancellation happened.
  void fireQueued() {
    _active = false;
    _onFire();
  }
}

Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.value();
  }
}

Future<void> _withManualReadySession(
  Future<void> Function(
    CbioGlucoseSession,
    _FakeConnection,
    List<_ManualTimer>,
    void Function(DateTime),
  )
  body, {
  CbioSessionTiming timing = _fastTiming,
}) async {
  final timers = <_ManualTimer>[];
  var now = DateTime.utc(2026, 9, 19);
  final connection = _FakeConnection();
  await _defaultResponder(connection);
  await runZoned(
    () async {
      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: timing,
        clock: () => now,
      );
      try {
        await session.initialize();
        await _drainMicrotasks();
        timers
            .singleWhere(
              (t) => t.isActive && t.duration == _fastTiming.historyIdleWindow,
            )
            .fire();
        await _drainMicrotasks();
        expect(session.currentSnapshot.stage, CgmSyncStage.ready);
        await body(session, connection, timers, (value) => now = value);
      } finally {
        await session.disconnect();
      }
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

void _fireTimer(List<_ManualTimer> timers, Duration duration) => timers
    .singleWhere((timer) => timer.isActive && timer.duration == duration)
    .fire();

/// Counts how many times a session resolves vendor material.
final class _CountingCredentialSource implements CbioCredentialSource {
  _CountingCredentialSource([this.credentials]);

  final CbioCredentials? credentials;
  int reads = 0;

  @override
  bool get isConfigured => credentials != null;

  @override
  CbioCredentials read() {
    reads += 1;
    final value = credentials;
    if (value == null) {
      throw const CbioCredentialUnavailable('set CBIO_VENDOR_STREAM_KEY_HEX');
    }
    return value;
  }
}

const DiscoveredSensor _sensor = DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'AA:BB:CC:DD:EE:FF',
  displayName: 'Cbio / SiSensing candidate',
  storageKey: 'AA:BB:CC:DD:EE:FF',
  rssi: -60,
  capabilities: CbioGlucoseSession.capabilities,
);

DiscoveredSensor _withMetadata(Map<String, String> metadata) =>
    DiscoveredSensor(
      driverId: _sensor.driverId,
      deviceId: _sensor.deviceId,
      displayName: _sensor.displayName,
      storageKey: _sensor.storageKey,
      rssi: _sensor.rssi,
      capabilities: _sensor.capabilities,
      metadata: metadata,
    );

/// Short windows so a session reaches its live phase inside one test.
const CbioSessionTiming _fastTiming = CbioSessionTiming(
  connectTimeout: Duration(milliseconds: 500),
  discoveryTimeout: Duration(milliseconds: 500),
  writeTimeout: Duration(milliseconds: 300),
  authTimeout: Duration(milliseconds: 200),
  historyWindow: Duration(milliseconds: 120),
  historyIdleWindow: Duration(milliseconds: 60),
  livePollInterval: Duration(milliseconds: 40),
  liveResponseWindow: Duration(milliseconds: 30),
  publishInterval: Duration.zero,
);

Future<void> _pumpUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('condition was not satisfied before the deadline');
}

/// Answers every session write the way the examined sensor does.
Future<void> _defaultResponder(
  _FakeConnection connection, {
  List<int> authReply = _authAccepted,
  List<List<int>> rawBatches = const <List<int>>[],
  List<int>? packedReply,
}) async {
  connection.onWrite = (plaintext) async {
    final opcode = plaintext.length > 1 ? plaintext[1] : -1;
    switch (opcode) {
      case 0x01:
        connection.emitPlaintext(authReply);
      case 0x0a:
        if (packedReply != null) {
          connection.emitPlaintext(packedReply);
        }
      case 0x08:
        for (final batch in rawBatches) {
          connection.emitPlaintext(batch);
        }
      default:
        break;
    }
  };
}

String _phaseOf(CgmSessionSnapshot snapshot) =>
    snapshot.metadata[cbioPhaseMetadataKey] ?? '';

void main() {
  test(
    'caller counter-failure reason never survives ready or later link loss',
    () async {
      const reasonKey = 'cgm.cbio.resume.counterFailureReason';
      final connection = _FakeConnection();
      await _defaultResponder(
        connection,
        rawBatches: [
          _rawBatch(
            startIndex: 1,
            baseEpochSeconds: 1000,
            baseReindex: 1,
            currents: [64],
          ),
        ],
      );
      final session = CbioGlucoseSession(
        sensor: _withMetadata({reasonKey: 'before-checkpoint'}),
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      expect(session.currentSnapshot.metadata[reasonKey], isNull);
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.ready,
      );
      expect(session.currentSnapshot.metadata[reasonKey], isNull);
      connection.dropLink();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.disconnected,
      );
      expect(session.currentSnapshot.metadata[reasonKey], isNull);
      await session.disconnect();
    },
  );
  group('CbioGlucoseSession lifecycle', () {
    test(
      'authenticates with the vendor frames and never writes anything else',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(
          connection,
          rawBatches: <List<int>>[
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1780000000,
              baseReindex: 1,
              currents: <int>[64],
            ),
          ],
        );

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(() => connection.writes.length >= 4);

        final plaintext = connection.writes.map(_unmaskWrite).toList();
        expect(plaintext, isNotEmpty);
        for (final frame in plaintext) {
          final key =
              '${frame[0].toRadixString(16).padLeft(2, '0')}'
              '${frame[1].toRadixString(16).padLeft(2, '0')}';
          expect(
            CbioGlucoseSession.allowedCommandKeys,
            contains(key),
            reason: 'the GS1 link must never write $key',
          );
        }
        expect(
          plaintext.where((frame) => frame[1] == 0x07),
          isEmpty,
          reason: 'activation must never be sent',
        );
        final auth = plaintext.firstWhere((frame) => frame[1] == 0x01);
        expect(auth.sublist(0, 3), <int>[0x19, 0x01, 0x00]);
        expect(auth.sublist(3, 9), _serialOctets);
        expect(auth.length, 26);
        expect(connection.serialReads, hasLength(1));
        expect(
          connection.serialReads.single.serviceUuid,
          '0000180a-0000-1000-8000-00805f9b34fb',
          reason: 'serial reads must use the discovered service UUID',
        );
        final clocks = plaintext.where((frame) => frame[1] == 0x03).toList();
        expect(clocks, hasLength(1));
        await session.disconnect();
      },
    );

    test(
      'falls back to the reversed advertised address when 2A25 is empty',
      () async {
        final connection = _FakeConnection(serial: <int>[]);
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => connection.writes.map(_unmaskWrite).any((f) => f[1] == 0x01),
        );

        final auth = connection.writes
            .map(_unmaskWrite)
            .firstWhere((frame) => frame[1] == 0x01);
        // With 2A25 empty the session falls back to the advertised identity,
        // reversed, exactly as the vendor link setup does.
        expect(auth.sublist(3, 9), <int>[0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa]);
        await session.disconnect();
      },
    );

    test(
      'uses the discovered serial on an opaque iOS device identifier',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);

        final session = CbioGlucoseSession(
          sensor: const DiscoveredSensor(
            driverId: 'cbio',
            deviceId: 'A4E7D0B1-4CB4-4A0A-9B6A-OPAQUE',
            displayName: 'Cbio / SiSensing candidate',
            storageKey: 'ios:opaque',
            rssi: -60,
            capabilities: CbioGlucoseSession.capabilities,
          ),
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => connection.writes
              .map(_unmaskWrite)
              .any((frame) => frame[1] == 0x01),
        );

        final auth = connection.writes
            .map(_unmaskWrite)
            .firstWhere((frame) => frame[1] == 0x01);
        expect(auth.sublist(3, 9), _serialOctets);
        expect(session.currentSnapshot.stage, isNot(CgmSyncStage.error));
        await session.disconnect();
      },
    );

    test('a rejected authentication stops before any read is sent', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection, authReply: _authRejected);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );

      final plaintext = connection.writes.map(_unmaskWrite).toList();
      expect(plaintext.map((frame) => frame[1]), <int>[0x01]);
      expect(session.currentSnapshot.lastError, 'cbio.auth.rejected');
      await _pumpUntil(() => connection.disconnected);
      await session.disconnect();
    });

    test('a refused credential is not worth an automatic retry', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection, authReply: _authRejected);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );

      expect(session.currentSnapshot.lastError, 'cbio.auth.rejected');
      expect(
        session
            .currentSnapshot
            .metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
        reason: 'the same credential would be refused byte for byte',
      );
      await session.disconnect();
    });

    test('an unanswered authentication times out without reads', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      connection.onWrite = (_) async {};

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );

      expect(
        connection.writes.map(_unmaskWrite).map((frame) => frame[1]),
        <int>[0x01],
      );
      expect(session.currentSnapshot.lastError, 'cbio.auth.timeout');
      await session.disconnect();
    });

    test('a link that never came up stays worth a retry', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      connection.onWrite = (_) async {};

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );

      expect(session.currentSnapshot.lastError, 'cbio.auth.timeout');
      expect(
        session.currentSnapshot.metadata,
        isNot(contains(cgmAutomaticReconnectAllowedMetadataKey)),
        reason: 'an unanswered link is a transient radio state',
      );
      await session.disconnect();
    });

    test(
      'a write the radio refuses fails the setup with its own code',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);
        connection.onWrite = (_) async {
          throw StateError('radio refused the frame');
        };

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => session.currentSnapshot.stage == CgmSyncStage.error,
        );

        expect(
          session.currentSnapshot.lastError,
          'cbio.write.failed',
          reason: 'a frame the sensor never received is its own failure',
        );
        expect(session.currentSnapshot.stage, CgmSyncStage.error);
        expect(
          session.currentSnapshot.metadata[cbioPhaseMetadataKey],
          CbioSessionPhase.failed,
        );
        await _pumpUntil(() => connection.disconnected);
        await session.disconnect();
      },
    );

    test('an unusable credential is never reported as a refused one', () async {
      final connection = _FakeConnection(serial: <int>[]);
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);

      final session = CbioGlucoseSession(
        sensor: DiscoveredSensor(
          driverId: 'cbio',
          deviceId: 'not-an-address',
          displayName: 'GS1 sensor',
          storageKey: 'cbio:test',
          rssi: -55,
          capabilities: CbioGlucoseSession.capabilities,
        ),
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );

      expect(session.currentSnapshot.lastError, 'cbio.auth.material');
      expect(
        session.currentSnapshot.lastError,
        isNot('cbio.auth.rejected'),
        reason: 'the link resolves its own credential before asking the sensor',
      );
      await session.disconnect();
    });

    test('never logs the link credential', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);
      final logs = <String>[];

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      final subscription = session.logs.listen(
        (entry) => logs.add(entry.message),
      );
      await session.initialize();
      await _pumpUntil(() => logs.isNotEmpty);
      await session.disconnect();
      await subscription.cancel();

      final credential = _syntheticCredentials.authMaterial
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      expect(logs, isNotEmpty);
      for (final message in logs) {
        expect(message.toLowerCase(), isNot(contains(credential)));
      }
    });
  });

  group('CbioGlucoseSession glucose', () {
    test(
      'ingests the raw stream into a provisional live reading and history',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        final now = DateTime.now().toUtc();
        final base = now.millisecondsSinceEpoch ~/ 1000 - 120;
        await _defaultResponder(
          connection,
          rawBatches: <List<int>>[
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: base,
              baseReindex: 3,
              currents: <int>[64, 80, 97],
            ),
          ],
        );

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => now,
        );
        await session.initialize();
        await _pumpUntil(
          () =>
              session.currentSnapshot.history.length == 3 &&
              session.currentSnapshot.stage == CgmSyncStage.ready,
        );

        final snapshot = session.currentSnapshot;
        final latest = snapshot.latestReading!;
        expect(snapshot.stage, CgmSyncStage.ready);
        expect(latest.source, CgmRecordSource.raw);
        expect(latest.isDisplayProvisional, isTrue);
        expect(latest.rawValue, 97);
        expect(latest.sensorMinute, 3);
        // The record carries the unverified /10 scale of its own raw field.
        // The archive publishes no glucose unit, so the session publishes the
        // same unit-free number the hero renders - not a converted mg/dL value.
        expect(latest.valueMgdl, 9.7);
        // These records stamp the clock this session wrote, so the index is
        // anchored to it and each position steps 60 s back from the newest.
        // The counter itself is never the source: the clock-anchor group below
        // holds the case where it does not agree with the app's clock.
        expect(
          snapshot.history.map((reading) => reading.recordedAt),
          <DateTime?>[
            for (final offset in <int>[0, 60, 120])
              DateTime.fromMillisecondsSinceEpoch(
                (base + offset) * 1000,
                isUtc: true,
              ),
          ],
        );
        expect(snapshot.history.map((r) => r.sensorMinute), <int>[1, 2, 3]);
        expect(snapshot.capabilities.supportsHistory, isTrue);
        await session.disconnect();
      },
    );

    test(
      'surfaces a restarted sensor counter instead of absorbing it',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        final now = DateTime.now().toUtc();
        final base = now.millisecondsSinceEpoch ~/ 1000 - 120;
        await _defaultResponder(
          connection,
          rawBatches: <List<int>>[
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: base,
              baseReindex: 3,
              currents: <int>[64, 80, 97],
            ),
            // The same three positions come back stamped from a counter a week
            // away: the sensor's numbering restarted, so these are different
            // records wearing indexes the archive already holds.
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: base - 604800,
              baseReindex: 3,
              currents: <int>[70, 88, 99],
            ),
          ],
        );

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => now,
        );
        final messages = <String>[];
        final subscription = session.logs.listen(
          (entry) => messages.add(entry.message),
        );
        await session.initialize();
        await _pumpUntil(() => session.currentSnapshot.history.length == 3);
        await _pumpUntil(
          () => messages.any((m) => m.contains('counter-restart')),
        );

        // The old numbering keeps its records: the new cycle is not spliced on
        // to it, and no position is silently renumbered.
        expect(
          session.currentSnapshot.history.map((r) => r.sensorMinute),
          <int>[1, 2, 3],
        );
        expect(session.currentSnapshot.history.map((r) => r.rawValue), <int>[
          64,
          80,
          97,
        ]);
        expect(
          messages.any((m) => m.contains('counter-restart')),
          isTrue,
          reason: 'a restart must be visible, not absorbed as a duplicate',
        );
        expect(session.currentSnapshot.stage, CgmSyncStage.error);
        expect(
          session.currentSnapshot.metadata['cgm.cbio.checkpoint'],
          isNotNull,
        );
        await subscription.cancel();
        await session.disconnect();
      },
    );

    test(
      'reports history progress until the archive reaches the live edge',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        final now = DateTime.now().toUtc();
        final base = now.millisecondsSinceEpoch ~/ 1000 - 3600;
        await _defaultResponder(
          connection,
          rawBatches: <List<int>>[
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: base,
              baseReindex: 2,
              currents: <int>[64, 70],
            ),
          ],
        );

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => now,
        );
        await session.initialize();
        await _pumpUntil(() => session.currentSnapshot.history.length == 2);

        final syncing = session.currentSnapshot;
        expect(syncing.historySync.storedCount, 2);
        expect(syncing.historySync.latestStoredOffset, 2);
        expect(syncing.historySync.startIndex, 1);
        expect(
          syncing.historySync.inProgress,
          isTrue,
          reason: 'stored history stops an hour short of the live edge',
        );
        expect(_phaseOf(syncing), CbioSessionPhase.history);
        await session.disconnect();
      },
    );

    test('a caught-up archive reports completed history', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      final now = DateTime.now().toUtc();
      final base = now.millisecondsSinceEpoch ~/ 1000 - 120;
      await _defaultResponder(
        connection,
        rawBatches: <List<int>>[
          _rawBatch(
            startIndex: 1,
            baseEpochSeconds: base,
            baseReindex: 3,
            currents: <int>[64, 70, 75],
          ),
        ],
      );

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(
        () =>
            session.currentSnapshot.stage == CgmSyncStage.ready &&
            session.currentSnapshot.historySync.inProgress == false,
      );

      final snapshot = session.currentSnapshot;
      expect(snapshot.stage, CgmSyncStage.ready);
      expect(_phaseOf(snapshot), CbioSessionPhase.live);
      expect(snapshot.historySync.storedCount, 3);
      expect(snapshot.historySync.totalAvailable, 3);
      expect(snapshot.historySync.lastSyncAt, isNotNull);
      expect(snapshot.statusText, contains('Live'));
      await session.disconnect();
    });

    test('keeps polling for new records after the live edge', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      final now = DateTime.now().toUtc();
      final base = now.millisecondsSinceEpoch ~/ 1000 - 60;
      await _defaultResponder(
        connection,
        rawBatches: <List<int>>[
          _rawBatch(
            startIndex: 1,
            baseEpochSeconds: base,
            baseReindex: 1,
            currents: <int>[64],
          ),
        ],
      );

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(() => session.currentSnapshot.history.length == 1);

      // The next raw read is requested at the index after the newest one.
      connection.onWrite = (plaintext) async {
        if (plaintext[1] == 0x01) {
          connection.emitPlaintext(_authAccepted);
          return;
        }
        if (plaintext[1] != 0x08) return;
        if (plaintext[2] != 2) return;
        connection.emitPlaintext(
          _rawBatch(
            startIndex: 2,
            baseEpochSeconds: base + 60,
            baseReindex: 2,
            currents: <int>[88],
          ),
        );
      };
      await _pumpUntil(() => session.currentSnapshot.history.length == 2);

      expect(session.currentSnapshot.latestReading!.rawValue, 88);
      expect(session.currentSnapshot.history.map((r) => r.sensorMinute), <int>[
        1,
        2,
      ]);
      await session.disconnect();
    });

    test(
      'ignores the zero packed path and undecodable notifications',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(
          connection,
          packedReply: _packedBatch(startIndex: 1, count: 4),
        );

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => connection.writes.map(_unmaskWrite).any((f) => f[1] == 0x0a),
        );
        connection.emitPlaintext(<int>[0x03, 0x99, 0x00]);
        connection.emitPlaintext(_packedBatch(startIndex: 1, count: 4));
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(session.currentSnapshot.history, isEmpty);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.stage, isNot(CgmSyncStage.error));
        await session.disconnect();
      },
    );

    test('reassembles a record batch split across notifications', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      final now = DateTime.now().toUtc();
      final frame = _rawBatch(
        startIndex: 1,
        baseEpochSeconds: now.millisecondsSinceEpoch ~/ 1000 - 60,
        baseReindex: 2,
        currents: <int>[64, 70],
      );
      final masked = maskCbioFrame(frame, key: _syntheticKey);
      await _defaultResponder(connection);
      connection.onWrite = (plaintext) async {
        if (plaintext[1] == 0x01) {
          connection.emitPlaintext(_authAccepted);
          return;
        }
        if (plaintext[1] == 0x08) {
          // One vended frame delivered as two consecutive notifications.
          connection.emitMasked(masked.sublist(0, 7));
          connection.emitMasked(masked.sublist(7));
        }
      };

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(() => session.currentSnapshot.history.length == 2);

      expect(session.currentSnapshot.latestReading!.rawValue, 70);
      await session.disconnect();
    });
  });

  group('CbioGlucoseSession fail-closed behaviour', () {
    test(
      'queued history timeout cannot resurrect a disconnected session',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);
        final timers = <_ManualTimer>[];

        await runZoned(
          () async {
            final session = CbioGlucoseSession(
              sensor: _sensor,
              transport: transport,
              credentials: _syntheticSource,
              timing: _fastTiming,
            );
            await session.initialize();
            for (var index = 0; index < 100; index++) {
              await Future<void>.value();
            }
            expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
            final historyTimers = timers
                .where((timer) => timer.isActive)
                .toList();
            expect(historyTimers, hasLength(2));

            connection.dropLink();
            for (var index = 0; index < 10; index++) {
              await Future<void>.value();
            }
            expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);

            for (final timer in historyTimers) {
              timer.fireQueued();
            }
            expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
            await session.disconnect();
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              final timer = _ManualTimer(duration, callback);
              timers.add(timer);
              return timer;
            },
          ),
        );
      },
    );

    // Omitting a terminal guard must not revive the session, publish another
    // snapshot, or arm a new poll when an already-queued callback arrives.
    for (final timerKind in ['history idle', 'history deadline', 'catch-up']) {
      for (final terminal in [
        'write failure',
        'transport drop',
        'explicit close',
      ]) {
        test('queued $timerKind is inert after $terminal', () async {
          final connection = _FakeConnection();
          final transport = _FakeTransport(connection);
          await _defaultResponder(connection);
          final timers = <_ManualTimer>[];
          final snapshots = <CgmSessionSnapshot>[];
          const timing = _fastTiming;

          Future<void> drainMicrotasks() async {
            for (var index = 0; index < 100; index++) {
              await Future<void>.value();
            }
          }

          await runZoned(
            () async {
              final session = CbioGlucoseSession(
                sensor: _sensor,
                transport: transport,
                credentials: _syntheticSource,
                timing: timing,
              );
              final subscription = session.snapshots.listen(snapshots.add);
              try {
                await session.initialize();
                await drainMicrotasks();
                expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
                final idle = timers.singleWhere(
                  (timer) =>
                      timer.isActive &&
                      timer.duration == timing.historyIdleWindow,
                );
                final deadline = timers.singleWhere(
                  (timer) =>
                      timer.isActive && timer.duration == timing.historyWindow,
                );
                if (timerKind == 'catch-up') {
                  idle.fire();
                  await drainMicrotasks();
                  expect(session.currentSnapshot.stage, CgmSyncStage.ready);
                }

                final failingWrite = Completer<void>();
                connection.onWrite = (_) async {
                  if (terminal == 'write failure') {
                    await failingWrite.future;
                  }
                };
                var settledCallers = 0;
                final first = session.syncHistory().then(
                  (_) => settledCallers++,
                );
                final second = session.syncHistory().then(
                  (_) => settledCallers++,
                );
                if (timerKind == 'catch-up') {
                  _fireTimer(timers, timing.livePollInterval);
                }
                await drainMicrotasks();
                expect(settledCallers, 0);
                final queuedTimer = switch (timerKind) {
                  'history idle' => idle,
                  'history deadline' => deadline,
                  _ => timers.singleWhere(
                    (timer) =>
                        timer.isActive &&
                        timer.duration == timing.catchUpWindow,
                  ),
                };
                expect(queuedTimer.isActive, isTrue);

                switch (terminal) {
                  case 'write failure':
                    failingWrite.completeError(
                      StateError('synthetic write failure'),
                    );
                  case 'transport drop':
                    connection.dropLink();
                  case 'explicit close':
                    await session.disconnect();
                }
                await drainMicrotasks();
                expect(
                  settledCallers,
                  2,
                  reason: 'active and queued callers settle',
                );
                await Future.wait([first, second]);
                final expectedStage = terminal == 'write failure'
                    ? CgmSyncStage.error
                    : CgmSyncStage.disconnected;
                expect(session.currentSnapshot.stage, expectedStage);
                expect(queuedTimer.isActive, isFalse);
                expect(timers.where((timer) => timer.isActive), isEmpty);
                final terminalError = session.currentSnapshot.lastError;
                final writesAtTerminal = connection.writes.length;
                final timersAtTerminal = timers.length;
                final snapshotsAtTerminal = snapshots.length;

                queuedTimer.fireQueued();
                await drainMicrotasks();

                expect(session.currentSnapshot.stage, expectedStage);
                expect(session.currentSnapshot.lastError, terminalError);
                expect(snapshots, hasLength(snapshotsAtTerminal));
                expect(connection.writes, hasLength(writesAtTerminal));
                expect(timers, hasLength(timersAtTerminal));
                expect(timers.where((timer) => timer.isActive), isEmpty);
              } finally {
                await session.disconnect();
                await subscription.cancel();
              }
            },
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
                final timer = _ManualTimer(duration, callback);
                timers.add(timer);
                return timer;
              },
            ),
          );
        });
      }
    }

    test(
      'initial history write failure is terminal and never becomes ready',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        connection.onWrite = (plaintext) async {
          if (plaintext[1] == 0x01) {
            connection.emitPlaintext(_authAccepted);
          } else if (plaintext[1] == 0x08) {
            throw StateError('history write failed');
          }
        };

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => session.currentSnapshot.stage == CgmSyncStage.error,
        );
        expect(session.currentSnapshot.lastError, CbioSessionFailure.write);
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(session.currentSnapshot.stage, CgmSyncStage.error);
        expect(connection.disconnected, isTrue);
        await session.disconnect();
      },
    );

    test('live write failure settles refresh and stays terminal', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.ready,
      );
      connection.onWrite = (_) async {
        throw StateError('live write failed');
      };

      await session.refreshLiveData();
      expect(session.currentSnapshot.lastError, CbioSessionFailure.write);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(connection.disconnected, isTrue);
      await session.disconnect();
    });

    test('topology failure releases an established GATT connection', () async {
      final connection = _FakeConnection(
        services: const <BleService>[
          BleService(
            uuid: CbioUuids.service,
            characteristics: <BleCharacteristicRef>[],
          ),
        ],
      );
      final transport = _FakeTransport(connection);
      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );

      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );
      expect(session.currentSnapshot.lastError, CbioSessionFailure.topology);
      await _pumpUntil(() => connection.disconnected);
      expect(connection.disconnected, isTrue);
      await session.disconnect();
    });

    test('disconnect settles an outstanding live read', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming.copyWith(
          liveResponseWindow: const Duration(seconds: 5),
        ),
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.ready,
      );
      connection.onWrite = (_) async {};
      final refresh = session.refreshLiveData();
      await _pumpUntil(() => connection.writes.length >= 4);
      await session.disconnect();
      await refresh;
      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
    });

    test('overlapping refreshes are coalesced and both settle', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.ready,
      );
      final before = connection.writes.length;
      final first = session.refreshLiveData();
      final second = session.refreshLiveData();
      await Future.wait(<Future<void>>[first, second]);
      expect(connection.writes.length, before + 1);
      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      await session.disconnect();
    });

    test('default paced polling continues beyond 1000 no-data ticks', () async {
      await _withManualReadySession((
        session,
        connection,
        timers,
        setClock,
      ) async {
        final initial = connection.writes.length;
        for (var tick = 0; tick < 1001; tick++) {
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          expect(
            connection.writes.length,
            initial + tick + 1,
            reason: 'production tick $tick must not exhaust a lifetime cap',
          );
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
        }
        expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      });
    });

    test(
      'manual bursts and wall-clock jumps cannot bypass polling pace',
      () async {
        await _withManualReadySession((
          session,
          connection,
          timers,
          setClock,
        ) async {
          final initial = connection.writes.length;
          var settled = 0;
          final callers = <Future<void>>[];
          for (var i = 0; i < 100; i++) {
            setClock(DateTime.utc(i.isEven ? 2036 : 2016));
            callers.add(session.refreshLiveData().then((_) => settled++));
          }
          await _drainMicrotasks();
          expect(connection.writes.length, initial);
          expect(settled, 0);
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          expect(connection.writes.length, initial + 1);
          for (var i = 0; i < 100; i++) {
            callers.add(session.refreshLiveData().then((_) => settled++));
          }
          await _drainMicrotasks();
          expect(connection.writes.length, initial + 1);
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
          expect(settled, 200);
          await Future.wait(callers);
          expect(connection.writes.length, initial + 1);
          expect(timers.where((t) => t.isActive), hasLength(1));
        });
      },
    );

    test('default polling ingests new records beyond 1000 ticks', () async {
      await _withManualReadySession((
        session,
        connection,
        timers,
        setClock,
      ) async {
        var next = 1;
        connection.onWrite = (frame) async {
          expect(frame[1], 0x08);
          expect(frame[2] | frame[3] << 8, next);
          connection.emitPlaintext(
            _rawBatch(
              startIndex: next,
              baseEpochSeconds: 100000 + next * 60,
              baseReindex: next,
              currents: [59],
            ),
          );
          next++;
        };
        for (var tick = 0; tick < 1001; tick++) {
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
          expect(session.currentSnapshot.history.length, tick + 1);
          expect(session.currentSnapshot.lastError, isNull);
        }
      });
    });

    test(
      'coalesced catch-up preserves earliest cursor and defers live cursor',
      () async {
        await _withManualReadySession((
          session,
          connection,
          timers,
          setClock,
        ) async {
          final callers = [
            session.syncHistory(requestedStartOffset: 20),
            session.syncHistory(requestedStartOffset: 5),
            session.syncHistory(requestedStartOffset: 12),
          ];
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          expect(_unmaskWrite(connection.writes.last)[2], 5);
          final earlier = session.syncHistory(requestedStartOffset: 2);
          final earliest = session.syncHistory(requestedStartOffset: 1);
          final current = session.refreshLiveData();
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
          await Future.wait([...callers, current]);
          final before = connection.writes.length;
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          expect(connection.writes.length, before + 1);
          expect(_unmaskWrite(connection.writes.last)[2], 1);
          connection.emitPlaintext(
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 100000,
              baseReindex: 1,
              currents: [59, 60, 61],
            ),
          );
          await _drainMicrotasks();
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
          await Future.wait([earlier, earliest]);
          final deferred = session.refreshLiveData();
          connection.emitPlaintext(
            _rawBatch(
              startIndex: 4,
              baseEpochSeconds: 100180,
              baseReindex: 4,
              currents: [62],
            ),
          );
          await _drainMicrotasks();
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          expect(_unmaskWrite(connection.writes.last)[2], 5);
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
          await deferred;
        });
      },
    );

    for (final terminal in ['disconnect', 'drop', 'counter restart']) {
      for (final lateError in [false, true]) {
        test(
          'late write (error=$lateError) cannot revive $terminal or strand coalesced callers',
          () async {
            await _withManualReadySession((
              session,
              connection,
              timers,
              setClock,
            ) async {
              connection.emitPlaintext(
                _rawBatch(
                  startIndex: 1,
                  baseEpochSeconds: 100000,
                  baseReindex: 1,
                  currents: [59],
                ),
              );
              await _drainMicrotasks();
              final write = Completer<void>();
              connection.onWrite = (_) => write.future;
              var settled = 0;
              final first = session.refreshLiveData().then((_) => settled++);
              _fireTimer(timers, _fastTiming.livePollInterval);
              await _drainMicrotasks();
              final second = session
                  .syncHistory(requestedStartOffset: 1)
                  .then((_) => settled++);
              switch (terminal) {
                case 'disconnect':
                  await session.disconnect();
                case 'drop':
                  connection.dropLink();
                case 'counter restart':
                  connection.emitPlaintext(
                    _rawBatch(
                      startIndex: 1,
                      baseEpochSeconds: 200000,
                      baseReindex: 1,
                      currents: [60],
                    ),
                  );
              }
              await _drainMicrotasks();
              expect(settled, 2);
              await Future.wait([first, second]);
              final writes = connection.writes.length;
              final count = timers.length;
              final errorAtTerminal = session.currentSnapshot.lastError;
              if (lateError) {
                write.completeError(StateError('late transport error'));
              } else {
                write.complete();
              }
              await _drainMicrotasks();
              expect(connection.writes.length, writes);
              expect(timers.length, count);
              expect(timers.where((t) => t.isActive), isEmpty);
              expect(session.currentSnapshot.lastError, errorAtTerminal);
              expect(
                session.currentSnapshot.stage,
                terminal == 'counter restart'
                    ? CgmSyncStage.error
                    : CgmSyncStage.disconnected,
              );
            });
          },
        );
      }
    }

    test(
      'opt-in bench cap pauses without failure and settles refresh callers',
      () async {
        await _withManualReadySession((
          session,
          connection,
          timers,
          setClock,
        ) async {
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          _fireTimer(timers, _fastTiming.liveResponseWindow);
          await _drainMicrotasks();
          final writes = connection.writes.length;
          var settled = 0;
          final first = session.refreshLiveData().then((_) => settled++);
          final second = session
              .syncHistory(requestedStartOffset: 1)
              .then((_) => settled++);
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          expect(settled, 2);
          await Future.wait([first, second]);
          expect(connection.writes.length, writes);
          expect(session.currentSnapshot.stage, CgmSyncStage.ready);
          expect(session.currentSnapshot.lastError, isNull);
          expect(session.currentSnapshot.statusText, contains('paused'));
          expect(timers.where((t) => t.isActive), isEmpty);
          await session.refreshLiveData();
          expect(connection.writes.length, writes);
        }, timing: _fastTiming.copyWith(maxReadsPerSession: 3));
      },
    );

    for (final terminal in ['disconnect', 'drop']) {
      test('queued cooldown is inert after $terminal', () async {
        await _withManualReadySession((
          session,
          connection,
          timers,
          setClock,
        ) async {
          final cooldown = timers.singleWhere(
            (t) => t.isActive && t.duration == _fastTiming.livePollInterval,
          );
          var settled = false;
          final pending = session.refreshLiveData().then((_) => settled = true);
          if (terminal == 'disconnect') {
            await session.disconnect();
          } else {
            connection.dropLink();
          }
          await _drainMicrotasks();
          expect(settled, isTrue);
          await pending;
          final count = timers.length;
          final writes = connection.writes.length;
          cooldown.fireQueued();
          await _drainMicrotasks();
          expect(timers.length, count);
          expect(connection.writes.length, writes);
          expect(timers.where((t) => t.isActive), isEmpty);
        });
      });
    }

    test(
      'invalid catch-up cursor rejects its caller without an unhandled task',
      () async {
        await _withManualReadySession((
          session,
          connection,
          timers,
          setClock,
        ) async {
          final before = connection.writes.length;
          final result = expectLater(
            session.syncHistory(requestedStartOffset: -1),
            throwsArgumentError,
          );
          _fireTimer(timers, _fastTiming.livePollInterval);
          await _drainMicrotasks();
          await result;
          expect(connection.writes.length, before);
        });
      },
    );

    test('stops reading once the read budget is spent', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming.copyWith(maxReadsPerSession: 1),
      );
      await session.initialize();
      await _pumpUntil(() => connection.writes.length >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(connection.writes, hasLength(3));
      expect(
        connection.writes.map(_unmaskWrite).map((frame) => frame[1]),
        isNot(contains(0x08)),
        reason: 'an exhausted read budget blocks the raw history read',
      );
      expect(session.currentSnapshot.stage, isNot(CgmSyncStage.error));
      expect(session.currentSnapshot.statusText, contains('paused'));
      await session.disconnect();
    });

    test(
      'a dropped link reports a disconnected stage without more writes',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(() => connection.writes.isNotEmpty);
        final writesBeforeDrop = connection.writes.length;
        connection.dropLink();
        await _pumpUntil(
          () => session.currentSnapshot.stage == CgmSyncStage.disconnected,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(connection.writes, hasLength(writesBeforeDrop));
        expect(session.currentSnapshot.lastError, 'cbio.disconnected');
        await session.disconnect();
      },
    );

    test('disconnect releases the link and closes both streams', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(() => connection.writes.isNotEmpty);
      await session.disconnect();
      await session.disconnect();

      expect(connection.disconnected, isTrue);
      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
      await expectLater(session.snapshots, emitsDone);
      await expectLater(session.logs, emitsDone);
    });
  });

  group('CbioGlucoseSession resume', () {
    test('counter rollback below resumed window is not merged', () async {
      final connection = _FakeConnection();
      await _defaultResponder(
        connection,
        rawBatches: [
          _rawBatch(
            startIndex: 100,
            baseEpochSeconds: 7000,
            baseReindex: 100,
            currents: [60],
          ),
        ],
      );
      final session = CbioGlucoseSession(
        sensor: _withMetadata({
          cbioCheckpointMetadataKey: jsonEncode({
            'version': 1,
            'sensorKey': _sensor.storageKey,
            'index': 100,
            'rawTime': 7000,
          }),
        }),
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(() => session.currentSnapshot.history.length == 1);
      connection.emitPlaintext(
        _rawBatch(
          startIndex: 1,
          baseEpochSeconds: 9000,
          baseReindex: 1,
          currents: [99],
        ),
      );
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );
      expect(session.currentSnapshot.history.map((r) => r.sensorMinute), [100]);
      expect(session.currentSnapshot.lastError, 'cbio.counter.restart');
      await session.disconnect();
    });

    test('does not checkpoint beyond an unfilled history gap', () async {
      final connection = _FakeConnection();
      await _defaultResponder(
        connection,
        rawBatches: [
          _rawBatch(
            startIndex: 1,
            baseEpochSeconds: 1000,
            baseReindex: 2,
            currents: [60, 61],
          ),
          _rawBatch(
            startIndex: 10,
            baseEpochSeconds: 1540,
            baseReindex: 10,
            currents: [99],
          ),
        ],
      );
      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(() => session.currentSnapshot.history.length == 3);
      final checkpoint = CbioSessionCheckpoint.decode(
        session.currentSnapshot.metadata[cbioCheckpointMetadataKey]!,
        _sensor.storageKey,
      );
      expect(checkpoint!.index, 2);
      await session.disconnect();
    });

    test('an initial suffix cannot establish a complete checkpoint', () async {
      final connection = _FakeConnection();
      await _defaultResponder(
        connection,
        rawBatches: [
          _rawBatch(
            startIndex: 10,
            baseEpochSeconds: 1540,
            baseReindex: 10,
            currents: [99],
          ),
        ],
      );
      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(() => session.currentSnapshot.history.isNotEmpty);
      expect(
        session.currentSnapshot.metadata[cbioCheckpointMetadataKey],
        isNull,
      );
      await session.disconnect();
    });

    test(
      'does not skip history on an unverified legacy resume offset',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);

        final session = CbioGlucoseSession(
          sensor: const DiscoveredSensor(
            driverId: 'cbio',
            deviceId: 'AA:BB:CC:DD:EE:FF',
            displayName: 'Cbio / SiSensing candidate',
            storageKey: 'AA:BB:CC:DD:EE:FF',
            rssi: -60,
            capabilities: CbioGlucoseSession.capabilities,
            metadata: <String, String>{'resumeOffset': '9981'},
          ),
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => connection.writes.map(_unmaskWrite).any((f) => f[1] == 0x08),
        );

        final raw = connection.writes
            .map(_unmaskWrite)
            .firstWhere((frame) => frame[1] == 0x08);
        expect(raw[2] | (raw[3] << 8), 1);
        await session.disconnect();
      },
    );

    test(
      'round-tripped checkpoint rechecks witness and retains old time',
      () async {
        final then = DateTime.utc(2026, 1, 1);
        final epoch = then.millisecondsSinceEpoch ~/ 1000;
        final firstConnection = _FakeConnection();
        await _defaultResponder(
          firstConnection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: epoch - 60,
              baseReindex: 2,
              currents: [60, 61],
            ),
          ],
        );
        final first = CbioGlucoseSession(
          sensor: _sensor,
          transport: _FakeTransport(firstConnection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => then,
        );
        await first.initialize();
        await _pumpUntil(() => first.currentSnapshot.history.length == 2);
        final metadata = Map<String, String>.from(
          jsonDecode(jsonEncode(first.currentSnapshot.metadata)) as Map,
        );
        expect(metadata['cgm.cbio.checkpoint'], isNotNull);
        await first.disconnect();
        expect(
          first.currentSnapshot.metadata[cbioCheckpointMetadataKey],
          metadata[cbioCheckpointMetadataKey],
        );

        final connection = _FakeConnection();
        await _defaultResponder(
          connection,
          rawBatches: [
            _rawBatch(
              startIndex: 2,
              baseEpochSeconds: epoch,
              baseReindex: 2,
              currents: [61, 62],
            ),
          ],
        );
        final restored = CbioGlucoseSession(
          sensor: _withMetadata(metadata),
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => then.add(const Duration(hours: 1)),
        );
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.resume.status'],
          'pending',
        );
        expect(
          restored
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          isNull,
        );
        await restored.initialize();
        await _pumpUntil(() => restored.currentSnapshot.history.isNotEmpty);
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.resume.status'],
          'confirmed',
        );
        expect(
          restored
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          metadata[cbioCheckpointMetadataKey],
        );
        final query = connection.writes
            .map(_unmaskWrite)
            .firstWhere((frame) => frame[1] == 0x08);
        expect(query[2] | (query[3] << 8), 2);
        expect(restored.currentSnapshot.history.first.recordedAt, then);
        expect(
          restored.currentSnapshot.history.last.recordedAt,
          then.add(const Duration(minutes: 1)),
        );
        final next = CbioSessionCheckpoint.decode(
          restored.currentSnapshot.metadata[cbioCheckpointMetadataKey]!,
          _sensor.storageKey,
        );
        expect(next?.anchor?.anchorEpochSeconds, epoch);
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.lifecycle'],
          'unknown',
        );
        final advancedCheckpoint =
            restored.currentSnapshot.metadata[cbioCheckpointMetadataKey];
        await restored.disconnect();
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.resume.status'],
          'confirmed',
        );
        expect(
          restored
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          metadata[cbioCheckpointMetadataKey],
        );
        expect(
          restored.currentSnapshot.metadata[cbioCheckpointMetadataKey],
          advancedCheckpoint,
        );
      },
    );

    for (final raw in ['{', '{}', '{"version":99}']) {
      test('malformed checkpoint fails before radio: $raw', () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        final session = CbioGlucoseSession(
          sensor: _withMetadata({'cgm.cbio.checkpoint': raw}),
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        expect(session.currentSnapshot.lastError, 'cbio.resume.invalid');
        expect(transport.connects, 0);
        await session.disconnect();
      });
    }

    test(
      'unreconciled restored metadata never exposes a clock anchor',
      () async {
        final connection = _FakeConnection();
        await _defaultResponder(connection);
        final session = CbioGlucoseSession(
          sensor: _withMetadata({
            cbioCheckpointMetadataKey: jsonEncode({
              'version': 1,
              'sensorKey': _sensor.storageKey,
              'index': 2,
              'rawTime': 1000,
            }),
            cbioAnchorIndexMetadataKey: '2',
            cbioAnchorEpochMetadataKey: '1000',
          }),
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        expect(
          CbioIndexTimeAnchor.fromMetadata(session.currentSnapshot.metadata),
          isNull,
        );
        await session.disconnect();
        expect(
          CbioIndexTimeAnchor.fromMetadata(session.currentSnapshot.metadata),
          isNull,
        );
      },
    );

    for (final batchKind in ['missing', 'conflicting', 'suffix-only']) {
      test('$batchKind witness never publishes a new era', () async {
        final connection = _FakeConnection();
        final frames = batchKind == 'missing'
            ? <List<int>>[]
            : [
                _rawBatch(
                  startIndex: batchKind == 'suffix-only' ? 3 : 2,
                  baseEpochSeconds: 9000,
                  baseReindex: 2,
                  currents: [99],
                ),
              ];
        await _defaultResponder(connection, rawBatches: frames);
        final checkpoint = jsonEncode({
          'version': 1,
          'sensorKey': _sensor.storageKey,
          'index': 2,
          'rawTime': 1000,
        });
        final session = CbioGlucoseSession(
          sensor: _withMetadata({
            cbioCheckpointMetadataKey: checkpoint,
            cbioAnchorIndexMetadataKey: '2',
            cbioAnchorEpochMetadataKey: '1000',
          }),
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming,
        );
        await session.initialize();
        await _pumpUntil(
          () => session.currentSnapshot.stage == CgmSyncStage.error,
        );
        expect(session.currentSnapshot.history, isEmpty);
        expect(
          session.currentSnapshot.metadata['cgm.cbio.resume.status'],
          'failed',
        );
        expect(
          session
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          isNull,
        );
        expect(
          session.currentSnapshot.metadata['cgm.cbio.checkpoint'],
          checkpoint,
        );
        expect(
          session
              .currentSnapshot
              .metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
        final writes = connection.writes.length;
        await session.refreshLiveData();
        await session.syncHistory();
        expect(connection.writes.length, writes);
        await session.disconnect();
        expect(
          session.currentSnapshot.metadata[cbioCheckpointMetadataKey],
          checkpoint,
        );
        expect(
          CbioIndexTimeAnchor.fromMetadata(session.currentSnapshot.metadata),
          isNull,
        );
        expect(
          session
              .currentSnapshot
              .metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
      });
    }
  });

  group('CbioGlucoseSession provisional scale', () {
    test('the app and the capture harness share one raw field and one scale', () {
      // Replayed 08 batch: the sample the capture harness read out of the
      // sensor was raw 47..53 at index 9940..9992. Those counters live in the
      // same record field the session publishes as `rawValue`, so the app and
      // the harness already agree byte for byte. Only the unit label differed:
      // the app multiplied the unverified /10 scale by 18.0182 and called the
      // result mg/dL, which no reference measurement supports.
      final frame = _rawBatch(
        startIndex: 9940,
        baseEpochSeconds: 596400,
        baseReindex: 9940,
        currents: <int>[47, 50, 53],
      );

      final batch = parseCbioRawDataFrame(frame);

      expect(batch.records.map((record) => record.processed.index), <int>[
        9940,
        9941,
        9942,
      ]);
      expect(batch.records.map((record) => record.rawPayload), <int>[
        47,
        50,
        53,
      ]);
      final archived = <CbioRawGlucoseRecord>[
        for (final record in batch.records)
          CbioRawGlucoseRecord(
            index: record.processed.index,
            rawTime: record.processed.rawTime,
            reindex: record.processed.reindex,
            rawTemperature: record.rawTemperature,
            rawDump: record.rawDump,
            rawPayload: record.rawPayload,
            rawProcessed: record.processed.rawWord,
          ),
      ];

      for (final record in archived) {
        // The one scale both paths use, stated without a glucose unit.
        expect(record.rawPayloadScaled, record.rawPayload / 10);
        expect(record.isUnitVerified, isFalse);
      }
      expect(archived.first.rawPayloadScaled, 4.7);
      expect(archived.last.rawPayloadScaled, 5.3);
      // No unit-bearing derivation is left to publish: the record exposes the
      // raw field and its /10 scale, and the glucose unit stays unclaimed until
      // a reference measurement settles it.
    });
  });

  group('CbioGlucoseSession vendor material', () {
    test('resolves the material once per session', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      await _defaultResponder(connection);
      final source = _CountingCredentialSource(_syntheticCredentials);

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: source,
        timing: _fastTiming,
      );
      // `initialize` is idempotent, so a second call must not re-read either.
      await session.initialize();
      await session.initialize();
      await session.disconnect();

      expect(source.reads, 1);
      expect(transport.connects, 1);
    });

    test('fails closed before the radio when the build carries none', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      final source = _CountingCredentialSource();

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: source,
        timing: _fastTiming,
      );
      await session.initialize();

      // Nothing was connected, subscribed, or written: a build without vendor
      // material cannot authenticate or unmask, so it never opens the link.
      expect(transport.connects, 0);
      expect(connection.writes, isEmpty);
      expect(connection.notifySubscribed, isFalse);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(
        session.currentSnapshot.lastError,
        CbioSessionFailure.authMaterial,
      );
      expect(session.currentSnapshot.statusText, contains('vendor material'));
      await session.disconnect();
    });
  });

  group('CbioGlucoseSession clock anchor', () {
    test('stamps stored history once the sensor took the clock', () async {
      final connection = _FakeConnection();
      final transport = _FakeTransport(connection);
      final now = DateTime.now().toUtc();
      final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
      final base = nowSeconds - 120;
      await _defaultResponder(
        connection,
        rawBatches: <List<int>>[
          _rawBatch(
            startIndex: 1,
            baseEpochSeconds: base,
            baseReindex: 3,
            currents: <int>[64, 70, 75],
          ),
        ],
      );

      final session = CbioGlucoseSession(
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(() => session.currentSnapshot.history.length == 3);

      final snapshot = session.currentSnapshot;
      final anchor = CbioIndexTimeAnchor.fromMetadata(snapshot.metadata);
      expect(anchor, isNotNull);
      expect(anchor!.anchorIndex, 3);
      expect(anchor.coveredFromIndex, 1);
      expect(anchor.anchorEpochSeconds, nowSeconds);
      expect(
        anchor.clockReferenceEpochSeconds,
        nowSeconds,
        reason: 'the reference is the epoch this session wrote to the sensor',
      );
      expect(anchor.clockAgreement, Duration.zero);
      expect(
        snapshot.history.map((reading) => reading.recordedAt),
        <DateTime?>[
          for (final offset in <int>[-120, -60, 0])
            DateTime.fromMillisecondsSinceEpoch(
              (nowSeconds + offset) * 1000,
              isUtc: true,
            ),
        ],
        reason:
            'positions step 60 s from the anchored record, not from the '
            'counter',
      );
      expect(
        await session.refreshDiagnostics().then(
          (items) => items.single.fields['clockAnchor'],
        ),
        contains('index 3'),
      );
      await session.disconnect();
    });

    test(
      'publishes no timestamp while the sensor clock is the counter',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        final now = DateTime.now().toUtc();
        final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
        // The #146 capture: the newest stored record is 448 positions, 7 h 28 m,
        // away from the clock the app set.
        final base = nowSeconds - 448 * 60;
        await _defaultResponder(
          connection,
          rawBatches: <List<int>>[
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: base,
              baseReindex: 3,
              currents: <int>[64, 70, 75],
            ),
          ],
        );

        final session = CbioGlucoseSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => now,
        );
        await session.initialize();
        await _pumpUntil(() => session.currentSnapshot.history.length == 3);

        final snapshot = session.currentSnapshot;
        expect(CbioIndexTimeAnchor.fromMetadata(snapshot.metadata), isNull);
        expect(
          snapshot.history.every((reading) => reading.recordedAt == null),
          isTrue,
          reason: 'the counter is a position, never a clock',
        );
        expect(
          await session.refreshDiagnostics().then(
            (items) => items.single.fields['clockAnchor'],
          ),
          contains('unsynced'),
        );
        await session.disconnect();
      },
    );
  });
}
