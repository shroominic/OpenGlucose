import 'dart:async';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'libre2_nfc_setup.dart';
import 'libre_gen1_fresh_nfc_history.dart';
import 'libre_nfc_history_sync.dart';

/// One explicit recorder-free read of an already-saved receiver. Construction
/// performs no I/O. It never falls back to capture, enrollment or calibration.
/// Create one platform per sync; disposing its bound session disposes this owner.
final class LibreGen1ReceiverHistoryPlatform {
  LibreGen1ReceiverHistoryPlatform({
    MethodChannel channel = const MethodChannel(channelName),
    Stream<Object?>? events,
    @visibleForTesting bool? supported,
    this.capabilityTimeout = const Duration(seconds: 3),
    @visibleForTesting this.methodTimeout = const Duration(seconds: 30),
  }) : _channel = channel,
       _events = events,
       _supported =
           supported ??
           (!kIsWeb &&
               kDebugMode &&
               defaultTargetPlatform == TargetPlatform.android) {
    if (capabilityTimeout <= Duration.zero || methodTimeout <= Duration.zero) {
      throw ArgumentError('History platform timeouts must be positive.');
    }
  }

  static const channelName = 'com.openglucose/libre2_receiver';
  static const eventsName = 'com.openglucose/libre2_receiver_history_events';
  final MethodChannel _channel;
  final Stream<Object?>? _events;
  final bool _supported;
  final Duration capabilityTimeout;
  final Duration methodTimeout;
  final Map<Completer<bool>, Timer> _capabilities = {};
  final List<LibreGen1FreshNfcHistoryReader> _readers = [];
  _ReceiverHistorySession? _session;
  bool _disposed = false;

  Future<bool> readAvailable() {
    if (_disposed || !_supported) return Future.value(false);
    final completion = Completer<bool>();
    void finish({required bool available}) {
      if (completion.isCompleted) return;
      _capabilities.remove(completion)?.cancel();
      completion.complete(available && !_disposed);
    }

    _capabilities[completion] = Timer(
      capabilityTimeout,
      () => finish(available: false),
    );
    unawaited(
      Future<Object?>.sync(
        () => _channel.invokeMethod<Object?>(
          'historyCapabilities',
          const <String, Object?>{},
        ),
      ).then<void>(
        (value) => finish(available: _validCapabilities(value)),
        onError: (Object _, StackTrace _) => finish(available: false),
      ),
    );
    return completion.future;
  }

  Libre2NfcSetupSession createReadSession(
    LibreGen1StreamingBootstrap bootstrap,
  ) {
    if (_disposed ||
        _session != null ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(bootstrap.bootstrapId)) {
      throw StateError('Receiver history session is unavailable.');
    }
    // Validates the exact immutable UID/frozen-model binding without a read.
    LibreGen1ObservationBinding.forSensor(
      bootstrapId: bootstrap.bootstrapId,
      uid: bootstrap.uid,
      initialPatchInfo: bootstrap.initialPatchInfo,
    );
    return _session = _ReceiverHistorySession(this, bootstrap.bootstrapId);
  }

  LibreGen1FreshNfcHistoryReader createFreshReader() {
    if (_disposed) {
      throw StateError('Receiver history platform is unavailable.');
    }
    final reader = LibreGen1FreshNfcHistoryReader(
      channel: _ReceiverEvidenceChannel(this),
    );
    _readers.add(reader);
    return reader;
  }

  Future<Object?> _readEvidence(String method, Object? arguments) async {
    final session = _session;
    if (_disposed ||
        !_supported ||
        method != LibreGen1FreshNfcHistoryReader.methodName ||
        arguments is! Map<String, Object?> ||
        arguments.length != 2 ||
        session == null ||
        arguments['bootstrapId'] != session.bootstrapId ||
        arguments['attemptId'] != session.attemptId ||
        !session.canReadEvidence) {
      throw PlatformException(code: 'nfc_unavailable');
    }
    // Native consumption remains authoritative; a lost reply is not reusable.
    session.evidenceConsumed = true;
    return _channel.invokeMethod<Object?>(method, arguments);
  }

  /// Cancels local probes/delivery only. Bound session disposal owns native
  /// discard plus stop and must complete before the controller releases RF.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final reader in _readers) {
      reader.revoke();
    }
    final pending = Map<Completer<bool>, Timer>.of(_capabilities);
    _capabilities.clear();
    for (final entry in pending.entries) {
      entry.value.cancel();
      entry.key.complete(false);
    }
  }

  static bool _validCapabilities(Object? value) {
    const fields = {
      'schemaVersion',
      'backend',
      'readAvailable',
      'activationAvailable',
      'streamingAvailable',
      'receiverAvailable',
      'rawCapture',
    };
    return value is Map &&
        value.length == fields.length &&
        value.keys.every(fields.contains) &&
        value['schemaVersion'] is int &&
        value['schemaVersion'] == 1 &&
        value['backend'] == 'receiverHistory' &&
        value['readAvailable'] == true &&
        value['activationAvailable'] == false &&
        value['streamingAvailable'] == false &&
        value['receiverAvailable'] == false &&
        value['rawCapture'] == false;
  }
}

/// Keep the fresh reader's public channel injection and platform gate intact.
/// This proxy admits only this owner's exact one-use handoff, then delegates
/// to the receiver channel supplied to the platform (never the capture name).
final class _ReceiverEvidenceChannel extends MethodChannel {
  const _ReceiverEvidenceChannel(this.platform)
    : super(LibreGen1ReceiverHistoryPlatform.channelName);
  final LibreGen1ReceiverHistoryPlatform platform;
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async =>
      await platform._readEvidence(method, arguments) as T?;
}

final class _ReceiverHistorySession
    implements
        Libre2NfcSetupSession,
        Libre2NfcCompletedReadAttemptProvider,
        LibreNfcHistoryEvidenceRevoker {
  _ReceiverHistorySession(this.platform, this.bootstrapId) {
    _delegate = PlatformLibre2NfcSetupSession(
      platformEvents: !platform._supported
          ? const Stream<Object?>.empty()
          : platform._events ??
                const EventChannel(
                  LibreGen1ReceiverHistoryPlatform.eventsName,
                ).receiveBroadcastStream(),
      invokeMethod: _invoke,
      methodTimeout: platform.methodTimeout,
      allowActivationProof: false,
      allowCompletedReadHandoff: true,
      allowTerminalReadRevocation: true,
    );
  }
  final LibreGen1ReceiverHistoryPlatform platform;
  final String bootstrapId;
  late final PlatformLibre2NfcSetupSession _delegate;
  String? attemptId;
  int _generation = 0;
  bool _dispatched = false;
  bool _startSettled = false;
  bool _stopConfirmed = false;
  bool _stopAbandoned = false;
  bool _revoked = false;
  bool evidenceConsumed = false;
  bool _disposing = false;
  late final Future<Object?> _startResult;
  Future<void>? _stop;
  Future<void>? _discard;
  Future<void>? _lateStop;
  Future<void>? _disposal;

  bool get canReadEvidence =>
      _stopConfirmed && !_revoked && !_disposing && !evidenceConsumed;

  @override
  Stream<Libre2NfcSetupState> get states => _delegate.states;
  @override
  String? get completedReadAttemptId =>
      _revoked || _disposing ? null : _delegate.completedReadAttemptId;
  @override
  Future<void> start() => _delegate.start();
  @override
  Future<void> retry() => Future.error(
    StateError(
      'Create a new receiver history session for another read.',
    ),
  );

  Future<Object?> _invoke(String method, Map<String, Object?> arguments) async {
    final attempt = arguments['attemptId'];
    if (arguments.length != 1 ||
        attempt is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{8,120}$').hasMatch(attempt) ||
        (method != 'startLibre2NfcSetup' && method != 'stopLibre2NfcSetup')) {
      throw PlatformException(code: 'bad_args');
    }
    if (method == 'stopLibre2NfcSetup') {
      if (attemptId != attempt) throw PlatformException(code: 'bad_args');
      _generation++;
      await _stopExact();
      return null;
    }
    if (attemptId != null ||
        _revoked ||
        _disposing ||
        platform._disposed ||
        !platform._supported) {
      throw PlatformException(code: 'nfc_unavailable');
    }
    attemptId = attempt;
    final generation = ++_generation;
    final available = await platform.readAvailable();
    if (generation != _generation ||
        _revoked ||
        _disposing ||
        platform._disposed ||
        !available) {
      throw PlatformException(code: 'nfc_unavailable');
    }
    _dispatched = true;
    final result = Completer<Object?>();
    _startResult = result.future;
    unawaited(
      result.future.then<void>(
        (_) => _afterStart(),
        onError: (Object _, StackTrace _) => _afterStart(),
      ),
    );
    unawaited(
      Future<Object?>.sync(
        () => platform._channel.invokeMethod<Object?>(
          'startLibreGen1HistoryRead',
          _arguments,
        ),
      ).then<void>(result.complete, onError: result.completeError),
    );
    try {
      final value = await result.future;
      if (value != null) throw StateError('Invalid receiver history reply.');
      return null;
    } catch (_) {
      // After dispatch even a lost reply needs exact native cleanup; do not
      // reclassify it as a preflight error that drops the session attempt.
      throw PlatformException(code: 'nfc_state_blocked');
    }
  }

  void _afterStart() {
    _startSettled = true;
    if (_stopAbandoned) {
      unawaited(
        _closeLateStart().then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
  }

  Map<String, Object?> get _arguments => {
    'attemptId': attemptId,
    'bootstrapId': bootstrapId,
  };

  Future<void> _nativeNull(String method) async {
    final value = await platform._channel
        .invokeMethod<Object?>(
          method,
          _arguments,
        )
        .timeout(platform.methodTimeout);
    if (value != null) {
      throw StateError('Receiver history cleanup is unconfirmed.');
    }
  }

  Future<void> _closeLateStart() => _lateStop ??= () async {
    await _nativeNull('stopLibreGen1HistoryRead');
    await _nativeNull('discardLibreGen1FreshHistoryEvidence');
    // A late close does not repair the earlier unknown-cleanup result.
  }();

  Future<void> _stopExact() {
    if (!_dispatched) return Future.value();
    final existing = _stop;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _stop = completion.future;
    unawaited(() async {
      final wasPending = !_startSettled;
      try {
        await _nativeNull('stopLibreGen1HistoryRead');
        if (wasPending) {
          try {
            await _startResult.timeout(platform.methodTimeout);
          } on TimeoutException {
            rethrow;
          } catch (_) {
            /* A rejected start still needs a subsequent stop. */
          }
          await _nativeNull('stopLibreGen1HistoryRead');
        }
        _stopConfirmed = true;
        completion.complete();
      } catch (_) {
        _stopAbandoned = true;
        completion.completeError(
          StateError('Receiver history cleanup is unconfirmed.'),
        );
        if (_startSettled) {
          unawaited(
            _closeLateStart().then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
          );
        }
      }
    }());
    return completion.future;
  }

  @override
  Future<void> stop() => _delegate.stop();

  @override
  Future<void> revokeHistoryEvidence() {
    _revoked = true;
    _generation++;
    if (!_dispatched) return Future.value();
    return _discard ??= _nativeNull('discardLibreGen1FreshHistoryEvidence');
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposing = true;
    var failed = false;
    final discard = revokeHistoryEvidence();
    // Observe discard while independently driving physical stop. Neither
    // operation is proof that the other one completed.
    unawaited(discard.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    try {
      await _delegate.dispose();
    } catch (_) {
      failed = true;
    }
    try {
      await _stopExact();
    } catch (_) {
      failed = true;
    }
    try {
      await discard;
    } catch (_) {
      failed = true;
    }
    platform.dispose();
    if (failed) throw StateError('Receiver history cleanup is unconfirmed.');
  }
}
