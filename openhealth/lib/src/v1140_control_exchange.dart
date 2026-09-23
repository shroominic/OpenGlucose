import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';

enum V1140ExchangeCapability { readOnlyRehearsal, pairOnce }

enum V1140ExchangeFailureKind {
  rejected,
  malformedResponse,
  deadlineExceeded,
  disconnected,
  writeOutcomeUnknown,
  cleanupFailed,
}

final class V1140ExchangeException implements Exception {
  const V1140ExchangeException(this.kind);
  final V1140ExchangeFailureKind kind;
  @override
  String toString() => 'V1140ExchangeException(${kind.name})';
}

final class V1140ControlExchange {
  V1140ControlExchange._(
    this._connection,
    this._writeRef,
    this._notifyRef,
    this._capability,
    this._requestDeadline,
    this._cleanupDeadline,
  );

  final BleConnection _connection;
  final BleCharacteristicRef _writeRef;
  final BleCharacteristicRef _notifyRef;
  final V1140ExchangeCapability _capability;
  final Duration _requestDeadline;
  final Duration _cleanupDeadline;
  // Owned for the lifetime of this exchange and cancelled by _performClose.
  // ignore: cancel_subscriptions
  StreamSubscription<BleConnectionState>? _stateSubscription;
  // This owned listener is cancelled by _performClose on every exit path.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? _notificationSubscription;
  Future<void>? _closeFuture;
  Completer<void>? _setupFailure;
  Completer<List<int>>? _requestFailure;
  Completer<List<int>>? _response;
  List<int>? _candidate;
  bool _notifyAttempted = false;
  bool _terminal = false;
  int _step = 0;

  static Future<V1140ControlExchange> open({
    required BleConnection connection,
    required BleCharacteristicRef writeCharacteristic,
    required BleCharacteristicRef notifyCharacteristic,
    required V1140ExchangeCapability capability,
    required Duration setupDeadline,
    required Duration requestDeadline,
    required Duration cleanupDeadline,
  }) async {
    if (setupDeadline <= Duration.zero ||
        requestDeadline <= Duration.zero ||
        cleanupDeadline <= Duration.zero) {
      throw const V1140ExchangeException(V1140ExchangeFailureKind.rejected);
    }
    final exchange = V1140ControlExchange._(
      connection,
      writeCharacteristic,
      notifyCharacteristic,
      capability,
      requestDeadline,
      cleanupDeadline,
    );
    final setupClock = Stopwatch()..start();
    try {
      if (!_matches(writeCharacteristic.serviceUuid, yuwellCt5ServiceUuid) ||
          !_matches(
            writeCharacteristic.characteristicUuid,
            yuwellCt5WriteCharacteristicUuid,
          ) ||
          !writeCharacteristic.properties.write ||
          !_matches(notifyCharacteristic.serviceUuid, yuwellCt5ServiceUuid) ||
          !_matches(
            notifyCharacteristic.characteristicUuid,
            yuwellCt5NotifyCharacteristicUuid,
          ) ||
          !(notifyCharacteristic.properties.notify ||
              notifyCharacteristic.properties.indicate)) {
        throw const V1140ExchangeException(V1140ExchangeFailureKind.rejected);
      }
      exchange._setupFailure = Completer<void>();
      exchange._stateSubscription = connection.connectionStates.listen(
        exchange._onState,
        onError: (Object _) =>
            exchange._abort(V1140ExchangeFailureKind.disconnected),
        onDone: () => exchange._abort(V1140ExchangeFailureKind.disconnected),
      );
      exchange._notificationSubscription = connection
          .notifications(notifyCharacteristic)
          .listen(
            exchange._onNotification,
            onError: (Object _) =>
                exchange._abort(V1140ExchangeFailureKind.malformedResponse),
            onDone: () =>
                exchange._abort(V1140ExchangeFailureKind.disconnected),
          );
      if (exchange._terminal) {
        throw const V1140ExchangeException(
          V1140ExchangeFailureKind.disconnected,
        );
      }
      final remaining = setupDeadline - setupClock.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('setup deadline');
      exchange._notifyAttempted = true;
      await Future.any<void>([
        connection.setNotify(notifyCharacteristic, true),
        exchange._setupFailure!.future,
      ]).timeout(remaining);
      if (exchange._terminal) {
        throw const V1140ExchangeException(
          V1140ExchangeFailureKind.disconnected,
        );
      }
      exchange._setupFailure = null;
      return exchange;
    } on TimeoutException {
      await exchange._ignoreCleanupFailure();
      throw const V1140ExchangeException(
        V1140ExchangeFailureKind.deadlineExceeded,
      );
    } on V1140ExchangeException {
      await exchange._ignoreCleanupFailure();
      rethrow;
    } catch (_) {
      await exchange._ignoreCleanupFailure();
      throw const V1140ExchangeException(V1140ExchangeFailureKind.rejected);
    }
  }

  static bool _matches(String actual, String expected) =>
      actual.toLowerCase() == expected.toLowerCase();

  Future<List<int>> exchange(List<int> command) async {
    if (_terminal || _response != null || !_validNext(command)) {
      _abort(V1140ExchangeFailureKind.rejected);
      await _ignoreCleanupFailure();
      throw const V1140ExchangeException(V1140ExchangeFailureKind.rejected);
    }
    final request = List<int>.unmodifiable(command);
    _step++;
    final response = _response = Completer<List<int>>();
    final failure = _requestFailure = Completer<List<int>>();
    final timeout = Completer<List<int>>();
    final timer = Timer(_requestDeadline, () {
      if (!timeout.isCompleted) {
        timeout.completeError(
          const V1140ExchangeException(
            V1140ExchangeFailureKind.deadlineExceeded,
          ),
        );
      }
    });
    var writeStarted = false;
    try {
      Future<List<int>> writeAndReceive() async {
        writeStarted = true;
        await _connection.write(_writeRef, request, withoutResponse: false);
        return response.future;
      }

      final frame = await Future.any<List<int>>([
        writeAndReceive(),
        timeout.future,
        failure.future,
      ]);
      if (_terminal) {
        throw const V1140ExchangeException(V1140ExchangeFailureKind.rejected);
      }
      return frame;
    } catch (error) {
      final kind = request.first == 0x30 && writeStarted
          ? V1140ExchangeFailureKind.writeOutcomeUnknown
          : error is V1140ExchangeException
          ? error.kind
          : V1140ExchangeFailureKind.rejected;
      _abort(kind);
      await _ignoreCleanupFailure();
      throw V1140ExchangeException(kind);
    } finally {
      timer.cancel();
      _response = null;
      _requestFailure = null;
      _candidate = null;
    }
  }

  bool _validNext(List<int> command) {
    if (_step == 0) {
      return _same(command, YuwellCt5Commands.readVersion());
    }
    if (_step == 1) {
      return _same(command, YuwellCt5Commands.readBindingStatus());
    }
    if (_step == 2 && _capability == V1140ExchangeCapability.pairOnce) {
      return command.length == 10 &&
          command.first == 0x30 &&
          hasValidSum8Frame(command);
    }
    return false;
  }

  static bool _same(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  void _onState(BleConnectionState state) {
    if (state == BleConnectionState.disconnected) {
      _abort(V1140ExchangeFailureKind.disconnected);
    }
  }

  void _onNotification(List<int> input) {
    if (_terminal) return;
    final response = _response;
    if (response == null || response.isCompleted || _candidate != null) {
      _abort(
        response == null
            ? V1140ExchangeFailureKind.rejected
            : V1140ExchangeFailureKind.malformedResponse,
      );
      return;
    }
    try {
      final frame = switch (_step) {
        1 => YuwellCt5Responses.version(input),
        2 => YuwellCt5Responses.requireResponse(input, opcode: 0x11),
        3 => YuwellCt5Responses.requireResponse(input, opcode: 0x30),
        _ => throw const V1140ExchangeException(
          V1140ExchangeFailureKind.malformedResponse,
        ),
      };
      if (_step == 1 &&
          (frame[6] != 1 || frame[7] != 1 || frame[8] != 4 || frame[9] != 0)) {
        throw const V1140ExchangeException(
          V1140ExchangeFailureKind.malformedResponse,
        );
      }
      if (_step == 2 && YuwellCt5Responses.bindingStatus(frame)) {
        throw const V1140ExchangeException(
          V1140ExchangeFailureKind.malformedResponse,
        );
      }
      if (_step == 3 && frame.length < 10) {
        throw const V1140ExchangeException(
          V1140ExchangeFailureKind.malformedResponse,
        );
      }
      _candidate = List<int>.unmodifiable(frame);
      scheduleMicrotask(() {
        if (!_terminal &&
            identical(_response, response) &&
            !response.isCompleted) {
          response.complete(_candidate!);
        }
      });
    } catch (_) {
      _abort(V1140ExchangeFailureKind.malformedResponse);
    }
  }

  void _abort(V1140ExchangeFailureKind kind) {
    if (_terminal) return;
    _terminal = true;
    final exception = V1140ExchangeException(kind);
    final setup = _setupFailure;
    if (setup != null && !setup.isCompleted) setup.completeError(exception);
    final failure = _requestFailure;
    if (failure != null && !failure.isCompleted) {
      failure.completeError(exception);
    }
    unawaited(_ignoreCleanupFailure());
  }

  Future<void> _ignoreCleanupFailure() async {
    try {
      await _closeInternal();
    } on V1140ExchangeException {
      // Preserve the primary failure.
    }
  }

  Future<void> close() {
    if (_requestFailure != null) _abort(V1140ExchangeFailureKind.rejected);
    return _closeInternal();
  }

  Future<void> _closeInternal() => _closeFuture ??= _performClose();

  Future<void> _performClose() async {
    _terminal = true;
    final operations = <Future<void>>[];
    try {
      if (_notificationSubscription case final subscription?) {
        operations.add(Future<void>.sync(subscription.cancel));
      }
      if (_stateSubscription case final subscription?) {
        operations.add(Future<void>.sync(subscription.cancel));
      }
      if (_notifyAttempted) {
        operations.add(
          Future<void>.sync(() => _connection.setNotify(_notifyRef, false)),
        );
      }
      operations.add(Future<void>.sync(_connection.disconnect));
      await Future.wait<void>(operations).timeout(_cleanupDeadline);
    } catch (_) {
      throw const V1140ExchangeException(
        V1140ExchangeFailureKind.cleanupFailed,
      );
    }
  }
}
