import 'dart:async';
import 'dart:math' as math;

import 'package:cgm_core/cgm_core.dart';

class DemoCgmDriver implements CgmDriver {
  DemoCgmDriver({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const _capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsVendorPairing: true,
    supportsAdvertisementGlucose: true,
    supportsHistory: true,
    supportsRawHistory: true,
    supportsCalibration: true,
    supportsDiagnostics: true,
    supportsCommunicationInterval: true,
  );

  @override
  String get driverId => 'demo-aidex';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    yield DiscoveredSensor(
      driverId: driverId,
      deviceId: 'demo-aidex-07A12',
      displayName: 'AiDEX Demo 07A12',
      storageKey: 'demo:07A12',
      rssi: -46,
      capabilities: _capabilities,
      advertisement: const CgmAdvertisement(
        payloadHex: '5900DEMO0712',
        counter: 12,
        phaseHex: '21',
        glucoseTriplet: <int>[122, 124, 127],
        qualifiers: <int>[1, 0, 0],
        displayValueMgdl: 124,
      ),
      notes: 'Demo transport for web, screenshots, and widget tests.',
      metadata: const <String, String>{'serial': '07A12', 'mode': 'demo'},
    );
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    return DemoCgmSession(sensor: sensor, clock: _clock);
  }
}

class DemoCgmSession implements CgmSession {
  DemoCgmSession({required this.sensor, required DateTime Function() clock})
    : _clock = clock {
    final snapshot = _buildSnapshot();
    _snapshot = snapshot;
    _history = snapshot.history;
    _calibrations = snapshot.calibrations;
    _diagnostics = snapshot.diagnostics;
    _log(CgmLogLevel.info, 'Demo session initialized');
  }

  @override
  final DiscoveredSensor sensor;

  final DateTime Function() _clock;
  final StreamController<CgmSessionSnapshot> _snapshotController =
      StreamController<CgmSessionSnapshot>.broadcast();
  final StreamController<CgmLogEntry> _logController =
      StreamController<CgmLogEntry>.broadcast();

  late CgmSessionSnapshot _snapshot;
  late List<CgmReading> _history;
  late List<CgmCalibrationEntry> _calibrations;
  late List<CgmDiagnosticItem> _diagnostics;
  bool _closed = false;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> refresh() async {
    _ensureOpen();
    final latestTime = _clock();
    final sessionStart = _snapshot.sessionInfo.sessionStart ?? latestTime;
    final sensorMinute = latestTime.difference(sessionStart).inMinutes;
    final latest = CgmReading(
      valueMgdl: 118 + (math.sin(sensorMinute / 11) * 10),
      source: CgmRecordSource.broadcast,
      sensorMinute: sensorMinute,
      recordedAt: latestTime,
      qualifier: 1,
    );
    _history =
        <CgmReading>[
          ..._history.where((reading) => reading.sensorMinute != sensorMinute),
          latest,
        ]..sort(
          (left, right) =>
              (left.sensorMinute ?? 0).compareTo(right.sensorMinute ?? 0),
        );
    _emitSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: 'Demo reading refreshed',
        latestReading: latest,
        history: _history,
        historySync: _snapshot.historySync.copyWith(lastSyncAt: latestTime),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'historyCount': _history.length.toString(),
        },
      ),
    );
    _log(CgmLogLevel.info, 'Demo refresh produced ${latest.valueMgdl}');
  }

  @override
  Future<void> refreshLiveData() => refresh();

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {
    _ensureOpen();
    final rawHistory = includeRawHistory
        ? _history
              .map((reading) => reading.copyWith(source: CgmRecordSource.raw))
              .toList(growable: false)
        : _snapshot.rawHistory;
    _emitSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: 'Demo history synced',
        history: _history,
        rawHistory: rawHistory,
        latestReading: _history.isEmpty ? null : _history.last,
        historySync: _snapshot.historySync.copyWith(
          inProgress: false,
          totalAvailable: _history.length,
          storedCount: _history.length,
          latestStoredOffset: _history.isEmpty
              ? null
              : _history.last.sensorMinute,
          lastSyncAt: _clock(),
        ),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'historyCount': _history.length.toString(),
        },
      ),
    );
    _log(CgmLogLevel.info, 'Demo history sync complete');
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async {
    _ensureOpen();
    _emitSnapshot(_snapshot.copyWith(calibrations: _calibrations));
    _log(CgmLogLevel.debug, 'Loaded ${_calibrations.length} demo calibrations');
    return _calibrations;
  }

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {
    _ensureOpen();
    _calibrations = <CgmCalibrationEntry>[
      ..._calibrations,
      CgmCalibrationEntry(
        index: _calibrations.length + 1,
        glucoseMgdl: glucoseMgdl,
        sensorMinute: sensorMinute,
        recordedAt: recordedAt ?? _clock(),
        payloadHex:
            '${glucoseMgdl.toRadixString(16).padLeft(4, '0')}${(sensorMinute ?? 0).toRadixString(16).padLeft(4, '0')}',
      ),
    ];
    _emitSnapshot(_snapshot.copyWith(calibrations: _calibrations));
    _log(CgmLogLevel.info, 'Demo calibration submitted: $glucoseMgdl mg/dL');
  }

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async {
    _ensureOpen();
    _diagnostics = _buildDiagnostics();
    _emitSnapshot(_snapshot.copyWith(diagnostics: _diagnostics));
    _log(CgmLogLevel.debug, 'Demo diagnostics refreshed');
    return _diagnostics;
  }

  @override
  Future<void> disconnect() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _snapshotController.close();
    await _logController.close();
  }

  CgmSessionSnapshot _buildSnapshot() {
    final now = _clock();
    final sessionStart = now.subtract(const Duration(hours: 16));
    final history = List<CgmReading>.generate(48, (index) {
      final recordedAt = now.subtract(Duration(minutes: (47 - index) * 5));
      final sensorMinute = recordedAt.difference(sessionStart).inMinutes;
      final value = 118 + (math.sin(index / 4) * 16) + ((index % 5) - 2);
      return CgmReading(
        valueMgdl: value,
        source: index == 47
            ? CgmRecordSource.broadcast
            : CgmRecordSource.vendor,
        sensorMinute: sensorMinute,
        recordedAt: recordedAt,
        rawValue: value.round(),
        qualifier: 1,
      );
    });
    final diagnostics = _buildDiagnostics();
    final calibrations = <CgmCalibrationEntry>[
      CgmCalibrationEntry(
        index: 1,
        glucoseMgdl: 118,
        sensorMinute: history[20].sensorMinute,
        recordedAt: history[20].recordedAt,
        payloadHex: '7600150c',
      ),
    ];
    return CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Demo session ready',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: history.last,
      lastAdvertisement: sensor.advertisement,
      history: history,
      rawHistory: history
          .map((reading) => reading.copyWith(source: CgmRecordSource.raw))
          .toList(growable: false),
      calibrations: calibrations,
      diagnostics: diagnostics,
      sessionInfo: CgmSessionInfo(
        manufacturer: 'MicroTech Medical',
        model: 'AiDEX X',
        serial: sensor.metadata['serial'] ?? '07A12',
        firmware: '1.9.7-demo',
        sessionStart: sessionStart,
        sessionStartPayloadHex: 'E907040D01080C0000',
        elapsedMinutes: history.last.sensorMinute,
      ),
      health: const CgmHealthSnapshot(
        statusText: 'Sensor active',
        warningFlagsHex: '0x00',
        sensorCheckHex: '0100',
      ),
      historySync: CgmHistorySyncState(
        storedCount: history.length,
        totalAvailable: history.length,
        latestStoredOffset: history.last.sensorMinute,
        startIndex: history.first.sensorMinute,
        targetIndex: history.last.sensorMinute,
        lastSyncAt: now,
      ),
      metadata: <String, String>{
        'deviceId': sensor.deviceId,
        'serial': sensor.metadata['serial'] ?? '07A12',
        'mode': 'demo',
        'driverId': sensor.driverId,
        'historyCount': history.length.toString(),
      },
    );
  }

  List<CgmDiagnosticItem> _buildDiagnostics() {
    return <CgmDiagnosticItem>[
      CgmDiagnosticItem(
        key: 'pair',
        title: 'Vendor Pair State',
        summary: 'Demo transport always reports the vendor session as ready.',
        rawHex: '1122334455667788',
      ),
      const CgmDiagnosticItem(
        key: 'device',
        title: 'Device Information',
        fields: <String, String>{
          'manufacturer': 'MicroTech Medical',
          'model': 'AiDEX X',
          'firmware': '1.9.7-demo',
        },
      ),
      const CgmDiagnosticItem(
        key: 'status',
        title: 'Standard CGM State',
        fields: <String, String>{
          'featureHex': '8B3F',
          'statusHex': '0000010000000000',
          'sessionRunTimeHex': '00480000',
        },
      ),
    ];
  }

  void _emitSnapshot(CgmSessionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void _log(CgmLogLevel level, String message) {
    if (_logController.isClosed) {
      return;
    }
    _logController.add(
      CgmLogEntry(timestamp: _clock(), level: level, message: message),
    );
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Demo session is disconnected.');
    }
  }
}
