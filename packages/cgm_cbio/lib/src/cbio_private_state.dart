/// Restricted persistence for the driver's sensor-bound raw state.
///
/// Envelopes are opaque to composition code and are never normalized glucose.
/// A successful write must mean the complete envelope is durable atomically.
abstract interface class CbioPrivateStateStore {
  Future<String?> read(String sensorKey);

  Future<void> write(String sensorKey, String envelope);
}

/// Optional opaque complete-input persistence; no normalized or raw API rows.
/// A completed write must atomically persist the entire sensor-bound envelope.
abstract interface class CbioFullRecordStore implements CbioPrivateStateStore {
  Future<String?> readFullRecords(String sensorKey);

  Future<void> writeFullRecords(String sensorKey, String envelope);

  /// Lowercase SHA256 of the exact original envelope encoded as UTF8.
  String legacySha256(String legacyEnvelope);
}
