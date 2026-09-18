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
    this.observedAt,
  });

  final String deviceId;
  final String deviceName;
  final int rssi;
  final List<String> serviceUuids;
  final List<BleManufacturerData> manufacturerData;
  final Map<String, List<int>> serviceData;

  /// Time of the actual advertisement observation, not cached replay delivery.
  /// Null means the transport cannot prove when it observed the advertisement.
  final DateTime? observedAt;
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

/// Optional transport contract for one explicit physical connection attempt.
///
/// Implementations must not retry, install automatic reconnection, or create
/// or remove bonds. Wrappers must preserve this contract end to end; when the
/// underlying transport cannot supply it they report false and fail without
/// falling back to [BleTransport.connect]. Existing connect behavior is intact.
abstract interface class BleSingleAttemptTransport implements BleTransport {
  bool get supportsSingleAttemptConnect;

  Future<BleConnection> connectOnce(
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

  /// Writes [value] and, unless [withoutResponse] is true, completes only
  /// after the peer's ATT Write Response confirms acceptance.
  ///
  /// A timeout or disconnect before that response has an unknown outcome.
  /// Callers must not retry an irreversible write automatically.
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

/// Optional connection capability that reports the ATT MTU actually agreed
/// with the peer. A completed MTU request alone is not proof of this value.
abstract interface class BleNegotiatedMtu {
  int? get negotiatedMtu;
}
