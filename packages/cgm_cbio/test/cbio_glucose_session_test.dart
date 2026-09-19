import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_cbio/src/cbio_history_state.dart';
import 'package:cgm_cbio/src/cbio_full_record_state.dart';
import 'package:cgm_cbio/src/cbio_private_state_owner.dart';
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
    this.failDisconnect = false,
    this.failNotificationCancel = false,
    List<BleService>? services,
    List<int>? streamKey,
  }) : services = services ?? _defaultServices,
       streamKey = streamKey ?? _syntheticKey {
    _notifications = failNotificationCancel
        ? StreamController<List<int>>(
            onCancel: () async {
              notificationCancelCalls++;
              throw StateError('synthetic native cancellation detail');
            },
          )
        : StreamController<List<int>>.broadcast();
  }

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
  final bool failDisconnect;
  final bool failNotificationCancel;
  final StreamController<BleConnectionState> _states =
      StreamController<BleConnectionState>.broadcast();
  late final StreamController<List<int>> _notifications;
  final List<List<int>> writes = <List<int>>[];
  final List<BleCharacteristicRef> serialReads = <BleCharacteristicRef>[];

  /// Invoked with each plaintext command the session writes.
  Future<void> Function(List<int> plaintext)? onWrite;
  bool notifySubscribed = false;
  bool disconnected = false;
  int mtuRequests = 0;
  int disconnectCalls = 0;
  int notificationCancelCalls = 0;

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
    disconnectCalls++;
    disconnected = true;
    await _states.close();
    await _notifications.close();
    if (failDisconnect) throw StateError('synthetic native disconnect detail');
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
  _FakeConnection? connection,
  CbioPrivateStateStore? privateStateStore,
}) async {
  final timers = <_ManualTimer>[];
  var now = DateTime.utc(2026, 9, 19);
  final activeConnection = connection ?? _FakeConnection();
  await _defaultResponder(activeConnection);
  await runZoned(
    () async {
      final session = await _privateSession(
        sensor: _sensor,
        transport: _FakeTransport(activeConnection),
        credentials: _syntheticSource,
        timing: timing,
        clock: () => now,
        privateStateStore: privateStateStore,
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
        await body(session, activeConnection, timers, (value) => now = value);
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

Future<void> _pumpUntil(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
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

final _owners = Expando<CbioPrivateStateOwner>();

Future<CbioGlucoseSession> _privateSession({
  required DiscoveredSensor sensor,
  required BleTransport transport,
  CbioCredentialSource credentials = const CbioDefineCredentialSource(),
  CbioSessionTiming timing = const CbioSessionTiming(),
  DateTime Function() clock = DateTime.now,
  CbioPrivateStateStore? privateStateStore,
}) async {
  final store = privateStateStore ?? _PrivateStore();
  final encoded = sensor.metadata[cbioCheckpointMetadataKey];
  if (privateStateStore == null && encoded != null) {
    final checkpoint = CbioSessionCheckpoint.decode(encoded, sensor.storageKey);
    if (checkpoint == null) {
      return CbioGlucoseSession(
        sensor: sensor,
        transport: transport,
        credentials: credentials,
        timing: timing,
        clock: clock,
      );
    }
    await store.write(
      sensor.storageKey,
      CbioHistoryState(
        sensorKey: sensor.storageKey,
        checkpoint: encoded,
        history: [
          CgmReading(
            valueMgdl: 6,
            rawValue: 60,
            source: CgmRecordSource.raw,
            sensorMinute: checkpoint.index,
            isDisplayProvisional: true,
          ),
        ],
      ).encode(),
    );
  }
  final owner = await CbioPrivateStateOwner.load(sensor.storageKey, store);
  final session = CbioGlucoseSession(
    sensor: sensor,
    transport: transport,
    credentials: credentials,
    timing: timing,
    clock: clock,
    privateState: owner,
  );
  _owners[session] = owner;
  session.logs.listen((entry) {
    if (entry.message.startsWith('cbio.raw.records') ||
        entry.message.startsWith('cbio.raw.counter-restart') ||
        entry.message.startsWith('cbio.clock.anchor')) {
      expect(
        entry.message,
        anyOf(
          'cbio.raw.records',
          'cbio.raw.counter-restart',
          'cbio.clock.anchor',
        ),
      );
    }
  });
  return session;
}

Future<int> _rawCount(CbioGlucoseSession session) async =>
    _owners[session]!.acquisitionArchive.length;
String? _privateCheckpoint(CbioGlucoseSession session) =>
    _owners[session]?.state?.checkpoint;

String _phaseOf(CgmSessionSnapshot snapshot) =>
    snapshot.metadata[cbioPhaseMetadataKey] ?? '';

final class _FullStore implements CbioFullRecordStore {
  String? legacy;
  String? expectedLegacy;
  String? full;
  int legacyWrites = 0;
  int writes = 0;
  bool failFull = false;
  Completer<void>? hold;
  Completer<void>? started;
  @override
  Future<String?> read(String sensorKey) async => legacy;
  @override
  Future<void> write(String sensorKey, String envelope) async {
    legacyWrites++;
    legacy = envelope;
  }

  @override
  Future<String?> readFullRecords(String sensorKey) async => full;
  @override
  Future<void> writeFullRecords(String sensorKey, String envelope) async {
    writes++;
    if (started?.isCompleted == false) started!.complete();
    await hold?.future;
    if (failFull) throw StateError('private-store-path');
    full = envelope;
  }

  @override
  String legacySha256(String legacyEnvelope) {
    if (legacyEnvelope == expectedLegacy) return 'a' * 64;
    throw StateError('Unexpected legacy fixture');
  }
}

CbioFullRecordState _fullSaved(_FullStore store) =>
    CbioFullRecordState.decode(store.full!, sensorKey: _sensor.storageKey);

final class _PrivateStore implements CbioPrivateStateStore {
  String? envelope;
  bool failWrite = false;
  @override
  Future<String?> read(String sensorKey) async => envelope;
  @override
  Future<void> write(String sensorKey, String value) async {
    if (failWrite) throw StateError('synthetic private write failure');
    envelope = value;
  }
}

Future<List<CgmReading>> _storedHistory(
  CbioGlucoseSession session,
  _PrivateStore store,
) async {
  await session.flushPrivateState();
  return CbioHistoryState.decode(
    store.envelope!,
    sensorKey: session.sensor.storageKey,
  ).history;
}

void main() {
  group('private failure trace', () {
    const enabled = bool.fromEnvironment('CBIO_FAILURE_TRACE');
    for (final scenario in ['success', 'auth', 'write', 'witness']) {
      test('$scenario emits only an opted-in closed failure', () async {
        final output = <String>[];
        await runZoned(
          () async {
            final connection = _FakeConnection();
            await _defaultResponder(
              connection,
              authReply: scenario == 'auth' ? _authRejected : _authAccepted,
              rawBatches: scenario == 'witness'
                  ? [
                      _rawBatch(
                        startIndex: 2,
                        baseEpochSeconds: 9000,
                        baseReindex: 2,
                        currents: [99],
                      ),
                    ]
                  : [],
            );
            if (scenario == 'write') {
              connection.onWrite = (_) async {
                throw StateError(
                  'private-native-detail ${_sensor.deviceId} '
                  '${_syntheticCredentials.authMaterial}',
                );
              };
            }
            final session = await _privateSession(
              sensor: scenario == 'witness'
                  ? _withMetadata({
                      cbioCheckpointMetadataKey: jsonEncode({
                        'version': 1,
                        'sensorKey': _sensor.storageKey,
                        'index': 2,
                        'rawTime': 1000,
                      }),
                    })
                  : _sensor,
              transport: _FakeTransport(connection),
              credentials: _syntheticSource,
              timing: _fastTiming,
            );
            await session.initialize();
            await _pumpUntil(
              () =>
                  session.currentSnapshot.stage ==
                  (scenario == 'success'
                      ? CgmSyncStage.ready
                      : CgmSyncStage.error),
            );
            if (scenario != 'success') {
              await _pumpUntil(() => connection.disconnected);
              await session.refreshLiveData();
              await session.syncHistory();
            }
            await session.disconnect();
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => output.add(line),
          ),
        );
        final expected = switch (scenario) {
          'auth' => 'CBIO failure=cbio.auth.rejected',
          'write' => 'CBIO failure=cbio.write.failed',
          'witness' =>
            'CBIO failure=cbio.counter.restart '
                'counterFailureReason=witness-time-mismatch',
          _ => null,
        };
        expect(output, enabled && expected != null ? [expected] : isEmpty);
      });
    }

    test('a throwing trace sink cannot prevent terminal cleanup', () async {
      await runZoned(
        () async {
          final connection = _FakeConnection();
          await _defaultResponder(connection, authReply: _authRejected);
          final session = await _privateSession(
            sensor: _sensor,
            transport: _FakeTransport(connection),
            credentials: _syntheticSource,
            timing: _fastTiming,
          );
          await session.initialize();
          await _pumpUntil(() => connection.disconnected);
          expect(session.currentSnapshot.lastError, 'cbio.auth.rejected');
          expect(session.currentSnapshot.stage, CgmSyncStage.error);
          await session.disconnect();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => throw StateError('sink failed'),
        ),
      );
    });
  });

  group('throwing cleanup', () {
    for (final cleanup in ['disconnect', 'notification', 'both']) {
      test(
        '$cleanup failure cannot replace terminal write failure or revive reads',
        () async {
          final store = _FullStore();
          final connection = _FakeConnection(
            failDisconnect: cleanup != 'notification',
            failNotificationCancel: cleanup != 'disconnect',
          );
          await _withManualReadySession(
            (session, connection, timers, _) async {
              connection.emitPlaintext(
                _rawBatch(
                  startIndex: 1,
                  baseEpochSeconds: 1000,
                  baseReindex: 0,
                  currents: [64],
                  temperature: 321,
                ),
              );
              await _drainMicrotasks();
              expect(_fullSaved(store).isPending, isTrue);
              final originalWrite = Completer<void>();
              connection.onWrite = (_) => originalWrite.future;
              var settled = 0;
              final first = session.refreshLiveData().then((_) => settled++);
              _fireTimer(timers, _fastTiming.livePollInterval);
              await _drainMicrotasks();
              final second = session
                  .syncHistory(requestedStartOffset: 1)
                  .then((_) => settled++);
              await _drainMicrotasks();
              expect(settled, 0);
              final queued = timers
                  .where(
                    (timer) => timer.duration == _fastTiming.livePollInterval,
                  )
                  .toList();
              originalWrite.completeError(
                StateError('synthetic original write failure'),
              );
              await _drainMicrotasks();
              expect(settled, 2);
              await Future.wait([first, second]);
              expect(session.currentSnapshot.stage, CgmSyncStage.error);
              expect(
                session.currentSnapshot.lastError,
                CbioSessionFailure.write,
              );
              expect(
                connection.disconnectCalls,
                1,
                reason:
                    'notification cancellation failure must not skip link cleanup',
              );
              if (cleanup != 'disconnect') {
                expect(connection.notificationCancelCalls, 1);
              }
              final writesAtFailure = connection.writes.length;
              final timersAtFailure = timers.length;
              for (final timer in queued) {
                timer.fireQueued();
              }
              await _drainMicrotasks();
              await session.refreshLiveData();
              await session.syncHistory();
              expect(connection.writes.length, writesAtFailure);
              expect(timers.length, timersAtFailure);
              expect(timers.where((timer) => timer.isActive), isEmpty);
              expect(
                session.currentSnapshot.lastError,
                CbioSessionFailure.write,
              );
              await session.disconnect();
              expect(
                session.currentSnapshot.lastError,
                CbioSessionFailure.write,
              );
              expect(_fullSaved(store).records.single.rawTemperature, 321);
              expect(_fullSaved(store).records.single.rawPayload, 64);
              final nextOwner = await CbioPrivateStateOwner.load(
                _sensor.storageKey,
                store,
              );
              await nextOwner.adoptFullRecords();
              expect(
                CbioSessionCheckpoint.decode(
                  nextOwner.resumeCheckpoint!,
                  _sensor.storageKey,
                )!.index,
                1,
              );
              await nextOwner.close();
              expect(store.legacyWrites, 0);
            },
            connection: connection,
            privateStateStore: store,
          );
        },
      );
    }

    for (final failDrain in [false, true]) {
      test(
        'explicit throwing cleanup preserves durable lease until drain succeeds failure=$failDrain',
        () async {
          final store = _FullStore();
          final connection = _FakeConnection(
            failDisconnect: true,
            failNotificationCancel: true,
          );
          await _withManualReadySession(
            (session, connection, timers, _) async {
              connection.emitPlaintext(
                _rawBatch(
                  startIndex: 1,
                  baseEpochSeconds: 1000,
                  baseReindex: 0,
                  currents: [64],
                  temperature: 321,
                ),
              );
              await _drainMicrotasks();
              final before = store.full;
              final release = Completer<void>();
              store.hold = release;
              store.failFull = failDrain;
              store.started = Completer<void>();
              final queued = timers
                  .where(
                    (timer) => timer.duration == _fastTiming.livePollInterval,
                  )
                  .toList();
              var readersSettled = 0;
              final first = session.refreshLiveData().then(
                (_) => readersSettled++,
              );
              final second = session.syncHistory().then(
                (_) => readersSettled++,
              );
              var closeSettled = false;
              Object? closeError;
              final closing = session.disconnect().then<void>(
                (_) {
                  closeSettled = true;
                },
                onError: (Object error) {
                  closeError = error;
                  closeSettled = true;
                },
              );
              await _drainMicrotasks();
              expect(store.started!.isCompleted, isTrue);
              expect(closeSettled, isFalse);
              expect(readersSettled, 2);
              await Future.wait([first, second]);
              expect(connection.disconnectCalls, 1);
              expect(connection.notificationCancelCalls, 1);
              expect(store.full, before);
              final competitor = await CbioPrivateStateOwner.load(
                _sensor.storageKey,
                store,
              );
              await expectLater(
                competitor.adoptFullRecords(),
                throwsA(isA<CbioPrivateStateFailure>()),
              );
              final writesAtClose = connection.writes.length;
              final timersAtClose = timers.length;
              for (final timer in queued) {
                timer.fireQueued();
              }
              await _drainMicrotasks();
              expect(connection.writes.length, writesAtClose);
              expect(timers.length, timersAtClose);
              expect(timers.where((timer) => timer.isActive), isEmpty);
              release.complete();
              await closing;
              if (failDrain) {
                expect(closeError, isA<CbioPrivateStateFailure>());
                expect(store.full, before);
                await expectLater(
                  competitor.adoptFullRecords(),
                  throwsA(isA<CbioPrivateStateFailure>()),
                );
                store.failFull = false;
                await session.disconnect();
              } else {
                expect(closeError, isNull);
              }
              expect(_fullSaved(store).records.single.rawTemperature, 321);
              expect(
                CbioSessionCheckpoint.decode(
                  _fullSaved(store).currentCheckpoint!,
                  _sensor.storageKey,
                )!.index,
                1,
              );
              await competitor.adoptFullRecords();
              expect(
                competitor.resumeCheckpoint,
                _fullSaved(store).currentCheckpoint,
              );
              await competitor.close();
              expect(store.legacyWrites, 0);
              expect(connection.disconnectCalls, 1);
            },
            connection: connection,
            privateStateStore: store,
          );
        },
      );
    }
  });

  group('complete private inputs', () {
    test(
      'legacy bootstrap remains byte-identical after full-input suffix save',
      () async {
        final legacy = CbioHistoryState(
          sensorKey: _sensor.storageKey,
          checkpoint: CbioSessionCheckpoint(
            sensorKey: _sensor.storageKey,
            index: 1,
            rawTime: 1000,
          ).encode(),
          history: const [
            CgmReading(
              valueMgdl: 6.4,
              rawValue: 64,
              sensorMinute: 1,
              source: CgmRecordSource.raw,
              isDisplayProvisional: true,
            ),
          ],
        ).encode();
        final store = _FullStore()
          ..legacy = legacy
          ..expectedLegacy = legacy;
        final connection = _FakeConnection();
        await _defaultResponder(
          connection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 0,
              currents: [64, 70],
            ),
          ],
        );
        final session = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await session.initialize();
        await _pumpUntil(() => _rawCount(session).then((count) => count == 2));
        await session.disconnect();
        expect(store.legacy, legacy);
        expect(store.legacyWrites, 0);
        expect(_fullSaved(store).records.map((r) => r.rawTemperature), [
          315,
          315,
        ]);
        expect(
          _fullSaved(store).bootstrapCheckpoint,
          CbioSessionCheckpoint(
            sensorKey: _sensor.storageKey,
            index: 1,
            rawTime: 1000,
          ).encode(),
        );
        expect(
          CbioSessionCheckpoint.decode(
            _fullSaved(store).currentCheckpoint!,
            _sensor.storageKey,
          )!.index,
          2,
        );
      },
    );

    test(
      'restored same-index same-time witness cannot hide changed temperature',
      () async {
        final store = _FullStore();
        final firstConnection = _FakeConnection();
        await _defaultResponder(
          firstConnection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 0,
              currents: [64],
              temperature: 315,
            ),
          ],
        );
        final first = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(firstConnection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await first.initialize();
        await _pumpUntil(() => _rawCount(first).then((count) => count == 1));
        await first.disconnect();
        final saved = store.full;
        final secondConnection = _FakeConnection();
        await _defaultResponder(
          secondConnection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 0,
              currents: [64],
              temperature: 325,
            ),
          ],
        );
        final second = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(secondConnection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await second.initialize();
        await _pumpUntil(
          () => second.currentSnapshot.stage == CgmSyncStage.error,
        );
        expect(
          second.currentSnapshot.lastError,
          CbioSessionFailure.conflictingHistory,
        );
        await second.disconnect();
        expect(store.full, saved);
        expect(second.currentSnapshot.latestReading, isNull);
      },
    );

    test(
      'prepare stays read-only and pending durability precedes BLE',
      () async {
        final store = _FullStore()
          ..hold = Completer<void>()
          ..started = Completer<void>();
        final connection = _FakeConnection();
        await _defaultResponder(connection);
        final transport = _FakeTransport(connection);
        final driver = CbioSensorDriver(
          transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await driver.prepareTarget(_sensor);
        expect(store.full, isNull);
        expect(store.writes, 0);
        final session = await driver.connect(_sensor);
        await store.started!.future;
        expect(transport.connects, 0);
        store.hold!.complete();
        await _pumpUntil(() => transport.connects == 1);
        expect(_fullSaved(store).isPending, isTrue);
        await session.disconnect();
      },
    );

    test('failed adoption never opens BLE or writes lossy legacy', () async {
      final store = _FullStore()..failFull = true;
      final transport = _FakeTransport(_FakeConnection());
      final driver = CbioSensorDriver(
        transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        privateStateStore: store,
      );
      final session = await driver.connect(_sensor);
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.error,
      );
      expect(transport.connects, 0);
      expect(store.legacyWrites, 0);
      expect(session.currentSnapshot.lastError, 'cbio.private-state.failed');
      expect(
        session
            .currentSnapshot
            .metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
      await session.disconnect();
    });

    test(
      'two temperatures survive restart and authoritative witness resumes suffix',
      () async {
        final store = _FullStore();
        final firstConnection = _FakeConnection();
        await _defaultResponder(
          firstConnection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 1,
              currents: [64],
              temperature: 315,
            ),
            _rawBatch(
              startIndex: 2,
              baseEpochSeconds: 1060,
              baseReindex: 0,
              currents: [64],
              temperature: 325,
            ),
          ],
        );
        final first = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(firstConnection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await first.initialize();
        await _pumpUntil(() => _rawCount(first).then((count) => count == 2));
        await first.disconnect();
        expect(store.full, isNotNull);
        expect(_fullSaved(store).records.map((r) => r.rawTemperature), [
          315,
          325,
        ]);
        expect(store.legacyWrites, 0);
        final secondConnection = _FakeConnection();
        await _defaultResponder(
          secondConnection,
          rawBatches: [
            _rawBatch(
              startIndex: 2,
              baseEpochSeconds: 1060,
              baseReindex: 1,
              currents: [64],
              temperature: 325,
            ),
            _rawBatch(
              startIndex: 3,
              baseEpochSeconds: 1120,
              baseReindex: 0,
              currents: [72],
              temperature: 326,
            ),
          ],
        );
        final second = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(secondConnection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await second.initialize();
        await _pumpUntil(() => _rawCount(second).then((count) => count == 2));
        await second.disconnect();
        expect(_fullSaved(store).records.map((r) => r.rawTemperature), [
          315,
          325,
          326,
        ]);
        final query = secondConnection.writes
            .map(_unmaskWrite)
            .firstWhere((w) => w[1] == 0x08);
        expect(query[2] | (query[3] << 8), 2);
        expect(second.currentSnapshot.history, isEmpty);
        expect(second.currentSnapshot.rawHistory, isEmpty);
        expect(second.currentSnapshot.latestReading, isNull);
      },
    );

    test(
      'changed-temperature duplicate before coalesced publication fails closed',
      () async {
        final store = _FullStore();
        final connection = _FakeConnection();
        await _defaultResponder(
          connection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 0,
              currents: [64],
              temperature: 315,
            ),
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 0,
              currents: [64],
              temperature: 325,
            ),
          ],
        );
        final session = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming.copyWith(
            publishInterval: const Duration(seconds: 1),
          ),
          privateStateStore: store,
        );
        await session.initialize();
        await _drainMicrotasks();
        expect(
          session.currentSnapshot.lastError,
          CbioSessionFailure.conflictingHistory,
        );
        expect(_fullSaved(store).isPending, isTrue);
        await session.disconnect();
      },
    );

    test(
      'explicit save failure pauses radio and cannot advance checkpoint',
      () async {
        final store = _FullStore();
        final connection = _FakeConnection();
        await _defaultResponder(
          connection,
          rawBatches: [
            _rawBatch(
              startIndex: 1,
              baseEpochSeconds: 1000,
              baseReindex: 0,
              currents: [64],
            ),
          ],
        );
        final session = await _privateSession(
          sensor: _sensor,
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          privateStateStore: store,
        );
        await session.initialize();
        await _pumpUntil(() => _rawCount(session).then((count) => count == 1));
        final pending = store.full;
        store.failFull = true;
        await expectLater(session.flushPrivateState(), throwsException);
        expect(session.currentSnapshot.lastError, 'cbio.private-state.failed');
        expect(store.full, pending);
        final writeCount = connection.writes.length;
        await session.refreshLiveData();
        expect(connection.writes.length, writeCount);
        store.failFull = false;
        await session.disconnect();
        expect(_fullSaved(store).records, hasLength(1));
        expect(store.legacyWrites, 0);
      },
    );
  });

  test(
    'caller advertisement cannot become unverified glucose fallback',
    () async {
      final sensor = DiscoveredSensor.fromJson({
        ..._sensor.toJson(),
        'advertisement': const CgmAdvertisement(
          payloadHex: 'synthetic',
          displayValueMgdl: 59,
        ).toJson(),
      });
      final session = await _privateSession(
        sensor: sensor,
        transport: _FakeTransport(_FakeConnection()),
      );
      expect(session.currentSnapshot.sensor.advertisement, isNull);
      expect(session.currentSnapshot.lastAdvertisement, isNull);
      expect(session.currentSnapshot.latestReading, isNull);
      await session.disconnect();
    },
  );
  test(
    'driver preparation is read only and rejects malformed saved state',
    () async {
      final store = _PrivateStore()..envelope = '{invalid';
      final transport = _FakeTransport(_FakeConnection());
      final driver = CbioSensorDriver(transport, privateStateStore: store);
      await expectLater(driver.prepareTarget(_sensor), throwsException);
      expect(transport.connects, 0);
      expect(store.envelope, '{invalid');
    },
  );

  test(
    'driver ignores forged caller resume proof and retains failed dirty save',
    () async {
      final store = _PrivateStore();
      final connection = _FakeConnection();
      await _defaultResponder(
        connection,
        rawBatches: [
          _rawBatch(
            startIndex: 1,
            baseEpochSeconds: 1000,
            baseReindex: 1,
            currents: [64, 80],
          ),
        ],
      );
      final driver = CbioSensorDriver(
        _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
        privateStateStore: store,
      );
      final session = await driver.connect(
        _withMetadata({
          cbioCheckpointMetadataKey: '{forged',
          cbioResumeStatusMetadataKey: CbioResumeStatus.confirmed,
          cbioConfirmedCheckpointMetadataKey: '{forged',
        }),
      );
      await _pumpUntil(
        () => session.currentSnapshot.stage == CgmSyncStage.ready,
      );
      expect(session.currentSnapshot.history, isEmpty);
      expect(session.currentSnapshot.rawHistory, isEmpty);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(
        session.currentSnapshot.metadata[cbioResumeStatusMetadataKey],
        isNull,
      );
      store.failWrite = true;
      await expectLater(session.disconnect(), throwsException);
      expect(store.envelope, isNull);
      store.failWrite = false;
      await driver.flushPrivateState();
      expect(
        CbioHistoryState.decode(
          store.envelope!,
          sensorKey: _sensor.storageKey,
        ).history.map((r) => r.rawValue),
        [64, 80],
      );
    },
  );

  test('raw acquisition never enters any public reading field', () async {
    final privateStore = _PrivateStore();
    final connection = _FakeConnection();
    await _defaultResponder(
      connection,
      rawBatches: [
        _rawBatch(
          startIndex: 1,
          baseEpochSeconds: 1000,
          baseReindex: 1,
          currents: [64, 80],
        ),
      ],
    );
    final session = await _privateSession(
      privateStateStore: privateStore,
      sensor: _sensor,
      transport: _FakeTransport(connection),
      credentials: _syntheticSource,
      timing: _fastTiming,
    );
    await session.initialize();
    await _pumpUntil(() => session.currentSnapshot.stage == CgmSyncStage.ready);
    expect(session.currentSnapshot.latestReading, isNull);
    expect(session.currentSnapshot.history, isEmpty);
    expect(session.currentSnapshot.rawHistory, isEmpty);
    await session.disconnect();
  });
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
      final session = await _privateSession(
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

        final session = await _privateSession(
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

        final session = await _privateSession(
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

        final session = await _privateSession(
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

      final session = await _privateSession(
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

      final session = await _privateSession(
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

      final session = await _privateSession(
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

      final session = await _privateSession(
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

        final session = await _privateSession(
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

      final session = await _privateSession(
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

      final session = await _privateSession(
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
    test('ingests raw stream privately without publishing glucose', () async {
      final privateStore = _PrivateStore();
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

      final session = await _privateSession(
        privateStateStore: privateStore,
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(
        () async =>
            (await _rawCount(session)) == 3 &&
            session.currentSnapshot.stage == CgmSyncStage.ready,
      );

      final snapshot = session.currentSnapshot;
      final rawHistory = await _storedHistory(session, privateStore);
      final latest = rawHistory.last;
      expect(snapshot.latestReading, isNull);
      expect(snapshot.history, isEmpty);
      expect(snapshot.rawHistory, isEmpty);
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
        (await _storedHistory(
          session,
          privateStore,
        )).map((reading) => reading.recordedAt),
        <DateTime?>[
          for (final offset in <int>[0, 60, 120])
            DateTime.fromMillisecondsSinceEpoch(
              (base + offset) * 1000,
              isUtc: true,
            ),
        ],
      );
      expect(
        (await _storedHistory(
          session,
          privateStore,
        )).map((r) => r.sensorMinute),
        <int>[1, 2, 3],
      );
      expect(snapshot.capabilities.supportsHistory, isFalse);
      expect(snapshot.capabilities.supportsRawHistory, isFalse);
      await session.disconnect();
    });

    test(
      'surfaces a restarted sensor counter instead of absorbing it',
      () async {
        final privateStore = _PrivateStore();
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

        final session = await _privateSession(
          privateStateStore: privateStore,
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
        await _pumpUntil(() async => await _rawCount(session) == 3);
        await _pumpUntil(
          () => messages.any((m) => m.contains('counter-restart')),
        );

        // The old numbering keeps its records: the new cycle is not spliced on
        // to it, and no position is silently renumbered.
        expect(
          (await _storedHistory(
            session,
            privateStore,
          )).map((r) => r.sensorMinute),
          <int>[1, 2, 3],
        );
        expect(
          (await _storedHistory(session, privateStore)).map((r) => r.rawValue),
          <int>[64, 80, 97],
        );
        expect(
          messages.any((m) => m.contains('counter-restart')),
          isTrue,
          reason: 'a restart must be visible, not absorbed as a duplicate',
        );
        expect(session.currentSnapshot.stage, CgmSyncStage.error);
        expect(_privateCheckpoint(session), isNotNull);
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

        final session = await _privateSession(
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => now,
        );
        await session.initialize();
        await _pumpUntil(() async => await _rawCount(session) == 2);

        final syncing = session.currentSnapshot;
        expect(syncing.historySync.storedCount, 0);
        expect(syncing.historySync.latestStoredOffset, isNull);
        expect(syncing.historySync.startIndex, isNull);
        expect(syncing.historySync.inProgress, isFalse);
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

      final session = await _privateSession(
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
      expect(snapshot.historySync.storedCount, 0);
      expect(snapshot.historySync.totalAvailable, 0);
      expect(snapshot.historySync.lastSyncAt, isNull);
      expect(snapshot.statusText, contains('Live'));
      await session.disconnect();
    });

    test('keeps polling for new records after the live edge', () async {
      final privateStore = _PrivateStore();
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

      final session = await _privateSession(
        privateStateStore: privateStore,
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(() async => await _rawCount(session) == 1);

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
      await _pumpUntil(() async => await _rawCount(session) == 2);

      expect((await _storedHistory(session, privateStore)).last.rawValue, 88);
      expect(
        (await _storedHistory(
          session,
          privateStore,
        )).map((r) => r.sensorMinute),
        <int>[1, 2],
      );
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

        final session = await _privateSession(
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
      final privateStore = _PrivateStore();
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

      final session = await _privateSession(
        privateStateStore: privateStore,
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(() async => await _rawCount(session) == 2);

      expect((await _storedHistory(session, privateStore)).last.rawValue, 70);
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
            final session = await _privateSession(
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
              final session = await _privateSession(
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

        final session = await _privateSession(
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

      final session = await _privateSession(
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
      final session = await _privateSession(
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

      final session = await _privateSession(
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

      final session = await _privateSession(
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
          expect(await _rawCount(session), tick + 1);
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

      final session = await _privateSession(
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

        final session = await _privateSession(
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

      final session = await _privateSession(
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
      final session = await _privateSession(
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
      await _pumpUntil(() async => await _rawCount(session) == 1);
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
      expect(await _rawCount(session), 1);
      expect(session.currentSnapshot.history, isEmpty);
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
      final session = await _privateSession(
        sensor: _sensor,
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(() async => await _rawCount(session) == 3);
      final checkpoint = CbioSessionCheckpoint.decode(
        _privateCheckpoint(session)!,
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
      final session = await _privateSession(
        sensor: _sensor,
        transport: _FakeTransport(connection),
        credentials: _syntheticSource,
        timing: _fastTiming,
      );
      await session.initialize();
      await _pumpUntil(() async => await _rawCount(session) > 0);
      expect(_privateCheckpoint(session), isNull);
      await session.disconnect();
    });

    test(
      'does not skip history on an unverified legacy resume offset',
      () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        await _defaultResponder(connection);

        final session = await _privateSession(
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
        final privateStore = _PrivateStore();
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
        final first = await _privateSession(
          privateStateStore: privateStore,
          sensor: _sensor,
          transport: _FakeTransport(firstConnection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => then,
        );
        await first.initialize();
        await _pumpUntil(() async => await _rawCount(first) == 2);
        final metadata = Map<String, String>.from({
          cbioCheckpointMetadataKey: _privateCheckpoint(first)!,
        });
        expect(metadata['cgm.cbio.checkpoint'], isNotNull);
        await first.disconnect();
        expect(_privateCheckpoint(first), metadata[cbioCheckpointMetadataKey]);

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
        final restored = await _privateSession(
          privateStateStore: privateStore,
          sensor: _withMetadata(metadata),
          transport: _FakeTransport(connection),
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => then.add(const Duration(hours: 1)),
        );
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.resume.status'],
          isNull,
        );
        expect(
          restored
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          isNull,
        );
        await restored.initialize();
        await _pumpUntil(() async => await _rawCount(restored) > 0);
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.resume.status'],
          isNull,
        );
        expect(
          restored
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          isNull,
        );
        final query = connection.writes
            .map(_unmaskWrite)
            .firstWhere((frame) => frame[1] == 0x08);
        expect(query[2] | (query[3] << 8), 2);
        expect(
          (await _storedHistory(restored, privateStore))[1].recordedAt,
          then,
        );
        expect(
          (await _storedHistory(restored, privateStore)).last.recordedAt,
          then.add(const Duration(minutes: 1)),
        );
        final next = CbioSessionCheckpoint.decode(
          _privateCheckpoint(restored)!,
          _sensor.storageKey,
        );
        expect(next?.anchor?.anchorEpochSeconds, epoch);
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.lifecycle'],
          'unknown',
        );
        final advancedCheckpoint = _privateCheckpoint(restored);
        await restored.disconnect();
        expect(
          restored.currentSnapshot.metadata['cgm.cbio.resume.status'],
          isNull,
        );
        expect(
          restored
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          isNull,
        );
        expect(_privateCheckpoint(restored), advancedCheckpoint);
      },
    );

    for (final raw in ['{', '{}', '{"version":99}']) {
      test('malformed checkpoint fails before radio: $raw', () async {
        final connection = _FakeConnection();
        final transport = _FakeTransport(connection);
        final session = await _privateSession(
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
        final session = await _privateSession(
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
        final session = await _privateSession(
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
          isNull,
        );
        expect(
          session
              .currentSnapshot
              .metadata['cgm.cbio.resume.confirmedCheckpoint'],
          isNull,
        );
        expect(_privateCheckpoint(session), checkpoint);
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
        expect(_privateCheckpoint(session), checkpoint);
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

      final session = await _privateSession(
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

      final session = await _privateSession(
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
      final privateStore = _PrivateStore();
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

      final session = await _privateSession(
        privateStateStore: privateStore,
        sensor: _sensor,
        transport: transport,
        credentials: _syntheticSource,
        timing: _fastTiming,
        clock: () => now,
      );
      await session.initialize();
      await _pumpUntil(() async => await _rawCount(session) == 3);

      final snapshot = session.currentSnapshot;
      final anchor = CbioSessionCheckpoint.decode(
        _privateCheckpoint(session)!,
        _sensor.storageKey,
      )?.anchor;
      expect(snapshot.history, isEmpty);
      expect(
        snapshot.metadata.keys.where(
          (key) => key.contains('checkpoint') || key.contains('clock.'),
        ),
        isEmpty,
      );
      expect(
        snapshot.sensor.metadata.keys.where(
          (key) => key.contains('checkpoint') || key.contains('clock.'),
        ),
        isEmpty,
      );
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
        (await _storedHistory(
          session,
          privateStore,
        )).map((reading) => reading.recordedAt),
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
        (await session.refreshDiagnostics()).single.fields.keys,
        isNot(contains('clockAnchor')),
      );
      await session.disconnect();
    });

    test(
      'publishes no timestamp while the sensor clock is the counter',
      () async {
        final privateStore = _PrivateStore();
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

        final session = await _privateSession(
          privateStateStore: privateStore,
          sensor: _sensor,
          transport: transport,
          credentials: _syntheticSource,
          timing: _fastTiming,
          clock: () => now,
        );
        await session.initialize();
        await _pumpUntil(() async => await _rawCount(session) == 3);

        final snapshot = session.currentSnapshot;
        expect(CbioIndexTimeAnchor.fromMetadata(snapshot.metadata), isNull);
        expect(
          (await _storedHistory(
            session,
            privateStore,
          )).every((reading) => reading.recordedAt == null),
          isTrue,
          reason: 'the counter is a position, never a clock',
        );
        expect(
          (await session.refreshDiagnostics()).single.fields.keys,
          isNot(contains('clockAnchor')),
        );
        await session.disconnect();
      },
    );
  });
}
