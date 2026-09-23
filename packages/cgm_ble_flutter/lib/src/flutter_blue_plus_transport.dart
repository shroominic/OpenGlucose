import 'dart:async';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

/// Instance-owned proof that a FlutterBluePlus scan start completed.
///
/// The process-global `isScanning` signal can become true before the native
/// start request completes. Debug capture code uses this tracker to bind
/// readiness to the exact transport scan attempt that completed successfully.
final class FlutterBluePlusScanStartTracker {
  final StreamController<int> _acknowledgements =
      StreamController<int>.broadcast(sync: true);

  var _latestAttempt = 0;

  int get latestAttempt => _latestAttempt;
  Stream<int> get acknowledgements => _acknowledgements.stream;

  int _beginAttempt() => ++_latestAttempt;

  void _acknowledge(int attempt) {
    if (!_acknowledgements.isClosed) {
      _acknowledgements.add(attempt);
    }
  }
}

class FlutterBluePlusTransport
    implements BleTransport, BleSingleAttemptTransport {
  const FlutterBluePlusTransport({
    this.androidUsesFineLocation = true,
    this.androidCheckLocationServices = true,
    this.adapterReadyTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 12),
    this.discoveryTimeout = const Duration(seconds: 30),
    this.showPowerAlert = true,
    this.restoreState = false,
    this.scanStartTracker,
  });

  final bool androidUsesFineLocation;
  final bool androidCheckLocationServices;
  final Duration adapterReadyTimeout;
  final Duration operationTimeout;
  final Duration discoveryTimeout;
  final bool showPowerAlert;
  final bool restoreState;
  final FlutterBluePlusScanStartTracker? scanStartTracker;

  @override
  bool get supportsSingleAttemptConnect => true;

  static Future<void>? _setOptionsFuture;

  /// Process-wide scan activity reported by flutter_blue_plus.
  ///
  /// This does not expose scan results or payloads. Capture tooling can use it
  /// to prove that a requested passive scan reached the platform scanner.
  static Stream<bool> get scanStates => fbp.FlutterBluePlus.isScanning;

  /// The current process-wide scan state reported by flutter_blue_plus.
  static bool get isScanningNow => fbp.FlutterBluePlus.isScanningNow;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    final tracker = scanStartTracker;
    final scanAttempt = tracker?._beginAttempt();
    final controller = StreamController<BleScanResult>();
    final seen = <String, String>{};

    StreamSubscription<List<fbp.ScanResult>>? resultsSubscription;
    StreamSubscription<bool>? scanningSubscription;
    Future<void>? startupFuture;
    Future<void>? closeFuture;
    Timer? scanDeadline;
    var startedScan = false;
    var closed = false;

    Future<void> closeStream({
      bool stopScan = true,
      bool waitForStartup = true,
    }) {
      final existing = closeFuture;
      if (existing != null) {
        return existing;
      }
      closed = true;
      scanDeadline?.cancel();
      scanDeadline = null;
      final completer = Completer<void>();
      closeFuture = completer.future;
      final results = resultsSubscription;
      final scanning = scanningSubscription;
      // Close the caller's stream before cleanup. Cleanup awaits plugin
      // futures that can stay pending on some Android stacks, and a scan the
      // platform already stopped must not hold its caller open behind them.
      unawaited(
        controller.close().then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      unawaited(
        closeFlutterBluePlusScanResources(
              cancelResults: results?.cancel,
              cancelScanning: scanning?.cancel,
              awaitPendingStart: waitForStartup
                  ? () async {
                      final pending = startupFuture;
                      if (pending != null) {
                        await pending;
                      }
                    }
                  : null,
              stopScan: stopScan
                  ? () async {
                      if (fbp.FlutterBluePlus.isScanningNow) {
                        await fbp.FlutterBluePlus.stopScan();
                      }
                    }
                  : null,
              closeController: controller.close,
            )
            .timeout(
              // The radio is already stopped by this point; a plugin future that
              // never completes must not leave cancellation pending forever.
              const Duration(seconds: 5),
              onTimeout: () {},
            )
            .then<void>(
              (_) => completer.complete(),
              onError: (Object error, StackTrace stackTrace) =>
                  completer.completeError(error, stackTrace),
            ),
      );
      return completer.future;
    }

    void closeStreamSafely({bool stopScan = true, bool waitForStartup = true}) {
      unawaited(
        closeStream(
          stopScan: stopScan,
          waitForStartup: waitForStartup,
        ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }

    /// Closes this scan when the requested window elapses.
    ///
    /// `flutter_blue_plus` stops the radio when its own `timeout` fires, but
    /// that stop is not reliably visible here: the plugin can finish the scan
    /// without publishing `isScanning = false`, and its pending `startScan`
    /// future can stay pending past the window. Callers pass `timeout`
    /// expecting a bounded scan, so the stream must bound itself instead of
    /// waiting for a signal that may never arrive.
    void armScanDeadline(Duration window) {
      scanDeadline?.cancel();
      scanDeadline = Timer(window + const Duration(milliseconds: 750), () {
        if (closed) {
          return;
        }
        // Close the caller's stream first: cleanup below awaits plugin
        // futures that may themselves be the pending signal.
        unawaited(
          controller.close().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
        closeStreamSafely(waitForStartup: false);
      });
    }

    String signatureOf(BleScanResult result) {
      final manufacturer = result.manufacturerData
          .map((entry) => '${entry.companyId}:${entry.bytes.join(",")}')
          .join('|');
      final services = result.serviceUuids.join('|');
      return '${result.rssi}|$manufacturer|$services';
    }

    void emitScanResult(fbp.ScanResult value) {
      final mapped = _mapScanResult(value);
      if (!allowDuplicates) {
        final signature = signatureOf(mapped);
        if (seen[mapped.deviceId] == signature) {
          return;
        }
        seen[mapped.deviceId] = signature;
      }
      if (!closed && !controller.isClosed) {
        controller.add(mapped);
      }
    }

    void emitScanError(Object error, StackTrace stackTrace) {
      if (closed || controller.isClosed) {
        return;
      }
      controller.addError(
        classifyFlutterBluePlusFailure(error, operation: BleOperation.scan),
        stackTrace,
      );
    }

    controller.onCancel = closeStream;

    startupFuture = () async {
      try {
        final window = timeout;
        if (window != null) {
          armScanDeadline(window);
        }
        await _ensureAdapterReady();
        if (closed) {
          return;
        }
        resultsSubscription = fbp.FlutterBluePlus.onScanResults.listen(
          (results) {
            for (final result in results) {
              emitScanResult(result);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            emitScanError(error, stackTrace);
          },
        );
        scanningSubscription = fbp.FlutterBluePlus.isScanning.listen(
          (scanning) {
            if (startedScan && !scanning) {
              closeStreamSafely(stopScan: false);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            emitScanError(error, stackTrace);
          },
        );
        if (closed) {
          return;
        }
        await fbp.FlutterBluePlus.startScan(
          withServices: (withServices ?? const <String>[])
              .map(fbp.Guid.new)
              .toList(growable: false),
          timeout: timeout,
          continuousUpdates: true,
          oneByOne: true,
          androidUsesFineLocation: androidUsesFineLocation,
          androidCheckLocationServices: androidCheckLocationServices,
        );
        startedScan = true;
        if (!closed && scanAttempt != null) {
          tracker!._acknowledge(scanAttempt);
        } else if (closed && fbp.FlutterBluePlus.isScanningNow) {
          await fbp.FlutterBluePlus.stopScan();
        }
      } catch (error, stackTrace) {
        if (!closed && !controller.isClosed) {
          emitScanError(error, stackTrace);
        }
        if (closed) {
          if (fbp.FlutterBluePlus.isScanningNow) {
            await fbp.FlutterBluePlus.stopScan();
          }
        } else {
          closeStreamSafely(waitForStartup: false);
        }
      }
    }();
    unawaited(
      startupFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );

    return controller.stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _connect(deviceId, timeout: timeout, retryAndroidStatus133: true);
  }

  /// Connects with one direct FlutterBluePlus connect invocation.
  ///
  /// This path still waits for the process-wide scanner to stop, but it never
  /// uses the Android status-133 retry from [connect]. It also does not create,
  /// remove, or otherwise reconcile an Android bond. Protocols with one-shot
  /// connection semantics, such as the audited Libre Gen1 handshake, must use
  /// this method instead of [connect].
  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _connect(deviceId, timeout: timeout, retryAndroidStatus133: false);
  }

  Future<BleConnection> _connect(
    String deviceId, {
    required Duration timeout,
    required bool retryAndroidStatus133,
  }) async {
    try {
      await _ensureAdapterReady();
      Future<fbp.BluetoothDevice> connectDevice() async {
        final device = fbp.BluetoothDevice.fromId(deviceId);
        await device.connect(
          // Keep compatibility with the app's locked flutter_blue_plus 2.2.x.
          // ignore: deprecated_member_use
          license: fbp.License.free,
          timeout: timeout,
          mtu: null,
          // A one-shot protocol must not install a background reconnect.
          autoConnect: false,
        );
        return device;
      }

      final device = retryAndroidStatus133
          ? await connectWithScanStoppedRetry<fbp.BluetoothDevice>(
              stopScan: fbp.FlutterBluePlus.stopScan,
              connect: connectDevice,
              shouldRetry: _shouldRetryAndroidConnect,
              waitBeforeRetry: () =>
                  Future<void>.delayed(const Duration(milliseconds: 800)),
            )
          : await connectWithScanStoppedOnce<fbp.BluetoothDevice>(
              stopScan: fbp.FlutterBluePlus.stopScan,
              connect: connectDevice,
            );
      return _FlutterBluePlusConnection(
        device,
        operationTimeout: operationTimeout,
        discoveryTimeout: discoveryTimeout,
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        classifyFlutterBluePlusFailure(error, operation: BleOperation.connect),
        stackTrace,
      );
    }
  }

  Future<void> _ensureAdapterReady() async {
    try {
      await _ensureConfigured();
      final state = await fbp.FlutterBluePlus.adapterState
          .where(
            (value) =>
                value != fbp.BluetoothAdapterState.unknown &&
                value != fbp.BluetoothAdapterState.turningOn,
          )
          .first
          .timeout(adapterReadyTimeout);
      switch (state) {
        case fbp.BluetoothAdapterState.on:
          return;
        case fbp.BluetoothAdapterState.unauthorized:
          throw BleFailure(
            kind: BleFailureKind.permissionRequired,
            operation: BleOperation.adapter,
            diagnosticCode: 'fbp.adapter.unauthorized',
          );
        case fbp.BluetoothAdapterState.off ||
            fbp.BluetoothAdapterState.turningOff:
          throw BleFailure(
            kind: BleFailureKind.bluetoothOff,
            operation: BleOperation.adapter,
            diagnosticCode: 'fbp.adapter.off',
          );
        case fbp.BluetoothAdapterState.unavailable:
          throw BleFailure(
            kind: BleFailureKind.bluetoothUnavailable,
            operation: BleOperation.adapter,
            diagnosticCode: 'fbp.adapter.unavailable',
          );
        case fbp.BluetoothAdapterState.unknown ||
            fbp.BluetoothAdapterState.turningOn:
          throw BleFailure(
            kind: BleFailureKind.bluetoothUnavailable,
            operation: BleOperation.adapter,
            diagnosticCode: 'fbp.adapter.not-ready',
          );
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        classifyFlutterBluePlusFailure(error, operation: BleOperation.adapter),
        stackTrace,
      );
    }
  }

  Future<void> _ensureConfigured() async {
    if (kIsWeb) {
      return;
    }
    if (!Platform.isIOS && !Platform.isMacOS) {
      return;
    }
    _setOptionsFuture ??= fbp.FlutterBluePlus.setOptions(
      showPowerAlert: showPowerAlert,
      restoreState: restoreState,
    );
    await _setOptionsFuture;
  }

  BleScanResult _mapScanResult(fbp.ScanResult result) {
    final advertisement = result.advertisementData;
    final name = advertisement.advName.trim().isNotEmpty
        ? advertisement.advName.trim()
        : result.device.platformName.trim();
    return BleScanResult(
      deviceId: result.device.remoteId.str,
      deviceName: name,
      rssi: result.rssi,
      observedAt: result.timeStamp.toUtc(),
      serviceUuids: advertisement.serviceUuids
          .map((uuid) => _normalizeUuid(uuid.toString()))
          .toList(growable: false),
      manufacturerData: advertisement.manufacturerData.entries
          .map(
            (entry) => BleManufacturerData(
              companyId: entry.key,
              bytes: List<int>.from(entry.value, growable: false),
            ),
          )
          .toList(growable: false),
      serviceData: <String, List<int>>{
        for (final entry in advertisement.serviceData.entries)
          _normalizeUuid(entry.key.toString()): List<int>.from(
            entry.value,
            growable: false,
          ),
      },
    );
  }

  bool _shouldRetryAndroidConnect(Object error) {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }
    final message = error.toString().toUpperCase();
    return message.contains('ANDROID_SPECIFIC_ERROR') ||
        message.contains('CONNECT') && message.contains('133');
  }
}

/// Cancels all scan resources even when an earlier cleanup step fails.
@visibleForTesting
Future<void> closeFlutterBluePlusScanResources({
  required Future<void> Function()? cancelResults,
  required Future<void> Function()? cancelScanning,
  Future<void> Function()? awaitPendingStart,
  required Future<void> Function()? stopScan,
  required Future<void> Function() closeController,
  Duration stepTimeout = const Duration(seconds: 5),
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;

  Future<void> run(Future<void> Function()? action) async {
    if (action == null) {
      return;
    }
    try {
      // A radio that already stopped can leave these plugin futures pending
      // forever. Bound each one so cleanup always finishes.
      await action().timeout(stepTimeout, onTimeout: () {});
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  // Close the caller's stream first. This is the step every caller depends on;
  // it must not sit behind plugin futures that may never complete.
  await run(closeController);
  await run(cancelResults);
  await run(cancelScanning);
  await run(awaitPendingStart);
  await run(stopScan);
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStackTrace!);
  }
}

/// Runs both the initial connection attempt and its optional retry only after
/// FlutterBluePlus has finished stopping its scanner.
///
/// Some Android Bluetooth stacks cannot establish GATT while a BLE scan is
/// active. Calling [stopScan] unconditionally also serializes against a scan
/// that is still starting inside FlutterBluePlus.
@visibleForTesting
Future<T> connectWithScanStoppedRetry<T>({
  required Future<void> Function() stopScan,
  required Future<T> Function() connect,
  required bool Function(Object error) shouldRetry,
  required Future<void> Function() waitBeforeRetry,
}) async {
  Future<T> attempt() async {
    await stopScan();
    return connect();
  }

  try {
    return await attempt();
  } catch (error, stackTrace) {
    if (!shouldRetry(error)) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  await waitBeforeRetry();
  return attempt();
}

/// Runs one connection invocation after FlutterBluePlus stops its scanner.
///
/// Unlike [connectWithScanStoppedRetry], this helper has no retry callback or
/// delay hook. A connect error, including Android GATT status 133, is returned
/// to the caller after the first invocation. No bond operation is part of this
/// sequence.
@visibleForTesting
Future<T> connectWithScanStoppedOnce<T>({
  required Future<void> Function() stopScan,
  required Future<T> Function() connect,
}) async {
  await stopScan();
  return connect();
}

/// Discovers the GATT table without subscribing to the optional Service
/// Changed characteristic.
///
/// OpenGlucose does not consume FlutterBluePlus' service-reset stream, and the
/// extra protected subscription can fail on stricter Android BLE stacks.
@visibleForTesting
Future<T> discoverServicesWithoutServiceChanged<T>(
  Future<T> Function(bool subscribeToServicesChanged, int timeoutSeconds)
  discoverServices, {
  required Duration timeout,
}) {
  return discoverServices(false, _flutterBluePlusTimeoutSeconds(timeout));
}

/// Runs a notification subscription with FlutterBluePlus owning its timeout.
///
/// The plugin serializes BLE operations behind a global mutex. Returning its
/// Future directly ensures the mutex is released before setup recovery starts.
@visibleForTesting
Future<T> setNotifyWithPluginTimeout<T>(
  Future<T> Function(int timeoutSeconds) setNotifyValue, {
  required Duration timeout,
}) {
  return setNotifyValue(_flutterBluePlusTimeoutSeconds(timeout));
}

/// Runs a characteristic write with FlutterBluePlus owning its timeout.
///
/// In with-response mode, the returned plugin Future completes only after the
/// ATT Write Response. Returning that Future directly prevents a late,
/// irreversible write from completing after an outer Dart timeout fires.
@visibleForTesting
Future<T> writeWithPluginTimeout<T>(
  Future<T> Function(bool withoutResponse, int timeoutSeconds) write, {
  required bool withoutResponse,
  required Duration timeout,
}) {
  return write(withoutResponse, _flutterBluePlusTimeoutSeconds(timeout));
}

/// Runs a bond removal with FlutterBluePlus owning its operation timeout.
@visibleForTesting
Future<T> removeBondWithPluginTimeout<T>(
  Future<T> Function(int timeoutSeconds) removeBond, {
  required Duration timeout,
}) {
  return removeBond(_flutterBluePlusTimeoutSeconds(timeout));
}

/// Runs a disconnect with FlutterBluePlus owning its operation timeout.
@visibleForTesting
Future<T> disconnectWithPluginTimeout<T>(
  Future<T> Function(int timeoutSeconds) disconnect, {
  required Duration timeout,
}) {
  return disconnect(_flutterBluePlusTimeoutSeconds(timeout));
}

class _FlutterBluePlusConnection implements BleConnection, BleNegotiatedMtu {
  _FlutterBluePlusConnection(
    this._device, {
    required this.operationTimeout,
    required this.discoveryTimeout,
  });

  final fbp.BluetoothDevice _device;
  final Duration operationTimeout;
  final Duration discoveryTimeout;
  final Map<String, fbp.BluetoothCharacteristic> _characteristics =
      <String, fbp.BluetoothCharacteristic>{};
  int? _negotiatedMtu;

  @override
  int? get negotiatedMtu => _negotiatedMtu;

  @override
  String get deviceId => _device.remoteId.str;

  @override
  bool get supportsBondLifecycle => !kIsWeb && Platform.isAndroid;

  @override
  Stream<BleConnectionState> get connectionStates => _device.connectionState
      .map(
        (state) => switch (state) {
          fbp.BluetoothConnectionState.connected =>
            BleConnectionState.connected,
          _ => BleConnectionState.disconnected,
        },
      )
      .transform(
        StreamTransformer<BleConnectionState, BleConnectionState>.fromHandlers(
          handleError: (error, stackTrace, sink) {
            sink.addError(
              classifyFlutterBluePlusFailure(
                error,
                operation: BleOperation.connect,
              ),
              stackTrace,
            );
          },
        ),
      );

  @override
  Future<void> ensureBonded() async {
    await _runBleOperation<void>(BleOperation.bond, () async {
      if (kIsWeb || !Platform.isAndroid) {
        return;
      }
      await ensureAndroidBond(
        currentState: currentBondState,
        bondStates: _device.bondState.map(
          (state) => (
            state: _mapBondState(state),
            previousState: _mapOptionalBondState(_device.prevBondState),
          ),
        ),
        createBond: () => _device.createBond(),
        reconciliationTimeout: const Duration(seconds: 90),
      );
    });
  }

  @override
  Future<BleBondState> currentBondState() async {
    return _runBleOperation<BleBondState>(BleOperation.bond, () async {
      if (kIsWeb || !Platform.isAndroid) {
        return BleBondState.bonded;
      }
      final bondState = await _device.bondState.first;
      return _mapBondState(bondState);
    });
  }

  @override
  Future<void> requestMtu(int mtu) async {
    await _runBleOperation<void>(BleOperation.requestMtu, () async {
      if (kIsWeb || !Platform.isAndroid) {
        return;
      }
      _negotiatedMtu = await _device.requestMtu(mtu).timeout(operationTimeout);
    });
  }

  @override
  Future<List<BleService>> discoverServices() async {
    return _runBleOperation<List<BleService>>(
      BleOperation.discoverServices,
      () async {
        final services = await discoverServicesWithoutServiceChanged(
          (subscribeToServicesChanged, timeoutSeconds) =>
              _device.discoverServices(
                subscribeToServicesChanged: subscribeToServicesChanged,
                timeout: timeoutSeconds,
              ),
          timeout: discoveryTimeout,
        );
        _cacheServices(services);
        return services
            .where((service) => service.isPrimary)
            .map(
              (service) => BleService(
                uuid: _normalizeUuid(service.uuid.toString()),
                characteristics: service.characteristics
                    .map(
                      (characteristic) => BleCharacteristicRef(
                        serviceUuid: _normalizeUuid(service.uuid.toString()),
                        characteristicUuid: _normalizeUuid(
                          characteristic.uuid.toString(),
                        ),
                        properties: BleCharacteristicProperties(
                          read: characteristic.properties.read,
                          write: characteristic.properties.write,
                          writeWithoutResponse:
                              characteristic.properties.writeWithoutResponse,
                          notify: characteristic.properties.notify,
                          indicate: characteristic.properties.indicate,
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            )
            .toList(growable: false);
      },
    );
  }

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async {
    return _runBleOperation<List<int>>(BleOperation.read, () async {
      final resolved = await _resolveCharacteristic(characteristic);
      return resolved.read().timeout(operationTimeout);
    });
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    await _runBleOperation<void>(BleOperation.write, () async {
      final resolved = await _resolveCharacteristic(characteristic);
      await writeWithPluginTimeout<void>(
        (writeWithoutResponse, timeoutSeconds) => resolved.write(
          value,
          withoutResponse: writeWithoutResponse,
          timeout: timeoutSeconds,
        ),
        withoutResponse: withoutResponse,
        timeout: operationTimeout,
      );
    });
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    await _runBleOperation<void>(BleOperation.subscribe, () async {
      final resolved = await _resolveCharacteristic(characteristic);
      await setNotifyWithPluginTimeout<void>((timeoutSeconds) async {
        await resolved.setNotifyValue(enabled, timeout: timeoutSeconds);
      }, timeout: operationTimeout);
    });
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) async* {
    try {
      final resolved = await _resolveCharacteristic(characteristic);
      yield* resolved.onValueReceived;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        classifyFlutterBluePlusFailure(
          error,
          operation: BleOperation.subscribe,
        ),
        stackTrace,
      );
    }
  }

  @override
  Future<void> removeBond() async {
    await _runBleOperation<void>(BleOperation.removeBond, () async {
      if (kIsWeb || !Platform.isAndroid) {
        return;
      }
      final state = await currentBondState();
      if (state == BleBondState.unbonded) {
        return;
      }
      await removeBondWithPluginTimeout<void>(
        (timeoutSeconds) => _device.removeBond(timeout: timeoutSeconds),
        timeout: operationTimeout,
      );
    });
  }

  @override
  Future<void> disconnect() async {
    await _runBleOperation<void>(BleOperation.disconnect, () async {
      if (_device.isConnected) {
        await disconnectWithPluginTimeout<void>(
          (timeoutSeconds) => _device.disconnect(timeout: timeoutSeconds),
          timeout: operationTimeout,
        );
      }
    });
  }

  Future<T> _runBleOperation<T>(
    BleOperation operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        classifyFlutterBluePlusFailure(error, operation: operation),
        stackTrace,
      );
    }
  }

  Future<fbp.BluetoothCharacteristic> _resolveCharacteristic(
    BleCharacteristicRef characteristic,
  ) async {
    final key = _characteristicKey(
      characteristic.serviceUuid,
      characteristic.characteristicUuid,
    );
    final cached = _characteristics[key];
    if (cached != null) {
      return cached;
    }
    final knownServices = _device.servicesList;
    if (knownServices.isNotEmpty) {
      _cacheServices(knownServices);
      final updated = _characteristics[key];
      if (updated != null) {
        return updated;
      }
    }
    await discoverServices();
    final resolved = _characteristics[key];
    if (resolved == null) {
      throw StateError(
        'Characteristic ${characteristic.characteristicUuid} not found on '
        'service ${characteristic.serviceUuid} for $deviceId.',
      );
    }
    return resolved;
  }

  void _cacheServices(List<fbp.BluetoothService> services) {
    // Discovery after establishing a bond can return new native
    // characteristic objects. Never retain pre-bond handles that are absent
    // from the refreshed service table.
    final refreshedCharacteristics = <String, fbp.BluetoothCharacteristic>{};
    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      for (final characteristic in service.characteristics) {
        refreshedCharacteristics[_characteristicKey(
              serviceUuid,
              _normalizeUuid(characteristic.uuid.toString()),
            )] =
            characteristic;
      }
    }
    _characteristics
      ..clear()
      ..addAll(refreshedCharacteristics);
  }

  String _characteristicKey(String serviceUuid, String characteristicUuid) {
    return '${_normalizeUuid(serviceUuid)}|${_normalizeUuid(characteristicUuid)}';
  }
}

/// Completes Android bonding even when the plugin loses its GATT connection
/// after Android has already persisted the OS bond.
///
/// flutter_blue_plus races its bond-state response with the GATT connection
/// stream. Some Android stacks disconnect GATT as the bond completes, causing
/// `createBond` to throw `deviceIsDisconnected` even though the cached OS bond
/// state is already `bonded`. Only that exact plugin failure is reconciled;
/// rejection, timeout, and all other failures retain their original meaning.
Future<void> ensureAndroidBond({
  required Future<BleBondState> Function() currentState,
  required Stream<AndroidBondStateObservation> bondStates,
  required Future<void> Function() createBond,
  required Duration reconciliationTimeout,
}) async {
  final initialState = await currentState();
  if (initialState == BleBondState.bonded) {
    return;
  }
  final outcomeObserver = _AndroidBondOutcomeObserver(
    bondStates,
    reconciliationTimeout,
  );
  try {
    if (initialState == BleBondState.bonding) {
      _throwIfBondDidNotComplete(await outcomeObserver.result);
      return;
    }

    try {
      await createBond();
    } catch (error, stackTrace) {
      if (!_isGattDisconnectDuringCreateBond(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      _throwIfBondDidNotComplete(await outcomeObserver.result);
    }
  } finally {
    await outcomeObserver.cancel();
  }
}

typedef AndroidBondStateObservation = ({
  BleBondState state,
  BleBondState? previousState,
});

typedef _AndroidBondOutcomeResult = ({
  AndroidBondStateObservation? outcome,
  Object? error,
  StackTrace? stackTrace,
});

class _AndroidBondOutcomeObserver {
  _AndroidBondOutcomeObserver(
    Stream<AndroidBondStateObservation> bondStates,
    Duration timeout,
  ) {
    _timer = Timer(timeout, () {
      _complete(
        error: BleFailure(
          kind: BleFailureKind.bondTimedOut,
          operation: BleOperation.bond,
          diagnosticCode: 'fbp.bond.reconcile-timeout',
        ),
        stackTrace: StackTrace.current,
      );
    });
    _subscription = bondStates.listen(
      _handleObservation,
      onError: _handleError,
    );
  }

  final Completer<_AndroidBondOutcomeResult> _result =
      Completer<_AndroidBondOutcomeResult>();
  late final StreamSubscription<AndroidBondStateObservation> _subscription;
  late final Timer _timer;
  bool _sawBonding = false;

  Future<_AndroidBondOutcomeResult> get result => _result.future;

  void _handleObservation(AndroidBondStateObservation observation) {
    if (observation.state == BleBondState.bonding) {
      _sawBonding = true;
      return;
    }
    if (observation.state == BleBondState.bonded ||
        observation.state == BleBondState.unbonded &&
            (_sawBonding ||
                observation.previousState == BleBondState.bonding)) {
      _complete(outcome: observation);
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _complete(error: error, stackTrace: stackTrace);
  }

  void _complete({
    AndroidBondStateObservation? outcome,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_result.isCompleted) {
      return;
    }
    _timer.cancel();
    _result.complete((outcome: outcome, error: error, stackTrace: stackTrace));
  }

  Future<void> cancel() async {
    _timer.cancel();
    await _subscription.cancel();
  }
}

void _throwIfBondDidNotComplete(_AndroidBondOutcomeResult result) {
  final error = result.error;
  if (error != null) {
    Error.throwWithStackTrace(error, result.stackTrace ?? StackTrace.current);
  }
  final outcome = result.outcome;
  if (outcome == null) {
    throw StateError('Bond outcome completed without a value');
  }
  if (outcome.state != BleBondState.bonded) {
    throw BleFailure(
      kind: BleFailureKind.bondRejected,
      operation: BleOperation.bond,
      diagnosticCode: 'fbp.bond.not-completed',
    );
  }
}

bool _isGattDisconnectDuringCreateBond(Object error) {
  return error is fbp.FlutterBluePlusException &&
      error.platform == fbp.ErrorPlatform.fbp &&
      error.function == 'createBond' &&
      error.code == fbp.FbpErrorCode.deviceIsDisconnected.index;
}

BleBondState _mapBondState(fbp.BluetoothBondState state) => switch (state) {
  fbp.BluetoothBondState.none => BleBondState.unbonded,
  fbp.BluetoothBondState.bonding => BleBondState.bonding,
  fbp.BluetoothBondState.bonded => BleBondState.bonded,
};

BleBondState? _mapOptionalBondState(fbp.BluetoothBondState? state) {
  return state == null ? null : _mapBondState(state);
}

String _normalizeUuid(String value) => value.toUpperCase();

int _flutterBluePlusTimeoutSeconds(Duration timeout) {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'must be greater than zero');
  }
  return (timeout.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/
      Duration.microsecondsPerSecond;
}

/// Converts plugin/native failures into identifier-free transport failures.
///
/// Native descriptions are inspected only for classification. They are never
/// copied into [BleFailure] because some Android BLE errors include a remote
/// address or characteristic identifier.
BleFailure classifyFlutterBluePlusFailure(
  Object error, {
  required BleOperation operation,
}) {
  if (error is BleFailure) {
    return error;
  }
  if (error is TimeoutException) {
    final kind = switch (operation) {
      BleOperation.adapter => BleFailureKind.bluetoothUnavailable,
      BleOperation.bond => BleFailureKind.bondTimedOut,
      _ => BleFailureKind.operationTimedOut,
    };
    return BleFailure(
      kind: kind,
      operation: operation,
      diagnosticCode: 'dart.${operation.name}.timeout.${kind.name}',
    );
  }

  if (error is fbp.FlutterBluePlusException) {
    final safeFunction = _safePluginFunction(error.function, operation);
    final kind = _classifyBleFailureKind(
      operation: operation,
      signal: '${error.function} ${error.description ?? ''}',
      pluginCode: error.code,
      usesFbpErrorCodes: error.platform == fbp.ErrorPlatform.fbp,
    );
    return BleFailure(
      kind: kind,
      operation: operation,
      diagnosticCode:
          'fbp.${error.platform.name}.$safeFunction.'
          '${error.code ?? 'none'}.${kind.name}',
    );
  }

  if (error is PlatformException) {
    final safeFunction = _safePluginFunction(error.code, operation);
    final kind = _classifyBleFailureKind(
      operation: operation,
      signal: '${error.code} ${error.message ?? ''}',
    );
    return BleFailure(
      kind: kind,
      operation: operation,
      diagnosticCode: 'platform.$safeFunction.${kind.name}',
    );
  }

  final kind = _classifyBleFailureKind(
    operation: operation,
    signal: error.toString(),
  );
  return BleFailure(
    kind: kind,
    operation: operation,
    diagnosticCode: 'ble.${operation.name}.${kind.name}',
  );
}

BleFailureKind _classifyBleFailureKind({
  required BleOperation operation,
  required String signal,
  int? pluginCode,
  bool usesFbpErrorCodes = false,
}) {
  final normalized = signal.toLowerCase();
  final isBondOperation = operation == BleOperation.bond;

  if ((usesFbpErrorCodes &&
          pluginCode == fbp.FbpErrorCode.adapterIsOff.index) ||
      normalized.contains('bluetooth must be turned on') ||
      normalized.contains('adapter is off') ||
      normalized.contains('bluetooth_not_enabled')) {
    return BleFailureKind.bluetoothOff;
  }
  if (normalized.contains('permission') ||
      normalized.contains('unauthorized') ||
      normalized.contains('not allowed') ||
      normalized.contains('location services are required')) {
    return BleFailureKind.permissionRequired;
  }
  if (normalized.contains('not supported') ||
      normalized.contains('unavailable') ||
      normalized.contains('scanner() is null') ||
      normalized.contains('getbluetoothlescanner() is null')) {
    return BleFailureKind.bluetoothUnavailable;
  }
  if (isBondOperation &&
      ((usesFbpErrorCodes && pluginCode == fbp.FbpErrorCode.timeout.index) ||
          normalized.contains('timed out') ||
          normalized.contains('timeout'))) {
    return BleFailureKind.bondTimedOut;
  }
  if ((isBondOperation &&
          (normalized.contains('device.createbond() returned false') ||
              normalized.contains('device is disconnected'))) ||
      normalized.contains('gatt_busy') ||
      normalized.contains('gatt error: 133') ||
      normalized.contains('gatt_error (133)') ||
      normalized.contains('android-code: 133') ||
      (!usesFbpErrorCodes &&
          operation == BleOperation.connect &&
          pluginCode == 133) ||
      normalized.contains('connect') && normalized.contains(' 133')) {
    return BleFailureKind.sensorPossiblyInUse;
  }
  if (normalized.contains('auth_fail') ||
      normalized.contains('insufficient_authentication') ||
      normalized.contains('insufficient_encryption') ||
      normalized.contains('authentication required')) {
    return BleFailureKind.bondRejected;
  }
  if (isBondOperation &&
      ((usesFbpErrorCodes &&
              (pluginCode == fbp.FbpErrorCode.userRejected.index ||
                  pluginCode == fbp.FbpErrorCode.createBondFailed.index)) ||
          normalized.contains('failed to create bond') ||
          normalized.contains('bond-none') ||
          normalized.contains('auth_fail') ||
          normalized.contains('insufficient_authentication') ||
          normalized.contains('insufficient_encryption'))) {
    return BleFailureKind.bondRejected;
  }
  if ((usesFbpErrorCodes &&
          pluginCode == fbp.FbpErrorCode.deviceIsDisconnected.index) ||
      normalized.contains('device is disconnected') ||
      normalized.contains('disconnected')) {
    return BleFailureKind.deviceDisconnected;
  }
  if ((usesFbpErrorCodes && pluginCode == fbp.FbpErrorCode.timeout.index) ||
      normalized.contains('timed out') ||
      normalized.contains('timeout')) {
    return BleFailureKind.operationTimedOut;
  }
  return BleFailureKind.unexpected;
}

String _safePluginFunction(String value, BleOperation fallback) {
  return switch (value) {
    'scan' || 'startScan' => 'scan',
    'connect' => 'connect',
    'discoverServices' => 'discover-services',
    'createBond' || 'getBondState' || 'bondState' => 'bond',
    'requestMtu' => 'request-mtu',
    'readCharacteristic' => 'read',
    'writeCharacteristic' => 'write',
    'setNotifyValue' => 'subscribe',
    'removeBond' => 'remove-bond',
    'disconnect' => 'disconnect',
    _ => fallback.name,
  };
}
