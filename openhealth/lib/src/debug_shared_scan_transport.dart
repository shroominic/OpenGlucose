import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';

typedef DebugPhysicalScanActive = bool Function();
typedef DebugPhysicalScanAttempt = int Function();
typedef DebugScanRetryDelay = Future<void> Function(Duration duration);

enum DebugSharedScanState {
  notStarted,
  starting,
  running,
  suspended,
  error,
  stopped,
}

/// Debug-only BLE transport that owns one process-wide physical scanner.
///
/// [physicalServiceUuids] is a fixed union containing the passive capture
/// service and every service used by the wrapped app driver. Logical callers
/// receive only their requested services, while the recording delegate sees
/// every physical advertisement. Default connections pause only during setup.
/// Single-attempt connections keep the scanner paused until their connection
/// cleanup is confirmed. Uncertain cleanup permanently quarantines ownership.
/// Exhausting physical scan recovery fails all logical scans. This transport
/// instance cannot restart that exhausted scanner or hide it behind a timeout.
///
/// [unfilteredPhysicalScan] is an explicit debug-only escape hatch for a
/// passive target whose advertisements cannot be selected reliably by an
/// advertised service UUID. It requires an empty service list. This keeps an
/// empty list from silently changing a filtered capture into a broad scan.
final class DebugSharedScanTransport implements BleSingleAttemptTransport {
  DebugSharedScanTransport({
    required BleTransport delegate,
    required List<String> physicalServiceUuids,
    this.unfilteredPhysicalScan = false,
    required Stream<bool> physicalScanStates,
    required DebugPhysicalScanActive physicalScanIsActive,
    required Stream<int> physicalScanStartAcknowledgements,
    required DebugPhysicalScanAttempt physicalScanAttempt,
    DebugScanRetryDelay? retryDelay,
    List<Duration> retryBackoff = const <Duration>[
      Duration(milliseconds: 250),
      Duration(seconds: 1),
      Duration(seconds: 3),
    ],
  }) : _delegate = delegate,
       physicalServiceUuids = List<String>.unmodifiable(
         _deduplicateServices(physicalServiceUuids),
       ),
       _physicalScanStates = physicalScanStates,
       _physicalScanIsActive = physicalScanIsActive,
       _physicalScanStartAcknowledgements = physicalScanStartAcknowledgements,
       _physicalScanAttempt = physicalScanAttempt,
       _retryDelay = retryDelay ?? Future<void>.delayed,
       _retryBackoff = List<Duration>.unmodifiable(retryBackoff) {
    if (!unfilteredPhysicalScan && this.physicalServiceUuids.isEmpty) {
      throw ArgumentError.value(
        physicalServiceUuids,
        'physicalServiceUuids',
        'must contain the complete debug scan service union',
      );
    }
    if (unfilteredPhysicalScan && this.physicalServiceUuids.isNotEmpty) {
      throw ArgumentError.value(
        physicalServiceUuids,
        'physicalServiceUuids',
        'must be empty when unfilteredPhysicalScan is enabled',
      );
    }
    if (_retryBackoff.any((duration) => duration.isNegative)) {
      throw ArgumentError.value(
        retryBackoff,
        'retryBackoff',
        'must not contain negative durations',
      );
    }
  }

  final BleTransport _delegate;
  final List<String> physicalServiceUuids;
  final bool unfilteredPhysicalScan;
  final Stream<bool> _physicalScanStates;
  final DebugPhysicalScanActive _physicalScanIsActive;
  final Stream<int> _physicalScanStartAcknowledgements;
  final DebugPhysicalScanAttempt _physicalScanAttempt;
  final DebugScanRetryDelay _retryDelay;
  final List<Duration> _retryBackoff;

  final StreamController<DebugSharedScanState> _states =
      StreamController<DebugSharedScanState>.broadcast(sync: true);
  final List<_LogicalScan> _logicalScans = <_LogicalScan>[];

  Future<void> _transitionTail = Future<void>.value();
  StreamSubscription<BleScanResult>? _physicalSubscription;
  Future<void>? _physicalCancellation;
  bool _physicalStopUnconfirmed = false;
  _ScanPausedConnection? _pausedConnection;
  StreamSubscription<bool>? _physicalStateSubscription;
  StreamSubscription<int>? _physicalStartSubscription;
  DebugSharedScanState _state = DebugSharedScanState.notStarted;
  Timer? _retryTimer;
  bool _retryDelayActive = false;
  bool _scanRecoveryExhausted = false;
  BleFailure? _lastPhysicalFailure;
  var _generation = 0;
  int? _expectedScanAttempt;
  int? _acknowledgedScanAttempt;
  var _consecutiveFailures = 0;
  var _connectDepth = 0;
  var _desired = false;
  var _closed = false;
  Future<void> _connectTail = Future<void>.value();

  DebugSharedScanState get state => _state;
  Stream<DebugSharedScanState> get states => _states.stream;

  Future<void> start() {
    return _serialize(() async {
      if (_closed || _physicalStopUnconfirmed) {
        throw StateError('The debug shared scanner is closed.');
      }
      if (_scanRecoveryExhausted) throw _scanRecoveryFailure();
      _desired = true;
      _physicalStateSubscription ??= _physicalScanStates.distinct().listen(
        _handlePhysicalScanState,
        onError: (Object error, StackTrace _) {
          _recoverPhysicalFailure(_generation, error: error);
        },
      );
      _physicalStartSubscription ??= _physicalScanStartAcknowledgements.listen(
        _handlePhysicalScanStartAcknowledged,
        onError: (Object error, StackTrace _) {
          _recoverPhysicalFailure(_generation, error: error);
        },
      );
      if (_connectDepth == 0) {
        _startPhysicalScan();
      }
    });
  }

  Future<void> stop() {
    return _serialize(() async {
      if (_closed) {
        if (_physicalStopUnconfirmed) {
          throw StateError('Physical scan cleanup remains unconfirmed.');
        }
        return;
      }
      _desired = false;
      _closed = true;
      _retryTimer?.cancel();
      _retryTimer = null;
      _setState(DebugSharedScanState.stopped);
      Object? firstError;
      StackTrace? firstStackTrace;

      Future<void> runCleanup(Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }

      await runCleanup(_stopPhysicalScan);
      await runCleanup(() async {
        await _physicalStateSubscription?.cancel();
      });
      _physicalStateSubscription = null;
      await runCleanup(() async {
        await _physicalStartSubscription?.cancel();
      });
      _physicalStartSubscription = null;
      for (final scan in List<_LogicalScan>.of(_logicalScans)) {
        await runCleanup(scan.close);
      }
      _logicalScans.clear();
      await runCleanup(_states.close);
      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStackTrace!);
      }
    });
  }

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    if (_closed || _physicalStopUnconfirmed) {
      return Stream<BleScanResult>.error(
        StateError('The debug shared scanner is closed.'),
      );
    }
    if (_scanRecoveryExhausted) {
      return Stream<BleScanResult>.error(_scanRecoveryFailure());
    }
    final requestedServices = withServices == null
        ? null
        : List<String>.unmodifiable(_deduplicateServices(withServices));
    if (requestedServices != null && !unfilteredPhysicalScan) {
      final physical = physicalServiceUuids.toSet();
      final unsupported = requestedServices
          .map(_canonicalUuid)
          .where((uuid) => !physical.contains(uuid))
          .toList(growable: false);
      if (unsupported.isNotEmpty) {
        return Stream<BleScanResult>.error(
          ArgumentError.value(
            withServices,
            'withServices',
            'must be contained in the debug physical service union',
          ),
        );
      }
    }

    late final _LogicalScan logical;
    final controller = StreamController<BleScanResult>(sync: true);
    logical = _LogicalScan(
      controller: controller,
      requestedServices: requestedServices,
      allowDuplicates: allowDuplicates,
      onClosed: () => _logicalScans.remove(logical),
    );
    controller.onCancel = logical.close;
    _logicalScans.add(logical);
    if (timeout != null) {
      logical.timeoutTimer = Timer(timeout, () {
        unawaited(logical.close());
      });
    }
    if (!_desired) {
      unawaited(start());
    }
    return controller.stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => _queueConnect(deviceId, timeout: timeout, singleAttempt: false);

  @override
  bool get supportsSingleAttemptConnect {
    final delegate = _delegate;
    return delegate is BleSingleAttemptTransport &&
        delegate.supportsSingleAttemptConnect;
  }

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (_scanRecoveryExhausted) {
      return Future<BleConnection>.error(_scanRecoveryFailure());
    }
    if (!supportsSingleAttemptConnect) {
      return Future<BleConnection>.error(
        UnsupportedError('Single-attempt BLE connection is unavailable.'),
      );
    }
    return _queueConnect(deviceId, timeout: timeout, singleAttempt: true);
  }

  Future<BleConnection> _queueConnect(
    String deviceId, {
    required Duration timeout,
    required bool singleAttempt,
  }) {
    final operation = _connectTail.then(
      (_) => _connectWithPausedScan(
        deviceId,
        timeout: timeout,
        singleAttempt: singleAttempt,
      ),
    );
    _connectTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<BleConnection> _connectWithPausedScan(
    String deviceId, {
    required Duration timeout,
    required bool singleAttempt,
  }) async {
    var enteredConnect = false;
    try {
      await _serialize(() async {
        if (_closed || _physicalStopUnconfirmed || _pausedConnection != null) {
          throw StateError('The debug shared scanner is closed.');
        }
        if (_scanRecoveryExhausted) throw _scanRecoveryFailure();
        _connectDepth += 1;
        enteredConnect = true;
        if (_connectDepth == 1) {
          _retryTimer?.cancel();
          _retryTimer = null;
          _setState(DebugSharedScanState.suspended);
          await _stopPhysicalScan();
        }
      });
    } catch (_) {
      if (enteredConnect) {
        await _serialize(() async {
          _connectDepth -= 1;
          _handlePhysicalFailure();
        });
      }
      rethrow;
    }

    var retainedPause = false;
    try {
      if (singleAttempt) {
        final delegate = _delegate;
        if (delegate is! BleSingleAttemptTransport ||
            !delegate.supportsSingleAttemptConnect) {
          throw UnsupportedError(
            'Single-attempt BLE connection is unavailable.',
          );
        }
        final connection = await delegate.connectOnce(
          deviceId,
          timeout: timeout,
        );
        final paused = _ScanPausedConnection(
          connection,
          _closePausedConnection,
        );
        // Transfer the exact pause owner to the connection. A connected event
        // is not permission to resume discovery alongside the live session.
        _pausedConnection = paused;
        retainedPause = true;
        return paused;
      }
      return await _delegate.connect(deviceId, timeout: timeout);
    } finally {
      if (!retainedPause) await _releaseConnectPause();
    }
  }

  Future<void> _releaseConnectPause() => _serialize(() async {
    _connectDepth -= 1;
    if (_connectDepth == 0 && _desired && !_closed) {
      _consecutiveFailures = 0;
      _startPhysicalScan();
    }
  });

  Future<void> _closePausedConnection(_ScanPausedConnection owner) async {
    try {
      await owner.delegate.disconnect().timeout(const Duration(seconds: 15));
    } catch (_) {
      // Keep the exact connection and its memoized close future. A late close
      // completion cannot erase an uncertain ownership result or allow retry.
      _physicalStopUnconfirmed = true;
      _retryTimer?.cancel();
      _retryTimer = null;
      if (!_closed) _setState(DebugSharedScanState.error);
      throw StateError('BLE session cleanup remains unconfirmed.');
    }
    if (identical(_pausedConnection, owner)) {
      _pausedConnection = null;
      await _releaseConnectPause();
    }
  }

  void _startPhysicalScan() {
    if (!_desired ||
        _closed ||
        _scanRecoveryExhausted ||
        _connectDepth != 0 ||
        _physicalStopUnconfirmed ||
        _physicalCancellation != null) {
      return;
    }
    if (_physicalSubscription != null) {
      _maybeMarkPhysicalScanRunning();
      return;
    }

    final generation = ++_generation;
    _expectedScanAttempt = null;
    _acknowledgedScanAttempt = null;
    _setState(DebugSharedScanState.starting);
    try {
      final source = _delegate.scan(
        allowDuplicates: true,
        withServices: unfilteredPhysicalScan ? null : physicalServiceUuids,
      );
      _expectedScanAttempt = _physicalScanAttempt();
      late final StreamSubscription<BleScanResult> subscription;
      subscription = source.listen(
        _routePhysicalResult,
        onError: (Object error, StackTrace stackTrace) {
          if (generation != _generation) {
            return;
          }
          for (final logical in List<_LogicalScan>.of(_logicalScans)) {
            logical.addError(error, stackTrace);
          }
          _recoverPhysicalFailure(generation, error: error);
        },
        onDone: () {
          _handlePhysicalDone(generation, subscription);
        },
      );
      _physicalSubscription = subscription;
      _maybeMarkPhysicalScanRunning();
    } catch (error) {
      _physicalSubscription = null;
      if (error is BleFailure) _lastPhysicalFailure = error;
      _handlePhysicalFailure();
    }
  }

  Future<void> _stopPhysicalScan() async {
    if (_physicalStopUnconfirmed) {
      throw StateError('Physical scan cleanup remains unconfirmed.');
    }
    final subscription = _physicalSubscription;
    if (subscription == null) {
      _generation += 1;
      _expectedScanAttempt = null;
      _acknowledgedScanAttempt = null;
      return;
    }
    _generation += 1;
    _expectedScanAttempt = null;
    _acknowledgedScanAttempt = null;
    // Keep both the exact owner and its original cancellation future until
    // success. A failed or timed-out stop is not permission to start another
    // scanner. No later callback, retry, or stop call can clear this latch.
    final cancellation = _physicalCancellation ??= Future<void>.sync(
      subscription.cancel,
    );
    try {
      await cancellation.timeout(const Duration(seconds: 5));
    } catch (_) {
      _physicalStopUnconfirmed = true;
      _retryTimer?.cancel();
      _retryTimer = null;
      if (!_closed) _setState(DebugSharedScanState.error);
      throw StateError('Physical scan cleanup remains unconfirmed.');
    }
    if (identical(_physicalSubscription, subscription)) {
      _physicalSubscription = null;
      _physicalCancellation = null;
    }
  }

  void _handlePhysicalScanState(bool active) {
    if (!active) {
      if (_state == DebugSharedScanState.running &&
          _desired &&
          !_closed &&
          _connectDepth == 0 &&
          _physicalSubscription != null) {
        _recoverPhysicalFailure(_generation);
      }
      return;
    }
    _maybeMarkPhysicalScanRunning();
  }

  void _handlePhysicalScanStartAcknowledged(int attempt) {
    if (attempt != _expectedScanAttempt) {
      return;
    }
    _acknowledgedScanAttempt = attempt;
    _maybeMarkPhysicalScanRunning();
  }

  void _maybeMarkPhysicalScanRunning() {
    if (!_desired ||
        _closed ||
        _scanRecoveryExhausted ||
        _physicalStopUnconfirmed ||
        _physicalCancellation != null ||
        _connectDepth != 0 ||
        _physicalSubscription == null ||
        _expectedScanAttempt == null ||
        _acknowledgedScanAttempt != _expectedScanAttempt ||
        !_physicalScanIsActive()) {
      return;
    }
    _consecutiveFailures = 0;
    _lastPhysicalFailure = null;
    _setState(DebugSharedScanState.running);
  }

  void _handlePhysicalDone(
    int generation,
    StreamSubscription<BleScanResult> subscription,
  ) {
    if (generation != _generation ||
        !identical(_physicalSubscription, subscription)) {
      return;
    }
    _physicalSubscription = null;
    _expectedScanAttempt = null;
    _acknowledgedScanAttempt = null;
    if (_desired && !_closed && _connectDepth == 0) {
      _handlePhysicalFailure();
    }
  }

  void _recoverPhysicalFailure(int generation, {Object? error}) {
    if (generation != _generation ||
        !_desired ||
        _closed ||
        _scanRecoveryExhausted ||
        _physicalStopUnconfirmed ||
        _physicalCancellation != null) {
      return;
    }
    if (error is BleFailure) _lastPhysicalFailure = error;
    _setState(DebugSharedScanState.error);
    unawaited(
      _serialize(() async {
        if (generation != _generation) {
          return;
        }
        try {
          await _stopPhysicalScan();
        } finally {
          _handlePhysicalFailure();
        }
      }).then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // The state was set to error before cleanup. Readiness stays closed
          // even if the platform subscription cannot be cancelled cleanly.
        },
      ),
    );
  }

  void _handlePhysicalFailure() {
    if (!_desired ||
        _closed ||
        _scanRecoveryExhausted ||
        _connectDepth != 0 ||
        _physicalStopUnconfirmed) {
      return;
    }
    _setState(DebugSharedScanState.error);
    if (_retryTimer != null || _retryDelayActive) {
      return;
    }
    if (_consecutiveFailures >= _retryBackoff.length) {
      _scanRecoveryExhausted = true;
      for (final logical in List<_LogicalScan>.of(_logicalScans)) {
        logical.addError(_scanRecoveryFailure(), StackTrace.empty);
        unawaited(logical.close());
      }
      return;
    }
    final delay = _retryBackoff[_consecutiveFailures++];
    _retryTimer = Timer(Duration.zero, () {
      _retryTimer = null;
      _retryDelayActive = true;
      unawaited(
        () async {
          try {
            await _retryDelay(delay);
            await _serialize(() async {
              _retryDelayActive = false;
              if (_desired && !_closed && _connectDepth == 0) {
                _startPhysicalScan();
              }
            });
          } catch (_) {
            await _serialize(() async {
              _retryDelayActive = false;
              _handlePhysicalFailure();
            });
          }
        }().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    });
  }

  void _routePhysicalResult(BleScanResult result) {
    if (_physicalStopUnconfirmed ||
        _physicalCancellation != null ||
        _closed ||
        _scanRecoveryExhausted) {
      return;
    }
    for (final logical in List<_LogicalScan>.of(_logicalScans)) {
      logical.add(result);
    }
  }

  BleFailure _scanRecoveryFailure() =>
      _lastPhysicalFailure ??
      BleFailure(
        kind: BleFailureKind.unexpected,
        operation: BleOperation.scan,
        diagnosticCode: 'debug.shared_scan.recovery_exhausted',
      );

  void _setState(DebugSharedScanState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _transitionTail.then((_) => action());
    _transitionTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

final class _ScanPausedConnection implements BleConnection, BleNegotiatedMtu {
  _ScanPausedConnection(this.delegate, this._close);
  final BleConnection delegate;
  final Future<void> Function(_ScanPausedConnection) _close;
  Future<void>? _closeFuture;

  @override
  String get deviceId => delegate.deviceId;
  @override
  Stream<BleConnectionState> get connectionStates => delegate.connectionStates;
  @override
  bool get supportsBondLifecycle => delegate.supportsBondLifecycle;
  @override
  int? get negotiatedMtu => delegate is BleNegotiatedMtu
      ? (delegate as BleNegotiatedMtu).negotiatedMtu
      : null;
  @override
  Future<void> ensureBonded() => delegate.ensureBonded();
  @override
  Future<BleBondState> currentBondState() => delegate.currentBondState();
  @override
  Future<void> requestMtu(int mtu) => delegate.requestMtu(mtu);
  @override
  Future<List<BleService>> discoverServices() => delegate.discoverServices();
  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) =>
      delegate.read(characteristic);
  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) => delegate.write(characteristic, value, withoutResponse: withoutResponse);
  @override
  Future<void> setNotify(BleCharacteristicRef characteristic, bool enabled) =>
      delegate.setNotify(characteristic, enabled);
  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      delegate.notifications(characteristic);
  @override
  Future<void> removeBond() => delegate.removeBond();
  @override
  Future<void> disconnect() => _closeFuture ??= _close(this);
}

final class _LogicalScan {
  _LogicalScan({
    required this.controller,
    required this.requestedServices,
    required this.allowDuplicates,
    required this.onClosed,
  });

  final StreamController<BleScanResult> controller;
  final List<String>? requestedServices;
  final bool allowDuplicates;
  final void Function() onClosed;
  final Map<String, String> _seen = <String, String>{};

  Timer? timeoutTimer;
  var _closed = false;

  void add(BleScanResult result) {
    if (_closed || !_matchesServices(result)) {
      return;
    }
    if (!allowDuplicates) {
      final signature = _signatureOf(result);
      if (_seen[result.deviceId] == signature) {
        return;
      }
      _seen[result.deviceId] = signature;
    }
    controller.add(result);
  }

  void addError(Object error, StackTrace stackTrace) {
    if (!_closed) {
      controller.addError(error, stackTrace);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    timeoutTimer?.cancel();
    onClosed();
    await controller.close();
  }

  bool _matchesServices(BleScanResult result) {
    final requested = requestedServices;
    if (requested == null || requested.isEmpty) {
      return true;
    }
    final advertised = <String>{
      ...result.serviceUuids.map(_canonicalUuid),
      ...result.serviceData.keys.map(_canonicalUuid),
    };
    return requested.map(_canonicalUuid).any(advertised.contains);
  }
}

List<String> _deduplicateServices(List<String> services) {
  final seen = <String>{};
  return <String>[
    for (final service in services)
      if (seen.add(_canonicalUuid(service))) _canonicalUuid(service),
  ];
}

String _canonicalUuid(String value) {
  var compact = value.trim().replaceAll('-', '').toLowerCase();
  compact = switch (compact.length) {
    4 => '0000${compact}00001000800000805f9b34fb',
    8 => '${compact}00001000800000805f9b34fb',
    _ => compact,
  };
  if (compact.length != 32) {
    return compact;
  }
  return '${compact.substring(0, 8)}-'
      '${compact.substring(8, 12)}-'
      '${compact.substring(12, 16)}-'
      '${compact.substring(16, 20)}-'
      '${compact.substring(20)}';
}

String _signatureOf(BleScanResult result) {
  final manufacturer = result.manufacturerData
      .map((entry) => '${entry.companyId}:${entry.bytes.join(",")}')
      .join('|');
  final services = result.serviceUuids.join('|');
  return '${result.rssi}|$manufacturer|$services';
}
