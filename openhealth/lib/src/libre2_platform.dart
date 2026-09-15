import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'libre2_nfc_setup.dart';

/// Routes the explicit reader to one native backend, without widening its
/// authority. A missing production bridge never falls back to the recorder.
final class Libre2Platform {
  Libre2Platform({
    this.useDebugCapture = false,
    MethodChannel channel = const MethodChannel('com.openglucose/libre2'),
    Stream<Object?>? events,
    @visibleForTesting bool? supported,
    this.capabilityTimeout = const Duration(seconds: 3),
  }) : _channel = channel,
       _events = events,
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final bool useDebugCapture;
  final MethodChannel _channel;
  final Stream<Object?>? _events;
  final bool _supported;
  final Duration capabilityTimeout;
  final Map<Completer<bool>, Timer> _capabilityChecks = {};
  bool _disposed = false;

  /// Availability is a native capability, not a connection or activation claim.
  /// NFC enabled/foreground/ownership checks are repeated natively on start.
  Future<bool> readAvailable() {
    if (_disposed || !_supported) return Future<bool>.value(false);
    if (useDebugCapture) return Future<bool>.value(kDebugMode);
    final completion = Completer<bool>();
    void finish({required bool available}) {
      if (completion.isCompleted) return;
      _capabilityChecks.remove(completion)?.cancel();
      completion.complete(available && !_disposed);
    }

    _capabilityChecks[completion] = Timer(
      capabilityTimeout,
      () => finish(available: false),
    );
    try {
      unawaited(
        _channel
            .invokeMethod<Object?>('capabilities', const <String, Object?>{})
            .then<void>(
              (value) => finish(available: _validReadOnlyCapabilities(value)),
              onError: (Object _, StackTrace _) => finish(available: false),
            ),
      );
    } catch (_) {
      finish(available: false);
    }
    return completion.future;
  }

  /// Cancels only local capability queries. Read-session owners must still
  /// stop/dispose their session; dispatched native cleanup is never skipped.
  void dispose() {
    _disposed = true;
    final pending = Map<Completer<bool>, Timer>.of(_capabilityChecks);
    _capabilityChecks.clear();
    for (final entry in pending.entries) {
      entry.value.cancel();
      entry.key.complete(false);
    }
  }

  Libre2NfcSetupSession createReadSession() {
    if (_disposed) {
      throw StateError('NFC platform has been disposed.');
    }
    if (useDebugCapture && _supported && kDebugMode) {
      return PlatformLibre2NfcSetupSession();
    }
    var generation = 0;
    String? waitingAttempt;
    final dispatched = <String>{};

    Future<Object?> invokeReadOnly(
      String method,
      Map<String, Object?> arguments,
    ) async {
      final attempt = arguments['attemptId'];
      if (!_supported ||
          attempt is! String ||
          (method != 'startLibre2NfcSetup' && method != 'stopLibre2NfcSetup')) {
        throw PlatformException(code: 'nfc_unavailable');
      }
      if (method == 'stopLibre2NfcSetup') {
        if (waitingAttempt == attempt) {
          generation += 1;
          waitingAttempt = null;
        }
        // Before dispatch there is no native owner to release. Invalidating
        // the generation also prevents a late capability reply from starting
        // an NFC reader after its UI has already closed.
        if (!dispatched.contains(attempt)) return null;
        // Once dispatched, even a failed/timed-out start requires exact native
        // cleanup. Capability loss must not prevent that stop from being sent.
        final result = await _channel.invokeMethod<Object?>(method, arguments);
        dispatched.remove(attempt);
        return result;
      }

      final currentGeneration = ++generation;
      waitingAttempt = attempt;
      final available = await readAvailable();
      if (currentGeneration != generation || waitingAttempt != attempt) {
        throw PlatformException(code: 'nfc_unavailable');
      }
      waitingAttempt = null;
      if (_disposed || !available) {
        throw PlatformException(code: 'nfc_unavailable');
      }
      dispatched.add(attempt);
      return _channel.invokeMethod<Object?>(method, arguments);
    }

    return PlatformLibre2NfcSetupSession(
      platformEvents:
          _events ??
          const EventChannel(
            'com.openglucose/libre2_events',
          ).receiveBroadcastStream(),
      invokeMethod: invokeReadOnly,
      allowActivationProof: false,
      allowCompletedReadHandoff: false,
      allowTerminalReadRevocation: true,
    );
  }

  static bool _validReadOnlyCapabilities(Object? value) {
    const keys = {
      'schemaVersion',
      'backend',
      'readAvailable',
      'activationAvailable',
      'streamingAvailable',
      'receiverAvailable',
      'rawCapture',
    };
    return value is Map &&
        value.length == keys.length &&
        value.keys.every(keys.contains) &&
        value['schemaVersion'] is int &&
        value['schemaVersion'] == 1 &&
        value['backend'] == 'readOnly' &&
        value['readAvailable'] == true &&
        value['activationAvailable'] == false &&
        value['streamingAvailable'] == false &&
        value['receiverAvailable'] == false &&
        value['rawCapture'] == false;
  }
}
