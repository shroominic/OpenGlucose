import 'cgm_models.dart';

const cgmBondTransferStateMetadataKey = 'cgm.bond-transfer.state';
const cgmBondTransferDiagnosticMetadataKey = 'cgm.bond-transfer.diagnostic';

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

/// The Bluetooth-standard bond deletion procedure selected for an explicit
/// sensor move.
enum CgmBondTransferScope {
  /// Delete only the requesting phone's LE bond (BMS opcode 0x03).
  requestingDeviceLe,

  /// Delete every LE bond stored by the sensor (BMS opcode 0x06).
  allLe,
}

class CgmBondTransferPlan {
  const CgmBondTransferPlan(this.scope);

  final CgmBondTransferScope scope;

  bool get removesAllLeBonds => scope == CgmBondTransferScope.allLe;

  @override
  bool operator ==(Object other) =>
      other is CgmBondTransferPlan && other.scope == scope;

  @override
  int get hashCode => scope.hashCode;
}

/// How far an explicit bond-transfer procedure progressed.
///
/// [unknown] and [sensorAccepted] are terminal for automatic behavior. A
/// caller must never repeat the sensor-side control-point write for them.
enum CgmBondTransferOutcome { notStarted, unknown, sensorAccepted }

enum CgmBondTransferFailureKind {
  unsupportedPlatform,
  sessionNotReady,
  linkNotAuthenticated,
  localBondMissing,
  bondStateUnavailable,
  serviceUnavailable,
  featureUnavailable,
  featureMalformed,
  authorizationCodeRequired,
  procedureUnsupported,
  featureChanged,
  statePersistenceFailed,
  sensorResponseUnknown,
  sensorRejected,
  disconnectUnconfirmed,
  localBondRemovalFailed,
  localBondRemovalUnconfirmed,
}

/// A closed, identifier-free failure from the explicit sensor-transfer flow.
class CgmBondTransferException implements Exception {
  const CgmBondTransferException(this.kind, {required this.outcome});

  final CgmBondTransferFailureKind kind;
  final CgmBondTransferOutcome outcome;

  String get diagnosticCode => switch (kind) {
    CgmBondTransferFailureKind.unsupportedPlatform =>
      'cgm.bond-transfer.android-required',
    CgmBondTransferFailureKind.sessionNotReady =>
      'cgm.bond-transfer.session-not-ready',
    CgmBondTransferFailureKind.linkNotAuthenticated =>
      'cgm.bond-transfer.link-not-authenticated',
    CgmBondTransferFailureKind.localBondMissing =>
      'cgm.bond-transfer.local-bond-missing',
    CgmBondTransferFailureKind.bondStateUnavailable =>
      'cgm.bond-transfer.bond-state-unavailable',
    CgmBondTransferFailureKind.serviceUnavailable =>
      'cgm.bond-transfer.service-unavailable',
    CgmBondTransferFailureKind.featureUnavailable =>
      'cgm.bond-transfer.feature-unavailable',
    CgmBondTransferFailureKind.featureMalformed =>
      'cgm.bond-transfer.feature-malformed',
    CgmBondTransferFailureKind.authorizationCodeRequired =>
      'cgm.bond-transfer.authorization-code-required',
    CgmBondTransferFailureKind.procedureUnsupported =>
      'cgm.bond-transfer.procedure-unsupported',
    CgmBondTransferFailureKind.featureChanged =>
      'cgm.bond-transfer.feature-changed',
    CgmBondTransferFailureKind.statePersistenceFailed =>
      'cgm.bond-transfer.state-persistence-failed',
    CgmBondTransferFailureKind.sensorResponseUnknown =>
      'cgm.bond-transfer.sensor-response-unknown',
    CgmBondTransferFailureKind.sensorRejected =>
      'cgm.bond-transfer.sensor-rejected',
    CgmBondTransferFailureKind.disconnectUnconfirmed =>
      'cgm.bond-transfer.disconnect-unconfirmed',
    CgmBondTransferFailureKind.localBondRemovalFailed =>
      'cgm.bond-transfer.local-bond-removal-failed',
    CgmBondTransferFailureKind.localBondRemovalUnconfirmed =>
      'cgm.bond-transfer.local-bond-removal-unconfirmed',
  };

  String get userMessage => switch (kind) {
    CgmBondTransferFailureKind.unsupportedPlatform =>
      'Moving a sensor is available only on Android.',
    CgmBondTransferFailureKind.sessionNotReady =>
      'Connect this phone to the sensor before moving it.',
    CgmBondTransferFailureKind.linkNotAuthenticated =>
      'The sensor connection is not authenticated.',
    CgmBondTransferFailureKind.localBondMissing =>
      'This phone does not own the active sensor bond.',
    CgmBondTransferFailureKind.bondStateUnavailable =>
      'Android could not confirm the sensor bond.',
    CgmBondTransferFailureKind.serviceUnavailable ||
    CgmBondTransferFailureKind.featureUnavailable ||
    CgmBondTransferFailureKind.featureMalformed ||
    CgmBondTransferFailureKind.procedureUnsupported =>
      'This sensor does not advertise a safe phone-transfer procedure.',
    CgmBondTransferFailureKind.authorizationCodeRequired =>
      'This sensor requires an authorization code that the app does not have.',
    CgmBondTransferFailureKind.featureChanged =>
      'The sensor transfer capability changed. Reopen settings and try again.',
    CgmBondTransferFailureKind.statePersistenceFailed =>
      'The app could not save the transfer state safely. Do not retry.',
    CgmBondTransferFailureKind.sensorResponseUnknown =>
      'The sensor response is unknown. Do not retry. Check Bluetooth settings.',
    CgmBondTransferFailureKind.sensorRejected =>
      'The sensor did not accept the transfer request.',
    CgmBondTransferFailureKind.disconnectUnconfirmed =>
      'The sensor accepted the request, but disconnection was not confirmed. '
          'Do not retry.',
    CgmBondTransferFailureKind.localBondRemovalFailed ||
    CgmBondTransferFailureKind.localBondRemovalUnconfirmed =>
      'The sensor accepted the request, but Android still has the old bond. '
          'Forget the sensor in Android Bluetooth settings. Do not retry.',
  };

  @override
  String toString() =>
      'CgmBondTransferException(${kind.name}, ${outcome.name}, '
      '$diagnosticCode)';
}

/// Optional capability implemented by sessions that can safely move their
/// current Bluetooth bond to another phone.
abstract interface class CgmBondTransferSession {
  /// Reads and validates the sensor's current BMS feature value.
  Future<CgmBondTransferPlan> inspectBondTransfer();

  /// Executes one user-confirmed transfer plan without automatic retries.
  Future<void> executeBondTransfer(
    CgmBondTransferPlan plan, {
    required Future<void> Function() onSensorAccepted,
  });
}

class UnsupportedCapabilityException implements Exception {
  UnsupportedCapabilityException(this.message);

  final String message;

  @override
  String toString() => 'UnsupportedCapabilityException: $message';
}
