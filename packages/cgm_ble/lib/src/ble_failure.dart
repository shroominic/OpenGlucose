enum BleFailureKind {
  permissionRequired,
  bluetoothOff,
  bluetoothUnavailable,
  bondRejected,
  bondTimedOut,
  sensorPossiblyInUse,
  deviceDisconnected,
  operationTimedOut,
  unexpected,
}

enum BleOperation {
  adapter,
  scan,
  connect,
  discoverServices,
  bond,
  requestMtu,
  read,
  write,
  subscribe,
  removeBond,
  disconnect,
}

const bleFailureKindMetadataKey = 'cgm.ble.failure.kind';
const bleFailureOperationMetadataKey = 'cgm.ble.failure.operation';
const bleFailureDiagnosticCodeMetadataKey = 'cgm.ble.failure.diagnosticCode';

/// A platform-neutral, identifier-free description of a BLE failure.
///
/// Native/plugin exception descriptions can contain device identifiers. BLE
/// adapters should translate them into this type before errors cross the
/// transport boundary. [diagnosticCode] is restricted to a small safe
/// character set so it can be retained in local diagnostics without copying
/// a native error message.
class BleFailure implements Exception {
  BleFailure({
    required this.kind,
    required this.operation,
    required String diagnosticCode,
  }) : diagnosticCode = _sanitizeDiagnosticCode(diagnosticCode);

  final BleFailureKind kind;
  final BleOperation operation;
  final String diagnosticCode;

  bool get allowsAutomaticRetry => switch (kind) {
    BleFailureKind.deviceDisconnected ||
    BleFailureKind.operationTimedOut => true,
    _ => false,
  };

  Map<String, String> toMetadata() => <String, String>{
    bleFailureKindMetadataKey: kind.name,
    bleFailureOperationMetadataKey: operation.name,
    bleFailureDiagnosticCodeMetadataKey: diagnosticCode,
  };

  static BleFailure? fromMetadata(Map<String, String> metadata) {
    final kindName = metadata[bleFailureKindMetadataKey];
    final operationName = metadata[bleFailureOperationMetadataKey];
    if (kindName == null || operationName == null) {
      return null;
    }
    final kind = _enumByName(BleFailureKind.values, kindName);
    final operation = _enumByName(BleOperation.values, operationName);
    if (kind == null || operation == null) {
      return null;
    }
    return BleFailure(
      kind: kind,
      operation: operation,
      diagnosticCode:
          metadata[bleFailureDiagnosticCodeMetadataKey] ?? 'ble.unknown',
    );
  }

  @override
  String toString() =>
      'BleFailure(${kind.name}, ${operation.name}, $diagnosticCode)';
}

T? _enumByName<T extends Enum>(Iterable<T> values, String name) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return null;
}

String _sanitizeDiagnosticCode(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty ||
      normalized.length > 96 ||
      !RegExp(r'^[a-z0-9._-]+$').hasMatch(normalized)) {
    return 'ble.redacted';
  }
  return normalized;
}
