import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('surfaces a debounced history persistence failure', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failSetPrefix: 'openHealth.history.',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);

    await controller.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(controller.lastError, contains('Saving history failed'));
    expect(controller.lastError, contains('StateError'));
    expect(
      controller.logs.any(
        (entry) => entry.message.contains('Saving history failed'),
      ),
      isTrue,
    );

    await controller.disconnect(clearSelection: false);
    controller.dispose();
  });

  test('does not report a failed history deletion as successful', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failRemovePrefix: 'openHealth.history.',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);

    final cleared = await controller.clearPersistedHistory();

    expect(cleared, isFalse);
    expect(store.removeAttempts, contains('openHealth.history.demo:07A12'));
    expect(controller.lastError, contains('Clearing stored history failed'));

    await controller.disconnect(clearSelection: false);
    controller.dispose();
  });

  test(
    'a history write does not clear an unrelated deletion failure',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore(
        failRemovePrefix: 'openHealth.history.',
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ProductionTestDriver(),
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(await controller.clearPersistedHistory(), isFalse);
      expect(controller.lastError, contains('Clearing stored history failed'));

      await controller.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(controller.lastError, contains('Clearing stored history failed'));

      await controller.disconnect(clearSelection: false);
      controller.dispose();
    },
  );

  test(
    'disconnect still clears private state when BLE teardown fails',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _DisconnectFailingDriver(),
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(store.getString('openHealth.lastSensor'), isNotNull);

      await controller.disconnect();

      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(controller.snapshot, isNull);
      expect(
        controller.lastError,
        contains('Disconnecting sensor session failed'),
      );
      expect(
        controller.logs.any(
          (entry) => entry.message.contains(
            'Disconnecting sensor session failed (StateError)',
          ),
        ),
        isTrue,
      );
      controller.dispose();
    },
  );
}

class _ProductionTestDriver implements CgmDriver {
  final DemoCgmDriver _delegate = DemoCgmDriver();

  @override
  String get driverId => _delegate.driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    return _delegate.scan(
      timeout: timeout,
      allowDuplicates: allowDuplicates,
    );
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    return _delegate.connect(sensor);
  }
}

class _DisconnectFailingDriver extends _ProductionTestDriver {
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    return _DisconnectFailingSession(await super.connect(sensor));
  }
}

class _DisconnectFailingSession implements CgmSession {
  _DisconnectFailingSession(this._delegate);

  final CgmSession _delegate;

  @override
  CgmSessionSnapshot get currentSnapshot => _delegate.currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => _delegate.logs;

  @override
  DiscoveredSensor get sensor => _delegate.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _delegate.snapshots;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => _delegate.unsafeAdmin;

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() {
    return _delegate.fetchCalibrations();
  }

  @override
  Future<void> refresh() => _delegate.refresh();

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() {
    return _delegate.refreshDiagnostics();
  }

  @override
  Future<void> refreshLiveData() => _delegate.refreshLiveData();

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) {
    return _delegate.submitCalibration(
      glucoseMgdl: glucoseMgdl,
      sensorMinute: sensorMinute,
      recordedAt: recordedAt,
    );
  }

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) {
    return _delegate.syncHistory(
      includeRawHistory: includeRawHistory,
      requestedStartOffset: requestedStartOffset,
    );
  }

  @override
  Future<void> disconnect() async {
    await _delegate.disconnect();
    throw StateError('simulated BLE teardown failure');
  }
}

class _ControllableHealthStateStore implements HealthStateStore {
  _ControllableHealthStateStore({this.failSetPrefix, this.failRemovePrefix});

  final String? failSetPrefix;
  final String? failRemovePrefix;
  final Map<String, String> _values = <String, String>{};
  final List<String> removeAttempts = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    if (failSetPrefix case final prefix? when key.startsWith(prefix)) {
      throw StateError('simulated restricted-state write failure');
    }
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    removeAttempts.add(key);
    if (failRemovePrefix case final prefix? when key.startsWith(prefix)) {
      throw StateError('simulated restricted-state delete failure');
    }
    _values.remove(key);
  }
}
