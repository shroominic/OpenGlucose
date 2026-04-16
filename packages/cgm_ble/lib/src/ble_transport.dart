enum BleConnectionState { connecting, connected, disconnected }

enum BleBondState { unknown, unbonded, bonding, bonded }

class BleManufacturerData {
  const BleManufacturerData({required this.companyId, required this.bytes});

  final int companyId;
  final List<int> bytes;
}

class BleScanResult {
  const BleScanResult({
    required this.deviceId,
    required this.deviceName,
    required this.rssi,
    this.serviceUuids = const <String>[],
    this.manufacturerData = const <BleManufacturerData>[],
    this.serviceData = const <String, List<int>>{},
  });

  final String deviceId;
  final String deviceName;
  final int rssi;
  final List<String> serviceUuids;
  final List<BleManufacturerData> manufacturerData;
  final Map<String, List<int>> serviceData;
}

class BleCharacteristicProperties {
  const BleCharacteristicProperties({
    this.read = false,
    this.write = false,
    this.writeWithoutResponse = false,
    this.notify = false,
    this.indicate = false,
  });

  final bool read;
  final bool write;
  final bool writeWithoutResponse;
  final bool notify;
  final bool indicate;
}

class BleCharacteristicRef {
  const BleCharacteristicRef({
    required this.serviceUuid,
    required this.characteristicUuid,
    this.properties = const BleCharacteristicProperties(),
  });

  final String serviceUuid;
  final String characteristicUuid;
  final BleCharacteristicProperties properties;

  BleCharacteristicRef copyWith({
    String? serviceUuid,
    String? characteristicUuid,
    BleCharacteristicProperties? properties,
  }) {
    return BleCharacteristicRef(
      serviceUuid: serviceUuid ?? this.serviceUuid,
      characteristicUuid: characteristicUuid ?? this.characteristicUuid,
      properties: properties ?? this.properties,
    );
  }
}

class BleService {
  const BleService({required this.uuid, required this.characteristics});

  final String uuid;
  final List<BleCharacteristicRef> characteristics;
}

abstract interface class BleTransport {
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  });

  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  });
}

abstract interface class BleConnection {
  String get deviceId;
  Stream<BleConnectionState> get connectionStates;
  bool get supportsBondLifecycle;

  Future<void> ensureBonded();

  Future<BleBondState> currentBondState();

  Future<void> requestMtu(int mtu);

  Future<List<BleService>> discoverServices();

  Future<List<int>> read(BleCharacteristicRef characteristic);

  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  });

  Future<void> setNotify(BleCharacteristicRef characteristic, bool enabled);

  Stream<List<int>> notifications(BleCharacteristicRef characteristic);

  Future<void> removeBond();

  Future<void> disconnect();
}
