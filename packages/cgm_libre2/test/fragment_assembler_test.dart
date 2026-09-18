import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  group('encrypted composite assembly', () {
    test('accepts only 20+18+8 and returns an immutable 46-byte value', () {
      final assembler = LibreFragmentAssembler.encryptedComposite();
      final source = List<int>.generate(46, (index) => index);

      final first = assembler.add(
        source.sublist(0, 20),
        observedAt: Duration.zero,
      );
      final second = assembler.add(
        source.sublist(20, 38),
        observedAt: const Duration(seconds: 1),
      );
      final third = assembler.add(
        source.sublist(38),
        observedAt: const Duration(seconds: 2),
      );

      expect(first.single, isA<LibreAssemblyProgress>());
      expect(second.single, isA<LibreAssemblyProgress>());
      final complete = third.single as LibreAssemblyComplete;
      expect(complete.kind, LibreAssemblyKind.encryptedComposite);
      expect(complete.value.length, 46);
      expect(complete.value.bytes, source);
      expect(() => complete.value.bytes[0] = 99, throwsUnsupportedError);
      expect(complete.value.toString(), isNot(contains('[0, 1')));
      expect(complete.value.toString(), contains('<redacted>'));
      expect(assembler.hasPartialValue, isFalse);
    });

    test('rejects a wrong fragment length and discards the partial value', () {
      final assembler = LibreFragmentAssembler.encryptedComposite();
      assembler.add(List<int>.filled(20, 1), observedAt: Duration.zero);

      final failure = assembler.add(
        List<int>.filled(8, 2),
        observedAt: const Duration(seconds: 1),
      );

      final error = (failure.single as LibreAssemblyFailure).error;
      expect(error.kind, LibreProtocolErrorKind.fragmentLengthMismatch);
      expect(error.expectedLength, 18);
      expect(error.actualLength, 8);
      expect(error.fragmentIndex, 1);
      expect(error.isConnectionTerminal, isFalse);
      expect(assembler.nextFragmentIndex, 0);

      final restarted = assembler.add(
        List<int>.filled(20, 3),
        observedAt: const Duration(seconds: 2),
      );
      expect(restarted.single, isA<LibreAssemblyProgress>());
    });

    test(
      'expires at exactly ten seconds and does not reuse the late input',
      () {
        final assembler = LibreFragmentAssembler.encryptedComposite();
        assembler.add(List<int>.filled(20, 1), observedAt: Duration.zero);

        final expired = assembler.add(
          List<int>.filled(18, 2),
          observedAt: const Duration(seconds: 10),
        );

        final error = (expired.single as LibreAssemblyFailure).error;
        expect(error.kind, LibreProtocolErrorKind.fragmentTimeout);
        expect(error.actualLength, 20);
        expect(error.fragmentIndex, 1);
        expect(assembler.nextFragmentIndex, 0);
      },
    );

    test('rejects invalid bytes and non-monotonic observations', () {
      final assembler = LibreFragmentAssembler.encryptedComposite();
      final invalidBytes = assembler.add(<int>[
        300,
        ...List<int>.filled(19, 0),
      ], observedAt: const Duration(seconds: 2));
      expect(
        (invalidBytes.single as LibreAssemblyFailure).error.kind,
        LibreProtocolErrorKind.invalidPayloadByte,
      );

      assembler.add(
        List<int>.filled(20, 0),
        observedAt: const Duration(seconds: 3),
      );
      final backwards = assembler.add(
        List<int>.filled(18, 0),
        observedAt: const Duration(seconds: 2),
      );
      expect(
        (backwards.single as LibreAssemblyFailure).error.kind,
        LibreProtocolErrorKind.nonMonotonicObservation,
      );
      expect(assembler.hasPartialValue, isFalse);
    });
  });

  group('Gen2 session-information assembly', () {
    test('assembles 7+18 and has no guessed default timeout', () {
      final assembler = LibreFragmentAssembler.gen2SessionInformation();
      assembler.add(
        List<int>.generate(7, (index) => index),
        observedAt: Duration.zero,
      );

      expect(assembler.expire(observedAt: const Duration(days: 1)), isEmpty);
      final complete = assembler.add(
        List<int>.generate(18, (index) => index + 7),
        observedAt: const Duration(days: 1),
      );
      expect((complete.single as LibreAssemblyComplete).value.length, 25);
    });

    test('uses an explicit timeout when evidence owner supplies one', () {
      final assembler = LibreFragmentAssembler.gen2SessionInformation(
        timeout: const Duration(seconds: 3),
      );
      assembler.add(List<int>.filled(7, 0), observedAt: Duration.zero);

      final expired = assembler.expire(observedAt: const Duration(seconds: 3));
      expect(
        (expired.single as LibreAssemblyFailure).error.kind,
        LibreProtocolErrorKind.fragmentTimeout,
      );
      expect(
        (expired.single as LibreAssemblyFailure).error.isConnectionTerminal,
        isTrue,
      );
    });
  });
}
