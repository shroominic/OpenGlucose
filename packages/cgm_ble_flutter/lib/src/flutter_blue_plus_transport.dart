import 'dart:async';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

class FlutterBluePlusTransport implements BleTransport {
  const FlutterBluePlusTransport({
    this.androidUsesFineLocation = true,
    this.androidCheckLocationServices = true,
    this.adapterReadyTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 12),
    this.showPowerAlert = true,
    this.restoreState = false,
  });

  final bool androidUsesFineLocation;
  final bool androidCheckLocationServices;
  final Duration adapterReadyTimeout;
  final Duration operationTimeout;
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
        resultsSubscription = fbp.FlutterBluePlus.onScanResults.listen((
          results,
        ) {
          for (final result in results) {
            emitScanResult(result);
          }
        }, onError: controller.addError);
        scanningSubscription = fbp.FlutterBluePlus.isScanning.listen((
          scanning,
        ) {
          if (startedScan && !scanning) {
            unawaited(closeStream(stopScan: false));
          }
        }, onError: controller.addError);
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
        controller.addError(error, stackTrace);
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
    await _ensureAdapterReady();
    final device = fbp.BluetoothDevice.fromId(deviceId);
    try {
      await device.connect(
        // Keep compatibility with the app's locked flutter_blue_plus 2.2.x.
        // ignore: deprecated_member_use
        license: fbp.License.free,
        timeout: timeout,
        mtu: null,
      );
    } catch (error) {
      if (!_shouldRetryAndroidConnect(error)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await device.connect(
        // Keep compatibility with the app's locked flutter_blue_plus 2.2.x.
        // ignore: deprecated_member_use
        license: fbp.License.free,
        timeout: timeout,
        mtu: null,
      );
    }
    return _FlutterBluePlusConnection(
      device,
      operationTimeout: operationTimeout,
    );
  }

  Future<void> _ensureAdapterReady() async {
    await _ensureConfigured();
    final state = await fbp.FlutterBluePlus.adapterState
        .where(
          (value) =>
              value != fbp.BluetoothAdapterState.unknown &&
              value != fbp.BluetoothAdapterState.turningOn,
        )
        .first
        .timeout(adapterReadyTimeout);
    if (state != fbp.BluetoothAdapterState.on) {
      throw StateError('Bluetooth adapter is ${state.name}.');
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

class _FlutterBluePlusConnection implements BleConnection {
  _FlutterBluePlusConnection(this._device, {required this.operationTimeout});

  final fbp.BluetoothDevice _device;
  final Duration operationTimeout;
  final Map<String, fbp.BluetoothCharacteristic> _characteristics =
      <String, fbp.BluetoothCharacteristic>{};

  @override
  String get deviceId => _device.remoteId.str;

  @override
  bool get supportsBondLifecycle => !kIsWeb && Platform.isAndroid;

  @override
  Stream<BleConnectionState> get connectionStates =>
      _device.connectionState.map(
        (state) => switch (state) {
          fbp.BluetoothConnectionState.connected =>
            BleConnectionState.connected,
          _ => BleConnectionState.disconnected,
        },
      );

  @override
  Future<void> ensureBonded() async {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    final currentState = await currentBondState();
    if (currentState == BleBondState.bonded) {
      return;
    }
    if (currentState == BleBondState.bonding) {
      final settledState = await _device.bondState
          .where((state) => state != fbp.BluetoothBondState.bonding)
          .first
          .timeout(operationTimeout);
      if (settledState != fbp.BluetoothBondState.bonded) {
        throw StateError('Failed to create bond. $settledState');
      }
      return;
    }
    await _device.createBond();
  }

  @override
  Future<BleBondState> currentBondState() async {
    if (kIsWeb || !Platform.isAndroid) {
      return BleBondState.bonded;
    }
    final bondState = await _device.bondState.first;
    return switch (bondState) {
      fbp.BluetoothBondState.none => BleBondState.unbonded,
      fbp.BluetoothBondState.bonding => BleBondState.bonding,
      fbp.BluetoothBondState.bonded => BleBondState.bonded,
    };
  }

  @override
  Future<void> requestMtu(int mtu) async {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    await _device.requestMtu(mtu).timeout(operationTimeout);
  }

  @override
  Future<List<BleService>> discoverServices() async {
    final services = await _device.discoverServices().timeout(operationTimeout);
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
  }

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async {
    final resolved = await _resolveCharacteristic(characteristic);
    return resolved.read().timeout(operationTimeout);
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final resolved = await _resolveCharacteristic(characteristic);
    await resolved
        .write(value, withoutResponse: withoutResponse)
        .timeout(operationTimeout);
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    final resolved = await _resolveCharacteristic(characteristic);
    await resolved.setNotifyValue(enabled).timeout(operationTimeout);
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) async* {
    final resolved = await _resolveCharacteristic(characteristic);
    yield* resolved.onValueReceived;
  }

  @override
  Future<void> removeBond() async {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    final state = await currentBondState();
    if (state == BleBondState.unbonded) {
      return;
    }
    await _device.removeBond().timeout(operationTimeout);
  }

  @override
  Future<void> disconnect() async {
    if (_device.isConnected) {
      await _device.disconnect().timeout(operationTimeout);
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
    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      for (final characteristic in service.characteristics) {
        _characteristics[_characteristicKey(
              serviceUuid,
              _normalizeUuid(characteristic.uuid.toString()),
            )] =
            characteristic;
      }
    }
  }

  String _characteristicKey(String serviceUuid, String characteristicUuid) {
    return '${_normalizeUuid(serviceUuid)}|${_normalizeUuid(characteristicUuid)}';
  }
}

String _normalizeUuid(String value) => value.toUpperCase();
