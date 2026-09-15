import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'app_controller.dart';
import 'libre2_nfc_setup.dart';
import 'libre_gen1_fresh_nfc_history.dart';
import 'libre_nfc_history.dart';
import 'sensor_history_repository.dart';

enum LibreNfcHistorySyncPhase {
  idle,
  pausing,
  listening,
  reading,
  stopping,
  decoding,
  importing,
  completed,
  cancelled,
  failed,
}

enum LibreNfcHistorySyncFailure {
  busy,
  unavailable,
  invalidTarget,
  staleOwner,
  readFailed,
  readExpired,
  invalidEvidence,
  storageUnavailable,
  timedOut,
  cleanupUnconfirmed,
}

final class LibreNfcHistorySyncState {
  const LibreNfcHistorySyncState(
    this.phase, {
    this.failure,
    this.importedReadingCount,
  });
  final LibreNfcHistorySyncPhase phase;
  final LibreNfcHistorySyncFailure? failure;
  final int? importedReadingCount;

  @override
  String toString() =>
      'LibreNfcHistorySyncState(${phase.name}, ${failure?.name ?? 'none'})';
}

abstract interface class LibreNfcHistorySyncController {
  LibreNfcHistorySyncState get state;
  Stream<LibreNfcHistorySyncState> get states;
  bool get cleanupUnconfirmed;
  Future<LibreNfcHistorySyncState> sync({
    required DiscoveredSensor sensor,
    required LibreGen1StreamingBootstrap bootstrap,
  });
  Future<void> cancel();

  /// Required after every attempt. Terminal sync/cancel has stopped NFC, but
  /// RF ownership stays reserved until disposal confirms the final cleanup.
  Future<void> dispose();
}

/// Optional native evidence revocation. Revocation never replaces RF stop.
/// Existing capture sessions do not implement this recorder-free contract.
// This optional instance capability cannot be replaced with a top-level call.
// ignore: one_member_abstracts
abstract interface class LibreNfcHistoryEvidenceRevoker {
  Future<void> revokeHistoryEvidence();
}

/// One explicit, receiver-bound history read. This owner never activates,
/// enables streaming, changes keys, or reconnects a sensor. It owns the supplied
/// NFC session/reader; do not share them with a Connect/setup UI owner.
final class LibreNfcHistorySync implements LibreNfcHistorySyncController {
  LibreNfcHistorySync({
    required CgmAppController controller,
    required SensorHistoryRepository repository,
    Libre2NfcSetupSession? session,
    Libre2NfcSetupSession Function(LibreGen1StreamingBootstrap bootstrap)?
    sessionFactory,
    required LibreGen1FreshNfcHistoryReader reader,
    required LibreGen1NfcHistoryDecoder decoder,
    this.pauseTimeout = const Duration(seconds: 45),
    this.methodTimeout = const Duration(seconds: 35),
    this.readTimeout = const Duration(seconds: 120),
    this.storageTimeout = const Duration(seconds: 15),
  }) : _controller = controller,
       _repository = repository,
       _session = session,
       _sessionFactory = sessionFactory,
       _reader = reader,
       _decoder = decoder {
    if ((session == null) == (sessionFactory == null)) {
      throw ArgumentError('Supply exactly one history read session source.');
    }
    if ([
      pauseTimeout,
      methodTimeout,
      readTimeout,
      storageTimeout,
    ].any((value) => value <= Duration.zero)) {
      throw ArgumentError('History sync timeouts must be positive.');
    }
  }

  final CgmAppController _controller;
  final SensorHistoryRepository _repository;
  Libre2NfcSetupSession? _session;
  final Libre2NfcSetupSession Function(LibreGen1StreamingBootstrap bootstrap)?
  _sessionFactory;
  final LibreGen1FreshNfcHistoryReader _reader;
  final LibreGen1NfcHistoryDecoder _decoder;
  final Duration pauseTimeout;
  final Duration methodTimeout;
  final Duration readTimeout;
  final Duration storageTimeout;
  final StreamController<LibreNfcHistorySyncState> _states =
      StreamController.broadcast(sync: true);
  final List<LibreNfcHistorySyncState> _pendingStates = [];
  bool _emitting = false;
  LibreNfcHistorySyncState _state = const LibreNfcHistorySyncState(
    LibreNfcHistorySyncPhase.idle,
  );
  _SyncOperation? _active;
  bool _disposed = false;
  bool _blocked = false;
  bool _used = false;
  CgmPausedSensorConnection? _completedScope;
  bool _completedCleanupConfirmed = false;
  Future<void>? _disposal;

  @override
  Stream<LibreNfcHistorySyncState> get states => _states.stream;
  @override
  LibreNfcHistorySyncState get state => _state;
  @override
  bool get cleanupUnconfirmed => _blocked;

  @override
  Future<LibreNfcHistorySyncState> sync({
    required DiscoveredSensor sensor,
    required LibreGen1StreamingBootstrap bootstrap,
  }) {
    if (_disposed || _blocked || _used) {
      return Future.value(
        LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.failed,
          failure: _blocked
              ? LibreNfcHistorySyncFailure.cleanupUnconfirmed
              : LibreNfcHistorySyncFailure.busy,
        ),
      );
    }
    final operation = _SyncOperation();
    _used = true;
    _active = operation;
    unawaited(_run(operation, sensor, bootstrap));
    return operation.completion.future;
  }

  /// Revocation is synchronous; completion waits the native/durable barriers.
  @override
  Future<void> cancel() {
    final operation = _active;
    if (operation == null) return Future.value();
    operation.cancelled = true;
    if (!operation.cancellation.isCompleted) operation.cancellation.complete();
    _reader.revoke();
    _revokeEvidence(operation);
    _cancelTicket(operation);
    if (operation.startDispatched && !operation.stopAfterStartConfirmed) {
      unawaited(_stop(operation));
    }
    return operation.completion.future.then<void>((_) {});
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _reader.revoke();
    await cancel();
    try {
      await _session?.dispose().timeout(methodTimeout);
    } catch (_) {
      _blocked = true;
    }
    try {
      _completedScope?.release(
        cleanupConfirmed: _completedCleanupConfirmed && !_blocked,
      );
    } catch (_) {
      _blocked = true;
    }
    await _states.close();
  }

  Future<void> _run(
    _SyncOperation operation,
    DiscoveredSensor sensor,
    LibreGen1StreamingBootstrap bootstrap,
  ) async {
    var terminal = const LibreNfcHistorySyncState(
      LibreNfcHistorySyncPhase.failed,
      failure: LibreNfcHistorySyncFailure.readFailed,
    );
    StreamSubscription<Libre2NfcSetupState>? subscription;
    try {
      final binding = LibreGen1ObservationBinding.forSensor(
        bootstrapId: bootstrap.bootstrapId,
        uid: bootstrap.uid,
        initialPatchInfo: bootstrap.initialPatchInfo,
      );
      if (sensor.driverId != binding.driverId ||
          sensor.storageKey != binding.storageKey ||
          sensor.deviceId != bootstrap.deviceId) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.invalidTarget);
      }
      _check(operation, requireScope: false);
      // Create the receiver-bound owner only after validating the exact target.
      // A factory must construct locally; start remains the only NFC dispatch.
      final Libre2NfcSetupSession session;
      try {
        session = _session ??= _sessionFactory!(bootstrap);
      } catch (_) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.unavailable);
      }
      _check(operation, requireScope: false);
      if (session is! Libre2NfcCompletedReadAttemptProvider ||
          (session is PlatformLibre2NfcSetupSession &&
              session.allowActivationProof)) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.invalidTarget);
      }
      _emit(const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.pausing));
      _check(operation, requireScope: false);
      final pause = _controller.pauseForLibreHistoryRead(sensor);
      unawaited(
        pause.then<void>((scope) {
          operation.scope = scope;
          if (operation.finished || operation.pauseAbandoned) {
            // A late successful pause is not permission to begin NFC. Its owner
            // remains conservatively quarantined until a real app restart.
            scope.release(cleanupConfirmed: false);
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      try {
        operation.scope = await _await(operation, pause, pauseTimeout);
      } catch (_) {
        operation.pauseAbandoned = true;
        operation.uncertain = true;
        rethrow;
      }
      _check(operation);
      // Validate or migrate local retained history under the exact protected
      // bootstrap before issuing the ticket. This performs no sensor I/O.
      operation.storageBarrier = _repository
          .loadLibre(binding)
          .then<void>((_) {});
      operation.historyKey = sensorHistoryKey(sensor);
      await _await(operation, operation.storageBarrier!, storageTimeout);
      _check(operation);
      final issue = _repository.beginNfcHistoryImport(
        binding,
        connectionOwner: operation.scope!,
      );
      unawaited(
        issue.then<void>((ticket) {
          operation.ticket = ticket;
          if (operation.cancelled || operation.finished) {
            _cancelTicket(operation);
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      operation.ticket = await _await(operation, issue, storageTimeout);
      _check(operation);
      final metadata = Completer<Libre2NfcSetupState>();
      subscription = session.states.listen(
        (event) {
          if (operation.finished ||
              operation.cancelled ||
              metadata.isCompleted) {
            return;
          }
          if (event.failure == Libre2NfcFailureKind.cleanupUnconfirmed) {
            operation.uncertain = true;
          }
          switch (event.phase) {
            case Libre2NfcSetupPhase.listening:
              _emit(
                const LibreNfcHistorySyncState(
                  LibreNfcHistorySyncPhase.listening,
                ),
              );
            case Libre2NfcSetupPhase.tagDetected:
            case Libre2NfcSetupPhase.reading:
              _emit(
                const LibreNfcHistorySyncState(
                  LibreNfcHistorySyncPhase.reading,
                ),
              );
            case Libre2NfcSetupPhase.metadataRead:
            case Libre2NfcSetupPhase.failed:
              metadata.complete(event);
            case Libre2NfcSetupPhase.idle:
              break;
          }
        },
        onError: (Object _, StackTrace _) {
          if (!metadata.isCompleted) {
            metadata.complete(
              const Libre2NfcSetupState.failed(Libre2NfcFailureKind.readFailed),
            );
          }
        },
        onDone: () {
          if (!metadata.isCompleted) {
            metadata.complete(
              const Libre2NfcSetupState.failed(Libre2NfcFailureKind.readFailed),
            );
          }
        },
      );
      _check(operation);
      operation.startDispatched = true;
      final started = Completer<void>();
      operation.start = started.future;
      void closeLateStart() {
        if (operation.startCleanupDeadlineExpired ||
            operation.finished && operation.uncertain) {
          // Observe and close a late start, but never upgrade released cleanup.
          operation.stop = null;
          unawaited(_stop(operation));
        }
      }

      unawaited(
        operation.start!.then<void>(
          (_) => closeLateStart(),
          onError: (Object _, StackTrace _) => closeLateStart(),
        ),
      );
      unawaited(
        Future<void>.sync(session.start).then<void>(
          (_) {
            operation.startSettled = true;
            started.complete();
          },
          onError: (Object error, StackTrace stack) {
            operation.startSettled = true;
            started.completeError(error, stack);
          },
        ),
      );
      await _await(operation, operation.start!, methodTimeout);
      _check(operation);
      final completed = await _await(operation, metadata.future, readTimeout);
      _check(operation);
      if (completed.phase != Libre2NfcSetupPhase.metadataRead ||
          completed.model != Libre2SensorModel.libre2 ||
          completed.isActivationVerified ||
          (completed.sensorStatus != Libre2SensorStatus.active &&
              completed.sensorStatus != Libre2SensorStatus.warmingUp)) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.readFailed);
      }
      if (completed.isReadExpired) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.readExpired);
      }
      // Platform emits the terminal event synchronously before marking its
      // getter complete. Defer one microtask, then capture before stop clears it.
      await Future<void>.value();
      _check(operation);
      final attemptId = (session as Libre2NfcCompletedReadAttemptProvider)
          .completedReadAttemptId;
      if (attemptId == null) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.invalidEvidence);
      }
      if (!await _stop(operation)) {
        throw const _SyncFailure(LibreNfcHistorySyncFailure.cleanupUnconfirmed);
      }
      _check(operation);
      _emit(const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.decoding));
      _check(operation);
      final decoded = await _await(
        operation,
        _reader.readDecoded(
          bootstrap: bootstrap,
          attemptId: attemptId,
          decoder: _decoder,
        ),
        methodTimeout,
      );
      _check(operation);
      _emit(const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.importing));
      _check(operation);
      operation.import = _repository.importNfcHistory(
        operation.ticket!,
        connectionOwner: operation.scope!,
        scanMinute: decoded.scanMinute,
        scanReceivedAt: decoded.receivedAt,
        samples: decoded.samples,
      );
      final imported = await _await(
        operation,
        operation.import!,
        storageTimeout,
      );
      _check(operation);
      _controller.refreshImportedLibreHistory(sensor);
      _check(operation);
      terminal = LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.completed,
        importedReadingCount: imported.importedReadingCount,
      );
    } on _SyncCancelled {
      terminal = const LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.cancelled,
      );
    } on _SyncFailure catch (failure) {
      terminal = LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.failed,
        failure: failure.kind,
      );
    } on LibreGen1FreshNfcHistoryException catch (failure) {
      terminal = LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.failed,
        failure: failure.kind == LibreGen1FreshNfcFailure.timedOut
            ? LibreNfcHistorySyncFailure.timedOut
            : LibreNfcHistorySyncFailure.invalidEvidence,
      );
    } on TimeoutException {
      // A read deadline with a confirmed native stop is retryable. A pending
      // start, pause, or dispatched durable mutation is not assumed complete.
      if (operation.startDispatched && !operation.startSettled ||
          operation.import != null) {
        operation.uncertain = true;
      }
      terminal = const LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.failed,
        failure: LibreNfcHistorySyncFailure.timedOut,
      );
    } catch (_) {
      terminal = const LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.failed,
        failure: LibreNfcHistorySyncFailure.storageUnavailable,
      );
    } finally {
      _reader.revoke();
      _cancelTicket(operation);
      var cleanup = false;
      try {
        cleanup = await _cleanup(operation);
      } catch (_) {
        operation.uncertain = true;
      }
      try {
        await subscription?.cancel().timeout(methodTimeout);
      } catch (_) {
        operation.uncertain = true;
      }
      operation.finished = true;
      final confirmed = cleanup && !operation.uncertain;
      if (!confirmed) {
        _blocked = true;
        terminal = const LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.failed,
          failure: LibreNfcHistorySyncFailure.cleanupUnconfirmed,
        );
      } else if (operation.cancelled || _disposed) {
        terminal = const LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.cancelled,
        );
      }
      _completedScope = operation.scope;
      _completedCleanupConfirmed = confirmed;
      if (identical(_active, operation)) _active = null;
      _emit(terminal);
      operation.completion.complete(terminal);
    }
  }

  void _cancelTicket(_SyncOperation operation) {
    final ticket = operation.ticket;
    if (ticket == null || operation.ticketCancellation != null) return;
    operation.ticketCancellation = _repository.cancelNfcHistoryImport(ticket);
    unawaited(
      operation.ticketCancellation!.catchError((Object _) {
        operation.uncertain = true;
      }),
    );
  }

  void _revokeEvidence(_SyncOperation operation) {
    final session = _session;
    if (session == null ||
        session is! LibreNfcHistoryEvidenceRevoker ||
        operation.evidenceRevocation != null) {
      return;
    }
    final completion = Completer<void>();
    operation.evidenceRevocation = completion.future;
    unawaited(
      completion.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    unawaited(
      Future<void>.sync(
        (session as LibreNfcHistoryEvidenceRevoker).revokeHistoryEvidence,
      ).then<void>(
        (_) => completion.complete(),
        onError: completion.completeError,
      ),
    );
  }

  Future<bool> _stop(_SyncOperation operation) {
    final session = _session;
    if (session == null) return Future.value(true);
    if (operation.stopAfterStartConfirmed) return Future.value(true);
    final pending = operation.stop;
    if (pending != null) return pending;
    final completion = Completer<bool>();
    operation.stop = completion.future;
    unawaited(() async {
      _emit(const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.stopping));
      final startSettled = !operation.startDispatched || operation.startSettled;
      try {
        await Future<void>.sync(session.stop).timeout(methodTimeout);
        if (startSettled) operation.stopAfterStartConfirmed = true;
        completion.complete(true);
      } catch (_) {
        operation.uncertain = true;
        completion.complete(false);
      }
    }());
    return completion.future;
  }

  Future<bool> _cleanup(_SyncOperation operation) async {
    var confirmed = await _stop(operation);
    if (operation.start != null && !operation.startSettled) {
      try {
        await operation.start!.timeout(methodTimeout);
      } catch (_) {
        operation.startCleanupDeadlineExpired = true;
        operation.uncertain = true;
      }
    }
    if (operation.startSettled && !operation.stopAfterStartConfirmed) {
      operation.stop = null;
      confirmed = await _stop(operation) && confirmed;
    }
    for (final pending in <Future<Object?>?>[
      operation.storageBarrier,
      operation.import,
      operation.ticketCancellation,
    ]) {
      try {
        await pending?.timeout(storageTimeout);
      } on TimeoutException {
        // The original queued transaction remains observed, not replaced.
        operation.uncertain = true;
      } catch (_) {
        // Repository validation (for example Clear invalidating a ticket) can
        // prove no write was dispatched. Only the repository's per-key
        // quarantine marks an acknowledged-unknown durable write.
        if (operation.historyKey case final key?) {
          operation.uncertain |= _repository.isQuarantined(key);
        }
      }
    }
    try {
      await operation.evidenceRevocation?.timeout(methodTimeout);
    } catch (_) {
      operation.uncertain = true;
    }
    return confirmed;
  }

  Future<T> _await<T>(
    _SyncOperation operation,
    Future<T> pending,
    Duration timeout,
  ) => Future.any<T>([
    pending,
    operation.cancellation.future.then<T>((_) => throw const _SyncCancelled()),
  ]).timeout(timeout);

  void _check(_SyncOperation operation, {bool requireScope = true}) {
    if (operation.cancelled || _disposed) throw const _SyncCancelled();
    if (!identical(_active, operation) ||
        (requireScope && operation.scope?.isCurrent != true)) {
      throw const _SyncFailure(LibreNfcHistorySyncFailure.staleOwner);
    }
  }

  void _emit(LibreNfcHistorySyncState state) {
    if (_disposed || _states.isClosed) return;
    _state = state;
    _pendingStates.add(state);
    if (_emitting) return;
    _emitting = true;
    try {
      while (_pendingStates.isNotEmpty && !_disposed && !_states.isClosed) {
        _states.add(_pendingStates.removeAt(0));
      }
    } finally {
      _pendingStates.clear();
      _emitting = false;
    }
  }
}

final class _SyncOperation {
  final completion = Completer<LibreNfcHistorySyncState>();
  final cancellation = Completer<void>();
  CgmPausedSensorConnection? scope;
  LibreNfcHistoryImportTicket? ticket;
  Future<void>? ticketCancellation;
  Future<void>? evidenceRevocation;
  Future<void>? storageBarrier;
  String? historyKey;
  Future<void>? start;
  Future<bool>? stop;
  Future<LibreNfcHistoryImportResult>? import;
  bool cancelled = false;
  bool uncertain = false;
  bool finished = false;
  bool pauseAbandoned = false;
  bool startDispatched = false;
  bool startSettled = false;
  bool startCleanupDeadlineExpired = false;
  bool stopAfterStartConfirmed = false;
}

final class _SyncFailure implements Exception {
  const _SyncFailure(this.kind);
  final LibreNfcHistorySyncFailure kind;
}

final class _SyncCancelled implements Exception {
  const _SyncCancelled();
}
