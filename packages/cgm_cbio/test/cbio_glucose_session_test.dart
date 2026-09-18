import 'dart:async';

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
        expect(
          auth.sublist(3, 9),
          <int>[0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa],
        );
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
        // The archived record exposes the rounded mg/dL derivation of the
        // unverified mmol/L scale, never the raw field as a measurement.
        expect(latest.valueMgdl, 175);
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
    test('resumes the raw read after the persisted offset', () async {
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
      expect(raw[2] | (raw[3] << 8), 9982);
      await session.disconnect();
    });
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

      expect(
        batch.records.map((record) => record.packed.index),
        <int>[9940, 9941, 9942],
      );
      expect(batch.records.map((record) => record.rawCurrent), <int>[47, 50, 53]);
      final archived = <CbioRawGlucoseRecord>[
        for (final record in batch.records)
          CbioRawGlucoseRecord(
            index: record.packed.index,
            rawTime: record.packed.rawTime,
            reindex: record.packed.reindex,
            rawTemperature: record.rawTemperature,
            rawDump: record.rawDump,
            rawCurrent: record.rawCurrent,
            rawExtra: 0,
          ),
      ];

      for (final record in archived) {
        // The one scale both paths use, stated without a glucose unit.
        expect(record.derivedMillimolesPerLitre, record.rawCurrent / 10);
        expect(record.isUnitVerified, isFalse);
      }
      expect(archived.first.derivedMillimolesPerLitre, 4.7);
      expect(archived.last.derivedMillimolesPerLitre, 5.3);
      // The mg/dL derivation stays available for the chart's internal scale,
      // but it is a conversion of an unverified unit, never a measurement.
      expect(archived.first.derivedMilligramsPerDecilitre, 85);
      expect(archived.last.derivedMilligramsPerDecilitre, 95);
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
