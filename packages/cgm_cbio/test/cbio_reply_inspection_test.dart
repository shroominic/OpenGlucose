import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

// Synthetic byte patterns only, plus the identifier-free five-byte payload
// recovered from the live GS1 capture segment recorded on 2026-09-17. It holds
// no address, name, key, or timestamp.
List<int> checked(List<int> prefix) => [
  ...prefix,
  (-prefix.fold<int>(0, (sum, byte) => sum + byte)) & 255,
];

/// A synthetic complete 36-byte `0A` batch whose byte zero declares 36.
List<int> declared36Frame() => checked([
  0x23,
  0x0a,
  0x0c,
  0x01,
  0x00,
  0xe8,
  0x03,
  0x00,
  0x00,
  for (var i = 0; i < 24; i++) i,
  0x03,
  0x00,
]);

void main() {
  group('live FF31 reply', () {
    final live = cbioLiveUnresolvedReply;

    test('is the five identifier-free bytes from the capture segment', () {
      expect(live, [0x23, 0xf7, 0x6f, 0xd9, 0xf4]);
      expect(live.length, 5);
    });

    test('fails every plaintext frame invariant', () {
      final report = inspectCbioReply(live);
      expect(report.byteLength, 5);
      expect(report.sumModulo256, 0x56);
      expect(report.declaredTotalLength, 0x24);
      expect(report.missingTrailingBytes, 31);
      expect(report.acknowledgementMarkerPresent, isFalse);
      expect(report.declaredOpcodeKnown, isFalse);
      expect(report.plaintextFrameValid, isFalse);
      expect(report.plaintextFailure, CbioFrameFailure.length);
    });

    test('has no decoding result and no plaintext frame behind any mask', () {
      final report = inspectCbioReply(live);
      expect(report.frame, isNull);
      expect(report.verdict, CbioReplyVerdict.unresolved);
      expect(report.checksumBalances, isFalse);
      expect(report.declaresLongerFrame, isTrue);
      expect(report.plaintextFrameInAnyOrientation, isFalse);
      expect(report.plaintextFrameUnderSingleByteMask, isFalse);
    });

    test('stays unresolved when a single byte is masked or added', () {
      for (final mask in [0x00, 0x27, 0x5a, 0xe1, 0xff]) {
        expect(
          inspectCbioReply([
            for (final b in live) b ^ mask,
          ]).plaintextFrameValid,
          isFalse,
        );
      }
    });
  });

  group('plaintext control reply', () {
    final ack = checked([0x04, 0x01, 0x00, 0x03]);

    test('is recognised as a complete frame', () {
      final report = inspectCbioReply(ack);
      expect(report.verdict, CbioReplyVerdict.plaintextFrame);
      expect(report.plaintextFrameValid, isTrue);
      expect(report.plaintextFailure, isNull);
      expect(report.acknowledgementMarkerPresent, isTrue);
      expect(report.declaredOpcodeKnown, isTrue);
      expect(report.missingTrailingBytes, 0);
      expect(report.frame, isA<CbioAcknowledgement>());
      expect((report.frame! as CbioAcknowledgement).rawStatus, 0x03);
    });

    test('a short 08 reply fits the contract but no modelled layout', () {
      final report = inspectCbioReply(checked([0x04, 0x08, 0x00, 0x03]));
      expect(report.plaintextFrameValid, isTrue);
      expect(report.frame, isNull);
      expect(report.plaintextFailure, CbioFrameFailure.opcode);
    });

    test('is found again under a constant XOR mask', () {
      final masked = [for (final b in ack) b ^ 0x5a];
      expect(inspectCbioReply(masked).plaintextFrameValid, isFalse);
      expect(fitsCbioPlaintextFrameUnderSingleByteMask(masked), isTrue);
      expect(fitsCbioPlaintextFrameUnderSingleByteMask(ack), isTrue);
    });

    test('is not found when a keystream mask varies per byte', () {
      const keystream = [0x9e, 0x37, 0xff, 0x02, 0xc1];
      final masked = [
        for (var i = 0; i < ack.length; i++) ack[i] ^ keystream[i],
      ];
      expect(inspectCbioReply(masked).plaintextFrameValid, isFalse);
      expect(fitsCbioPlaintextFrameUnderSingleByteMask(masked), isFalse);
    });
  });

  group('frame orientation and truncation search', () {
    final frame = declared36Frame();

    test('declared length is honoured by a complete synthetic frame', () {
      final report = inspectCbioReply(frame);
      expect(frame.length, 36);
      expect(report.plaintextFrameValid, isTrue);
      expect(report.declaredTotalLength, 36);
      expect(report.frame, isNotNull);
    });

    test('a five-byte prefix of it stays unresolved, not decoded', () {
      final report = inspectCbioReply(frame.sublist(0, 5));
      expect(report.verdict, CbioReplyVerdict.unresolved);
      expect(report.plaintextFrameValid, isFalse);
      expect(report.declaresLongerFrame, isTrue);
      expect(report.missingTrailingBytes, 31);
      expect(report.frame, isNull);
    });

    test('rotations and reversal are searched but never invented', () {
      expect(
        fitsCbioPlaintextFrameInAnyOrientation(checked([4, 8, 0, 3])),
        isTrue,
      );
      expect(
        fitsCbioPlaintextFrameInAnyOrientation(cbioLiveUnresolvedReply),
        isFalse,
      );
      expect(
        inspectCbioReply([0x00, 0x01, 0x02]).verdict,
        CbioReplyVerdict.unresolved,
      );
    });
  });
}
