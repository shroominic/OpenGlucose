import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// User-visible phases of a FreeStyle Libre 2 NFC setup attempt.
///
/// This API deliberately contains no tag identifier or protocol payload. A
/// native implementation can therefore update setup UI without exposing
/// restricted sensor data to the widget tree, semantics tree, or screenshots.
enum Libre2NfcSetupPhase {
  idle,
  listening,
  tagDetected,
  reading,
  metadataRead,
  failed,
}

/// Sensor models that the NFC bridge can safely identify for display.
enum Libre2SensorModel { libre2, libre2Plus }

/// CRC-validated Libre 2 lifecycle states that are safe to show.
///
/// These values are the complete Dart-facing vocabulary. The bridge never
/// forwards NFC bytes, identifiers, hashes, or native diagnostic text.
enum Libre2SensorStatus {
  notActivated,
  warmingUp,
  active,
  expired,
  shutdown,
  failure,
  unknown,
}

/// Coarse failure reasons that never include native messages or identifiers.
enum Libre2NfcFailureKind {
  unavailable,
  disabled,
  tagMoved,
  readFailed,
  cleanupUnconfirmed,
}

@immutable
final class Libre2NfcSetupState {
  const Libre2NfcSetupState._({
    required this.phase,
    this.model,
    this.sensorStatus,
    this.failure,
    this.isActivationVerified = false,
    this.isReadExpired = false,
  });

  const Libre2NfcSetupState.idle() : this._(phase: Libre2NfcSetupPhase.idle);

  const Libre2NfcSetupState.listening()
    : this._(phase: Libre2NfcSetupPhase.listening);

  const Libre2NfcSetupState.tagDetected({Libre2SensorModel? model})
    : this._(phase: Libre2NfcSetupPhase.tagDetected, model: model);

  const Libre2NfcSetupState.reading({Libre2SensorModel? model})
    : this._(phase: Libre2NfcSetupPhase.reading, model: model);

  const Libre2NfcSetupState.metadataRead({
    required Libre2SensorModel model,
    required Libre2SensorStatus sensorStatus,
    bool isReadExpired = false,
  }) : this._(
         phase: Libre2NfcSetupPhase.metadataRead,
         model: model,
         sensorStatus: sensorStatus,
         isReadExpired: isReadExpired,
       );

  const Libre2NfcSetupState.failed(Libre2NfcFailureKind failure)
    : this._(phase: Libre2NfcSetupPhase.failed, failure: failure);

  const Libre2NfcSetupState.activationVerified()
    : this._(
        phase: Libre2NfcSetupPhase.metadataRead,
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.warmingUp,
        isActivationVerified: true,
      );

  final Libre2NfcSetupPhase phase;
  final Libre2SensorModel? model;
  final Libre2SensorStatus? sensorStatus;
  final Libre2NfcFailureKind? failure;
  final bool isActivationVerified;

  /// Local UI freshness hint, never native setup authority.
  final bool isReadExpired;
}

/// Historical activation proof only. It does not identify a selected sensor
/// or establish that the sensor is still warming up or connected now.
Future<bool> readLastLibre2ActivationVerified({
  Libre2NfcMethodInvoker? invokeMethod,
}) async {
  try {
    final result =
        await (invokeMethod ??
                (method, args) => const MethodChannel(
                  'com.openglucose/protocol_capture',
                ).invokeMethod<Object?>(method, args))(
              'readLastLibre2ActivationResult',
              const <String, Object?>{},
            )
            .timeout(const Duration(seconds: 10));
    return result is Map &&
        result.length == 2 &&
        result['activation'] == 'verified' &&
        result['lifecycleAtActivation'] == 'warmingUp';
  } catch (_) {
    return false;
  }
}

/// A redacted Dart-facing boundary for the native Libre 2 NFC setup flow.
///
/// Implementations own NFC I/O and emit only the safe states above. Passing a
/// session to a UI owner transfers lifecycle ownership: the owner
/// calls [stop] when setup closes and [dispose] when it is removed.
abstract interface class Libre2NfcSetupSession {
  Stream<Libre2NfcSetupState> get states;

  Future<void> start();

  Future<void> retry();

  Future<void> stop();

  Future<void> dispose();
}

/// Correlates a completed explicit read without exposing sensor identity.
/// Capture this token before stopping the read owner; stop invalidates it.
abstract interface class Libre2NfcCompletedReadAttemptProvider {
  String? get completedReadAttemptId;
}

/// Redacted platform-event adapter for the debug NFC bridge.
///
/// The native event channel is intentionally separate from the method channel
/// that owns restricted capture data. Only a small closed event vocabulary is
/// accepted. Unknown fields, arbitrary strings, and malformed events fail to a
/// generic state and are never forwarded to UI.
typedef Libre2NfcMethodInvoker =
    Future<Object?> Function(String method, Map<String, Object?> arguments);

/// Creates an opaque identifier accepted by the native explicit NFC lane.
///
/// The identifier is used only to cancel the same UI-owned attempt. It does
/// not contain a sensor identifier, protocol data, or other user data.
String newLibre2NfcSetupAttemptId() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
  final random = Random.secure();
  return List<String>.generate(
    24,
    (_) => alphabet[random.nextInt(alphabet.length)],
    growable: false,
  ).join();
}

final class PlatformLibre2NfcSetupSession
    implements Libre2NfcSetupSession, Libre2NfcCompletedReadAttemptProvider {
  PlatformLibre2NfcSetupSession({
    Stream<Object?>? platformEvents,
    Libre2NfcMethodInvoker? invokeMethod,
    String Function()? attemptIdFactory,
    this.activationPollInterval = const Duration(seconds: 1),
    this.methodTimeout = const Duration(seconds: 30),
    this.readValidity = const Duration(seconds: 110),
  }) : _invokeMethod = invokeMethod ?? _invokePlatformMethod,
       _attemptIdFactory = attemptIdFactory ?? newLibre2NfcSetupAttemptId,
       _platformEvents =
           platformEvents ??
           const EventChannel(
             'com.openglucose/protocol_capture_events',
           ).receiveBroadcastStream();

  static const MethodChannel _platformMethods = MethodChannel(
    'com.openglucose/protocol_capture',
  );

  static Future<Object?> _invokePlatformMethod(
    String method,
    Map<String, Object?> arguments,
  ) => _platformMethods.invokeMethod<Object?>(method, arguments);

  final Stream<Object?> _platformEvents;
  final Libre2NfcMethodInvoker _invokeMethod;
  final String Function() _attemptIdFactory;
  final Duration activationPollInterval;
  final Duration methodTimeout;
  // The native 120-second proof remains authoritative. This earlier UI hint
  // leaves a margin for channel delivery and the explicit connection action.
  final Duration readValidity;
  Timer? _readExpiryTimer;
  Future<void>? _pendingCancellation;
  bool _cleanupUncertain = false;
  Timer? _activationPollTimer;
  bool _activationPolling = false;
  final StreamController<Libre2NfcSetupState> _states =
      StreamController<Libre2NfcSetupState>.broadcast(sync: true);
  // Cancelled by both stop() and dispose().
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _platformSubscription;
  String? _activeAttemptId;
  var _activeAttemptReceivedEvent = false;
  var _activeAttemptTerminal = false;
  Libre2NfcSetupState? _lastState;
  var _lifecycleGeneration = 0;
  var _disposing = false;
  var _disposed = false;

  @override
  Stream<Libre2NfcSetupState> get states => _states.stream;

  @override
  String? get completedReadAttemptId =>
      !_disposed &&
          !_disposing &&
          !_cleanupUncertain &&
          _activeAttemptTerminal &&
          _lastState?.phase == Libre2NfcSetupPhase.metadataRead &&
          _lastState?.isReadExpired == false &&
          _lastState?.isActivationVerified == false
      ? _activeAttemptId
      : null;

  @override
  Future<void> start() async {
    if (_disposed ||
        _disposing ||
        _cleanupUncertain ||
        _activeAttemptId != null) {
      return;
    }
    final lifecycleGeneration = ++_lifecycleGeneration;
    final pending = _pendingCancellation;
    if (pending != null) await pending;
    await _startForGeneration(lifecycleGeneration);
  }

  Future<void> _startForGeneration(int lifecycleGeneration) async {
    if (_disposed ||
        _disposing ||
        _cleanupUncertain ||
        lifecycleGeneration != _lifecycleGeneration) {
      return;
    }
    _listenForPlatformEvents();
    if (_activeAttemptId != null) {
      return;
    }
    final attemptId = _attemptIdFactory();
    if (!_isSafeAttemptId(attemptId)) {
      _emit(
        const Libre2NfcSetupState.failed(Libre2NfcFailureKind.readFailed),
      );
      return;
    }
    _activeAttemptId = attemptId;
    _activeAttemptReceivedEvent = false;
    _activeAttemptTerminal = false;
    // State deduplication is attempt-local. A reopened UI must receive the new
    // attempt's listening state even when the previous attempt ended there.
    _lastState = null;
    try {
      await _invokeMethod(
        'startLibre2NfcSetup',
        <String, Object?>{'attemptId': attemptId},
      ).timeout(methodTimeout);
      if (lifecycleGeneration == _lifecycleGeneration &&
          _activeAttemptId == attemptId &&
          !_activeAttemptReceivedEvent) {
        _emit(const Libre2NfcSetupState.listening());
      }
    } on PlatformException catch (error) {
      if (lifecycleGeneration == _lifecycleGeneration &&
          _activeAttemptId == attemptId) {
        _activeAttemptId = null;
        _activeAttemptReceivedEvent = false;
        _emit(
          Libre2NfcSetupState.failed(
            _failureFromPlatformException(error),
          ),
        );
      }
    } catch (_) {
      if (lifecycleGeneration == _lifecycleGeneration &&
          _activeAttemptId == attemptId) {
        _emit(
          const Libre2NfcSetupState.failed(
            Libre2NfcFailureKind.readFailed,
          ),
        );
        await _cancelActiveAttempt();
      }
    }
  }

  @override
  Future<void> retry() async {
    if (_disposed || _disposing || _cleanupUncertain) {
      return;
    }
    final lifecycleGeneration = ++_lifecycleGeneration;
    _listenForPlatformEvents();
    await _cancelActiveAttempt();
    await _startForGeneration(lifecycleGeneration);
  }

  @override
  Future<void> stop() async {
    if (_disposed || _disposing) {
      return;
    }
    final lifecycleGeneration = ++_lifecycleGeneration;
    try {
      await _cancelActiveAttempt();
    } finally {
      if (!_disposed && lifecycleGeneration == _lifecycleGeneration) {
        final subscription = _platformSubscription;
        _platformSubscription = null;
        await _cancelSubscription(subscription);
      }
    }
    if (_disposed || lifecycleGeneration != _lifecycleGeneration) {
      return;
    }
    if (_cleanupUncertain) {
      throw StateError('NFC cleanup could not be confirmed.');
    }
    _emit(const Libre2NfcSetupState.idle());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposing = true;
    _lifecycleGeneration += 1;
    try {
      await _cancelActiveAttempt();
    } finally {
      final subscription = _platformSubscription;
      _platformSubscription = null;
      try {
        await _cancelSubscription(subscription);
      } finally {
        _disposed = true;
        await _states.close();
      }
    }
  }

  void _emit(Libre2NfcSetupState state) {
    if (!_disposed) {
      final previous = _lastState;
      if (previous?.phase == state.phase &&
          previous?.model == state.model &&
          previous?.sensorStatus == state.sensorStatus &&
          previous?.failure == state.failure &&
          previous?.isActivationVerified == state.isActivationVerified &&
          previous?.isReadExpired == state.isReadExpired) {
        return;
      }
      _lastState = state;
      _states.add(state);
    }
  }

  void _listenForPlatformEvents() {
    _platformSubscription ??= _platformEvents.listen(
      _handlePlatformEvent,
      // Event-channel failures are not bound to one explicit attempt. Ignore
      // them here; a bound native failure event or method failure can update
      // the UI without letting a global channel error affect an active scan.
      onError: (Object _, StackTrace _) {},
    );
  }

  void _handlePlatformEvent(Object? event) {
    final attemptId = _activeAttemptId;
    if (attemptId == null) {
      return;
    }
    final activationEvent =
        event is Map && event['event'] == 'activationVerified';
    if (activationEvent ? !_awaitingActivationProof : _activeAttemptTerminal) {
      return;
    }
    final state = libre2NfcSetupStateFromPlatformEvent(
      event,
      activeAttemptId: attemptId,
    );
    if (state == null || _activeAttemptId != attemptId) {
      return;
    }
    _activeAttemptReceivedEvent = true;
    _emit(state);
    if (state.phase == Libre2NfcSetupPhase.metadataRead ||
        state.phase == Libre2NfcSetupPhase.failed) {
      _activeAttemptTerminal = true;
    }
    if (state.phase == Libre2NfcSetupPhase.metadataRead &&
        !state.isActivationVerified) {
      _readExpiryTimer?.cancel();
      _readExpiryTimer = Timer(readValidity, () {
        if (_disposed ||
            _disposing ||
            _activeAttemptId != attemptId ||
            _lastState?.isActivationVerified == true) {
          return;
        }
        _emit(
          Libre2NfcSetupState.metadataRead(
            model: state.model!,
            sensorStatus: state.sensorStatus!,
            isReadExpired: true,
          ),
        );
      });
    }
    if (_awaitingActivationProof) {
      _activationPollTimer ??= Timer.periodic(
        activationPollInterval,
        (_) => unawaited(_pollActivationProof()),
      );
      unawaited(_pollActivationProof());
    } else {
      _activationPollTimer?.cancel();
      _activationPollTimer = null;
    }
  }

  bool get _awaitingActivationProof =>
      _activeAttemptTerminal &&
      _lastState?.phase == Libre2NfcSetupPhase.metadataRead &&
      _lastState?.sensorStatus == Libre2SensorStatus.notActivated &&
      _lastState?.isActivationVerified == false;

  Future<void> _pollActivationProof() async {
    final attemptId = _activeAttemptId;
    if (_activationPolling ||
        !_awaitingActivationProof ||
        attemptId == null ||
        _disposed ||
        _disposing) {
      return;
    }
    _activationPolling = true;
    try {
      final event = await _invokeMethod('readLibre2VerifiedActivation', {
        'attemptId': attemptId,
      }).timeout(const Duration(seconds: 10));
      if (!_disposed && !_disposing && _activeAttemptId == attemptId) {
        _handlePlatformEvent(event);
      }
    } catch (_) {
      // Missing proof does not change the last verified state.
    } finally {
      _activationPolling = false;
    }
  }

  Future<void> _cancelActiveAttempt() {
    _readExpiryTimer?.cancel();
    _readExpiryTimer = null;
    _activationPollTimer?.cancel();
    _activationPollTimer = null;
    final pending = _pendingCancellation;
    if (pending != null) return pending;
    final attemptId = _activeAttemptId;
    _activeAttemptId = null;
    _activeAttemptReceivedEvent = false;
    _activeAttemptTerminal = false;
    if (attemptId == null) {
      return Future<void>.value();
    }
    final cancellation = _stopNativeAttempt(attemptId);
    _pendingCancellation = cancellation;
    return cancellation.whenComplete(() {
      if (identical(_pendingCancellation, cancellation)) {
        _pendingCancellation = null;
      }
    });
  }

  Future<void> _stopNativeAttempt(String attemptId) async {
    try {
      await _invokeMethod(
        'stopLibre2NfcSetup',
        <String, Object?>{'attemptId': attemptId},
      ).timeout(methodTimeout);
    } catch (_) {
      _markCleanupUncertain();
      throw StateError('NFC cleanup could not be confirmed.');
    }
  }

  Future<void> _cancelSubscription(
    StreamSubscription<Object?>? subscription,
  ) async {
    try {
      await subscription?.cancel().timeout(methodTimeout);
    } catch (_) {
      _markCleanupUncertain();
      throw StateError('NFC cleanup could not be confirmed.');
    }
  }

  void _markCleanupUncertain() {
    _cleanupUncertain = true;
    _emit(
      const Libre2NfcSetupState.failed(Libre2NfcFailureKind.cleanupUnconfirmed),
    );
  }
}

bool _isSafeAttemptId(String value) =>
    value.length >= 8 &&
    value.length <= 120 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

Libre2NfcFailureKind _failureFromPlatformException(
  PlatformException error,
) => switch (error.code) {
  'nfc_unavailable' ||
  'nfc_permission_missing' => Libre2NfcFailureKind.unavailable,
  'nfc_disabled' => Libre2NfcFailureKind.disabled,
  _ => Libre2NfcFailureKind.readFailed,
};

/// Temporary adapter for a native capture bridge that has no Dart event stream.
///
/// It provides the honest listening state only. It cannot claim detection,
/// reading, or setup success. Replace it with an event-backed implementation
/// when the native bridge exposes redacted setup events.
final class ListeningOnlyLibre2NfcSetupSession
    implements Libre2NfcSetupSession {
  final StreamController<Libre2NfcSetupState> _states =
      StreamController<Libre2NfcSetupState>.broadcast(sync: true);
  var _disposed = false;

  @override
  Stream<Libre2NfcSetupState> get states => _states.stream;

  @override
  Future<void> start() async {
    _emit(const Libre2NfcSetupState.listening());
  }

  @override
  Future<void> retry() => start();

  @override
  Future<void> stop() async {
    _emit(const Libre2NfcSetupState.idle());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _states.close();
  }

  void _emit(Libre2NfcSetupState state) {
    if (!_disposed) {
      _states.add(state);
    }
  }
}

/// Converts one closed, identifier-free native event for [activeAttemptId].
///
/// Accepted maps carry the exact active attempt identifier, `event`, and only
/// the documented enum fields. A global, stale, malformed, or extended event
/// returns null and cannot update the UI. Rejecting additional keys keeps
/// future native changes from accidentally surfacing restricted values through
/// the UI layer.
Libre2NfcSetupState? libre2NfcSetupStateFromPlatformEvent(
  Object? event, {
  required String activeAttemptId,
}) {
  if (!_isSafeAttemptId(activeAttemptId)) {
    return null;
  }
  if (event is! Map<Object?, Object?>) {
    return null;
  }
  final eventName = event['event'];
  final attemptId = event['attemptId'];
  if (eventName is! String || attemptId != activeAttemptId) {
    return null;
  }
  final allowedKeys = switch (eventName) {
    'listening' => const <String>{'attemptId', 'event'},
    'tagDetected' || 'readingMetadata' => const <String>{
      'attemptId',
      'event',
    },
    'metadataRead' || 'activationVerified' => const <String>{
      'attemptId',
      'event',
      'model',
      'status',
    },
    'failed' => const <String>{'attemptId', 'event', 'reason'},
    _ => const <String>{},
  };
  if (allowedKeys.isEmpty ||
      event.length != allowedKeys.length ||
      event.keys.any((key) => key is! String || !allowedKeys.contains(key))) {
    return null;
  }

  return switch (eventName) {
    'listening' => const Libre2NfcSetupState.listening(),
    'tagDetected' => const Libre2NfcSetupState.tagDetected(),
    'readingMetadata' => const Libre2NfcSetupState.reading(),
    'metadataRead' => _metadataReadState(event),
    'activationVerified' =>
      event['model'] == 'libre2' && event['status'] == 'warmingUp'
          ? const Libre2NfcSetupState.activationVerified()
          : null,
    'failed' => _failedState(event),
    _ => null,
  };
}

Libre2NfcSetupState? _failedState(Map<Object?, Object?> event) {
  final failure = _libre2FailureFromCode(event['reason']);
  return failure == null ? null : Libre2NfcSetupState.failed(failure);
}

Libre2NfcSetupState? _metadataReadState(
  Map<Object?, Object?> event,
) {
  final model = _libre2ModelFromCode(event['model']);
  final status = _libre2StatusFromCode(event['status']);
  if (model != Libre2SensorModel.libre2 || status == null) {
    return null;
  }
  return Libre2NfcSetupState.metadataRead(
    model: Libre2SensorModel.libre2,
    sensorStatus: status,
  );
}

Libre2SensorModel? _libre2ModelFromCode(Object? code) => switch (code) {
  'libre2' => Libre2SensorModel.libre2,
  'libre2Plus' => Libre2SensorModel.libre2Plus,
  null => null,
  _ => null,
};

Libre2SensorStatus? _libre2StatusFromCode(Object? code) => switch (code) {
  'notActivated' => Libre2SensorStatus.notActivated,
  'warmingUp' => Libre2SensorStatus.warmingUp,
  'active' => Libre2SensorStatus.active,
  'expired' => Libre2SensorStatus.expired,
  'shutdown' => Libre2SensorStatus.shutdown,
  'failure' => Libre2SensorStatus.failure,
  'unknown' => Libre2SensorStatus.unknown,
  _ => null,
};

Libre2NfcFailureKind? _libre2FailureFromCode(Object? code) => switch (code) {
  'unavailable' => Libre2NfcFailureKind.unavailable,
  'disabled' => Libre2NfcFailureKind.disabled,
  'tagMoved' => Libre2NfcFailureKind.tagMoved,
  'readFailed' => Libre2NfcFailureKind.readFailed,
  _ => null,
};

String libre2SensorModelLabel(Libre2SensorModel model) => switch (model) {
  Libre2SensorModel.libre2 => 'FreeStyle Libre 2',
  Libre2SensorModel.libre2Plus => 'FreeStyle Libre 2 Plus',
};

String libre2SensorStatusLabel(Libre2SensorStatus status) => switch (status) {
  Libre2SensorStatus.notActivated => 'Not activated',
  Libre2SensorStatus.warmingUp => 'Warming up',
  Libre2SensorStatus.active => 'Active',
  Libre2SensorStatus.expired => 'Expired',
  Libre2SensorStatus.shutdown => 'Shut down',
  Libre2SensorStatus.failure => 'Sensor error',
  Libre2SensorStatus.unknown => 'State unavailable',
};
