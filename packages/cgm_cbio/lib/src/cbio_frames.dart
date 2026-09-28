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
    required this.rawWord,
    required this.rawGlucose,
    required this.rawTrend,
    required this.rawGlucoseWarning,
    required this.rawSharedWarning,
  });

  final int index;

  /// Epoch-less per-record counter: the batch base plus 60 per record.
  ///
  /// It is the sensor's own position, not Unix time. Never render it as a
  /// clock and never build a `DateTime` from it.
  final int rawTime;
  final int reindex;

  /// The two packed bytes as a little-endian unsigned 16-bit word, so a
  /// caller can see the span the ten-bit field is cut from.
  final int rawWord;

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
  _validateCbioFrame(bytes);
  return _parseCbioPlaintextFrame(bytes);
}

void _validateCbioFrame(List<int> bytes) {
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
}

CbioFrame _parseCbioPlaintextFrame(List<int> bytes) {
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
        rawWord: le16(9 + 2 * i),
        rawGlucose: (bytes[9 + 2 * i] >> 6) | (bytes[10 + 2 * i] << 2),
        rawTrend: (bytes[9 + 2 * i] >> 3) & 7,
        rawGlucoseWarning: (bytes[9 + 2 * i] >> 1) & 3,
        rawSharedWarning: bytes[9 + 2 * i] & 1,
      ),
  ]);
}

/// Fields from the separate eight-byte 0x08 record layout, without conversion.
///
/// The four 16-bit words are `temperature, dump, payload, processed`. They are
/// kept separate because they are not interchangeable: on the observed firmware
/// the payload word is the only one that carries a reading, and the processed
/// word decodes to zero in every captured record.
final class CbioRawRecord {
  const CbioRawRecord({
    required this.rawTemperature,
    required this.rawDump,
    required this.rawPayload,
    required this.processed,
  });

  /// LE16 at record offset 0. Independent clients read it as tenths of Celsius;
  /// the scale is still unverified here.
  final int rawTemperature;

  /// LE16 at record offset 2. No meaning is established for it.
  final int rawDump;

  /// LE16 at record offset 4: the word that carries the reading.
  ///
  /// The recovered native structure names this field `current`. It is the field
  /// the app's live path renders (`rawPayload / 10`), and it is the only field
  /// in an `08` record with content on the observed firmware. It is still not a
  /// validated glucose measurement: no reference measurement settles its scale,
  /// so no value derived from it is unit-verified.
  final int rawPayload;

  /// LE16 at record offset 6, sharing the `0A` packed bit layout.
  ///
  /// This is the firmware's processed field, not the payload. It read `0x0000`
  /// in every record of every captured GS1 session, so reporting it as the raw
  /// reading makes an empty processed field look like a measured zero.
  final CbioPackedRecord processed;

  /// Always false: no reference measurement has established the scale.
  bool get isUnitVerified => false;
}

/// Separate from [CbioFrame] to preserve the existing closed frame contract.
final class CbioRawBatch {
  CbioRawBatch(List<CbioRawRecord> records)
    : records = List.unmodifiable(records);

  final List<CbioRawRecord> records;
}

/// Parses only complete plaintext 0x08 data, never an ACK or a 0x0a batch.
///
/// This is the single owner of the `08` record layout; the history archive
/// decodes through it rather than repeating the offsets. The payload word is
/// not a validated glucose measurement. Native algorithms, firmware selection,
/// units, epoch, and validity remain separate.
CbioRawBatch parseCbioRawDataFrame(List<int> bytes) {
  _validateCbioFrame(bytes);
  if (bytes[1] != 0x08) {
    throw const CbioFrameException(CbioFrameFailure.opcode);
  }
  final count = bytes[2];
  if (bytes.length != 12 + 8 * count) {
    throw const CbioFrameException(CbioFrameFailure.count);
  }
  int le16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
  final index = le16(3);
  final time = le16(5) | (le16(7) << 16);
  final reindex = le16(bytes.length - 3);
  if (count > 0 &&
      (index + count - 1 > 0xffff ||
          time + 60 * (count - 1) > 0xffffffff ||
          reindex + count - 1 > 0xffff)) {
    throw const CbioFrameException(CbioFrameFailure.overflow);
  }
  return CbioRawBatch([
    for (var i = 0; i < count; i++)
      CbioRawRecord(
        rawTemperature: le16(9 + 8 * i),
        rawDump: le16(11 + 8 * i),
        rawPayload: le16(13 + 8 * i),
        processed: CbioPackedRecord(
          index: index + i,
          rawTime: time + 60 * i,
          reindex: reindex + count - 1 - i,
          rawWord: le16(15 + 8 * i),
          rawGlucose: (bytes[15 + 8 * i] >> 6) | (bytes[16 + 8 * i] << 2),
          rawTrend: (bytes[15 + 8 * i] >> 3) & 7,
          rawGlucoseWarning: (bytes[15 + 8 * i] >> 1) & 3,
          rawSharedWarning: bytes[15 + 8 * i] & 1,
        ),
      ),
  ]);
}

/// Storage information fields; no status or retention policy is inferred.
final class CbioStorageInfo {
  const CbioStorageInfo({
    required this.rawStatus,
    required this.rawStorageNumber,
    required this.rawConfigTimes,
    required this.rawKeyTimes,
  });

  final int rawStatus;
  final int rawStorageNumber;
  final int rawConfigTimes;
  final int rawKeyTimes;
}

/// Time information fields; no epoch, time unit, or sensor state is inferred.
final class CbioTimeInfo {
  const CbioTimeInfo({
    required this.rawStartoverTime,
    required this.rawActivationTime,
    required this.rawCurrentTime,
    required this.rawLastTime,
    required this.rawLastIndex,
  });

  final int rawStartoverTime;
  final int rawActivationTime;
  final int rawCurrentTime;
  final int rawLastTime;
  final int rawLastIndex;
}

/// The separate F0/02 state byte, without an inferred active/inactive enum.
///
/// This is not opcode 02 authentication switching and is not an auth ACK.
final class CbioActivationInfo {
  const CbioActivationInfo({required this.rawActivation});

  final int rawActivation;
}

void _validateCbioInformation(List<int> bytes, int selector, int length) {
  _validateCbioFrame(bytes);
  if (bytes[1] != 0xf0 || bytes[2] != selector) {
    throw const CbioFrameException(CbioFrameFailure.opcode);
  }
  if (bytes.length != length) {
    throw const CbioFrameException(CbioFrameFailure.length);
  }
}

/// Parses a complete plaintext F0/02 activation-information reply.
///
/// Use this selector-specific entry point for an outstanding information read.
/// Its five-byte length alone cannot distinguish it from a control reply.
/// All byte values are preserved; no value authorizes a sensor state change.
CbioActivationInfo parseCbioActivationFrame(List<int> bytes) {
  _validateCbioInformation(bytes, 2, 5);
  return CbioActivationInfo(rawActivation: bytes[3]);
}

/// Inspects an activation (07) or clock-update (03) ACK offline.
///
/// This checks the requested opcode only, not freshness or transaction identity.
/// Unknown result/status values are retained and never grant write permission.
CbioAcknowledgement parseCbioStartAckFrame(
  List<int> bytes, {
  required int expectedOpcode,
}) {
  _validateCbioFrame(bytes);
  if (!const {0x03, 0x07}.contains(expectedOpcode) ||
      bytes[1] != expectedOpcode) {
    throw const CbioFrameException(CbioFrameFailure.opcode);
  }
  if (bytes.length != 5) {
    throw const CbioFrameException(CbioFrameFailure.length);
  }
  return CbioAcknowledgement(
    opcode: bytes[1],
    result: bytes[2],
    rawStatus: bytes[3],
  );
}

/// Parses a complete plaintext F0/04 storage reply; rejects control ACKs.
CbioStorageInfo parseCbioStorageFrame(List<int> bytes) {
  _validateCbioInformation(bytes, 4, 9);
  return CbioStorageInfo(
    rawStatus: bytes[3],
    rawStorageNumber: bytes[4] | (bytes[5] << 8),
    rawConfigTimes: bytes[6],
    rawKeyTimes: bytes[7],
  );
}

/// Parses a complete plaintext F0/03 time reply; rejects control ACKs.
CbioTimeInfo parseCbioTimeFrame(List<int> bytes) {
  _validateCbioInformation(bytes, 3, 20);
  int le16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
  int le32(int offset) => le16(offset) | (le16(offset + 2) << 16);
  return CbioTimeInfo(
    rawStartoverTime: le16(3),
    rawActivationTime: le32(5),
    rawCurrentTime: le32(9),
    rawLastTime: le32(13),
    rawLastIndex: le16(17),
  );
}
