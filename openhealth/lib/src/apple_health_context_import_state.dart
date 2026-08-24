import 'dart:collection';

/// The durable, local-only cursor state for Apple Health context import.
///
/// This state intentionally lives outside the restricted sensor/glucose-state
/// schema. It contains HealthKit anchors and timestamps, so an older app must
/// leave an unknown future version untouched instead of trying to migrate it.
class AppleHealthContextImportState {
  AppleHealthContextImportState({
    this.lastSyncedAt,
    Map<String, String> anchors = const <String, String>{},
  }) : anchors = UnmodifiableMapView<String, String>(
         Map<String, String>.of(anchors),
       );

  final DateTime? lastSyncedAt;
  final Map<String, String> anchors;
}

/// Dedicated persistence boundary for Apple Health import cursors.
///
/// Production iOS uses a versioned, backup-excluded file implementation. The
/// interface deliberately has no generic key/value operations so the import
/// state cannot expand the restricted sensor/glucose-state schema by accident.
abstract interface class AppleHealthContextImportStateStore {
  Future<void> initialize();

  AppleHealthContextImportState get state;

  Future<void> save(AppleHealthContextImportState state);
}

/// In-memory implementation used for unsupported platforms and deterministic
/// tests. Apple Health is iOS-only; it is never selected for an iOS import.
class InMemoryAppleHealthContextImportStateStore
    implements AppleHealthContextImportStateStore {
  AppleHealthContextImportState _state = AppleHealthContextImportState();
  bool _initialized = false;

  @override
  AppleHealthContextImportState get state {
    if (!_initialized) {
      throw StateError('Apple Health import state is not initialized.');
    }
    return _state;
  }

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<void> save(AppleHealthContextImportState state) async {
    if (!_initialized) {
      throw StateError('Apple Health import state is not initialized.');
    }
    _state = AppleHealthContextImportState(
      lastSyncedAt: state.lastSyncedAt,
      anchors: state.anchors,
    );
  }
}
