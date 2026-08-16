import 'dart:async';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    as fbpi;

class FlutterBluePlusTransport implements BleTransport {
  const FlutterBluePlusTransport({
    this.androidUsesFineLocation = true,
    this.androidCheckLocationServices = true,
    this.adapterReadyTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 12),
    this.discoveryTimeout = const Duration(seconds: 30),
    this.showPowerAlert = true,
    this.restoreState = false,
  });

  final bool androidUsesFineLocation;
  final bool androidCheckLocationServices;
  final Duration adapterReadyTimeout;
  final Duration operationTimeout;
  final Duration discoveryTimeout;
  final bool showPowerAlert;
  final bool restoreState;

  static Future<void>? _setOptionsFuture;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    final controller = StreamController<BleScanResult>();
    final seen = <String, String>{};

    StreamSubscription<List<fbp.ScanResult>>? resultsSubscription;
    StreamSubscription<bool>? scanningSubscription;
    var startedScan = false;
    var closed = false;

    Future<void> closeStream({bool stopScan = true}) async {
      if (closed) {
        return;
      }
      closed = true;
      await resultsSubscription?.cancel();
      await scanningSubscription?.cancel();
      if (stopScan && fbp.FlutterBluePlus.isScanningNow) {
        await fbp.FlutterBluePlus.stopScan();
      }
      await controller.close();
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
      if (!controller.isClosed) {
        controller.add(mapped);
      }
    }

    controller.onCancel = closeStream;

    unawaited(() async {
      try {
        await _ensureAdapterReady();
        resultsSubscription = fbp.FlutterBluePlus.onScanResults.listen(
          (results) {
            for (final result in results) {
              emitScanResult(result);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            controller.addError(
              classifyFlutterBluePlusFailure(
                error,
                operation: BleOperation.scan,
              ),
              stackTrace,
            );
          },
        );
        scanningSubscription = fbp.FlutterBluePlus.isScanning.listen(
          (scanning) {
            if (startedScan && !scanning) {
              unawaited(closeStream(stopScan: false));
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            controller.addError(
              classifyFlutterBluePlusFailure(
                error,
                operation: BleOperation.scan,
              ),
              stackTrace,
            );
          },
        );
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
      } catch (error, stackTrace) {
        controller.addError(
          classifyFlutterBluePlusFailure(error, operation: BleOperation.scan),
          stackTrace,
        );
        await closeStream(stopScan: false);
      }
    }());

    return controller.stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      await _ensureAdapterReady();
      final device = await connectWithScanStoppedRetry<fbp.BluetoothDevice>(
        stopScan: fbp.FlutterBluePlus.stopScan,
        connect: () async {
          final device = fbp.BluetoothDevice.fromId(deviceId);
          await device.connect(
            // Keep compatibility with the app's locked flutter_blue_plus 2.2.x.
            // ignore: deprecated_member_use
            license: fbp.License.free,
            timeout: timeout,
            mtu: null,
          );
          return device;
        },
        shouldRetry: _shouldRetryAndroidConnect,
        waitBeforeRetry: () =>
            Future<void>.delayed(const Duration(milliseconds: 800)),
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

class _FlutterBluePlusConnection implements BleConnection {
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

  @override
  String get deviceId => _device.remoteId.str;

  @override
  bool get supportsBondLifecycle =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

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
      if (kIsWeb) {
        return;
      }
      if (Platform.isAndroid) {
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
        return;
      }
      if (Platform.isWindows) {
        final remoteId = fbpi.DeviceIdentifier(deviceId);
        await ensureWindowsBond(
          currentState: currentBondState,
          createBond: () => fbpi.FlutterBluePlusPlatform.instance
              .createBond(
                fbpi.BmCreateBondRequest(remoteId: remoteId, pin: null),
              )
              .timeout(const Duration(seconds: 90)),
        );
      }
    });
  }

  @override
  Future<BleBondState> currentBondState() async {
    return _runBleOperation<BleBondState>(BleOperation.bond, () async {
      if (kIsWeb) {
        return BleBondState.bonded;
      }
      if (Platform.isAndroid) {
        final bondState = await _device.bondState.first;
        return _mapBondState(bondState);
      }
      if (Platform.isWindows) {
        final response = await fbpi.FlutterBluePlusPlatform.instance
            .getBondState(
              fbpi.BmBondStateRequest(
                remoteId: fbpi.DeviceIdentifier(deviceId),
              ),
            )
            .timeout(operationTimeout);
        return _mapWindowsBondState(response.bondState);
      }
      return BleBondState.bonded;
    });
  }

  @override
  Future<void> requestMtu(int mtu) async {
    await _runBleOperation<void>(BleOperation.requestMtu, () async {
      if (kIsWeb || !Platform.isAndroid) {
        return;
      }
      await _device.requestMtu(mtu).timeout(operationTimeout);
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
      if (kIsWeb) {
        return;
      }
      final state = await currentBondState();
      if (state == BleBondState.unbonded) {
        return;
      }
      if (Platform.isAndroid) {
        await removeBondWithPluginTimeout<void>(
          (timeoutSeconds) => _device.removeBond(timeout: timeoutSeconds),
          timeout: operationTimeout,
        );
        return;
      }
      if (Platform.isWindows) {
        final remoteId = fbpi.DeviceIdentifier(deviceId);
        await removeWindowsBond(
          removeBond: () => fbpi.FlutterBluePlusPlatform.instance
              .removeBond(fbpi.BmRemoveBondRequest(remoteId: remoteId))
              .timeout(operationTimeout),
          currentState: currentBondState,
        );
      }
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

/// Establishes and verifies a Windows bond through the federated WinRT plugin.
///
/// FlutterBluePlus 2.2.x endorses a Windows implementation, but its public
/// [fbp.BluetoothDevice.createBond] wrapper still rejects non-Android callers.
/// The Windows plugin exposes the same operation through the public federated
/// platform interface. Unlike Android, that plugin completes its native
/// `PairAsync` call with a final result and does not emit intermediate bond
/// events, so verification must use an explicit state read.
@visibleForTesting
Future<void> ensureWindowsBond({
  required Future<BleBondState> Function() currentState,
  required Future<bool> Function() createBond,
}) async {
  if (await currentState() == BleBondState.bonded) {
    return;
  }

  await createBond();
  final finalState = await currentState();
  if (finalState == BleBondState.bonded) {
    return;
  }
  throw BleFailure(
    kind: BleFailureKind.bondRejected,
    operation: BleOperation.bond,
    diagnosticCode: 'fbp.windows.bond.not-completed',
  );
}

/// Removes and verifies a Windows bond after a confirmed sensor transfer.
///
/// This helper is never part of normal disconnect or retry behavior. The
/// protocol layer must clear the sensor-side bond first and call this local
/// operation only through its public, separately confirmed transfer contract.
@visibleForTesting
Future<void> removeWindowsBond({
  required Future<bool> Function() removeBond,
  required Future<BleBondState> Function() currentState,
}) async {
  await removeBond();
  final finalState = await currentState();
  if (finalState == BleBondState.unbonded) {
    return;
  }
  throw BleFailure(
    kind: BleFailureKind.unexpected,
    operation: BleOperation.removeBond,
    diagnosticCode: 'fbp.windows.remove-bond.not-completed',
  );
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

BleBondState _mapWindowsBondState(fbpi.BmBondStateEnum state) =>
    switch (state) {
      fbpi.BmBondStateEnum.none => BleBondState.unbonded,
      fbpi.BmBondStateEnum.bonding => BleBondState.bonding,
      fbpi.BmBondStateEnum.bonded => BleBondState.bonded,
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
