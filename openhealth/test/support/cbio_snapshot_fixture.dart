import 'package:cgm_core/cgm_core.dart';

/// Radio-free contract fixtures. Normalized records here are synthetic inputs,
/// never evidence that GS1 glucose decoding has been verified.
DiscoveredSensor syntheticSurfaceSensor([String driverId = 'cbio']) =>
    DiscoveredSensor(
      driverId: driverId,
      deviceId: 'synthetic-surface-device',
      displayName: 'Synthetic sensor',
      storageKey: 'synthetic-surface-storage',
      rssi: -40,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsHistory: true,
      ),
    );

CgmSessionSnapshot syntheticSurfaceSnapshot({
  String driverId = 'cbio',
  List<CgmReading> readings = const [],
  CgmSyncStage stage = CgmSyncStage.ready,
  CgmSessionInfo sessionInfo = const CgmSessionInfo(warmupMinutes: 0),
  CgmHistorySyncState historySync = const CgmHistorySyncState(),
  String? lastError,
  Map<String, String> metadata = const {},
}) {
  final sensor = syntheticSurfaceSensor(driverId);
  return CgmSessionSnapshot(
    sensor: sensor,
    capabilities: sensor.capabilities,
    stage: stage,
    statusText: 'synthetic-private-status',
    latestReading: readings.isEmpty ? null : readings.last,
    history: readings,
    sessionInfo: sessionInfo,
    historySync: historySync,
    lastError: lastError,
    metadata: {
      cgmAutomaticReconnectAllowedMetadataKey: 'false',
      ...metadata,
    },
  );
}

class SyntheticSurfaceDriver implements CgmDriver {
  SyntheticSurfaceDriver(this.snapshot);
  final CgmSessionSnapshot snapshot;

  @override
  String get driverId => snapshot.sensor.driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => Stream.value(snapshot.sensor);

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _SyntheticSurfaceSession(snapshot);
}

class _SyntheticSurfaceSession implements CgmSession {
  _SyntheticSurfaceSession(this.currentSnapshot);

  @override
  final CgmSessionSnapshot currentSnapshot;
  @override
  DiscoveredSensor get sensor => currentSnapshot.sensor;
  @override
  Stream<CgmLogEntry> get logs => const Stream.empty();
  @override
  Stream<CgmSessionSnapshot> get snapshots => const Stream.empty();
  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshLiveData() async {}
  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async => [];
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async => [];
  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}
  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
}
