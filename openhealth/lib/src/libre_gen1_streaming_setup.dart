import 'dart:async';

import 'package:flutter/services.dart';

import 'libre2_nfc_setup.dart';

enum LibreGen1StreamingPhase {
  idle,
  listening,
  tagDetected,
  readingMetadata,
  enablingStreaming,
  streamingEnabled,
  failed,
}

enum LibreGen1StreamingFailure {
  readFailed,
  tagMoved,
  expired,
  cancelled,
  outcomeUnknown,
}

final class LibreGen1StreamingState {
  const LibreGen1StreamingState(
    this.phase, {
    this.lifecycle,
    this.failure,
    this.isSavedReceiver = false,
    this.canRepeatReadOnlyCheck = false,
  });

  final LibreGen1StreamingPhase phase;
  final Libre2SensorStatus? lifecycle;
  final LibreGen1StreamingFailure? failure;
  final bool isSavedReceiver;

  /// True only when failure occurred before any native streaming start call.
  final bool canRepeatReadOnlyCheck;

  bool get isTerminal =>
      phase == LibreGen1StreamingPhase.streamingEnabled ||
      phase == LibreGen1StreamingPhase.failed;
}

/// A one-shot NFC setup owner. No UID, key, address or response enters the UI.
abstract interface class LibreGen1StreamingSession {
  Stream<LibreGen1StreamingState> get states;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}

LibreGen1StreamingState? libreGen1StreamingStateFromPlatformEvent(
  Object? event, {
  required String activeAttemptId,
}) {
  if (event is! Map ||
      event['operation'] != 'libreGen1Streaming' ||
      event['attemptId'] != activeAttemptId) {
    return null;
  }
  final name = event['event'];
  final expected = <String>{'operation', 'attemptId', 'event'};
  if (name == 'streamingEnabled') expected.add('lifecycle');
  if (name == 'failed') expected.add('reason');
  if (event.length != expected.length ||
      event.keys.any((key) => !expected.contains(key))) {
    return null;
  }
  final phase = switch (name) {
    'listening' => LibreGen1StreamingPhase.listening,
    'tagDetected' => LibreGen1StreamingPhase.tagDetected,
    'readingMetadata' => LibreGen1StreamingPhase.readingMetadata,
    'enablingStreaming' => LibreGen1StreamingPhase.enablingStreaming,
    'streamingEnabled' => LibreGen1StreamingPhase.streamingEnabled,
    'failed' => LibreGen1StreamingPhase.failed,
    _ => null,
  };
  if (phase == null) return null;
  if (phase == LibreGen1StreamingPhase.streamingEnabled) {
    final lifecycle = switch (event['lifecycle']) {
      'warmingUp' => Libre2SensorStatus.warmingUp,
      'active' => Libre2SensorStatus.active,
      _ => null,
    };
    return lifecycle == null
        ? null
        : LibreGen1StreamingState(phase, lifecycle: lifecycle);
  }
  if (phase == LibreGen1StreamingPhase.failed) {
    final failure = switch (event['reason']) {
      'readFailed' => LibreGen1StreamingFailure.readFailed,
      'tagMoved' => LibreGen1StreamingFailure.tagMoved,
      'expired' => LibreGen1StreamingFailure.expired,
      'cancelled' => LibreGen1StreamingFailure.cancelled,
      'outcomeUnknown' => LibreGen1StreamingFailure.outcomeUnknown,
      _ => null,
    };
    return failure == null
        ? null
        : LibreGen1StreamingState(phase, failure: failure);
  }
  return LibreGen1StreamingState(phase);
}

/// Uses the shared event channel only after the previous reader has stopped.
/// Retained, attempt-bound status recovers events lost during subscription.
/// A read-only native proof reuses an existing same-sensor receiver before any
/// NFC setup attempt. Current NFC evidence need not equal frozen BLE keys.
final class PlatformLibreGen1StreamingSession
    implements LibreGen1StreamingSession {
  PlatformLibreGen1StreamingSession({
    required this.sourceReadAttemptId,
    Stream<Object?>? platformEvents,
    Libre2NfcMethodInvoker? invokeMethod,
    String Function()? attemptIdFactory,
    this.pollInterval = const Duration(milliseconds: 500),
    this.methodTimeout = const Duration(seconds: 30),
    this.pollTimeout = const Duration(seconds: 10),
  }) : _events =
           platformEvents ??
           const EventChannel(
             'com.openglucose/protocol_capture_events',
           ).receiveBroadcastStream(),
       _invoke = invokeMethod ?? _platformInvoke,
       _attemptIdFactory = attemptIdFactory ?? newLibre2NfcSetupAttemptId;

  static const _channel = MethodChannel('com.openglucose/protocol_capture');
  static Future<Object?> _platformInvoke(
    String method,
    Map<String, Object?> arguments,
  ) => _channel.invokeMethod<Object?>(method, arguments);

  final Stream<Object?> _events;
  final String? sourceReadAttemptId;
  final Libre2NfcMethodInvoker _invoke;
  final String Function() _attemptIdFactory;
  final Duration pollInterval;
  final Duration methodTimeout;
  final Duration pollTimeout;
  final _states = StreamController<LibreGen1StreamingState>.broadcast(
    sync: true,
  );
  // Both stop and dispose cancel the subscription and timer.
  StreamSubscription<Object?>? _subscription;
  Timer? _pollTimer;
  String? _attemptId;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  bool _used = false;
  bool _disposed = false;
  bool _stopping = false;
  bool _polling = false;
  bool _cleanupUncertain = false;
  LibreGen1StreamingState _state = const LibreGen1StreamingState(
    LibreGen1StreamingPhase.idle,
  );

  @override
  Stream<LibreGen1StreamingState> get states => _states.stream;

  @override
  Future<void> start() {
    if (_used || _disposed || _stopping || _cleanupUncertain) {
      return _startFuture ?? Future<void>.value();
    }
    _used = true;
    return _startFuture = Future<void>.microtask(_start);
  }

  Future<void> _start() async {
    if (_disposed || _stopping) return;
    final sourceAttempt = sourceReadAttemptId;
    if (sourceAttempt == null ||
        sourceAttempt.length < 8 ||
        sourceAttempt.length > 120 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sourceAttempt)) {
      _fail(LibreGen1StreamingFailure.readFailed, readOnly: true);
      return;
    }
    try {
      final proof = await _invoke(
        'readLibreGen1ReceiverReuseProof',
        <String, Object?>{'attemptId': sourceAttempt},
      ).timeout(methodTimeout);
      if (_disposed || _stopping) return;
      if (proof != null) {
        final lifecycle = proof is Map
            ? switch (proof['lifecycle']) {
                'warmingUp' => Libre2SensorStatus.warmingUp,
                'active' => Libre2SensorStatus.active,
                _ => null,
              }
            : null;
        if (proof is! Map ||
            proof.length != 4 ||
            proof['attemptId'] != sourceAttempt ||
            proof['event'] != 'receiverReusable' ||
            proof['model'] != 'libre2' ||
            lifecycle == null ||
            !proof.keys.every(
              const {'attemptId', 'event', 'model', 'lifecycle'}.contains,
            )) {
          _fail(LibreGen1StreamingFailure.readFailed, readOnly: true);
          return;
        }
        _emit(
          LibreGen1StreamingState(
            LibreGen1StreamingPhase.streamingEnabled,
            lifecycle: lifecycle,
            isSavedReceiver: true,
          ),
        );
        return;
      }
    } catch (_) {
      // This is a read-only preflight. Failure is not evidence of an unknown
      // sensor write and must never fall through to a fresh enable attempt.
      if (!_disposed && !_stopping) {
        _fail(LibreGen1StreamingFailure.readFailed, readOnly: true);
      }
      return;
    }
    final attemptId = _attemptIdFactory();
    if (attemptId.length < 8 ||
        attemptId.length > 120 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(attemptId)) {
      _fail(LibreGen1StreamingFailure.readFailed, readOnly: true);
      return;
    }
    _attemptId = attemptId;
    _subscription = _events.listen(
      _accept,
      onError: (Object _, StackTrace _) {},
    );
    try {
      await _invoke('startLibreGen1Streaming', {
        'attemptId': attemptId,
      }).timeout(methodTimeout);
      if (_disposed || _stopping || _state.isTerminal) return;
      if (_state.phase == LibreGen1StreamingPhase.idle) {
        _emit(const LibreGen1StreamingState(LibreGen1StreamingPhase.listening));
      }
      _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
      await _poll();
    } catch (_) {
      if (!_disposed && !_stopping && !_state.isTerminal) {
        _fail(LibreGen1StreamingFailure.outcomeUnknown);
        // Queue the matching stop even when start's native result is late.
        // A timeout never authorizes another attempt or proves no write.
        unawaited(stop().catchError((Object _) {}));
      }
    }
  }

  Future<void> _poll() async {
    final attemptId = _attemptId;
    if (_polling ||
        _disposed ||
        _stopping ||
        _state.isTerminal ||
        attemptId == null) {
      return;
    }
    _polling = true;
    try {
      final event = await _invoke('readLibreGen1StreamingStatus', {
        'attemptId': attemptId,
      }).timeout(pollTimeout);
      if (!_stopping && !_disposed && _attemptId == attemptId) _accept(event);
    } catch (_) {
      // A transient channel failure cannot change a sensor outcome.
    } finally {
      _polling = false;
    }
  }

  void _accept(Object? event) {
    final attemptId = _attemptId;
    if (_disposed || _stopping || _state.isTerminal || attemptId == null) {
      return;
    }
    final next = libreGen1StreamingStateFromPlatformEvent(
      event,
      activeAttemptId: attemptId,
    );
    if (next == null || next.phase.index < _state.phase.index) return;
    _emit(next);
  }

  void _emit(LibreGen1StreamingState state) {
    if (_disposed) return;
    if (_state.phase == state.phase &&
        _state.lifecycle == state.lifecycle &&
        _state.failure == state.failure &&
        _state.isSavedReceiver == state.isSavedReceiver &&
        _state.canRepeatReadOnlyCheck == state.canRepeatReadOnlyCheck) {
      return;
    }
    _state = state;
    if (state.isTerminal) _pollTimer?.cancel();
    _states.add(state);
  }

  void _fail(LibreGen1StreamingFailure reason, {bool readOnly = false}) =>
      _emit(
        LibreGen1StreamingState(
          LibreGen1StreamingPhase.failed,
          failure: reason,
          canRepeatReadOnlyCheck: readOnly,
        ),
      );

  @override
  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _stopping = true;
    _pollTimer?.cancel();
    await _startFuture;
    final attemptId = _attemptId;
    try {
      if (attemptId != null) {
        await _invoke('stopLibreGen1Streaming', {
          'attemptId': attemptId,
        }).timeout(methodTimeout);
      }
    } catch (_) {
      _cleanupUncertain = true;
      _fail(LibreGen1StreamingFailure.outcomeUnknown);
    } finally {
      try {
        await _subscription?.cancel().timeout(methodTimeout);
      } catch (_) {
        _cleanupUncertain = true;
        _fail(LibreGen1StreamingFailure.outcomeUnknown);
      }
      _subscription = null;
    }
    if (_cleanupUncertain) {
      throw StateError('NFC setup cleanup could not be confirmed.');
    }
    _attemptId = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await stop();
    } finally {
      _disposed = true;
      await _states.close();
    }
  }
}
