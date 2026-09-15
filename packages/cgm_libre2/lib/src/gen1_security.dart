import 'package:cgm_core/cgm_core.dart';

import 'errors.dart';
import 'events.dart';
import 'model.dart';
import 'uuid.dart';

// Algorithm provenance and required MIT notices are recorded in the package
// root THIRD_PARTY_NOTICES.md and doc/evidence-boundary.md.

const int _uidLength = 8;
const int _patchInfoLength = 6;
const int _framLength = 43 * 8;
const int _encryptedBleLength = 46;
const int _decryptedBleLength = 44;
const int _gen1Secret = 0x1b6a;
const List<int> _key = <int>[0xa0c5, 0x6860, 0x0000, 0x14c6];

/// An eight-byte UID in the byte order consumed by the Gen1 algorithm.
///
/// Platform NFC APIs do not all expose the UID in the same order. The caller
/// must normalize it before constructing this value. The type validates only
/// shape, not device identity or compatibility.
final class LibreGen1Uid {
  LibreGen1Uid.algorithmOrder(Iterable<int> bytes)
    : value = _exactBytes(bytes, _uidLength);

  final LibreOpaqueBytes value;

  @override
  String toString() =>
      'LibreGen1Uid(length: ${value.length}, data: <redacted>)';
}

/// Strict six-byte patch information for a known Libre 2 Gen1 reference.
final class LibreGen1PatchInfo {
  factory LibreGen1PatchInfo(Iterable<int> bytes) {
    final value = _exactBytes(bytes, _patchInfoLength);
    final marker = value.bytes[2];
    final family = marker >> 4;
    final variant = marker & 0x0f;
    final isGen1 = switch (family) {
      3 => variant < 9,
      7 => variant < 4,
      _ => null,
    };
    if (isGen1 == false) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.unsupportedSecurityGeneration,
        generation: LibreSecurityGeneration.gen2,
      );
    }
    if (isGen1 == null) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.unsupportedPatchInfo,
      );
    }

    final signature =
        (value.bytes[0] << 16) | (value.bytes[1] << 8) | value.bytes[2];
    final model = switch (signature) {
      0x9d0830 || 0xc50930 || 0x7f0e30 => LibreGen1Model.libre2,
      0xc60931 || 0x7f0e31 => LibreGen1Model.libre2Plus,
      _ => null,
    };
    if (model == null) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.unsupportedPatchInfo,
      );
    }
    return LibreGen1PatchInfo._(value, model);
  }

  const LibreGen1PatchInfo._(this.value, this.model);

  final LibreOpaqueBytes value;
  final LibreGen1Model model;

  /// Informational identity from the already accepted patch signature.
  ///
  /// This contains no UID, region inference, key bytes, lifecycle evidence, or
  /// grant to use this reference variant with a live sensor. In particular,
  /// identifying Libre 2 Plus does not enable its live setup or receiver.
  CgmSensorVariant get sensorVariant => CgmSensorVariant(
    protocolFamily: 'abbott-sas',
    source: CgmSensorVariantSource.nfcPatchInfo,
    model: switch (model) {
      LibreGen1Model.libre2 => 'FreeStyle Libre 2',
      LibreGen1Model.libre2Plus => 'FreeStyle Libre 2 Plus',
    },
    variantCode: value.bytes
        .take(3)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(),
    securityGeneration: 'gen1',
  );

  @override
  String toString() =>
      'LibreGen1PatchInfo(model: ${model.name}, '
      'length: ${value.length}, data: <redacted>)';
}

/// Result of a 344-byte FRAM decrypt after all three CRCs pass.
final class LibreGen1DecryptedFram {
  LibreGen1DecryptedFram._(Iterable<int> bytes)
    : value = _exactBytes(bytes, _framLength);

  final LibreOpaqueBytes value;

  @override
  String toString() =>
      'LibreGen1DecryptedFram(length: ${value.length}, data: <redacted>)';
}

/// Result of a 46-byte BLE decrypt after the embedded CRC passes.
final class LibreGen1DecryptedBlePayload {
  LibreGen1DecryptedBlePayload._(Iterable<int> bytes)
    : value = _exactBytes(bytes, _decryptedBleLength);

  final LibreOpaqueBytes value;

  @override
  String toString() =>
      'LibreGen1DecryptedBlePayload('
      'length: ${value.length}, data: <redacted>)';
}

/// Semantic purpose of a pure Gen1 NFC command plan.
enum LibreGen1NfcCommandPurpose { activation, enableStreaming }

/// Transport shape established by the pinned reference call sites.
enum LibreGen1NfcTransportShape { iso15693HighDataRateCustomCommand }

/// A pure plan for a sensor-state-changing command.
///
/// This type performs no I/O. A caller must apply the repository R3 approval
/// and target-evidence gates before it uses these bytes with an NFC transport.
final class LibreGen1NfcCommandPlan {
  const LibreGen1NfcCommandPlan._({
    required this.purpose,
    required this.requestParameters,
    required this.referenceResponseLength,
  });

  final LibreGen1NfcCommandPurpose purpose;
  final LibreOpaqueBytes requestParameters;

  /// Response length handled by the pinned reference, not a success proof.
  final int referenceResponseLength;

  int get customCommandCode => 0xa1;
  bool get changesSensorState => true;
  LibreGen1NfcTransportShape get transportShape =>
      LibreGen1NfcTransportShape.iso15693HighDataRateCustomCommand;
  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;

  @override
  String toString() =>
      'LibreGen1NfcCommandPlan(purpose: ${purpose.name}, '
      'requestLength: ${requestParameters.length}, '
      'referenceResponseLength: $referenceResponseLength, data: <redacted>)';
}

/// Required write behavior for the pinned Gen1 BLE login call site.
enum LibreGen1BleLoginWriteMode { withResponse }

/// A pure F001 login plan. F002 subscription follows only after write success.
final class LibreGen1BleLoginPlan {
  const LibreGen1BleLoginPlan._(this.value);

  final LibreOpaqueBytes value;

  String get characteristicUuid => LibreUuids.sasLogin;
  String get subscribeAfterWriteUuid => LibreUuids.sasData;
  LibreGen1BleLoginWriteMode get writeMode =>
      LibreGen1BleLoginWriteMode.withResponse;
  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;

  @override
  String toString() =>
      'LibreGen1BleLoginPlan(valueLength: ${value.length}, '
      'writeMode: ${writeMode.name}, data: <redacted>)';
}

/// Pure, synchronous Libre 2 security-Gen1 core.
///
/// It contains no NFC, Bluetooth, storage, retry, calibration, or glucose
/// interpretation behavior.
final class LibreGen1OfflineCore {
  const LibreGen1OfflineCore({required this.uid, required this.patchInfo});

  final LibreGen1Uid uid;
  final LibreGen1PatchInfo patchInfo;

  /// Executes the common four-byte UID-derived primitive.
  LibreOpaqueBytes derivePrimitive({required int x, required int y}) {
    _requireUnsigned(x, 0xffff);
    _requireUnsigned(y, 0xffff);
    return LibreOpaqueBytes(_usefulFunction(uid.value.bytes, x, y));
  }

  /// Decrypts exactly 43 FRAM blocks and requires every region CRC to pass.
  LibreGen1DecryptedFram decryptFram(Iterable<int> encrypted) {
    final input = _exactBytes(encrypted, _framLength).bytes;
    final argument =
        (_littleEndian16(patchInfo.value.bytes, 4) ^ 0x44) & 0xffff;
    final clear = <int>[];
    for (var block = 0; block < 43; block += 1) {
      final words = _processCrypto(
        _prepareVariables(uid.value.bytes, block, argument),
      );
      final keyBytes = _wordsToLittleEndian(words);
      final offset = block * 8;
      for (var index = 0; index < 8; index += 1) {
        clear.add(input[offset + index] ^ keyBytes[index]);
      }
    }

    final headerValid = _regionCrcIsValid(clear, 0, 24);
    final bodyValid = _regionCrcIsValid(clear, 24, 320);
    final footerValid = _regionCrcIsValid(clear, 320, 344);
    if (!headerValid) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.integrityCheckFailed,
        integrityRegion: LibreIntegrityRegion.framHeader,
      );
    }
    if (!bodyValid) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.integrityCheckFailed,
        integrityRegion: LibreIntegrityRegion.framBody,
      );
    }
    if (!footerValid) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.integrityCheckFailed,
        integrityRegion: LibreIntegrityRegion.framFooter,
      );
    }
    return LibreGen1DecryptedFram._(clear);
  }

  /// Decrypts one exact 46-byte F002 composite and validates its CRC.
  LibreGen1DecryptedBlePayload decryptBle(Iterable<int> encrypted) {
    final input = _exactBytes(encrypted, _encryptedBleLength).bytes;
    final activation = _usefulFunction(uid.value.bytes, 0x1b, _gen1Secret);
    final x =
        (_littleEndian16(activation, 0) ^ _littleEndian16(activation, 2) |
        0x63);
    final y = _littleEndian16(input, 0) ^ 0x63;
    var words = _processCrypto(_prepareVariables(uid.value.bytes, x, y));
    final keyStream = <int>[];
    for (var round = 0; round < 8; round += 1) {
      keyStream.addAll(_wordsToLittleEndian(words));
      words = _processCrypto(words);
    }
    final clear = <int>[
      for (var index = 0; index < _decryptedBleLength; index += 1)
        input[index + 2] ^ keyStream[index],
    ];
    final expected = _littleEndian16(clear, 42);
    final actual = _crc16(clear.sublist(0, 42));
    if (actual != expected) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.integrityCheckFailed,
        integrityRegion: LibreIntegrityRegion.blePayload,
      );
    }
    return LibreGen1DecryptedBlePayload._(clear);
  }

  /// Plans the five custom parameters for Gen1 activation.
  LibreGen1NfcCommandPlan planActivation() {
    final authentication = _usefulFunction(uid.value.bytes, 0x1b, _gen1Secret);
    return LibreGen1NfcCommandPlan._(
      purpose: LibreGen1NfcCommandPurpose.activation,
      requestParameters: LibreOpaqueBytes(<int>[0x1b, ...authentication]),
      referenceResponseLength: 4,
    );
  }

  /// Plans the nine custom parameters for Gen1 streaming enablement.
  LibreGen1NfcCommandPlan planEnableStreaming({required int streamingBase}) {
    _requireUnsigned(streamingBase, 0xffffffff);
    final baseBytes = _littleEndian32(streamingBase);
    final secret =
        _littleEndian16(patchInfo.value.bytes, 4) ^ (streamingBase & 0xffff);
    final authentication = _usefulFunction(uid.value.bytes, 0x1e, secret);
    return LibreGen1NfcCommandPlan._(
      purpose: LibreGen1NfcCommandPurpose.enableStreaming,
      requestParameters: LibreOpaqueBytes(<int>[
        0x1e,
        ...baseBytes,
        ...authentication,
      ]),
      referenceResponseLength: 6,
    );
  }

  /// Plans the 12-byte F001 login value for an explicit persisted counter.
  LibreGen1BleLoginPlan planBleLogin({
    required int streamingBase,
    required int unlockCount,
  }) {
    _requireUnsigned(streamingBase, 0xffffffff);
    if (unlockCount < 1 || unlockCount > 0xffff) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.invalidNumericRange,
      );
    }
    final rollingValue = streamingBase + unlockCount;
    if (rollingValue > 0xffffffff) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.invalidNumericRange,
      );
    }
    final rollingBytes = _littleEndian32(rollingValue);
    final activation = _usefulFunction(uid.value.bytes, 0x1b, _gen1Secret);
    final enable = _usefulFunction(
      uid.value.bytes,
      0x1e,
      (streamingBase & 0xffff) ^ _littleEndian16(patchInfo.value.bytes, 4),
    );
    final first = <int>[
      _littleEndian16(enable, 0) ^ _littleEndian16(rollingBytes, 2),
      _littleEndian16(activation, 0),
      _littleEndian16(enable, 2) ^ _littleEndian16(rollingBytes, 0),
      _littleEndian16(activation, 2),
    ];
    final mixed = _processCrypto(_prepareVariables2(uid.value.bytes, first));
    final checks = <int>[
      _crc16(<int>[
        0xc1,
        0xc4,
        0xc3,
        0xc0,
        0xd4,
        0xe1,
        0xe7,
        0xba,
        mixed[0] & 0xff,
        mixed[0] >> 8,
      ]),
      _crc16(_wordsToLittleEndian(mixed.sublist(1))),
      _crc16(<int>[...activation, enable[0], enable[1]]),
      _crc16(<int>[enable[2], enable[3], ...rollingBytes]),
    ];
    final result = _wordsToLittleEndian(
      _processCrypto(_prepareVariables2(uid.value.bytes, checks)),
    );
    return LibreGen1BleLoginPlan._(
      LibreOpaqueBytes(<int>[...rollingBytes, ...result]),
    );
  }

  @override
  String toString() =>
      'LibreGen1OfflineCore(model: ${patchInfo.model.name}, data: <redacted>)';
}

LibreOpaqueBytes _exactBytes(Iterable<int> bytes, int expectedLength) {
  final value = LibreOpaqueBytes(bytes);
  if (value.length != expectedLength) {
    throw LibreProtocolError(
      kind: LibreProtocolErrorKind.payloadLengthMismatch,
      expectedLength: expectedLength,
      actualLength: value.length,
    );
  }
  return value;
}

void _requireUnsigned(int value, int maximum) {
  if (value < 0 || value > maximum) {
    throw const LibreProtocolError(
      kind: LibreProtocolErrorKind.invalidNumericRange,
    );
  }
}

int _littleEndian16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

List<int> _littleEndian32(int value) => <int>[
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> _prepareVariables(List<int> uid, int x, int y) => <int>[
  (_littleEndian16(uid, 4) + x + y) & 0xffff,
  (_littleEndian16(uid, 2) + _key[2]) & 0xffff,
  (_littleEndian16(uid, 0) + x * 2) & 0xffff,
  0x241a ^ _key[3],
];

List<int> _prepareVariables2(List<int> uid, List<int> input) => <int>[
  (_littleEndian16(uid, 4) + input[0]) & 0xffff,
  (_littleEndian16(uid, 2) + input[1]) & 0xffff,
  (_littleEndian16(uid, 0) + input[2] + _key[2]) & 0xffff,
  (input[3] + _key[3]) & 0xffff,
];

List<int> _processCrypto(List<int> input) {
  int operation(int value) {
    var result = value >> 2;
    if ((value & 1) != 0) result ^= _key[1];
    if ((value & 2) != 0) result ^= _key[0];
    return result & 0xffff;
  }

  final r0 = operation(input[0]) ^ input[3];
  final r1 = operation(r0) ^ input[2];
  final r2 = operation(r1) ^ input[1];
  final r3 = operation(r2) ^ input[0];
  final r4 = operation(r3);
  final r5 = operation(r4 ^ r0);
  final r6 = operation(r5 ^ r1);
  final r7 = operation(r6 ^ r2);
  return <int>[r3 ^ r7, r2 ^ r6, r1 ^ r5, r0 ^ r4];
}

List<int> _usefulFunction(List<int> uid, int x, int y) {
  final words = _processCrypto(_prepareVariables(uid, x, y));
  return _wordsToLittleEndian(<int>[words[0] ^ 0x4163, words[1] ^ 0x4344]);
}

List<int> _wordsToLittleEndian(List<int> words) => <int>[
  for (final word in words) ...<int>[word & 0xff, (word >> 8) & 0xff],
];

bool _regionCrcIsValid(List<int> bytes, int start, int end) {
  final expected = _littleEndian16(bytes, start);
  final actual = _crc16(bytes.sublist(start + 2, end));
  return expected == actual;
}

int _crc16(Iterable<int> bytes) {
  var crc = 0xffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  var reversed = 0;
  for (var bit = 0; bit < 16; bit += 1) {
    reversed = (reversed << 1) | (crc & 1);
    crc >>= 1;
  }
  return reversed & 0xffff;
}
