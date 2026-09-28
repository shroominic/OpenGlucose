import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('secure credential records', () {
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
      expect(credentials.toString(), isNot(contains('123456789012')));
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
}
