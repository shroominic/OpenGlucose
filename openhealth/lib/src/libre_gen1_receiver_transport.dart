import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'libre_gen1_receiver_store.dart';

/// Holds native NFC/BLE exclusion for the exact confirmed Libre receiver.
/// This wrapper is for the Libre driver only, not the shared scan registry.
/// Failed connect without a teardown handle retains the native blocker.
final class LibreGen1ReceiverTransport implements BleSingleAttemptTransport {
  LibreGen1ReceiverTransport({
    required BleTransport delegate,
    required LibreGen1ReceiverStore store,
  }) : _delegate = delegate,
       _store = store;

  final BleTransport _delegate;
  final LibreGen1ReceiverStore _store;
  // Below the driver's outer 15-second close bound. A late physical close
  // cannot resume this wrapper and release an owner already quarantined.
  static const _closeTimeout = Duration(seconds: 5);
  bool _busy = false;

  @override
  bool get supportsSingleAttemptConnect =>
      _delegate is BleSingleAttemptTransport &&
      _delegate.supportsSingleAttemptConnect;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => _delegate.scan(
    timeout: timeout,
    allowDuplicates: allowDuplicates,
    withServices: withServices,
  );

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => connectOnce(deviceId, timeout: timeout);

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_busy || !supportsSingleAttemptConnect) _unavailable();
    _busy = true;
    var acquired = false;
    try {
      final bootstrap = await _store.readBootstrap();
      if (bootstrap == null || bootstrap.deviceId != deviceId.toUpperCase()) {
        _unavailable();
      }
      await _store.acquire(bootstrap);
      acquired = true;
      final connection = await (_delegate as BleSingleAttemptTransport)
          .connectOnce(deviceId, timeout: timeout);
      if (connection.deviceId.toUpperCase() != bootstrap.deviceId) {
        // An unexpected connection still needs confirmed teardown. Neither
        // its identifiers nor arbitrary platform exception text are exposed.
        await connection.disconnect().timeout(_closeTimeout);
        await _store.releaseAfterTransportClosed();
        acquired = false;
        _unavailable();
      }
      return _ReceiverConnection(
        connection,
        _store,
        onClosed: () => _busy = false,
      );
    } catch (_) {
      if (acquired) {
        _store.retainUncertainOwnership();
      } else {
        _busy = false;
      }
      _unavailable();
    }
  }

  static Never _unavailable() => throw const LibreGen1LiveException(
    LibreGen1LiveFailure.bootstrapUnavailable,
  );
}

final class _ReceiverConnection implements BleConnection, BleNegotiatedMtu {
  _ReceiverConnection(this._delegate, this._store, {required this.onClosed});
  final BleConnection _delegate;
  final LibreGen1ReceiverStore _store;
  final void Function() onClosed;
  Future<void>? _close;
  bool _closing = false;

  void _requireOpen() {
    if (_closing) throw StateError('Libre connection is closing.');
  }

  @override
  String get deviceId => _delegate.deviceId;
  @override
  Stream<BleConnectionState> get connectionStates => _delegate.connectionStates;
  @override
  int? get negotiatedMtu => _delegate is BleNegotiatedMtu
      ? (_delegate as BleNegotiatedMtu).negotiatedMtu
      : null;
  @override
  bool get supportsBondLifecycle => false;
  @override
  Future<BleBondState> currentBondState() async => BleBondState.unknown;
  @override
  Future<void> ensureBonded() async =>
      throw UnsupportedError('Libre receiver does not use OS bond setup.');
  @override
  Future<void> removeBond() async =>
      throw UnsupportedError('Libre receiver does not use OS bond removal.');
  @override
  Future<void> requestMtu(int mtu) {
    _requireOpen();
    return _delegate.requestMtu(mtu);
  }

  @override
  Future<List<BleService>> discoverServices() {
    _requireOpen();
    return _delegate.discoverServices();
  }

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) {
    _requireOpen();
    return _delegate.read(characteristic);
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) {
    _requireOpen();
    return _delegate.write(
      characteristic,
      value,
      withoutResponse: withoutResponse,
    );
  }

  @override
  Future<void> setNotify(BleCharacteristicRef characteristic, bool enabled) {
    _requireOpen();
    return _delegate.setNotify(characteristic, enabled);
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) {
    _requireOpen();
    return _delegate.notifications(characteristic);
  }

  @override
  Future<void> disconnect() {
    _closing = true;
    return _close ??= _disconnect();
  }

  Future<void> _disconnect() async {
    try {
      await _delegate.disconnect().timeout(
        LibreGen1ReceiverTransport._closeTimeout,
      );
      await _store.releaseAfterTransportClosed();
      onClosed();
    } catch (_) {
      _store.retainUncertainOwnership();
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.cleanupUnconfirmed,
      );
    }
  }
}
