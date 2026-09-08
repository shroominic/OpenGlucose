import 'errors.dart';
import 'events.dart';
import 'model.dart';

sealed class LibreAssemblyOutcome {
  const LibreAssemblyOutcome();
}

final class LibreAssemblyProgress extends LibreAssemblyOutcome {
  const LibreAssemblyProgress({
    required this.kind,
    required this.fragmentIndex,
    required this.fragmentLength,
    required this.receivedLength,
  });

  final LibreAssemblyKind kind;
  final int fragmentIndex;
  final int fragmentLength;
  final int receivedLength;
}

final class LibreAssemblyComplete extends LibreAssemblyOutcome {
  const LibreAssemblyComplete({required this.kind, required this.value});

  final LibreAssemblyKind kind;
  final LibreOpaqueBytes value;
}

final class LibreAssemblyFailure extends LibreAssemblyOutcome {
  const LibreAssemblyFailure(this.error);

  final LibreProtocolError error;
}

/// Strict, timestamp-driven assembly for observed reference fragments.
///
/// The assembler never pads, truncates, reorders, or reuses a rejected
/// fragment. A failure discards the partial value and the next call starts a
/// new value at fragment zero.
final class LibreFragmentAssembler {
  LibreFragmentAssembler._({
    required this.kind,
    required List<int> expectedFragmentLengths,
    required this.timeout,
  }) : expectedFragmentLengths = List<int>.unmodifiable(
         expectedFragmentLengths,
       ) {
    if (expectedFragmentLengths.isEmpty ||
        expectedFragmentLengths.any((length) => length <= 0)) {
      throw ArgumentError.value(
        expectedFragmentLengths,
        'expectedFragmentLengths',
      );
    }
    if (timeout != null && timeout! <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }

  factory LibreFragmentAssembler.encryptedComposite({
    Duration timeout = const Duration(seconds: 10),
  }) {
    return LibreFragmentAssembler._(
      kind: LibreAssemblyKind.encryptedComposite,
      expectedFragmentLengths: const <int>[20, 18, 8],
      timeout: timeout,
    );
  }

  /// The 7+18 layout is reference-verified. No reference timeout was found,
  /// so timeout is disabled unless an evidence owner supplies one explicitly.
  factory LibreFragmentAssembler.gen2SessionInformation({Duration? timeout}) {
    return LibreFragmentAssembler._(
      kind: LibreAssemblyKind.gen2SessionInformation,
      expectedFragmentLengths: const <int>[7, 18],
      timeout: timeout,
    );
  }

  final LibreAssemblyKind kind;
  final List<int> expectedFragmentLengths;
  final Duration? timeout;

  final List<int> _buffer = <int>[];
  int _nextFragmentIndex = 0;
  Duration? _startedAt;
  Duration? _lastObservedAt;

  int get receivedLength => _buffer.length;
  int get nextFragmentIndex => _nextFragmentIndex;
  bool get hasPartialValue => _nextFragmentIndex != 0;

  List<LibreAssemblyOutcome> add(
    Iterable<int> fragment, {
    required Duration observedAt,
  }) {
    final timeError = _validateTime(observedAt);
    if (timeError != null) {
      _reset();
      return <LibreAssemblyOutcome>[LibreAssemblyFailure(timeError)];
    }
    _lastObservedAt = observedAt;

    final timeoutFailure = _expireIfNeeded(observedAt);
    if (timeoutFailure != null) {
      return <LibreAssemblyOutcome>[timeoutFailure];
    }

    final value = List<int>.of(fragment);
    for (final byte in value) {
      if (byte < 0 || byte > 0xff) {
        final error = LibreProtocolError(
          kind: LibreProtocolErrorKind.invalidPayloadByte,
          assemblyKind: kind,
          fragmentIndex: _nextFragmentIndex,
          actualLength: value.length,
        );
        _reset();
        return <LibreAssemblyOutcome>[LibreAssemblyFailure(error)];
      }
    }

    final fragmentIndex = _nextFragmentIndex;
    final expectedLength = expectedFragmentLengths[fragmentIndex];
    if (value.length != expectedLength) {
      final error = LibreProtocolError(
        kind: LibreProtocolErrorKind.fragmentLengthMismatch,
        assemblyKind: kind,
        expectedLength: expectedLength,
        actualLength: value.length,
        fragmentIndex: fragmentIndex,
      );
      _reset();
      return <LibreAssemblyOutcome>[LibreAssemblyFailure(error)];
    }

    _startedAt ??= observedAt;
    _buffer.addAll(value);
    _nextFragmentIndex += 1;
    if (_nextFragmentIndex == expectedFragmentLengths.length) {
      final complete = LibreOpaqueBytes(_buffer);
      _reset();
      return <LibreAssemblyOutcome>[
        LibreAssemblyComplete(kind: kind, value: complete),
      ];
    }

    return <LibreAssemblyOutcome>[
      LibreAssemblyProgress(
        kind: kind,
        fragmentIndex: fragmentIndex,
        fragmentLength: value.length,
        receivedLength: _buffer.length,
      ),
    ];
  }

  List<LibreAssemblyOutcome> expire({required Duration observedAt}) {
    final timeError = _validateTime(observedAt);
    if (timeError != null) {
      _reset();
      return <LibreAssemblyOutcome>[LibreAssemblyFailure(timeError)];
    }
    _lastObservedAt = observedAt;
    final failure = _expireIfNeeded(observedAt);
    return failure == null
        ? const <LibreAssemblyOutcome>[]
        : <LibreAssemblyOutcome>[failure];
  }

  /// Clears both partial bytes and the connection-scoped observation clock.
  void reset() => _reset(clearObservationClock: true);

  LibreProtocolError? _validateTime(Duration observedAt) {
    if (observedAt.isNegative) {
      return LibreProtocolError(
        kind: LibreProtocolErrorKind.invalidObservationTime,
        assemblyKind: kind,
        fragmentIndex: _nextFragmentIndex,
      );
    }
    final last = _lastObservedAt;
    if (last != null && observedAt < last) {
      return LibreProtocolError(
        kind: LibreProtocolErrorKind.nonMonotonicObservation,
        assemblyKind: kind,
        fragmentIndex: _nextFragmentIndex,
      );
    }
    return null;
  }

  LibreAssemblyFailure? _expireIfNeeded(Duration observedAt) {
    final limit = timeout;
    final started = _startedAt;
    if (limit == null || started == null || observedAt - started < limit) {
      return null;
    }
    final error = LibreProtocolError(
      kind: LibreProtocolErrorKind.fragmentTimeout,
      assemblyKind: kind,
      expectedLength: expectedFragmentLengths[_nextFragmentIndex],
      actualLength: _buffer.length,
      fragmentIndex: _nextFragmentIndex,
    );
    _reset();
    return LibreAssemblyFailure(error);
  }

  void _reset({bool clearObservationClock = false}) {
    _buffer.clear();
    _nextFragmentIndex = 0;
    _startedAt = null;
    if (clearObservationClock) {
      _lastObservedAt = null;
    }
  }
}
