/// Restricted persistence for the driver's sensor-bound raw state.
///
/// Envelopes are opaque to composition code and are never normalized glucose.
/// A successful write must mean the complete envelope is durable atomically.
abstract interface class CbioPrivateStateStore {
  Future<String?> read(String sensorKey);

  Future<void> write(String sensorKey, String envelope);
}
