/// Structural inspection of one raw FF31 notification payload.
///
/// The GS1 sensor answered the single bounded `06 08 01 00 00 00 F1` read with
/// five byte-identical notification bytes that the plaintext length invariant
/// rejects. This module reports which plaintext hypotheses those bytes survive
/// so a capture can be classified without inventing a decode. It does not
/// decrypt, reassemble fragments, hold a key, or produce a `CgmReading`.
library;

import 'cbio_frames.dart';

/// The identifier-free FF31 payload recovered from the live GS1 capture.
///
/// Byte-identical across the recorded sessions of 2026-09-17. It carries no
/// address, name, key, nonce, or timestamp, so it is safe to publish and test.
const List<int> cbioLiveUnresolvedReply = <int>[0x23, 0xf7, 0x6f, 0xd9, 0xf4];

/// The opcodes the plaintext contract can attribute to a complete frame.
const Set<int> cbioKnownOpcodes = <int>{
  0x00,
  0x01,
  0x02,
  0x03,
  0x04,
  0x07,
  0x08,
  0x0a,
  0xf0,
};

/// What the plaintext contract alone can say about a captured payload.
enum CbioReplyVerdict {
  /// The bytes satisfy the contract: declared length, checksum, known opcode.
  plaintextFrame,

  /// The bytes satisfy none of the plaintext hypotheses.
  ///
  /// A payload may still declare a longer frame through [declaredTotalLength];
  /// that reading is a hypothesis about framing, not a decoded result.
  unresolved,
}

/// Read-only findings for one notification payload.
///
/// Every field is derived from the bytes themselves. [frame] stays null unless
/// the existing plaintext parser accepted them, so an unresolved reply can
/// never be mistaken for a decoded one.
final class CbioReplyInspection {
  const CbioReplyInspection({
    required this.verdict,
    required this.byteLength,
    required this.sumModulo256,
    required this.declaredTotalLength,
    required this.missingTrailingBytes,
    required this.checksumBalances,
    required this.acknowledgementMarkerPresent,
    required this.declaredOpcodeKnown,
    required this.plaintextFrameValid,
    required this.plaintextFailure,
    required this.plaintextFrameInAnyOrientation,
    required this.plaintextFrameUnderSingleByteMask,
    this.frame,
  });

  final CbioReplyVerdict verdict;

  /// Number of bytes in the payload, verbatim from the capture.
  final int byteLength;

  /// Additive sum of every byte, modulo 256. Zero is the contract's check.
  final int sumModulo256;

  /// Byte zero read as the vendor's checksum offset, `L + 1`, or null if empty.
  ///
  /// This is only a hypothesis about the framing. It is not a header that the
  /// capture proved the sensor sends.
  final int? declaredTotalLength;

  /// Bytes still missing if [declaredTotalLength] framed this payload.
  final int missingTrailingBytes;

  /// Whether byte zero declares a frame longer than the captured payload.
  bool get declaresLongerFrame => missingTrailingBytes > 0;

  final bool checksumBalances;

  /// Whether the five-byte acknowledgement marker `0x04` leads the payload.
  final bool acknowledgementMarkerPresent;

  /// Whether byte one is an opcode the plaintext contract can attribute.
  final bool declaredOpcodeKnown;

  /// Whether the payload satisfies length, checksum, and opcode together.
  final bool plaintextFrameValid;

  /// Why the existing plaintext parser refused the bytes, if it did.
  final CbioFrameFailure? plaintextFailure;

  /// Whether any rotation or the reverse of the payload satisfies the contract.
  final bool plaintextFrameInAnyOrientation;

  /// Whether one constant XOR or additive mask exposes a valid plaintext frame.
  ///
  /// A constant mask is the weakest reversible transform hypothesis. A false
  /// result rules it out; it says nothing about a keyed stream cipher, which
  /// this module cannot test without the vendor key.
  final bool plaintextFrameUnderSingleByteMask;

  /// The parsed frame, only when the plaintext parser accepted the payload.
  final CbioFrame? frame;
}

/// Inspects one raw notification payload without transforming it.
CbioReplyInspection inspectCbioReply(List<int> bytes) {
  final sum = bytes.fold<int>(0, (acc, byte) => acc + byte) & 255;
  final declaredTotalLength = bytes.isEmpty ? null : bytes[0] + 1;
  final missingTrailingBytes = declaredTotalLength == null
      ? 0
      : declaredTotalLength - bytes.length > 0
      ? declaredTotalLength - bytes.length
      : 0;
  final checksumBalances = sum == 0;
  final acknowledgementMarkerPresent = bytes.isNotEmpty && bytes[0] == 0x04;
  final declaredOpcodeKnown =
      bytes.length > 1 && cbioKnownOpcodes.contains(bytes[1]);
  final plaintextFrameValid =
      declaredTotalLength == bytes.length &&
      checksumBalances &&
      declaredOpcodeKnown;

  CbioFrameFailure? plaintextFailure;
  CbioFrame? frame;
  try {
    frame = parseCbioPlaintextFrame(bytes);
  } on CbioFrameException catch (exception) {
    plaintextFailure = exception.reason;
  }

  final verdict = plaintextFrameValid
      ? CbioReplyVerdict.plaintextFrame
      : CbioReplyVerdict.unresolved;

  return CbioReplyInspection(
    verdict: verdict,
    byteLength: bytes.length,
    sumModulo256: sum,
    declaredTotalLength: declaredTotalLength,
    missingTrailingBytes: missingTrailingBytes,
    checksumBalances: checksumBalances,
    acknowledgementMarkerPresent: acknowledgementMarkerPresent,
    declaredOpcodeKnown: declaredOpcodeKnown,
    plaintextFrameValid: plaintextFrameValid,
    plaintextFailure: plaintextFailure,
    plaintextFrameInAnyOrientation: fitsCbioPlaintextFrameInAnyOrientation(
      bytes,
    ),
    plaintextFrameUnderSingleByteMask:
        fitsCbioPlaintextFrameUnderSingleByteMask(bytes),
    frame: frame,
  );
}

/// Whether the payload satisfies the complete plaintext contract.
///
/// The generic entry point models five-byte control replies and `0A` batches
/// only, so this checks the framing invariants and the known opcode set.
bool fitsCbioPlaintextFrame(List<int> bytes) {
  if (bytes.length < 5 || bytes.length > 256) {
    return false;
  }
  if (bytes.any((byte) => byte < 0 || byte > 255)) {
    return false;
  }
  if (bytes[0] + 1 != bytes.length) {
    return false;
  }
  if ((bytes.fold<int>(0, (total, byte) => total + byte) & 255) != 0) {
    return false;
  }
  return cbioKnownOpcodes.contains(bytes[1]);
}

/// Whether any rotation or the reversed payload satisfies the contract.
///
/// Byte-order mistakes and a leaked fragment tail are both worth ruling out
/// before a payload is reported as unexplained.
bool fitsCbioPlaintextFrameInAnyOrientation(List<int> bytes) {
  final candidates = <List<int>>[
    for (var offset = 0; offset < bytes.length; offset++)
      [...bytes.sublist(offset), ...bytes.sublist(0, offset)],
    bytes.reversed.toList(),
  ];
  return candidates.any(fitsCbioPlaintextFrame);
}

/// Whether one constant XOR or additive mask exposes a valid plaintext frame.
///
/// Only 512 candidate transforms are tested, so this is a bounded refutation:
/// it can rule out a constant mask and can confirm one, but it cannot rule out
/// a keyed per-byte keystream such as RC4.
bool fitsCbioPlaintextFrameUnderSingleByteMask(List<int> bytes) {
  for (var mask = 0; mask < 256; mask++) {
    if (fitsCbioPlaintextFrame([for (final byte in bytes) byte ^ mask])) {
      return true;
    }
    if (fitsCbioPlaintextFrame([
      for (final byte in bytes) (byte + mask) & 255,
    ])) {
      return true;
    }
  }
  return false;
}
