import 'dart:async';

import 'ble_failure.dart';
import 'ble_transport.dart';

/// The schema version emitted by [BleTraceEvent.toSensitiveJson].
const int bleTraceSchemaVersion = 1;

typedef BleTraceUtcClock = DateTime Function();
typedef BleTraceMonotonicClock = Duration Function();
typedef _BleTraceDataBuilder = Map<String, Object?> Function();

enum BleTraceOperation {
  captureHeartbeat,
  scan,
  connect,
  connectionState,
  ensureBonded,
  currentBondState,
  requestMtu,
  discoverServices,
  read,
  write,
  setNotify,
  notifications,
  removeBond,
  disconnect,
}

enum BleTraceEventType {
  captureHeartbeat,
  operationStarted,
  operationSucceeded,
  operationFailed,
  advertisement,
  connectionState,
  notificationData,
  streamCompleted,
  streamCancelled,
  streamCancellationFailed,
  streamFailed,
}

/// One immutable, ordered event from a BLE protocol trace.
///
/// Every event is sensitive. [data] can contain device identifiers, sensor
/// names, advertisements, service topology, and raw protocol bytes. Keep it in
/// app-private storage and never send it to a console or general-purpose log.
final class BleTraceEvent {
  BleTraceEvent({
    required this.sequence,
    required this.correlationId,
    required DateTime recordedAtUtc,
    required this.monotonicElapsed,
    required this.type,
    required this.operation,
    Map<String, Object?> data = const <String, Object?>{},
  }) : recordedAtUtc = recordedAtUtc.toUtc(),
       data = _snapshotMap(data);

  final int sequence;
  final String correlationId;
  final DateTime recordedAtUtc;
  final Duration monotonicElapsed;
  final BleTraceEventType type;
  final BleTraceOperation operation;
  final Map<String, Object?> data;

  /// Returns the versioned representation for an explicitly sensitive sink.
  ///
  /// The returned map contains raw BLE data. Do not print it or include it in
  /// ordinary application diagnostics.
  Map<String, Object?> toSensitiveJson() => <String, Object?>{
    'schema_version': bleTraceSchemaVersion,
    'sequence': sequence,
    'correlation_id': correlationId,
    'recorded_at_utc': recordedAtUtc.toIso8601String(),
    'monotonic_elapsed_microseconds': monotonicElapsed.inMicroseconds,
    'event_type': type.name,
    'operation': operation.name,
    'data': _snapshotMap(data),
  };

  @override
  String toString() =>
      'BleTraceEvent(schemaVersion: $bleTraceSchemaVersion, '
      'sequence: $sequence, type: ${type.name}, operation: ${operation.name}, '
      'sensitiveData: <redacted>)';
}

/// An append-only destination for sensitive BLE trace events.
///
/// Ordinary BLE diagnostics do not await this method. They ignore both
/// synchronous and asynchronous sink failures so diagnostics cannot change
/// BLE behavior. An explicit capture-health proof can await the same append
/// path without changing a BLE operation result.
abstract interface class BleTraceSink {
  FutureOr<void> append(BleTraceEvent event);
}

/// Adds sensitive protocol tracing to another [BleTransport].
final class RecordingBleTransport
    implements BleTransport, BleSingleAttemptTransport {
  factory RecordingBleTransport({
    required BleTransport delegate,
    required BleTraceSink sink,
    BleTraceUtcClock? utcNow,
    BleTraceMonotonicClock? monotonicNow,
  }) {
    return RecordingBleTransport._(
      delegate,
      _BleTraceRecorder.create(
        sink: sink,
        utcNow: utcNow,
        monotonicNow: monotonicNow,
      ),
    );
  }

  RecordingBleTransport._(this._delegate, this._recorder);

  final BleTransport _delegate;
  final _BleTraceRecorder _recorder;

  @override
  bool get supportsSingleAttemptConnect {
    final delegate = _delegate;
    return delegate is BleSingleAttemptTransport &&
        delegate.supportsSingleAttemptConnect;
  }

  /// Durably proves that the current trace sink can still append.
  ///
  /// This event shares the recorder sequence and clocks used by BLE events.
  /// Unlike diagnostic recording around BLE operations, sink failure is
  /// reported to this explicit health caller. It never changes BLE behavior.
  Future<void> recordCaptureHeartbeat() {
    return _recorder.recordAndWait(
      type: BleTraceEventType.captureHeartbeat,
      operation: BleTraceOperation.captureHeartbeat,
      correlationId: _recorder.nextCorrelationId(),
    );
  }

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    final correlationId = _recorder.nextCorrelationId();
    _recorder.record(
      type: BleTraceEventType.operationStarted,
      operation: BleTraceOperation.scan,
      correlationId: correlationId,
      data: () => <String, Object?>{
        'timeout_microseconds': timeout?.inMicroseconds,
        'allow_duplicates': allowDuplicates,
        'with_services': withServices == null
            ? null
            : List<String>.of(withServices),
      },
    );

    late final Stream<BleScanResult> source;
    try {
      source = _delegate.scan(
        timeout: timeout,
        allowDuplicates: allowDuplicates,
        withServices: withServices,
      );
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.streamFailed,
        operation: BleTraceOperation.scan,
        correlationId: correlationId,
        error: error,
      );
      rethrow;
    }

    return _recordedScanStream(
      source: source,
      recorder: _recorder,
      correlationId: correlationId,
    );
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => _connect(deviceId, timeout: timeout, singleAttempt: false);

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => _connect(deviceId, timeout: timeout, singleAttempt: true);

  Future<BleConnection> _connect(
    String deviceId, {
    required Duration timeout,
    required bool singleAttempt,
  }) async {
    final correlationId = _recorder.nextCorrelationId();
    _recorder.record(
      type: BleTraceEventType.operationStarted,
      operation: BleTraceOperation.connect,
      correlationId: correlationId,
      data: () => <String, Object?>{
        'device_id': deviceId,
        'timeout_microseconds': timeout.inMicroseconds,
      },
    );

    try {
      final delegate = _delegate;
      final BleConnection connection;
      if (singleAttempt) {
        if (delegate is! BleSingleAttemptTransport ||
            !delegate.supportsSingleAttemptConnect) {
          throw UnsupportedError('Single-attempt connection is unavailable.');
        }
        connection = await delegate.connectOnce(deviceId, timeout: timeout);
      } else {
        connection = await delegate.connect(deviceId, timeout: timeout);
      }
      _recorder.record(
        type: BleTraceEventType.operationSucceeded,
        operation: BleTraceOperation.connect,
        correlationId: correlationId,
        data: () => <String, Object?>{'device_id': connection.deviceId},
      );
      return RecordingBleConnection._(connection, _recorder, correlationId);
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.operationFailed,
        operation: BleTraceOperation.connect,
        correlationId: correlationId,
        error: error,
      );
      rethrow;
    }
  }
}

Stream<BleScanResult> _recordedScanStream({
  required Stream<BleScanResult> source,
  required _BleTraceRecorder recorder,
  required String correlationId,
}) {
  return _RecordedTraceStream<BleScanResult>(
    source: source,
    recorder: recorder,
    operation: BleTraceOperation.scan,
    correlationId: correlationId,
    recordData: (result) {
      recorder.record(
        type: BleTraceEventType.advertisement,
        operation: BleTraceOperation.scan,
        correlationId: correlationId,
        data: () => _scanResultData(result),
      );
    },
  );
}

final class _RecordedTraceStream<T> extends Stream<T> {
  const _RecordedTraceStream({
    required Stream<T> source,
    required _BleTraceRecorder recorder,
    required BleTraceOperation operation,
    required String correlationId,
    required void Function(T value) recordData,
    _BleTraceDataBuilder? terminalData,
  }) : _source = source,
       _recorder = recorder,
       _operation = operation,
       _correlationId = correlationId,
       _recordData = recordData,
       _terminalData = terminalData;

  final Stream<T> _source;
  final _BleTraceRecorder _recorder;
  final BleTraceOperation _operation;
  final String _correlationId;
  final void Function(T value) _recordData;
  final _BleTraceDataBuilder? _terminalData;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final lifecycle = _TraceStreamLifecycle(
      recorder: _recorder,
      operation: _operation,
      correlationId: _correlationId,
      terminalData: _terminalData,
    );
    final transformed = _source.transform(
      StreamTransformer<T, T>.fromHandlers(
        handleData: (value, sink) {
          _recordData(value);
          sink.add(value);
        },
        handleError: (error, stackTrace, sink) {
          lifecycle.recordError(error);
          sink.addError(error, stackTrace);
        },
        handleDone: (sink) {
          lifecycle.recordDone();
          sink.close();
        },
      ),
    );
    final subscription = transformed.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _RecordingTraceSubscription<T>(subscription, lifecycle);
  }
}

final class _TraceStreamLifecycle {
  _TraceStreamLifecycle({
    required this.recorder,
    required this.operation,
    required this.correlationId,
    required this.terminalData,
  });

  final _BleTraceRecorder recorder;
  final BleTraceOperation operation;
  final String correlationId;
  final _BleTraceDataBuilder? terminalData;

  var _state = 0;

  void beginCancellation() {
    if (_state == 0) {
      _state = 1;
    }
  }

  void recordDone() {
    if (_state != 0) {
      return;
    }
    _state = 2;
    recorder.record(
      type: BleTraceEventType.streamCompleted,
      operation: operation,
      correlationId: correlationId,
      data: terminalData,
    );
  }

  void recordError(Object error) {
    recorder.recordFailure(
      type: BleTraceEventType.streamFailed,
      operation: operation,
      correlationId: correlationId,
      error: error,
      data: terminalData,
    );
  }

  void recordCancellation() {
    if (_state != 1) {
      return;
    }
    _state = 2;
    recorder.record(
      type: BleTraceEventType.streamCancelled,
      operation: operation,
      correlationId: correlationId,
      data: terminalData,
    );
  }

  void recordCancellationFailure(Object error) {
    if (_state != 1) {
      return;
    }
    _state = 2;
    recorder.recordFailure(
      type: BleTraceEventType.streamCancellationFailed,
      operation: operation,
      correlationId: correlationId,
      error: error,
      data: terminalData,
    );
  }
}

final class _RecordingTraceSubscription<T> implements StreamSubscription<T> {
  _RecordingTraceSubscription(this._delegate, this._lifecycle);

  final StreamSubscription<T> _delegate;
  final _TraceStreamLifecycle _lifecycle;
  Future<void>? _cancellation;

  @override
  Future<void> cancel() => _cancellation ??= _cancelOnce();

  Future<void> _cancelOnce() async {
    _lifecycle.beginCancellation();
    try {
      await _delegate.cancel();
      _lifecycle.recordCancellation();
    } catch (error, stackTrace) {
      _lifecycle.recordCancellationFailure(error);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture<E>(futureValue);
}

/// Adds sensitive protocol tracing to an existing [BleConnection].
final class RecordingBleConnection implements BleConnection, BleNegotiatedMtu {
  factory RecordingBleConnection({
    required BleConnection delegate,
    required BleTraceSink sink,
    BleTraceUtcClock? utcNow,
    BleTraceMonotonicClock? monotonicNow,
  }) {
    final recorder = _BleTraceRecorder.create(
      sink: sink,
      utcNow: utcNow,
      monotonicNow: monotonicNow,
    );
    return RecordingBleConnection._(
      delegate,
      recorder,
      recorder.nextCorrelationId(),
    );
  }

  RecordingBleConnection._(
    this._delegate,
    this._recorder,
    this._connectionCorrelationId,
  );

  final BleConnection _delegate;
  final _BleTraceRecorder _recorder;
  final String _connectionCorrelationId;
  final Map<String, String> _notificationCorrelationIds = <String, String>{};

  Stream<BleConnectionState>? _recordedConnectionStates;

  @override
  String get deviceId => _delegate.deviceId;

  @override
  Stream<BleConnectionState> get connectionStates =>
      _recordedConnectionStates ??= _createConnectionStateStream();

  Stream<BleConnectionState> _createConnectionStateStream() {
    late final Stream<BleConnectionState> source;
    try {
      source = _delegate.connectionStates;
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.streamFailed,
        operation: BleTraceOperation.connectionState,
        correlationId: _connectionCorrelationId,
        error: error,
      );
      rethrow;
    }

    return _RecordedTraceStream<BleConnectionState>(
      source: source,
      recorder: _recorder,
      operation: BleTraceOperation.connectionState,
      correlationId: _connectionCorrelationId,
      recordData: (state) {
        _recorder.record(
          type: BleTraceEventType.connectionState,
          operation: BleTraceOperation.connectionState,
          correlationId: _connectionCorrelationId,
          data: () => <String, Object?>{
            'device_id': _delegate.deviceId,
            'state': state.name,
          },
        );
      },
      terminalData: _connectionData,
    );
  }

  @override
  bool get supportsBondLifecycle => _delegate.supportsBondLifecycle;

  @override
  int? get negotiatedMtu => switch (_delegate) {
    final BleNegotiatedMtu capable => capable.negotiatedMtu,
    _ => null,
  };

  @override
  Future<void> ensureBonded() => _runVoidOperation(
    BleTraceOperation.ensureBonded,
    action: _delegate.ensureBonded,
  );

  @override
  Future<BleBondState> currentBondState() => _runValueOperation<BleBondState>(
    BleTraceOperation.currentBondState,
    action: _delegate.currentBondState,
    successData: (state) => <String, Object?>{'state': state.name},
  );

  @override
  Future<void> requestMtu(int mtu) => _runVoidOperation(
    BleTraceOperation.requestMtu,
    startData: () => <String, Object?>{'mtu': mtu},
    action: () => _delegate.requestMtu(mtu),
  );

  @override
  Future<List<BleService>> discoverServices() =>
      _runValueOperation<List<BleService>>(
        BleTraceOperation.discoverServices,
        action: _delegate.discoverServices,
        successData: (services) => <String, Object?>{
          'services': services.map(_serviceData).toList(growable: false),
        },
      );

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) =>
      _runValueOperation<List<int>>(
        BleTraceOperation.read,
        startData: () => _characteristicData(characteristic),
        action: () => _delegate.read(characteristic),
        successData: (value) => <String, Object?>{
          ..._characteristicData(characteristic),
          'bytes': List<int>.of(value),
        },
      );

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) => _runVoidOperation(
    BleTraceOperation.write,
    startData: () => <String, Object?>{
      ..._characteristicData(characteristic),
      'bytes': List<int>.of(value),
      'without_response': withoutResponse,
    },
    action: () => _delegate.write(
      characteristic,
      value,
      withoutResponse: withoutResponse,
    ),
  );

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    final key = _characteristicKey(characteristic);
    final correlationId = enabled
        ? _recorder.nextCorrelationId()
        : _notificationCorrelationIds[key] ?? _recorder.nextCorrelationId();
    _recorder.record(
      type: BleTraceEventType.operationStarted,
      operation: BleTraceOperation.setNotify,
      correlationId: correlationId,
      data: () => <String, Object?>{
        ..._connectionData(),
        ..._characteristicData(characteristic),
        'enabled': enabled,
      },
    );

    try {
      await _delegate.setNotify(characteristic, enabled);
      if (enabled) {
        _notificationCorrelationIds[key] = correlationId;
      } else {
        _notificationCorrelationIds.remove(key);
      }
      _recorder.record(
        type: BleTraceEventType.operationSucceeded,
        operation: BleTraceOperation.setNotify,
        correlationId: correlationId,
        data: () => <String, Object?>{
          ..._connectionData(),
          ..._characteristicData(characteristic),
          'enabled': enabled,
        },
      );
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.operationFailed,
        operation: BleTraceOperation.setNotify,
        correlationId: correlationId,
        error: error,
        data: () => <String, Object?>{
          ..._connectionData(),
          ..._characteristicData(characteristic),
          'enabled': enabled,
        },
      );
      rethrow;
    }
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) {
    final key = _characteristicKey(characteristic);
    final correlationId =
        _notificationCorrelationIds[key] ?? _recorder.nextCorrelationId();

    late final Stream<List<int>> source;
    try {
      source = _delegate.notifications(characteristic);
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.streamFailed,
        operation: BleTraceOperation.notifications,
        correlationId: correlationId,
        error: error,
        data: () => <String, Object?>{
          ..._connectionData(),
          ..._characteristicData(characteristic),
        },
      );
      rethrow;
    }

    return _RecordedTraceStream<List<int>>(
      source: source,
      recorder: _recorder,
      operation: BleTraceOperation.notifications,
      correlationId: correlationId,
      recordData: (value) {
        _recorder.record(
          type: BleTraceEventType.notificationData,
          operation: BleTraceOperation.notifications,
          correlationId: correlationId,
          data: () => <String, Object?>{
            ..._connectionData(),
            ..._characteristicData(characteristic),
            'bytes': List<int>.of(value),
          },
        );
      },
      terminalData: () => <String, Object?>{
        ..._connectionData(),
        ..._characteristicData(characteristic),
      },
    );
  }

  @override
  Future<void> removeBond() => _runVoidOperation(
    BleTraceOperation.removeBond,
    action: _delegate.removeBond,
  );

  @override
  Future<void> disconnect() => _runVoidOperation(
    BleTraceOperation.disconnect,
    action: _delegate.disconnect,
  );

  Future<void> _runVoidOperation(
    BleTraceOperation operation, {
    _BleTraceDataBuilder? startData,
    required Future<void> Function() action,
  }) async {
    final correlationId = _recorder.nextCorrelationId();
    _recorder.record(
      type: BleTraceEventType.operationStarted,
      operation: operation,
      correlationId: correlationId,
      data: () => <String, Object?>{
        ..._connectionData(),
        ...?startData?.call(),
      },
    );

    try {
      await action();
      _recorder.record(
        type: BleTraceEventType.operationSucceeded,
        operation: operation,
        correlationId: correlationId,
        data: _connectionData,
      );
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.operationFailed,
        operation: operation,
        correlationId: correlationId,
        error: error,
        data: _connectionData,
      );
      rethrow;
    }
  }

  Future<T> _runValueOperation<T>(
    BleTraceOperation operation, {
    _BleTraceDataBuilder? startData,
    required Future<T> Function() action,
    required Map<String, Object?> Function(T value) successData,
  }) async {
    final correlationId = _recorder.nextCorrelationId();
    _recorder.record(
      type: BleTraceEventType.operationStarted,
      operation: operation,
      correlationId: correlationId,
      data: () => <String, Object?>{
        ..._connectionData(),
        ...?startData?.call(),
      },
    );

    try {
      final value = await action();
      _recorder.record(
        type: BleTraceEventType.operationSucceeded,
        operation: operation,
        correlationId: correlationId,
        data: () => <String, Object?>{
          ..._connectionData(),
          ...successData(value),
        },
      );
      return value;
    } catch (error) {
      _recorder.recordFailure(
        type: BleTraceEventType.operationFailed,
        operation: operation,
        correlationId: correlationId,
        error: error,
        data: _connectionData,
      );
      rethrow;
    }
  }

  Map<String, Object?> _connectionData() => <String, Object?>{
    'device_id': _delegate.deviceId,
  };
}

final class _BleTraceRecorder {
  _BleTraceRecorder({
    required BleTraceSink sink,
    required BleTraceUtcClock utcNow,
    required BleTraceMonotonicClock monotonicNow,
  }) : _sink = sink,
       _utcNow = utcNow,
       _monotonicNow = monotonicNow;

  factory _BleTraceRecorder.create({
    required BleTraceSink sink,
    BleTraceUtcClock? utcNow,
    BleTraceMonotonicClock? monotonicNow,
  }) {
    final stopwatch = Stopwatch()..start();
    return _BleTraceRecorder(
      sink: sink,
      utcNow: utcNow ?? () => DateTime.now().toUtc(),
      monotonicNow: monotonicNow ?? () => stopwatch.elapsed,
    );
  }

  final BleTraceSink _sink;
  final BleTraceUtcClock _utcNow;
  final BleTraceMonotonicClock _monotonicNow;

  int _sequence = 0;
  int _correlationSequence = 0;

  String nextCorrelationId() => 'c${++_correlationSequence}';

  void record({
    required BleTraceEventType type,
    required BleTraceOperation operation,
    required String correlationId,
    _BleTraceDataBuilder? data,
  }) {
    try {
      final event = BleTraceEvent(
        sequence: ++_sequence,
        correlationId: correlationId,
        recordedAtUtc: _utcNow(),
        monotonicElapsed: _monotonicNow(),
        type: type,
        operation: operation,
        data: data?.call() ?? const <String, Object?>{},
      );
      unawaited(
        Future<void>.sync(
          () => _sink.append(event),
        ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } catch (_) {
      // Trace collection is diagnostic-only and must never change BLE flow.
    }
  }

  Future<void> recordAndWait({
    required BleTraceEventType type,
    required BleTraceOperation operation,
    required String correlationId,
    _BleTraceDataBuilder? data,
  }) async {
    final event = BleTraceEvent(
      sequence: ++_sequence,
      correlationId: correlationId,
      recordedAtUtc: _utcNow(),
      monotonicElapsed: _monotonicNow(),
      type: type,
      operation: operation,
      data: data?.call() ?? const <String, Object?>{},
    );
    await _sink.append(event);
  }

  void recordFailure({
    required BleTraceEventType type,
    required BleTraceOperation operation,
    required String correlationId,
    required Object error,
    _BleTraceDataBuilder? data,
  }) {
    record(
      type: type,
      operation: operation,
      correlationId: correlationId,
      data: () => <String, Object?>{
        ...?data?.call(),
        'failure': _failureData(error),
      },
    );
  }
}

Map<String, Object?> _scanResultData(BleScanResult result) => <String, Object?>{
  if (result.observedAt != null)
    'observed_at_utc': result.observedAt!.toUtc().toIso8601String(),
  'device_id': result.deviceId,
  'device_name': result.deviceName,
  'rssi': result.rssi,
  'service_uuids': List<String>.of(result.serviceUuids),
  'manufacturer_data': result.manufacturerData
      .map(
        (entry) => <String, Object?>{
          'company_id': entry.companyId,
          'bytes': List<int>.of(entry.bytes),
        },
      )
      .toList(growable: false),
  'service_data': <String, Object?>{
    for (final entry in result.serviceData.entries)
      entry.key: List<int>.of(entry.value),
  },
};

Map<String, Object?> _serviceData(BleService service) => <String, Object?>{
  'uuid': service.uuid,
  'characteristics': service.characteristics
      .map(_characteristicData)
      .toList(growable: false),
};

Map<String, Object?> _characteristicData(
  BleCharacteristicRef characteristic,
) => <String, Object?>{
  'service_uuid': characteristic.serviceUuid,
  'characteristic_uuid': characteristic.characteristicUuid,
  'properties': <String, Object?>{
    'read': characteristic.properties.read,
    'write': characteristic.properties.write,
    'write_without_response': characteristic.properties.writeWithoutResponse,
    'notify': characteristic.properties.notify,
    'indicate': characteristic.properties.indicate,
  },
};

String _characteristicKey(BleCharacteristicRef characteristic) =>
    '${characteristic.serviceUuid}/${characteristic.characteristicUuid}';

Map<String, Object?> _failureData(Object error) {
  if (error case BleFailure failure) {
    return <String, Object?>{
      'classification': 'ble_failure',
      'kind': failure.kind.name,
      'operation': failure.operation.name,
      'diagnostic_code': failure.diagnosticCode,
    };
  }
  return const <String, Object?>{'classification': 'unclassified'};
}

Map<String, Object?> _snapshotMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final entry in source.entries)
        entry.key: _snapshotValue(entry.value),
    });

Object? _snapshotValue(Object? value) {
  return switch (value) {
    null || bool() || num() || String() => value,
    List<Object?>() => List<Object?>.unmodifiable(value.map(_snapshotValue)),
    Map<String, Object?>() => _snapshotMap(value),
    _ => throw ArgumentError.value(
      value,
      'value',
      'BLE trace data must use JSON-compatible value types',
    ),
  };
}
