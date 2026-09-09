/// Offline inspection of complete, already-decrypted GS1 V120 frames.
///
/// This code does not decrypt, assemble BLE fragments, write commands, or
/// produce CgmReading values. Units, epoch, and validity are not established.
sealed class CbioFrame {
  const CbioFrame(this.opcode);

  final int opcode;
}

/// Raw acknowledgement fields, before the vendor's command-specific mapping.
final class CbioAcknowledgement extends CbioFrame {
  const CbioAcknowledgement({
    required int opcode,
    required this.result,
    required this.rawStatus,
  }) : super(opcode);

  final int result;
  final int rawStatus;

  /// An opcode echo only; it cannot prove transaction identity or freshness.
  bool echoesCommand(int command) => opcode == command;
}

/// Packed record fields, deliberately without units or a wall-clock timestamp.
final class CbioPackedRecord {
  const CbioPackedRecord({
    required this.index,
    required this.rawTime,
    required this.reindex,
    required this.rawGlucose,
    required this.rawTrend,
    required this.rawGlucoseWarning,
    required this.rawSharedWarning,
  });

  final int index;
  final int rawTime;
  final int reindex;
  final int rawGlucose;
  final int rawTrend;
  final int rawGlucoseWarning;

  /// The examined native build assigns this bit to both twarn and cwarn.
  final int rawSharedWarning;
}

final class CbioPackedBatch extends CbioFrame {
  CbioPackedBatch(List<CbioPackedRecord> records)
    : records = List.unmodifiable(records),
      super(0x0a);

  final List<CbioPackedRecord> records;
}

/// Closed, identifier-free failure reasons. Exceptions never retain the input.
enum CbioFrameFailure {
  size,
  byteRange,
  length,
  checksum,
  opcode,
  count,
  overflow,
}

final class CbioFrameException implements Exception {
  const CbioFrameException(this.reason);

  final CbioFrameFailure reason;

  @override
  String toString() => 'CbioFrameException: ${reason.name}';
}

/// Parses one complete plaintext frame with strict bounds and integrity checks.
///
/// Five-byte control replies are supported for the observed/query/auth opcodes.
/// Only opcode 0x0a supports the packed record layout. Other layouts fail closed.
CbioFrame parseCbioPlaintextFrame(List<int> bytes) {
  if (bytes.length < 5 || bytes.length > 256) {
    throw const CbioFrameException(CbioFrameFailure.size);
  }
  if (bytes.any((byte) => byte < 0 || byte > 255)) {
    throw const CbioFrameException(CbioFrameFailure.byteRange);
  }
  if (bytes[0] + 1 != bytes.length) {
    throw const CbioFrameException(CbioFrameFailure.length);
  }
  if ((bytes.fold<int>(0, (sum, byte) => sum + byte) & 255) != 0) {
    throw const CbioFrameException(CbioFrameFailure.checksum);
  }
  final opcode = bytes[1];
  if (bytes.length == 5) {
    if (!const {0x00, 0x01, 0x02, 0x0a, 0xf0}.contains(opcode)) {
      throw const CbioFrameException(CbioFrameFailure.opcode);
    }
    return CbioAcknowledgement(
      opcode: opcode,
      result: bytes[2],
      rawStatus: bytes[3],
    );
  }
  if (opcode != 0x0a) {
    throw const CbioFrameException(CbioFrameFailure.opcode);
  }
  final count = bytes[2];
  if (bytes.length != 12 + 2 * count) {
    throw const CbioFrameException(CbioFrameFailure.count);
  }
  int le16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
  final initialIndex = le16(3);
  final initialTime = le16(5) | (le16(7) << 16);
  final baseReindex = le16(bytes.length - 3);
  // Counter wrap semantics are unknown. Do not silently infer a wrapped value.
  if (count > 0 &&
      (initialIndex + count - 1 > 0xffff ||
          initialTime + 60 * (count - 1) > 0xffffffff ||
          baseReindex + count - 1 > 0xffff)) {
    throw const CbioFrameException(CbioFrameFailure.overflow);
  }
  return CbioPackedBatch([
    for (var i = 0; i < count; i++)
      CbioPackedRecord(
        index: initialIndex + i,
        rawTime: initialTime + 60 * i,
        reindex: baseReindex + count - 1 - i,
        rawGlucose: (bytes[9 + 2 * i] >> 6) | (bytes[10 + 2 * i] << 2),
        rawTrend: (bytes[9 + 2 * i] >> 3) & 7,
        rawGlucoseWarning: (bytes[9 + 2 * i] >> 1) & 3,
        rawSharedWarning: bytes[9 + 2 * i] & 1,
      ),
  ]);
}
