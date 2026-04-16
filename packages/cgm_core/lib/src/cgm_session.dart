import 'cgm_models.dart';

abstract interface class CgmDriver {
  String get driverId;

  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  });

  Future<CgmSession> connect(DiscoveredSensor sensor);
}

abstract interface class CgmSession {
  DiscoveredSensor get sensor;
  CgmSessionSnapshot get currentSnapshot;
  Stream<CgmSessionSnapshot> get snapshots;
  Stream<CgmLogEntry> get logs;
  CgmUnsafeAdmin? get unsafeAdmin;

  Future<void> refresh();

  Future<void> refreshLiveData();

  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  });

  Future<List<CgmCalibrationEntry>> fetchCalibrations();

  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  });

  Future<List<CgmDiagnosticItem>> refreshDiagnostics();

  Future<void> disconnect();
}

abstract interface class CgmUnsafeAdmin {
  Set<CgmUnsafeOperation> get supportedOperations;

  Future<void> perform(CgmUnsafeOperation operation);
}

class UnsupportedCapabilityException implements Exception {
  UnsupportedCapabilityException(this.message);

  final String message;

  @override
  String toString() => 'UnsupportedCapabilityException: $message';
}
