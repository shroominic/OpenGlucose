import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

class AidexTimingProfile {
  const AidexTimingProfile({
    this.gattGap = const Duration(milliseconds: 800),
    this.discoveryRecoveryCloseGap = const Duration(seconds: 2),
    this.discoveryRecoveryPostConnectSettle = const Duration(seconds: 1),
    this.postStartSession = const Duration(milliseconds: 350),
    this.postSessionStartWrite = const Duration(milliseconds: 250),
    this.vendorPairTimeout = const Duration(seconds: 10),
    this.vendorCommandTimeout = const Duration(seconds: 15),
    this.warmupResumePollInterval = const Duration(minutes: 1),
  });

  final Duration gattGap;
  final Duration discoveryRecoveryCloseGap;
  final Duration discoveryRecoveryPostConnectSettle;
  final Duration postStartSession;
  final Duration postSessionStartWrite;
  final Duration vendorPairTimeout;
  final Duration vendorCommandTimeout;
  final Duration warmupResumePollInterval;

  static const production = AidexTimingProfile();
}

class AidexUuids {
  static const cgmService = '181F';
  static const deviceInfoService = '180A';
  static const bondManagementService = '181E';

  static const measurement = '2AA7';
  static const feature = '2AA8';
  static const status = '2AA9';
  static const sessionStart = '2AAA';
  static const sessionRunTime = '2AAB';
  static const racp = '2A52';
  static const specificOps = '2AAC';

  static const manufacturerName = '2A29';
  static const modelNumber = '2A24';
  static const serialNumber = '2A25';
  static const softwareRevision = '2A28';
  static const bondManagementControlPoint = '2AA4';
  static const bondManagementFeature = '2AA5';

  static const f001 = 'F001';
  static const f002 = 'F002';
  static const f003 = 'F003';
  static const f005 = 'F005';
}

enum AidexVendorOpcode {
  getDeviceInfo(0x10, 'getDeviceInfo'),
  getBroadcastData(0x11, 'getBroadcastData'),
  newSensor(0x20, 'newSensor'),
  getStartTime(0x21, 'getStartTime'),
  getHistoryRange(0x22, 'getHistoryRange'),
  getHistories(0x23, 'getHistories'),
  getRawHistories(0x24, 'getRawHistories'),
  calibration(0x25, 'calibration'),
  getCalibrationRange(0x26, 'getCalibrationRange'),
  getCalibration(0x27, 'getCalibration'),
  getSensorCheck(0x32, 'getSensorCheck'),
  getAutoUpdateStatus(0x33, 'getAutoUpdateStatus'),
  setAutoUpdateStatus(0x34, 'setAutoUpdateStatus'),
  setDynamicAdvMode(0x35, 'setDynamicAdvMode'),
  getLogRange(0xE0, 'getLogRange'),
  getLogs(0xE1, 'getLogs'),
  getErrorLogs(0xE2, 'getErrorLogs'),
  reset(0xF0, 'reset'),
  shelfMode(0xF1, 'shelfMode'),
  unpair(0xF2, 'unpair'),
  clearStorage(0xF3, 'clearStorage'),
  setGcBiasTrimming(0xF4, 'setGcBiasTrimming'),
  setGcImeasTrimming(0xF5, 'setGcImeasTrimming');

  const AidexVendorOpcode(this.code, this.title);

  final int code;
  final String title;

  static AidexVendorOpcode? fromCode(int code) {
    for (final opcode in AidexVendorOpcode.values) {
      if (opcode.code == code) {
        return opcode;
      }
    }
    return null;
  }
}

class AidexCryptoMaterial {
  const AidexCryptoMaterial({required this.secret, required this.iv});

  final Uint8List secret;
  final Uint8List iv;
}

class AidexVendorPairResult {
  const AidexVendorPairResult({
    required this.sessionKey,
    required this.rawDecrypted,
  });

  final Uint8List sessionKey;
  final Uint8List rawDecrypted;
}

class AidexVendorResponse {
  const AidexVendorResponse({
    required this.opcode,
    required this.payload,
    required this.plaintext,
  });

  final int opcode;
  final Uint8List payload;
  final Uint8List plaintext;
}

class AidexCgmStatus {
  const AidexCgmStatus({
    required this.timeOffsetMinutes,
    required this.sessionFlags,
    required this.calibrationTemperatureState,
    required this.warningFlags,
    required this.crc16,
    required this.crcValid,
  });

  final int timeOffsetMinutes;
  final int sessionFlags;
  final int calibrationTemperatureState;
  final int warningFlags;
  final int crc16;
  final bool crcValid;

  bool get sessionStopped => (sessionFlags & 0x01) != 0;
}

class AidexSessionStartInfo {
  const AidexSessionStartInfo({
    required this.payload,
    required this.absoluteStart,
    required this.isAllZero,
    required this.crcValid,
    this.crc16,
  });

  final Uint8List payload;
  final DateTime? absoluteStart;
  final bool isAllZero;
  final bool crcValid;
  final int? crc16;
}

class AidexVendorRangeResponse {
  const AidexVendorRangeResponse({
    required this.status,
    required this.lowIndex,
    required this.highIndex,
    required this.count,
  });

  final int status;
  final int lowIndex;
  final int highIndex;
  final int count;
}

class AidexVendorBroadcastData {
  const AidexVendorBroadcastData({
    required this.payloadHex,
    this.status,
    this.timeOffsetMinutes,
    this.reservedWord,
    this.trendByte,
    this.currentGlucoseRawByte,
    this.currentQualifier,
    this.tailHex = '',
  });

  final String payloadHex;
  final int? status;
  final int? timeOffsetMinutes;
  final int? reservedWord;
  final int? trendByte;
  final int? currentGlucoseRawByte;
  final int? currentQualifier;
  final String tailHex;

  double? get currentGlucoseMgdl {
    final raw = currentGlucoseRawByte;
    return raw?.toDouble();
  }

  bool get isUsableGlucose {
    final raw = currentGlucoseRawByte;
    final qualifier = currentQualifier;
    if (raw == null || qualifier == null) {
      return false;
    }
    return (qualifier == 0x80 || qualifier == 0x84) && raw >= 30 && raw <= 250;
  }
}

class AidexVendorStartTimeResponse {
  const AidexVendorStartTimeResponse({
    required this.status,
    required this.startTime,
  });

  final int status;
  final DateTime? startTime;
}

class AidexVendorHistoryRecordPair {
  const AidexVendorHistoryRecordPair({
    required this.glucoseByte,
    required this.qualifierByte,
  });

  final int glucoseByte;
  final int qualifierByte;
}

class AidexVendorHistoryPage {
  const AidexVendorHistoryPage({
    required this.status,
    required this.indexEcho,
    required this.rawPairs,
    required this.records,
  });

  final int status;
  final int indexEcho;
  final List<AidexVendorHistoryRecordPair> rawPairs;
  final List<CgmReading> records;
}

class AidexVendorHistorySyncPlan {
  const AidexVendorHistorySyncPlan({
    required this.startIndex,
    required this.targetIndex,
    required this.totalAvailable,
    required this.shouldResetCache,
  });

  final int startIndex;
  final int targetIndex;
  final int totalAvailable;
  final bool shouldResetCache;

  bool get isAlreadyCurrent => startIndex > targetIndex;
}

class AidexCommunicationIntervalState {
  const AidexCommunicationIntervalState({
    this.current,
    this.normalized,
    this.responseHex = '',
  });

  final int? current;
  final int? normalized;
  final String responseHex;
}

String hexOf(Iterable<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List bytesFromHex(String hex) {
  final cleaned = hex.replaceAll(' ', '');
  final out = <int>[];
  for (var index = 0; index < cleaned.length; index += 2) {
    final next = math.min(cleaned.length, index + 2);
    out.add(int.parse(cleaned.substring(index, next), radix: 16));
  }
  return Uint8List.fromList(out);
}

String extractAidexSerial(String name) {
  final normalized = name.trim();
  final dash = normalized.lastIndexOf('-');
  if (dash < 0 || dash == normalized.length - 1) {
    return '';
  }
  return normalized.substring(dash + 1).trim().toUpperCase();
}

double decodeSfloat(int raw) {
  var exponent = (raw >> 12) & 0x0F;
  if (exponent >= 8) {
    exponent -= 16;
  }
  var mantissa = raw & 0x0FFF;
  if (mantissa >= 0x800) {
    mantissa -= 0x1000;
  }
  if (mantissa == 0x07FF) {
    return double.nan;
  }
  return mantissa * math.pow(10, exponent).toDouble();
}

CgmAdvertisement parseAidexManufacturerData(List<int> manufacturerData) {
  if (manufacturerData.length < 15) {
    return CgmAdvertisement(payloadHex: hexOf(manufacturerData));
  }
  final triplet = <int>[
    _be16(manufacturerData, 6),
    _be16(manufacturerData, 9),
    _be16(manufacturerData, 12),
  ];
  final qualifiers = <int>[
    manufacturerData[8],
    manufacturerData[11],
    manufacturerData[14],
  ];
  return CgmAdvertisement(
    payloadHex: hexOf(manufacturerData),
    counter: _le16(manufacturerData, 2),
    phaseHex: hexOf(manufacturerData.sublist(4, 6)),
    glucoseTriplet: triplet,
    qualifiers: qualifiers,
    displayValueMgdl: _selectAidexAdvertisementDisplayValue(
      triplet,
      qualifiers,
    ),
  );
}

AidexCryptoMaterial deriveAidexCrypto(String serial) {
  final bytes = serial.toUpperCase().runes.map(_serialRuneToByte).toList();
  final secretSeed = Uint8List.fromList(
    bytes.map((byte) => (13 * byte + 0x3D) & 0xFF).toList(growable: false),
  );
  final ivSeed = Uint8List.fromList(
    bytes.map((byte) => (17 * byte + 0x13) & 0xFF).toList(growable: false),
  );
  return AidexCryptoMaterial(
    secret: Uint8List.fromList(crypto.md5.convert(secretSeed).bytes),
    iv: Uint8List.fromList(crypto.md5.convert(ivSeed).bytes),
  );
}

int crc16CcittFalse(Iterable<int> bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= (byte & 0xFF) << 8;
    for (var bit = 0; bit < 8; bit++) {
      if ((crc & 0x8000) != 0) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc & 0xFFFF;
}

int vendorCrc8(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc = _crc8Table[(crc ^ byte) & 0xFF];
  }
  return crc;
}

Uint8List aesCfb128Encrypt(Uint8List plaintext, Uint8List key, Uint8List iv) {
  return _aesCfb128Transform(input: plaintext, key: key, iv: iv, encrypt: true);
}

Uint8List aesCfb128Decrypt(Uint8List ciphertext, Uint8List key, Uint8List iv) {
  return _aesCfb128Transform(
    input: ciphertext,
    key: key,
    iv: iv,
    encrypt: false,
  );
}

AidexVendorPairResult? processVendorPairResponse(
  Uint8List pairResponse,
  Uint8List rawNotification,
  Uint8List serialIv,
) {
  if (pairResponse.length != 17 ||
      rawNotification.length != 16 ||
      serialIv.length != 16) {
    return null;
  }
  final decrypted = aesCfb128Decrypt(pairResponse, rawNotification, serialIv);
  final expected = decrypted[16];
  final computed = vendorCrc8(decrypted.sublist(0, 16));
  if (expected != computed) {
    return null;
  }
  return AidexVendorPairResult(
    sessionKey: Uint8List.fromList(decrypted.sublist(0, 16)),
    rawDecrypted: decrypted,
  );
}

Uint8List buildVendorCommand(
  AidexVendorOpcode opcode,
  Uint8List sessionKey,
  Uint8List sessionIv, {
  List<int> payload = const <int>[],
}) {
  final plaintext = BytesBuilder(copy: false)
    ..addByte(opcode.code)
    ..add(payload);
  final plaintextBytes = plaintext.toBytes();
  final crc = crc16CcittFalse(plaintextBytes);
  final command = BytesBuilder(copy: false)
    ..add(plaintextBytes)
    ..add(<int>[crc & 0xFF, (crc >> 8) & 0xFF]);
  return aesCfb128Encrypt(command.toBytes(), sessionKey, sessionIv);
}

AidexVendorResponse? decryptVendorResponse(
  Uint8List ciphertext,
  Uint8List sessionKey,
  Uint8List sessionIv,
) {
  if (ciphertext.length < 3) {
    return null;
  }
  final plaintext = aesCfb128Decrypt(ciphertext, sessionKey, sessionIv);
  final receivedCrc = _le16(plaintext, plaintext.length - 2);
  final computedCrc = crc16CcittFalse(
    plaintext.sublist(0, plaintext.length - 2),
  );
  if (receivedCrc != computedCrc) {
    return null;
  }
  return AidexVendorResponse(
    opcode: plaintext.first,
    payload: Uint8List.fromList(plaintext.sublist(1, plaintext.length - 2)),
    plaintext: plaintext,
  );
}

AidexCgmStatus? parseCgmStatus(List<int> bytes) {
  if (bytes.length < 7) {
    return null;
  }
  final payload = bytes.sublist(0, 5);
  final receivedCrc = _le16(bytes, 5);
  return AidexCgmStatus(
    timeOffsetMinutes: _le16(bytes, 0),
    sessionFlags: bytes[2],
    calibrationTemperatureState: bytes[3],
    warningFlags: bytes[4],
    crc16: receivedCrc,
    crcValid: receivedCrc == crc16CcittFalse(payload),
  );
}

AidexSessionStartInfo? parseSessionStart(List<int> bytes) {
  if (bytes.length < 9) {
    return null;
  }
  final payload = Uint8List.fromList(bytes.sublist(0, 9));
  final isAllZero = payload.every((byte) => byte == 0);
  final crc16 = bytes.length >= 11 ? _le16(bytes, 9) : null;
  final crcValid = crc16 == null ? false : crc16 == crc16CcittFalse(payload);
  return AidexSessionStartInfo(
    payload: payload,
    absoluteStart: isAllZero ? null : parseAidexDateTime(payload),
    isAllZero: isAllZero,
    crc16: crc16,
    crcValid: crcValid,
  );
}

String parseFirmwareRevision(List<int> bytes) {
  final raw = bytes.takeWhile((byte) => byte != 0).toList(growable: false);
  return utf8.decode(raw, allowMalformed: true).trim();
}

DateTime? parseAidexDateTime(List<int> payload) {
  if (payload.length < 9) {
    return null;
  }
  final year = _le16(payload, 0);
  final month = payload[2];
  final day = payload[3];
  final hour = payload[4];
  final minute = payload[5];
  final second = payload[6];
  final timezoneQuarterHours = payload[7] >= 0x80
      ? payload[7] - 0x100
      : payload[7];
  final dstQuarterHours = switch (payload[8]) {
    0x02 => 2,
    0x04 => 4,
    0x08 => 8,
    _ => 0,
  };
  final offsetMinutes = (timezoneQuarterHours + dstQuarterHours) * 15;
  final local = DateTime.utc(year, month, day, hour, minute, second);
  return local.subtract(Duration(minutes: offsetMinutes));
}

Uint8List buildAidexDateTimeBody(DateTime now, {Duration? timeZoneOffset}) {
  final offset = timeZoneOffset ?? now.timeZoneOffset;
  final local = now.toUtc().add(offset);
  final quarterHours = (offset.inMinutes / 15).round();
  return Uint8List.fromList(<int>[
    local.year & 0xFF,
    (local.year >> 8) & 0xFF,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
    quarterHours & 0xFF,
    0x00,
  ]);
}

Uint8List buildAidexSessionStartPayload(
  DateTime now, {
  Duration? timeZoneOffset,
}) {
  final body = buildAidexDateTimeBody(now, timeZoneOffset: timeZoneOffset);
  final crc = crc16CcittFalse(body);
  return Uint8List.fromList(<int>[...body, crc & 0xFF, (crc >> 8) & 0xFF]);
}

Uint8List buildSpecificOpsRequest(
  int opcode, {
  List<int> payload = const <int>[],
}) {
  final body = <int>[opcode, ...payload];
  final crc = crc16CcittFalse(body);
  return Uint8List.fromList(<int>[...body, crc & 0xFF, (crc >> 8) & 0xFF]);
}

Uint8List buildRacpReportStoredCountRequest() =>
    Uint8List.fromList(<int>[0x04, 0x01]);

Uint8List buildRacpReportAllRequest() => Uint8List.fromList(<int>[0x01, 0x01]);

Uint8List buildRacpAbortRequest() => Uint8List.fromList(<int>[0x03]);

AidexVendorRangeResponse? parseVendorRangePayload(List<int> payload) {
  if (payload.length >= 7) {
    return AidexVendorRangeResponse(
      status: payload[0],
      lowIndex: _le16(payload, 1),
      highIndex: _le16(payload, 3),
      count: _le16(payload, 5),
    );
  }
  if (payload.length < 5) {
    return null;
  }
  final lowIndex = _le16(payload, 1);
  final count = _le16(payload, 3);
  return AidexVendorRangeResponse(
    status: payload[0],
    lowIndex: lowIndex,
    highIndex: count <= 0 ? lowIndex : lowIndex + count - 1,
    count: count,
  );
}

AidexVendorBroadcastData parseVendorBroadcastData(List<int> payload) {
  return AidexVendorBroadcastData(
    payloadHex: hexOf(payload),
    status: payload.isEmpty ? null : payload.first,
    timeOffsetMinutes: payload.length >= 3 ? _le16(payload, 1) : null,
    reservedWord: payload.length >= 5 ? _le16(payload, 3) : null,
    trendByte: payload.length >= 6 ? payload[5] : null,
    currentGlucoseRawByte: payload.length >= 7 ? payload[6] : null,
    currentQualifier: payload.length >= 8 ? payload[7] : null,
    tailHex: payload.length > 8 ? hexOf(payload.sublist(8)) : '',
  );
}

AidexVendorStartTimeResponse? parseVendorStartTimeResponse(List<int> payload) {
  if (payload.length < 10) {
    return null;
  }
  return AidexVendorStartTimeResponse(
    status: payload[0],
    startTime: parseAidexDateTime(payload.sublist(1, 10)),
  );
}

AidexVendorHistorySyncPlan planVendorHistorySync({
  required AidexVendorRangeResponse range,
  required int storedCount,
  int? latestStoredOffset,
  int? requestedStartOffset,
}) {
  final totalAvailable = range.count;
  final shouldResetCache = storedCount > totalAvailable + 5;
  final effectiveStoredCount = shouldResetCache ? 0 : storedCount;
  final latestAvailableIndex = range.lowIndex + math.max(0, totalAvailable - 1);
  final baseStart = switch ((
    requestedStartOffset,
    effectiveStoredCount > 0,
    latestStoredOffset,
  )) {
    (final int requested?, _, _) => requested,
    (_, true, final int latest?) => latest + 1,
    _ => range.lowIndex,
  };
  final startIndex = math.max(range.lowIndex, baseStart).toInt();
  final targetIndex = math.max(startIndex - 1, latestAvailableIndex).toInt();
  return AidexVendorHistorySyncPlan(
    startIndex: startIndex,
    targetIndex: targetIndex,
    totalAvailable: totalAvailable,
    shouldResetCache: shouldResetCache,
  );
}

List<CgmReading> parseStandardMeasurementNotification(List<int> data) {
  final records = <CgmReading>[];
  var offset = 0;

  while (offset + 5 < data.length) {
    final size = data[offset];
    if (size < 6 || size > 20 || offset + size > data.length) {
      break;
    }

    final rawGlucose = _le16(data, offset + 2);
    final minute = _le16(data, offset + 4);
    final glucose = decodeSfloat(rawGlucose);
    final qualifier = size > 6 ? data[offset + 6] : null;

    if (glucose.isFinite && glucose > 0) {
      records.add(
        CgmReading(
          valueMgdl: glucose,
          source: CgmRecordSource.standard,
          sensorMinute: minute,
          rawValue: rawGlucose,
          qualifier: qualifier,
        ),
      );
    }

    offset += size;
  }

  return records;
}

AidexVendorHistoryPage? parseVendorHistoryPagePayload(
  List<int> payload, {
  required CgmRecordSource source,
}) {
  if (payload.length < 3) {
    return null;
  }
  final status = payload[0];
  final indexEcho = _le16(payload, 1);
  if (status != 0x01) {
    return AidexVendorHistoryPage(
      status: status,
      indexEcho: indexEcho,
      rawPairs: const <AidexVendorHistoryRecordPair>[],
      records: const <CgmReading>[],
    );
  }
  final recordBytes = payload.sublist(3);
  final rawPairs = <AidexVendorHistoryRecordPair>[];
  final records = <CgmReading>[];
  for (var pairIndex = 0; pairIndex + 1 < recordBytes.length; pairIndex += 2) {
    final glucoseByte = recordBytes[pairIndex];
    final qualifierByte = recordBytes[pairIndex + 1];
    rawPairs.add(
      AidexVendorHistoryRecordPair(
        glucoseByte: glucoseByte,
        qualifierByte: qualifierByte,
      ),
    );
    if (!_isUsableAidexVendorHistoryValue(qualifierByte, glucoseByte)) {
      continue;
    }
    records.add(
      CgmReading(
        valueMgdl: glucoseByte.toDouble(),
        source: source,
        sensorMinute: indexEcho + (pairIndex ~/ 2),
        rawValue: glucoseByte,
        qualifier: qualifierByte,
        isDisplayProvisional: source == CgmRecordSource.vendor,
      ),
    );
  }
  return AidexVendorHistoryPage(
    status: status,
    indexEcho: indexEcho,
    rawPairs: rawPairs,
    records: records,
  );
}

double? _selectAidexAdvertisementDisplayValue(
  List<int> triplet,
  List<int> qualifiers,
) {
  final sampleCount = math.min(triplet.length, qualifiers.length);
  for (var index = 0; index < sampleCount; index++) {
    final decoded = decodeSfloat(triplet[index]);
    if (_isUsableAidexAdvertisementValue(qualifiers[index], decoded)) {
      return decoded;
    }
  }
  return null;
}

bool _isUsableAidexAdvertisementValue(int qualifier, double valueMgdl) {
  if (!valueMgdl.isFinite) {
    return false;
  }
  final qualifierLooksUsable =
      qualifier == 0x88 || qualifier == 0x84 || qualifier == 0x80;
  return qualifierLooksUsable && valueMgdl >= 30 && valueMgdl <= 400;
}

bool _isUsableAidexVendorHistoryValue(int qualifier, int glucoseByte) {
  return (qualifier == 0x80 || qualifier == 0x84) &&
      glucoseByte >= 30 &&
      glucoseByte <= 250;
}

int? parseSpecificOpsCommunicationIntervalGet(List<int> payload) {
  if (payload.length < 4 || payload[0] != 0x03) {
    return null;
  }
  return payload[1];
}

AidexCommunicationIntervalState parseSpecificOpsCommunicationIntervalSet(
  List<int> payload,
) {
  return AidexCommunicationIntervalState(
    current: payload.length >= 4 ? payload[3] : null,
    normalized: payload.length >= 4 ? payload[3] : null,
    responseHex: hexOf(payload),
  );
}

Uint8List littleEndian16(int value) {
  final clamped = value.clamp(0, 0xFFFF);
  return Uint8List.fromList(<int>[clamped & 0xFF, (clamped >> 8) & 0xFF]);
}

int _serialRuneToByte(int rune) {
  if (rune >= 0x30 && rune <= 0x39) {
    return rune - 0x30;
  }
  if (rune >= 0x41 && rune <= 0x5A) {
    return rune - 0x41 + 10;
  }
  if (rune >= 0x61 && rune <= 0x7A) {
    return rune - 0x61 + 10;
  }
  throw ArgumentError.value(rune, 'rune', 'Unsupported serial character');
}

int _le16(List<int> bytes, int offset) {
  return (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8);
}

int _be16(List<int> bytes, int offset) {
  return ((bytes[offset] & 0xFF) << 8) | (bytes[offset + 1] & 0xFF);
}

Uint8List _aesCfb128Transform({
  required Uint8List input,
  required Uint8List key,
  required Uint8List iv,
  required bool encrypt,
}) {
  if (key.length != 16 || iv.length != 16) {
    throw ArgumentError('Aidex AES-CFB requires 16-byte key and IV.');
  }
  final result = Uint8List(input.length);
  var feedback = Uint8List.fromList(iv);
  var offset = 0;

  while (offset < input.length) {
    final encryptedFeedback = _aes128EncryptBlock(feedback, key);
    final chunkLength = math.min(16, input.length - offset);
    for (var index = 0; index < chunkLength; index++) {
      result[offset + index] = input[offset + index] ^ encryptedFeedback[index];
    }
    if (chunkLength == 16) {
      feedback = encrypt
          ? Uint8List.fromList(result.sublist(offset, offset + chunkLength))
          : Uint8List.fromList(input.sublist(offset, offset + chunkLength));
    } else {
      final padded = Uint8List(16);
      for (var index = 0; index < chunkLength; index++) {
        padded[index] = encrypt
            ? result[offset + index]
            : input[offset + index];
      }
      for (var index = chunkLength; index < 16; index++) {
        padded[index] = feedback[index - chunkLength];
      }
      feedback = padded;
    }
    offset += chunkLength;
  }

  return result;
}

Uint8List _aes128EncryptBlock(Uint8List block, Uint8List key) {
  final engine = AESEngine()..init(true, KeyParameter(key));
  final out = Uint8List(16);
  engine.processBlock(block, 0, out, 0);
  return out;
}

const List<int> _crc8Table = <int>[
  0x00,
  0x5e,
  0xbc,
  0xe2,
  0x61,
  0x3f,
  0xdd,
  0x83,
  0xc2,
  0x9c,
  0x7e,
  0x20,
  0xa3,
  0xfd,
  0x1f,
  0x41,
  0x9d,
  0xc3,
  0x21,
  0x7f,
  0xfc,
  0xa2,
  0x40,
  0x1e,
  0x5f,
  0x01,
  0xe3,
  0xbd,
  0x3e,
  0x60,
  0x82,
  0xdc,
  0x23,
  0x7d,
  0x9f,
  0xc1,
  0x42,
  0x1c,
  0xfe,
  0xa0,
  0xe1,
  0xbf,
  0x5d,
  0x03,
  0x80,
  0xde,
  0x3c,
  0x62,
  0xbe,
  0xe0,
  0x02,
  0x5c,
  0xdf,
  0x81,
  0x63,
  0x3d,
  0x7c,
  0x22,
  0xc0,
  0x9e,
  0x1d,
  0x43,
  0xa1,
  0xff,
  0x46,
  0x18,
  0xfa,
  0xa4,
  0x27,
  0x79,
  0x9b,
  0xc5,
  0x84,
  0xda,
  0x38,
  0x66,
  0xe5,
  0xbb,
  0x59,
  0x07,
  0xdb,
  0x85,
  0x67,
  0x39,
  0xba,
  0xe4,
  0x06,
  0x58,
  0x19,
  0x47,
  0xa5,
  0xfb,
  0x78,
  0x26,
  0xc4,
  0x9a,
  0x65,
  0x3b,
  0xd9,
  0x87,
  0x04,
  0x5a,
  0xb8,
  0xe6,
  0xa7,
  0xf9,
  0x1b,
  0x45,
  0xc6,
  0x98,
  0x7a,
  0x24,
  0xf8,
  0xa6,
  0x44,
  0x1a,
  0x99,
  0xc7,
  0x25,
  0x7b,
  0x3a,
  0x64,
  0x86,
  0xd8,
  0x5b,
  0x05,
  0xe7,
  0xb9,
  0x8c,
  0xd2,
  0x30,
  0x6e,
  0xed,
  0xb3,
  0x51,
  0x0f,
  0x4e,
  0x10,
  0xf2,
  0xac,
  0x2f,
  0x71,
  0x93,
  0xcd,
  0x11,
  0x4f,
  0xad,
  0xf3,
  0x70,
  0x2e,
  0xcc,
  0x92,
  0xd3,
  0x8d,
  0x6f,
  0x31,
  0xb2,
  0xec,
  0x0e,
  0x50,
  0xaf,
  0xf1,
  0x13,
  0x4d,
  0xce,
  0x90,
  0x72,
  0x2c,
  0x6d,
  0x33,
  0xd1,
  0x8f,
  0x0c,
  0x52,
  0xb0,
  0xee,
  0x32,
  0x6c,
  0x8e,
  0xd0,
  0x53,
  0x0d,
  0xef,
  0xb1,
  0xf0,
  0xae,
  0x4c,
  0x12,
  0x91,
  0xcf,
  0x2d,
  0x73,
  0xca,
  0x94,
  0x76,
  0x28,
  0xab,
  0xf5,
  0x17,
  0x49,
  0x08,
  0x56,
  0xb4,
  0xea,
  0x69,
  0x37,
  0xd5,
  0x8b,
  0x57,
  0x09,
  0xeb,
  0xb5,
  0x36,
  0x68,
  0x8a,
  0xd4,
  0x95,
  0xcb,
  0x29,
  0x77,
  0xf4,
  0xaa,
  0x48,
  0x16,
  0xe9,
  0xb7,
  0x55,
  0x0b,
  0x88,
  0xd6,
  0x34,
  0x6a,
  0x2b,
  0x75,
  0x97,
  0xc9,
  0x4a,
  0x14,
  0xf6,
  0xa8,
  0x74,
  0x2a,
  0xc8,
  0x96,
  0x15,
  0x4b,
  0xa9,
  0xf7,
  0xb6,
  0xe8,
  0x0a,
  0x54,
  0xd7,
  0x89,
  0x6b,
  0x35,
];
