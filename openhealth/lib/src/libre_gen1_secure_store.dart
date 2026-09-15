import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef LibreGen1StoreInvoker =
    Future<Object?> Function(String method, Map<String, Object?>? arguments);

/// Restricted historical factory evidence, not current sensor state or a
/// glucose reading. Only the calibrated decoder may interpret these bytes.
final class LibreGen1CalibrationEvidence {
  LibreGen1CalibrationEvidence._({
    required this.bootstrapId,
    required List<int> uid,
    required List<int> receiverInitialPatchInfo,
    required List<int> calibrationPatchInfo,
    required List<int> encryptedFram,
  }) : uid = List<int>.unmodifiable(uid),
       receiverInitialPatchInfo = List<int>.unmodifiable(
         receiverInitialPatchInfo,
       ),
       calibrationPatchInfo = List<int>.unmodifiable(calibrationPatchInfo),
       encryptedFram = List<int>.unmodifiable(encryptedFram);

  final String bootstrapId;
  final List<int> uid;

  /// Frozen Bluetooth receiver credential; never replaced by a later NFC read.
  final List<int> receiverInitialPatchInfo;

  /// Patch information read with this FRAM; its seed can differ from the receiver.
  final List<int> calibrationPatchInfo;
  final List<int> encryptedFram;

  @override
  String toString() => 'LibreGen1CalibrationEvidence(<redacted>)';
}

/// Narrow bridge to the native, journaled Libre receiver state. Restricted
/// bytes stay in this provider and the driver, never in UI state or errors.
final class LibreGen1SecureStore
    implements LibreGen1StreamingBootstrapProvider, LibreGen1LoginCounterStore {
  LibreGen1SecureStore({
    MethodChannel channel = const MethodChannel(channelName),
    @visibleForTesting bool? supported,
  }) : _channel = channel,
       _invokeMethod = null,
       _supported =
           supported ??
           (!kIsWeb &&
               kDebugMode &&
               defaultTargetPlatform == TargetPlatform.android);

  /// Parser shared with the recorder-free native receiver owner. This does not
  /// select a backend or grant RF access; [invokeMethod] must enforce native
  /// capability and exact live ownership for every counter operation.
  LibreGen1SecureStore.receiver({required LibreGen1StoreInvoker invokeMethod})
    : _channel = null,
      _invokeMethod = invokeMethod,
      _supported = true;

  static const channelName = 'com.openglucose/protocol_capture';
  static const _bootstrapKeys = <String>{
    'bootstrapId',
    'deviceId',
    'uid',
    'initialPatchInfo',
    'streamingBase',
    'lifecycle',
  };
  static const _calibrationKeys = <String>{
    'bootstrapId',
    'uid',
    'receiverInitialPatchInfo',
    'calibrationPatchInfo',
    'encryptedFram',
  };
  final MethodChannel? _channel;
  final LibreGen1StoreInvoker? _invokeMethod;
  final bool _supported;

  @override
  Future<LibreGen1StreamingBootstrap?> readBootstrap() async {
    final value = await _invoke('readLibreGen1StreamingBootstrap');
    if (value == null) return null;
    try {
      if (value is! Map ||
          value.length != _bootstrapKeys.length ||
          !value.keys.every(_bootstrapKeys.contains)) {
        throw const FormatException();
      }
      final bootstrapId = value['bootstrapId'];
      final deviceId = value['deviceId'];
      final base = value['streamingBase'];
      final lifecycle = switch (value['lifecycle']) {
        'warmingUp' => LibreGen1LifecycleState.warmingUp,
        'active' => LibreGen1LifecycleState.active,
        _ => throw const FormatException(),
      };
      if (bootstrapId is! String ||
          !_validToken(bootstrapId) ||
          deviceId is! String ||
          !RegExp(r'^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(deviceId) ||
          base is! int ||
          base < 0 ||
          base >= 0xffffffff) {
        throw const FormatException();
      }
      return LibreGen1StreamingBootstrap(
        bootstrapId: bootstrapId,
        deviceId: deviceId,
        uid: LibreGen1Uid.algorithmOrder(_bytes(value['uid'], 8)),
        initialPatchInfo: LibreGen1PatchInfo(
          _bytes(value['initialPatchInfo'], 6),
        ),
        streamingBase: base,
        lifecycle: lifecycle,
      );
    } catch (_) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.invalidBootstrap);
    }
  }

  /// Reads only native-validated evidence for this exact confirmed receiver.
  /// The native reader verifies every FRAM CRC. The decoder must also verify
  /// its input; none of this evidence belongs in UI, telemetry, or health data.
  /// Missing, different-sensor, and corrupt private records return null.
  Future<LibreGen1CalibrationEvidence?> readCalibrationEvidence(
    LibreGen1StreamingBootstrap bootstrap,
  ) async {
    if (!_validToken(bootstrap.bootstrapId)) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.invalidBootstrap);
    }
    final value = await _invoke('readLibreGen1CalibrationEvidence', {
      'bootstrapId': bootstrap.bootstrapId,
    });
    if (value == null) return null;
    try {
      if (value is! Map ||
          value.length != _calibrationKeys.length ||
          !value.keys.every(_calibrationKeys.contains) ||
          value['bootstrapId'] != bootstrap.bootstrapId) {
        throw const FormatException();
      }
      final uid = _bytes(value['uid'], 8);
      final receiverPatch = _bytes(value['receiverInitialPatchInfo'], 6);
      final calibrationPatch = _bytes(value['calibrationPatchInfo'], 6);
      final fram = _bytes(value['encryptedFram'], 344);
      if (!listEquals(uid, bootstrap.uid.value.bytes) ||
          !listEquals(receiverPatch, bootstrap.initialPatchInfo.value.bytes) ||
          !listEquals(
            receiverPatch.sublist(0, 4),
            calibrationPatch.sublist(0, 4),
          ) ||
          uid[6] != 7 ||
          uid[7] != 0xe0 ||
          bootstrap.initialPatchInfo.model != LibreGen1Model.libre2 ||
          LibreGen1PatchInfo(calibrationPatch).model != LibreGen1Model.libre2) {
        throw const FormatException();
      }
      return LibreGen1CalibrationEvidence._(
        bootstrapId: bootstrap.bootstrapId,
        uid: uid,
        receiverInitialPatchInfo: receiverPatch,
        calibrationPatchInfo: calibrationPatch,
        encryptedFram: fram,
      );
    } catch (_) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.invalidBootstrap);
    }
  }

  @override
  Future<int> reserveNextUnlockCount(String bootstrapId) async {
    if (!_validToken(bootstrapId)) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.counterUnavailable,
      );
    }
    final value = await _invoke('reserveLibreGen1UnlockCount', {
      'bootstrapId': bootstrapId,
    });
    if (value is! int || value < 1 || value > 0xffff) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.counterUnavailable,
      );
    }
    return value;
  }

  @override
  Future<void> markLoginOutcome(
    String bootstrapId,
    int unlockCount,
    LibreGen1LoginOutcome outcome,
  ) async {
    if (!_validToken(bootstrapId) || unlockCount < 1 || unlockCount > 0xffff) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.counterUnavailable,
      );
    }
    await _invoke('markLibreGen1LoginOutcome', {
      'bootstrapId': bootstrapId,
      'unlockCount': unlockCount,
      'outcome': outcome.name,
    });
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!_supported) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.bootstrapUnavailable,
      );
    }
    try {
      final invoke = _invokeMethod;
      final result = invoke != null
          ? invoke(method, arguments)
          : _channel!.invokeMethod<Object?>(method, arguments);
      return await result.timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.bootstrapUnavailable,
      );
    }
  }

  static bool _validToken(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value);

  static List<int> _bytes(Object? value, int length) {
    if (value is! List ||
        value.length != length ||
        value.any((byte) => byte is! int || byte < 0 || byte > 255)) {
      throw const FormatException();
    }
    return List<int>.of(value.cast<int>());
  }
}
