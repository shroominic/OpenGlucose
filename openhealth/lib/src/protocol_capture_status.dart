import 'dart:async';
import 'dart:math';

import 'debug_shared_scan_transport.dart';
import 'local_ble_trace_sink.dart';

typedef ProtocolCaptureStatusWriter =
    Future<void> Function(Map<String, Object?> status);
typedef ProtocolCaptureHeartbeatCommit = Future<void> Function();
typedef ProtocolCaptureHeartbeatTimerFactory =
    Timer Function(Duration interval, void Function() callback);

/// Publishes non-sensitive, fail-closed health for the debug capture harness.
///
/// A periodic heartbeat runs while the scanner is running or deliberately
/// suspended for a connection, with a healthy committed trace. Suspension
/// remains ineligible for NFC readiness; it is not a recording failure.
final class ProtocolCaptureStatusPublisher {
  ProtocolCaptureStatusPublisher({
    required this.processSessionId,
    required DebugSharedScanTransport scanner,
    required LocalBleTraceSink sink,
    required ProtocolCaptureStatusWriter writer,
    required ProtocolCaptureHeartbeatCommit commitHeartbeat,
    Duration heartbeatInterval = const Duration(seconds: 2),
    DateTime Function()? utcNow,
    Duration Function()? monotonicNow,
    ProtocolCaptureHeartbeatTimerFactory? timerFactory,
  }) : _scanner = scanner,
       _sink = sink,
       _writer = writer,
       _commitHeartbeat = commitHeartbeat,
       _heartbeatInterval = heartbeatInterval,
       _utcNow = utcNow ?? _defaultUtcNow,
       _monotonicNow = monotonicNow ?? _newMonotonicClock(),
       _timerFactory = timerFactory ?? _defaultTimerFactory {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(processSessionId)) {
      throw ArgumentError.value(
        processSessionId,
        'processSessionId',
        'must contain only status-safe characters',
      );
    }
    if (heartbeatInterval <= Duration.zero) {
      throw ArgumentError.value(
        heartbeatInterval,
        'heartbeatInterval',
        'must be positive',
      );
    }
  }

  final String processSessionId;
  final DebugSharedScanTransport _scanner;
  final LocalBleTraceSink _sink;
  final ProtocolCaptureStatusWriter _writer;
  final ProtocolCaptureHeartbeatCommit _commitHeartbeat;
  final Duration _heartbeatInterval;
  final DateTime Function() _utcNow;
  final Duration Function() _monotonicNow;
  final ProtocolCaptureHeartbeatTimerFactory _timerFactory;

  Future<void> _transactionTail = Future<void>.value();
  StreamSubscription<DebugSharedScanState>? _scannerSubscription;
  StreamSubscription<LocalBleTraceSinkHealth>? _sinkSubscription;
  Timer? _heartbeatTimer;
  LocalBleTraceSinkState _lastSinkState = LocalBleTraceSinkState.notStarted;
  String? _lastSinkSessionToken;
  String? _lastSinkSegmentFileName;
  var _lastHeartbeatMonotonicMicroseconds = 0;
  var _started = false;
  var _stopping = false;

  bool get isReady =>
      !_stopping &&
      _scanner.state == DebugSharedScanState.running &&
      _hasHealthyTrace;

  bool get _hasHealthyTrace =>
      _sink.health.state == LocalBleTraceSinkState.healthy &&
      _sink.health.lastCommittedSequence != null &&
      _sink.health.lastCommittedAtUtc != null &&
      _sink.health.segmentFileName != null;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final initialSinkHealth = _sink.health;
    _lastSinkState = initialSinkHealth.state;
    _lastSinkSessionToken = initialSinkHealth.sessionToken;
    _lastSinkSegmentFileName = initialSinkHealth.segmentFileName;
    _scannerSubscription = _scanner.states.listen((_) {
      _refreshHeartbeat();
      _publishSafely();
    });
    _sinkSubscription = _sink.healthChanges.listen((health) {
      final priorState = _lastSinkState;
      final priorSessionToken = _lastSinkSessionToken;
      final priorSegmentFileName = _lastSinkSegmentFileName;
      _lastSinkState = health.state;
      _lastSinkSessionToken = health.sessionToken;
      _lastSinkSegmentFileName = health.segmentFileName;
      _refreshHeartbeat();
      if (priorState != LocalBleTraceSinkState.healthy ||
          health.state != LocalBleTraceSinkState.healthy ||
          priorSessionToken != health.sessionToken ||
          priorSegmentFileName != health.segmentFileName) {
        _publishSafely();
      }
    });
    _refreshHeartbeat();
    await _publishWithHealthProof();
  }

  Future<void> markStopping() async {
    if (!_started || _stopping) {
      return;
    }
    _stopping = true;
    _refreshHeartbeat();
    await _publishWithHealthProof(stopping: true);
  }

  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _stopping = true;
    _refreshHeartbeat();
    await _scannerSubscription?.cancel();
    await _sinkSubscription?.cancel();
    _scannerSubscription = null;
    _sinkSubscription = null;
    await _publishWithHealthProof(stopping: true);
    await _transactionTail;
    _started = false;
  }

  Map<String, Object?> snapshot({bool? stopping}) {
    final sinkHealth = _sink.health;
    final monotonicCandidate = _monotonicNow().inMicroseconds;
    final monotonicMicroseconds =
        monotonicCandidate > _lastHeartbeatMonotonicMicroseconds
        ? monotonicCandidate
        : _lastHeartbeatMonotonicMicroseconds + 1;
    _lastHeartbeatMonotonicMicroseconds = monotonicMicroseconds;
    return <String, Object?>{
      'processSessionId': processSessionId,
      'bleTraceSessionId': sinkHealth.sessionToken,
      'bleTraceFileName': sinkHealth.segmentFileName,
      'scannerState': _scannerStateName(_scanner.state),
      'scannerServiceUuids': _scanner.physicalServiceUuids,
      'sinkState': _sinkStateName(sinkHealth.state),
      'lastCommittedBleSequence': sinkHealth.lastCommittedSequence,
      'lastCommittedBleRecordedAtUtc': sinkHealth.lastCommittedAtUtc
          ?.toUtc()
          .toIso8601String(),
      'capacityReached': sinkHealth.capacityReached,
      'sinkErrorCode': sinkHealth.errorCode,
      'heartbeatAtUtc': _utcNow().toUtc().toIso8601String(),
      'heartbeatMonotonicMicroseconds': monotonicMicroseconds,
      'stopping': stopping ?? _stopping,
    };
  }

  void _refreshHeartbeat() {
    if (!_stopping &&
        _hasHealthyTrace &&
        (_scanner.state == DebugSharedScanState.running ||
            _scanner.state == DebugSharedScanState.suspended)) {
      _heartbeatTimer ??= _timerFactory(
        _heartbeatInterval,
        _publishSafely,
      );
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _publishSafely() {
    unawaited(
      _publishWithHealthProof().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A failed status write leaves the last file stale. Harness freshness
          // checks therefore fail closed without exposing native error text.
        },
      ),
    );
  }

  Future<void> _publishWithHealthProof({bool? stopping}) {
    final operation = _transactionTail.then((_) async {
      if (_sink.health.state == LocalBleTraceSinkState.healthy) {
        await _commitHeartbeat();
      }
      await _writer(snapshot(stopping: stopping));
    });
    _transactionTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static DateTime _defaultUtcNow() => DateTime.now().toUtc();

  static Duration Function() _newMonotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  static Timer _defaultTimerFactory(
    Duration interval,
    void Function() callback,
  ) => Timer.periodic(interval, (_) => callback());
}

String _scannerStateName(DebugSharedScanState state) => switch (state) {
  DebugSharedScanState.notStarted => 'not_started',
  DebugSharedScanState.starting => 'starting',
  DebugSharedScanState.running => 'running',
  DebugSharedScanState.suspended => 'suspended',
  DebugSharedScanState.error => 'error',
  DebugSharedScanState.stopped => 'stopped',
};

String _sinkStateName(LocalBleTraceSinkState state) => switch (state) {
  LocalBleTraceSinkState.notStarted => 'not_started',
  LocalBleTraceSinkState.healthy => 'healthy',
  LocalBleTraceSinkState.capacityReached => 'capacity_reached',
  LocalBleTraceSinkState.writeError => 'write_error',
  LocalBleTraceSinkState.closed => 'closed',
};

String newProtocolCaptureProcessSessionId() {
  final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
  final random = Random.secure();
  final suffix = List<int>.generate(
    12,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '$timestamp-$suffix';
}
