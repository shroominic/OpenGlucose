import 'dart:math' as math;

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('secure credential records', () {
    test('restores and preserves exact schema v2 history identity', () {
      final record = <String, Object?>{
        'version': 2,
        'communicationIdentity': '123456789012',
        'cipher': 7,
        'k': 1.2,
        'r': 3.4,
        'transmitterComputed': true,
        'phase': YuwellCredentialPhase.active.name,
        'activationStartedAt': '2026-08-01T00:00:00.000Z',
        'initializationIndex': 15,
        'verifiedFirmware': 'V1150',
        'historyGeneration': 'b' * 32,
      };

      final restored = YuwellSessionCredentials.restoreFromSecureStorage(
        record,
      );

      expect(restored.serializeForSecureStorage(), record);
    });

    test('round-trips a prepared identity without using toString', () {
      final credentials = YuwellSessionCredentials(
        communicationIdentity: YuwellCommunicationIdentity.parse(
          '123456789012',
        ),
        cipher: null,
        k: 0,
        r: 0,
        transmitterComputed: true,
        phase: YuwellCredentialPhase.identityPrepared,
      );

      final serialized = credentials.serializeForSecureStorage();
      final restored = YuwellSessionCredentials.restoreFromSecureStorage(
        serialized,
      );

      expect(restored.phase, YuwellCredentialPhase.identityPrepared);
      expect(restored.cipher, isNull);
      expect(
        restored.communicationIdentity.serializeForSecureStorage(),
        '123456789012',
      );
      expect(restored.verifiedFirmware, isNull);
      expect(restored.historyGeneration, isNull);
      expect(restored.canRestoreHistory, isFalse);
      expect(serialized['version'], 1);
      expect(credentials.toString(), isNot(contains('123456789012')));
    });

    test('round-trips v2 identity and copy operations preserve it', () {
      final credentials = YuwellSessionCredentials(
        communicationIdentity: YuwellCommunicationIdentity.parse(
          '123456789012',
        ),
        cipher: 7,
        k: 1.2,
        r: 3.4,
        transmitterComputed: true,
        phase: YuwellCredentialPhase.active,
        activationStartedAt: DateTime.utc(2026, 8, 1),
        verifiedFirmware: 'V1150',
        historyGeneration: 'b' * 32,
      );

      final copied = credentials.copyWith(k: 2.4);
      final restored = YuwellSessionCredentials.restoreFromSecureStorage(
        copied.serializeForSecureStorage(),
      );

      expect(restored.k, 2.4);
      expect(restored.verifiedFirmware, 'V1150');
      expect(restored.historyGeneration, 'b' * 32);
      expect(restored.canRestoreHistory, isTrue);
      expect(restored.serializeForSecureStorage()['version'], 2);
      expect(restored.toString(), isNot(contains('V1150')));
      expect(restored.toString(), isNot(contains('b' * 32)));
    });

    test('upgrades v1 identity only with an exact complete pair', () {
      final legacy = YuwellSessionCredentials(
        communicationIdentity: YuwellCommunicationIdentity.parse(
          '123456789012',
        ),
        cipher: 7,
        k: 1.2,
        r: 3.4,
        transmitterComputed: true,
        phase: YuwellCredentialPhase.authenticated,
      );

      expect(
        () => legacy.copyWith(verifiedFirmware: 'V1150'),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => legacy.copyWith(historyGeneration: 'b' * 32),
        throwsA(isA<YuwellProtocolFormatException>()),
      );

      final upgraded = legacy.copyWith(
        verifiedFirmware: 'V1150',
        historyGeneration: 'b' * 32,
      );
      expect(upgraded.canRestoreHistory, isTrue);
      expect(upgraded.serializeForSecureStorage()['version'], 2);
    });

    test('rejects malformed, partial, extra, and future v2 identity', () {
      final valid = <String, Object?>{
        'version': 2,
        'communicationIdentity': '123456789012',
        'cipher': 7,
        'k': 1.2,
        'r': 3.4,
        'transmitterComputed': true,
        'phase': YuwellCredentialPhase.authenticated.name,
        'activationStartedAt': null,
        'initializationIndex': 15,
        'verifiedFirmware': 'V1150',
        'historyGeneration': 'b' * 32,
      };
      final invalid = <Map<String, Object?>>[
        <String, Object?>{...valid}..remove('verifiedFirmware'),
        <String, Object?>{...valid}..remove('historyGeneration'),
        <String, Object?>{...valid, 'verifiedFirmware': ''},
        <String, Object?>{...valid, 'verifiedFirmware': 'v1150'},
        <String, Object?>{...valid, 'verifiedFirmware': 'V${'A' * 32}'},
        <String, Object?>{...valid, 'historyGeneration': 'B' * 32},
        <String, Object?>{...valid, 'historyGeneration': 'b' * 31},
        <String, Object?>{...valid, 'extra': true},
        <String, Object?>{...valid, 'version': 3},
        <String, Object?>{...valid, 'version': 1},
      ];

      for (final record in invalid) {
        expect(
          () => YuwellSessionCredentials.restoreFromSecureStorage(record),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
      expect(
        () => YuwellSessionCredentials(
          communicationIdentity: YuwellCommunicationIdentity.parse(
            '123456789012',
          ),
          cipher: 7,
          k: 1.2,
          r: 3.4,
          transmitterComputed: true,
          phase: YuwellCredentialPhase.authenticated,
          verifiedFirmware: 'V1150',
        ).serializeForSecureStorage(),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('rejects non-finite coefficients and inconsistent phases', () {
      final active = YuwellSessionCredentials(
        communicationIdentity: YuwellCommunicationIdentity.parse(
          '123456789012',
        ),
        cipher: 7,
        k: 1.2,
        r: 3.4,
        transmitterComputed: true,
        phase: YuwellCredentialPhase.active,
        activationStartedAt: DateTime.utc(2026, 8, 1),
      ).serializeForSecureStorage();

      for (final mutation in <Map<String, Object?> Function()>[
        () => <String, Object?>{...active, 'k': double.nan},
        () => <String, Object?>{...active, 'r': double.infinity},
        () => <String, Object?>{...active, 'activationStartedAt': null},
        () => <String, Object?>{
          ...active,
          'phase': YuwellCredentialPhase.authenticated.name,
        },
        () => <String, Object?>{
          ...active,
          'phase': YuwellCredentialPhase.identityPrepared.name,
        },
      ]) {
        expect(
          () => YuwellSessionCredentials.restoreFromSecureStorage(mutation()),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });

    test('round-trips the durable post-initialize phase', () {
      final pending = YuwellSessionCredentials(
        communicationIdentity: YuwellCommunicationIdentity.parse(
          '123456789012',
        ),
        cipher: 7,
        k: 1.2,
        r: 3.4,
        transmitterComputed: true,
        phase: YuwellCredentialPhase.lowPowerPending,
        activationStartedAt: DateTime.utc(2026, 8, 1),
      );

      final restored = YuwellSessionCredentials.restoreFromSecureStorage(
        pending.serializeForSecureStorage(),
      );

      expect(restored.phase, YuwellCredentialPhase.lowPowerPending);
      expect(restored.activationStartedAt, DateTime.utc(2026, 8, 1));
    });
  });

  test('history generation uses exactly 16 opaque random bytes', () {
    final generator = YuwellSecureHistoryGenerationGenerator(
      random: math.Random(7),
    );

    final first = generator.generate();
    final second = generator.generate();

    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(second, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(second, isNot(first));
  });
}
