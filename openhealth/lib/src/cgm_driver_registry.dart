import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

typedef CgmDiscoveryMapper = DiscoveredSensor? Function(BleScanResult result);

/// Prints a scan lifecycle diagnostic in debug builds only.
///
/// The scan path was debugged against a physical device, so its transitions are
/// worth keeping. Every message stays identity-free, and the call sits inside
/// an `assert` so release builds neither build nor emit them.
void _debugScanStep(Object Function() message) {
  assert(() {
    // Diagnostic-only helper: the analyzer would otherwise flag the print.
    // ignore: avoid_print, intentional debug-only scan diagnostics.
    print('[scan] ${message()}');
    return true;
  }(), 'scan diagnostics run only in debug builds');
}

/// One vendor driver and its pure advertisement classifier.
final class CgmDriverRegistration {
  CgmDriverRegistration({
    required this.driver,
    required Iterable<String> scanServiceUuids,
    required this.discover,
    this.prepareDiscovery,
    this.requiresUnfilteredScan = false,
  }) : scanServiceUuids = List<String>.unmodifiable(
         _normalizeServices(scanServiceUuids),
       ) {
    if (driver.driverId.trim().isEmpty) {
      throw ArgumentError.value(
        driver.driverId,
        'driver.driverId',
        'must not be empty',
      );
    }
    if (this.scanServiceUuids.isEmpty) {
      throw ArgumentError.value(
        scanServiceUuids,
        'scanServiceUuids',
        'must contain at least one advertised service',
      );
    }
  }

  final CgmDriver driver;
  final List<String> scanServiceUuids;
  final CgmDiscoveryMapper discover;

  /// Read-only, bounded restoration before this registration maps results.
  /// Failure suppresses this driver for the scan; other drivers remain usable.
  final Future<void> Function()? prepareDiscovery;

  /// Whether this protocol can advertise without its GATT service UUID.
  ///
  /// One such registration makes the process-wide scan unfiltered. Every
  /// registration still applies its strict in-memory classifier before a
  /// device is shown or routed to a writable driver.
  final bool requiresUnfilteredScan;
}

/// Routes one physical BLE scan to independent vendor drivers.
///
/// `flutter_blue_plus` scanning is process-global. Starting one scan per
/// driver lets those scans stop and replace each other. The registry therefore
/// owns a fixed service union, maps every result in memory, and stops the
/// active scan before it dispatches a connection.
final class CgmDriverRegistry implements CgmDriver {
  CgmDriverRegistry({
    required BleTransport transport,
    required Iterable<CgmDriverRegistration> registrations,
  }) : _transport = transport,
       _registrations = List<CgmDriverRegistration>.unmodifiable(
         registrations,
       ) {
    if (_registrations.isEmpty) {
      throw ArgumentError.value(
        registrations,
        'registrations',
        'must contain at least one driver',
      );
    }
    final duplicateIds = <String>{};
    final registeredIds = <String>{};
    for (final registration in _registrations) {
      if (!registeredIds.add(registration.driver.driverId)) {
        duplicateIds.add(registration.driver.driverId);
      }
    }
    if (duplicateIds.isNotEmpty) {
      throw ArgumentError.value(
        duplicateIds.toList(growable: false)..sort(),
        'registrations',
        'must contain unique driver IDs',
      );
    }
    _driversById = Map<String, CgmDriver>.unmodifiable(<String, CgmDriver>{
      for (final registration in _registrations)
        registration.driver.driverId: registration.driver,
    });
    scanServiceUuids = List<String>.unmodifiable(
      _normalizeServices(
        _registrations.expand(
          (registration) => registration.scanServiceUuids,
        ),
      ),
    );
    usesUnfilteredScan = _registrations.any(
      (registration) => registration.requiresUnfilteredScan,
    );
  }

  final BleTransport _transport;
  final List<CgmDriverRegistration> _registrations;
  late final Map<String, CgmDriver> _driversById;
  late final List<String> scanServiceUuids;
  late final bool usesUnfilteredScan;

  Future<void> _lifecycleTail = Future<void>.value();
  Future<void> Function()? _cancelActiveScan;
  StreamController<DiscoveredSensor>? _activeScanController;
  Timer? _activeScanTimeout;
  Object? _scanStopFailure;
  StackTrace? _scanStopFailureStackTrace;
  var _scanGeneration = 0;

  /// Upper bound for one transport scan cancellation.
  ///
  /// A transport that cannot confirm its own cancellation must not be able to
  /// block the scan lifecycle (and therefore the UI) forever. Cancelling a
  /// healthy transport resolves in milliseconds, so this only bounds failure.
  static const _scanCancellationTimeout = Duration(seconds: 2);

  @override
  String get driverId => 'openglucose-driver-registry';

  Set<String> get registeredDriverIds =>
      Set<String>.unmodifiable(_driversById.keys);

  bool containsDriver(String candidateDriverId) =>
      _driversById.containsKey(candidateDriverId);

  CgmDriver? driverFor(String candidateDriverId) =>
      _driversById[candidateDriverId];

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    late final StreamController<DiscoveredSensor> controller;
    var cancelled = false;
    controller = StreamController<DiscoveredSensor>(
      onListen: () {
        unawaited(
          _serialize<void>(() async {
            await _stopActiveScanLocked();
            if (controller.isClosed) {
              return;
            }
            final generation = ++_scanGeneration;
            _activeScanController = controller;
            var deadlineExpired = false;
            _activeScanTimeout?.cancel();
            _activeScanTimeout = timeout == null
                ? null
                : Timer(timeout, () {
                    deadlineExpired = true;
                    unawaited(
                      _completeScanAtDeadline(generation, controller),
                    );
                  });
            // Discovery setup can await a vendor receiver. A scan that reaches
            // its deadline while that is pending must still end on time.
            bool aborted() {
              if (!deadlineExpired && !cancelled && !controller.isClosed) {
                return false;
              }
              if (identical(_activeScanController, controller)) {
                _activeScanTimeout?.cancel();
                _activeScanTimeout = null;
                _activeScanController = null;
                _cancelActiveScan = null;
              }
              if (!controller.isClosed) {
                unawaited(controller.close());
              }
              return true;
            }

            final seen = <String, String>{};
            try {
              final availableRegistrations = <CgmDriverRegistration>[];
              for (final registration in _registrations) {
                if (aborted()) return;
                try {
                  await registration.prepareDiscovery?.call().timeout(
                    const Duration(seconds: 15),
                  );
                  availableRegistrations.add(registration);
                } on Object {
                  // A missing or unreadable receiver must not hide other
                  // manufacturers or reuse its previously cached identity.
                }
              }
              if (aborted()) return;
              final source = _transport.scan(
                timeout: timeout,
                allowDuplicates: true,
                withServices: usesUnfilteredScan
                    ? const <String>[]
                    : scanServiceUuids,
              );
              final subscription = source.listen(
                (result) {
                  if (!_ownsScan(generation, controller)) {
                    return;
                  }
                  final candidates = <DiscoveredSensor>[];
                  for (final registration in availableRegistrations) {
                    DiscoveredSensor? sensor;
                    try {
                      sensor = registration.discover(result);
                    } on Object {
                      // One malformed vendor advertisement must not terminate
                      // discovery for every registered protocol.
                      continue;
                    }
                    if (sensor == null ||
                        sensor.driverId != registration.driver.driverId ||
                        sensor.deviceId.isEmpty ||
                        sensor.storageKey.isEmpty) {
                      continue;
                    }
                    candidates.add(sensor);
                  }
                  // One physical advertisement cannot safely identify two
                  // writable protocols. Drop an ambiguous result instead of
                  // presenting a sensor that could route to the wrong driver.
                  if (candidates.length != 1) {
                    return;
                  }
                  final sensor = candidates.single;
                  final identity = '${sensor.driverId}\u0000${sensor.deviceId}';
                  final signature = jsonEncode(sensor.toJson());
                  if (allowDuplicates || seen[identity] != signature) {
                    seen[identity] = signature;
                    controller.add(sensor);
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (_ownsScan(generation, controller)) {
                    controller.addError(error, stackTrace);
                  }
                },
                onDone: () {
                  unawaited(_finishScan(generation, controller));
                },
              );
              _cancelActiveScan = subscription.cancel;
              assert(() {
                _debugScanStep(() => 'started a transport scan');
                return true;
              }(), 'scan diagnostics run only in debug builds');
            } on Object catch (error, stackTrace) {
              if (_ownsScan(generation, controller)) {
                controller.addError(error, stackTrace);
              }
              await _finishScanLocked(generation, controller);
            }
          }).then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              if (!controller.isClosed) {
                controller.addError(error, stackTrace);
                unawaited(controller.close());
              }
            },
          ),
        );
      },
      onCancel: () {
        cancelled = true;
        if (controller.isClosed) {
          return null;
        }
        return _serialize<void>(() async {
          if (identical(_activeScanController, controller)) {
            await _stopActiveScanLocked(awaitControllerClose: false);
          }
        }).then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            // StreamIterator automatically cancels on source error/done, and
            // Dart can otherwise surface a failed asynchronous onCancel as an
            // uncaught zone error in addition to the original scan failure.
            // Keep cleanup fail-closed inside the registry; connect and every
            // replacement scan rethrow this latched failure.
            _latchScanStopFailure(error, stackTrace);
            assert(() {
              _debugScanStep(() => 'latched a failed scan cancellation');
              return true;
            }(), 'scan diagnostics run only in debug builds');
          },
        );
      },
    );
    return controller.stream;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    final driver = driverFor(sensor.driverId);
    if (driver == null) {
      return Future<CgmSession>.error(
        ArgumentError.value(
          sensor.driverId,
          'sensor.driverId',
          'is not registered',
        ),
      );
    }
    return _serialize<CgmSession>(() async {
      await _stopActiveScanLocked();
      return driver.connect(sensor);
    });
  }

  bool _ownsScan(
    int generation,
    StreamController<DiscoveredSensor> controller,
  ) =>
      generation == _scanGeneration &&
      identical(_activeScanController, controller) &&
      !controller.isClosed;

  /// Ends a scan whose transport stream never closed on its own.
  ///
  /// flutter_blue_plus can stop a physical scan without emitting the
  /// `isScanning == false` transition that `FlutterBluePlusTransport` waits
  /// for, which leaves the transport stream open past the requested timeout.
  /// The registry owns that timeout for every consumer, so the Connect-a-sensor
  /// panel and any caller that replaces a scan always observe completion
  /// instead of an indefinite spinner.
  Future<void> _completeScanAtDeadline(
    int generation,
    StreamController<DiscoveredSensor> controller,
  ) async {
    if (!_ownsScan(generation, controller)) {
      return;
    }
    _activeScanTimeout?.cancel();
    _activeScanTimeout = null;
    // Close the result stream first: the same listener drains and releases its
    // subscription before the cancellation below is serialized.
    unawaited(controller.close());
    assert(() {
      _debugScanStep(() => 'ended an overrun scan at its deadline');
      return true;
    }(), 'scan diagnostics run only in debug builds');
    try {
      await _serialize<void>(() async {
        if (identical(_activeScanController, controller)) {
          await _stopActiveScanLocked();
        }
      });
    } on Object {
      // The result stream is already closed and the transport could not
      // confirm its cancellation, which stays latched for the next scan
      // attempt. This deadline path must not surface a second unhandled error.
    }
  }

  Future<void> _finishScan(
    int generation,
    StreamController<DiscoveredSensor> controller,
  ) => _serialize<void>(
    () => _finishScanLocked(generation, controller),
  );

  Future<void> _finishScanLocked(
    int generation,
    StreamController<DiscoveredSensor> controller,
  ) async {
    if (!_ownsScan(generation, controller)) {
      return;
    }
    _cancelActiveScan = null;
    _activeScanController = null;
    _activeScanTimeout?.cancel();
    _activeScanTimeout = null;
    if (!controller.isClosed) {
      await controller.close();
    }
  }

  Future<void> _stopActiveScanLocked({bool awaitControllerClose = true}) async {
    final latchedFailure = _scanStopFailure;
    if (latchedFailure != null) {
      Error.throwWithStackTrace(
        latchedFailure,
        _scanStopFailureStackTrace ?? StackTrace.current,
      );
    }
    final cancelScan = _cancelActiveScan;
    final controller = _activeScanController;
    _scanGeneration += 1;
    _activeScanTimeout?.cancel();
    _activeScanTimeout = null;

    Object? cancellationError;
    StackTrace? cancellationStackTrace;
    var cancellationUnconfirmed = false;
    if (cancelScan != null) {
      // A transport that neither completes nor fails its own cancellation must
      // not hold the whole scan lifecycle open.
      var cancelled = false;
      await Future.any(<Future<void>>[
        cancelScan().then<void>(
          (_) => cancelled = true,
          onError: (Object error, StackTrace stackTrace) {
            cancellationError = error;
            cancellationStackTrace = stackTrace;
          },
        ),
        Future<void>.delayed(_scanCancellationTimeout),
      ]);
      cancellationUnconfirmed = !cancelled && cancellationError == null;
      if (cancellationUnconfirmed) {
        assert(() {
          _debugScanStep(() => 'proceeded past an unconfirmed cancellation');
          return true;
        }(), 'scan diagnostics run only in debug builds');
      }
    }

    if (controller != null && !controller.isClosed) {
      final close = controller.close();
      if (awaitControllerClose) {
        await close;
      }
    }

    final cancellationFailure = cancellationError;
    if (cancellationFailure != null) {
      // StreamSubscription.cancel is not retryable: later calls return the
      // same failed future. Latch the failure so no replacement scan or
      // routed connection can proceed without proof that the process-global
      // BLE scan stopped. Recreating the registry is the recovery boundary.
      // An unconfirmed cancellation is deliberately not latched: it is bounded
      // in time, and a retry in the same session must stay possible.
      _latchScanStopFailure(
        cancellationFailure,
        cancellationStackTrace ?? StackTrace.current,
      );
      Error.throwWithStackTrace(
        cancellationFailure,
        cancellationStackTrace ?? StackTrace.current,
      );
    }
    if (identical(_cancelActiveScan, cancelScan)) {
      _cancelActiveScan = null;
    }
    if (identical(_activeScanController, controller)) {
      _activeScanController = null;
    }
  }

  void _latchScanStopFailure(Object error, StackTrace stackTrace) {
    _scanStopFailure ??= error;
    _scanStopFailureStackTrace ??= stackTrace;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _lifecycleTail.then((_) => action());
    _lifecycleTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

List<String> _normalizeServices(Iterable<String> services) {
  final values = <String>[];
  final seen = <String>{};
  for (final service in services) {
    final trimmed = service.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final identity = trimmed.toLowerCase();
    if (seen.add(identity)) {
      values.add(trimmed);
    }
  }
  return values;
}
