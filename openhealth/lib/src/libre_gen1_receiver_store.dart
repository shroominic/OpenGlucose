import 'dart:math';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'libre_gen1_secure_store.dart';

enum _Ownership { idle, acquiring, held, releasing, blocked }

/// Recorder-free access to one already-confirmed native receiver. Not enrolled
/// by this class, not registered in the normal driver factory, and never routed
/// to the debug recorder. A lost reply or uncertain close retains ownership.
final class LibreGen1ReceiverStore
    implements LibreGen1StreamingBootstrapProvider, LibreGen1LoginCounterStore {
  LibreGen1ReceiverStore({
    MethodChannel channel = const MethodChannel(channelName),
    @visibleForTesting bool? supported,
    @visibleForTesting String Function()? sessionIdFactory,
    this.operationTimeout = const Duration(seconds: 15),
  }) : _channel = channel,
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _sessionIdFactory = sessionIdFactory ?? _newSessionId {
    _parser = LibreGen1SecureStore.receiver(invokeMethod: _invokeProtected);
  }

  static const channelName = 'com.openglucose/libre2_receiver';
  final MethodChannel _channel;
  final bool _supported;
  final String Function() _sessionIdFactory;
  final Duration operationTimeout;
  late final LibreGen1SecureStore _parser;
  _Ownership _ownership = _Ownership.idle;
  String? _sessionId;
  String? _bootstrapId;
  String? _leaseToken;

  Future<bool> isAvailable() async {
    if (!_supported || _ownership == _Ownership.blocked) return false;
    try {
      final value = await _call('capabilities', const {});
      const keys = {
        'schemaVersion',
        'backend',
        'restoreAvailable',
        'enrollmentAvailable',
        'rawCapture',
      };
      return value is Map &&
          value.length == keys.length &&
          value.keys.every(keys.contains) &&
          value['schemaVersion'] is int &&
          value['schemaVersion'] == 1 &&
          value['backend'] == 'receiver' &&
          value['restoreAvailable'] == true &&
          value['enrollmentAvailable'] == false &&
          value['rawCapture'] == false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<LibreGen1StreamingBootstrap?> readBootstrap() =>
      _parser.readBootstrap();

  Future<LibreGen1CalibrationEvidence?> readCalibrationEvidence(
    LibreGen1StreamingBootstrap bootstrap,
  ) => _parser.readCalibrationEvidence(bootstrap);

  @override
  Future<int> reserveNextUnlockCount(String bootstrapId) =>
      _parser.reserveNextUnlockCount(bootstrapId);

  @override
  Future<void> markLoginOutcome(
    String bootstrapId,
    int unlockCount,
    LibreGen1LoginOutcome outcome,
  ) => _parser.markLoginOutcome(bootstrapId, unlockCount, outcome);

  /// Must complete before the first physical connection attempt. Acquiring a
  /// durable lease can succeed natively even when its reply is lost, so any
  /// dispatched acquire failure blocks reuse rather than trying again.
  Future<void> acquire(LibreGen1StreamingBootstrap bootstrap) async {
    if (_ownership != _Ownership.idle) _unavailable();
    _ownership = _Ownership.acquiring;
    var dispatched = false;
    try {
      if (!await isAvailable()) _unavailable();
      final sessionId = _sessionIdFactory();
      if (!_validToken(sessionId)) _unavailable();
      _sessionId = sessionId;
      _bootstrapId = bootstrap.bootstrapId;
      dispatched = true;
      final token = await _call('acquireLibreGen1Receiver', {
        'sessionId': sessionId,
        'bootstrapId': bootstrap.bootstrapId,
      });
      if (token is! String || !_validToken(token)) _unavailable();
      _leaseToken = token;
      _ownership = _Ownership.held;
    } catch (_) {
      _ownership = dispatched ? _Ownership.blocked : _Ownership.idle;
      _unavailable();
    }
  }

  /// Called only by a connection wrapper after the delegate's confirmed close.
  /// An error or lost reply blocks this Dart owner. Native release may already
  /// have completed when its reply is lost; never infer its result or retry it.
  Future<void> releaseAfterTransportClosed() async {
    if (_ownership != _Ownership.held) _unavailable();
    final binding = _binding();
    _ownership = _Ownership.releasing;
    try {
      final result = await _call('releaseLibreGen1Receiver', {
        ...binding,
        'transportClosed': true,
      }, timeout: const Duration(seconds: 3));
      if (result != null) _unavailable();
      _sessionId = null;
      _bootstrapId = null;
      _leaseToken = null;
      _ownership = _Ownership.idle;
    } catch (_) {
      _ownership = _Ownership.blocked;
      _unavailable();
    }
  }

  /// No native release: a failed connection without a close handle is not
  /// evidence that Android stopped all RF activity.
  void retainUncertainOwnership() {
    _ownership = _Ownership.blocked;
  }

  Future<Object?> _invokeProtected(
    String method,
    Map<String, Object?>? arguments,
  ) async {
    if (!_supported || _ownership == _Ownership.blocked) _unavailable();
    switch (method) {
      case 'readLibreGen1StreamingBootstrap':
      case 'readLibreGen1CalibrationEvidence':
        if (!await isAvailable()) _unavailable();
        return _call(method, arguments);
      case 'reserveLibreGen1UnlockCount':
      case 'markLibreGen1LoginOutcome':
        if (_ownership != _Ownership.held ||
            arguments?['bootstrapId'] != _bootstrapId) {
          _unavailable();
        }
        final result = await _call(method, {...?arguments, ..._binding()});
        if (method == 'markLibreGen1LoginOutcome' && result != null) {
          _unavailable();
        }
        return result;
      default:
        _unavailable();
    }
  }

  Map<String, Object?> _binding() {
    final sessionId = _sessionId;
    final bootstrapId = _bootstrapId;
    final leaseToken = _leaseToken;
    if (sessionId == null || bootstrapId == null || leaseToken == null) {
      _unavailable();
    }
    return {
      'sessionId': sessionId,
      'bootstrapId': bootstrapId,
      'leaseToken': leaseToken,
    };
  }

  Future<Object?> _call(
    String method,
    Map<String, Object?>? arguments, {
    Duration? timeout,
  }) async {
    if (!_supported) _unavailable();
    try {
      return await _channel
          .invokeMethod<Object?>(method, arguments)
          .timeout(timeout ?? operationTimeout);
    } catch (_) {
      _unavailable();
    }
  }

  static Never _unavailable() => throw const LibreGen1LiveException(
    LibreGen1LiveFailure.bootstrapUnavailable,
  );

  static bool _validToken(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value);

  static String _newSessionId() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  @override
  String toString() => 'LibreGen1ReceiverStore(<redacted>)';
}
