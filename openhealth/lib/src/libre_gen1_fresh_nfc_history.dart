import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'libre_nfc_history.dart';

typedef LibreGen1FreshNfcInvoker =
    Future<Object?> Function(String method, Map<String, Object?> arguments);

enum LibreGen1FreshNfcFailure {
  unavailable,
  invalidEvidence,
  invalidDecodedHistory,
  timedOut,
  revoked,
}

final class LibreGen1FreshNfcHistoryException implements Exception {
  const LibreGen1FreshNfcHistoryException(this.kind);
  final LibreGen1FreshNfcFailure kind;

  @override
  String toString() => 'LibreGen1FreshNfcHistoryException(${kind.name})';
}

/// Restricted bytes available only during the synchronous decoder call.
///
/// Constructed only after exact native-attempt and receiver validation. The
/// reader clears its owned buffers in finally; this is best-effort lifetime
/// control, not a claim that all platform/decoder copies can be zeroized.
final class LibreGen1FreshNfcEvidence {
  LibreGen1FreshNfcEvidence._({
    required this.observedAtUtc,
    required Uint8List uid,
    required Uint8List receiverInitialPatchInfo,
    required Uint8List currentPatchInfo,
    required Uint8List encryptedFram,
  }) : _uid = uid,
       _receiverInitialPatchInfo = receiverInitialPatchInfo,
       _currentPatchInfo = currentPatchInfo,
       _encryptedFram = encryptedFram;

  final DateTime observedAtUtc;
  final Uint8List _uid;
  final Uint8List _receiverInitialPatchInfo;
  final Uint8List _currentPatchInfo;
  final Uint8List _encryptedFram;
  bool _cleared = false;

  List<int> get uid => _view(_uid);
  List<int> get receiverInitialPatchInfo => _view(_receiverInitialPatchInfo);
  List<int> get currentPatchInfo => _view(_currentPatchInfo);
  List<int> get encryptedFram => _view(_encryptedFram);

  List<int> _view(Uint8List bytes) {
    if (_cleared) {
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.revoked,
      );
    }
    return bytes.asUnmodifiableView();
  }

  void _clear() {
    _cleared = true;
    for (final bytes in [
      _uid,
      _receiverInitialPatchInfo,
      _currentPatchInfo,
      _encryptedFram,
    ]) {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  String toString() => 'LibreGen1FreshNfcEvidence(data: <redacted>)';
}

/// MIT composition contract; only the private entry supplies a GPL decoder.
// A named interface lets the private provider implement BLE and NFC contracts.
// ignore: one_member_abstracts
abstract interface class LibreGen1NfcHistoryDecoder {
  LibreGen1DecodedNfcHistory decodeFreshNfc(LibreGen1FreshNfcEvidence evidence);
}

final class LibreGen1DecodedNfcHistory {
  LibreGen1DecodedNfcHistory({
    required this.scanMinute,
    required this.receivedAt,
    required Iterable<LibreNfcHistorySample> samples,
  }) : samples = List.unmodifiable(samples);

  final int scanMinute;
  final DateTime receivedAt;
  final List<LibreNfcHistorySample> samples;

  @override
  String toString() => 'LibreGen1DecodedNfcHistory(data: <redacted>)';
}

/// Reads only fresh evidence retained for the current explicit native attempt.
/// It never starts NFC, grants RF ownership, or falls back to calibration/file
/// evidence. Native attempt/lease checks and the repository import ticket are
/// independent authorities; this reader does not replace either one.
final class LibreGen1FreshNfcHistoryReader {
  LibreGen1FreshNfcHistoryReader({
    MethodChannel channel = const MethodChannel(channelName),
    @visibleForTesting LibreGen1FreshNfcInvoker? invokeMethod,
    @visibleForTesting bool? supported,
  }) : _invokeMethod =
           invokeMethod ??
           ((method, arguments) =>
               channel.invokeMethod<Object?>(method, arguments)),
       _supported =
           supported ??
           (!kIsWeb &&
               kDebugMode &&
               defaultTargetPlatform == TargetPlatform.android);

  static const channelName = 'com.openglucose/protocol_capture';
  static const methodName = 'readLibreGen1FreshHistoryEvidence';
  static const _keys = {
    'attemptId',
    'bootstrapId',
    'uid',
    'receiverInitialPatchInfo',
    'currentPatchInfo',
    'encryptedFram',
    'observedAtUtc',
  };
  final LibreGen1FreshNfcInvoker _invokeMethod;
  final bool _supported;
  int _generation = 0;

  /// Cancels local delivery only. It does not imply native NFC/RF cleanup.
  void revoke() => _generation++;

  Future<LibreGen1DecodedNfcHistory> readDecoded({
    required LibreGen1StreamingBootstrap bootstrap,
    required String attemptId,
    required LibreGen1NfcHistoryDecoder decoder,
  }) async {
    if (!_supported) {
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.unavailable,
      );
    }
    if (!_safeToken(attemptId, 8) ||
        !_safeToken(bootstrap.bootstrapId, 16) ||
        !_allowed(
          bootstrap.uid.value.bytes,
          bootstrap.initialPatchInfo.value.bytes,
        )) {
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.invalidEvidence,
      );
    }
    // A replacement call invalidates the prior local delivery. Native still
    // decides whether this attempt owns a fresh, exact-target NFC artifact.
    final generation = ++_generation;
    LibreGen1FreshNfcEvidence? evidence;
    try {
      final value = await _invokeMethod(methodName, {
        'attemptId': attemptId,
        'bootstrapId': bootstrap.bootstrapId,
      }).timeout(const Duration(seconds: 15));
      if (generation != _generation) {
        throw const LibreGen1FreshNfcHistoryException(
          LibreGen1FreshNfcFailure.revoked,
        );
      }
      evidence = _parse(value, bootstrap, attemptId);
      final LibreGen1DecodedNfcHistory decoded;
      try {
        decoded = decoder.decodeFreshNfc(evidence);
        _validateDecoded(decoded, evidence.observedAtUtc);
      } catch (_) {
        throw const LibreGen1FreshNfcHistoryException(
          LibreGen1FreshNfcFailure.invalidDecodedHistory,
        );
      }
      if (generation != _generation) {
        throw const LibreGen1FreshNfcHistoryException(
          LibreGen1FreshNfcFailure.revoked,
        );
      }
      return decoded;
    } on LibreGen1FreshNfcHistoryException {
      rethrow;
    } on TimeoutException {
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.timedOut,
      );
    } catch (_) {
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.unavailable,
      );
    } finally {
      evidence?._clear();
    }
  }

  static LibreGen1FreshNfcEvidence _parse(
    Object? value,
    LibreGen1StreamingBootstrap bootstrap,
    String attemptId,
  ) {
    final owned = <Uint8List>[];
    Uint8List bytes(Object? value, int length) {
      if (value is! List ||
          value.length != length ||
          value.any((byte) => byte is! int || byte < 0 || byte > 255)) {
        throw const FormatException();
      }
      final copy = Uint8List.fromList(value.cast<int>());
      owned.add(copy);
      return copy;
    }

    try {
      if (value is! Map ||
          value.length != _keys.length ||
          !value.keys.every(_keys.contains) ||
          value['attemptId'] != attemptId ||
          value['bootstrapId'] != bootstrap.bootstrapId) {
        throw const FormatException();
      }
      final uid = bytes(value['uid'], 8);
      final receiverPatch = bytes(value['receiverInitialPatchInfo'], 6);
      final currentPatch = bytes(value['currentPatchInfo'], 6);
      final fram = bytes(value['encryptedFram'], 344);
      if (!listEquals(uid, bootstrap.uid.value.bytes) ||
          !listEquals(receiverPatch, bootstrap.initialPatchInfo.value.bytes) ||
          !listEquals(
            receiverPatch.sublist(0, 4),
            currentPatch.sublist(0, 4),
          ) ||
          !_allowed(uid, currentPatch)) {
        throw const FormatException();
      }
      return LibreGen1FreshNfcEvidence._(
        observedAtUtc: _utc(value['observedAtUtc']),
        uid: uid,
        receiverInitialPatchInfo: receiverPatch,
        currentPatchInfo: currentPatch,
        encryptedFram: fram,
      );
    } catch (_) {
      for (final bytes in owned) {
        bytes.fillRange(0, bytes.length, 0);
      }
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.invalidEvidence,
      );
    }
  }

  static bool _safeToken(String value, int minimum) =>
      value.length >= minimum &&
      value.length <= 120 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static bool _allowed(List<int> uid, List<int> patch) =>
      uid.length == 8 &&
      uid[6] == 7 &&
      uid[7] == 0xe0 &&
      patch.length == 6 &&
      LibreGen1PatchInfo(patch).model == LibreGen1Model.libre2;

  static DateTime _utc(Object? value) {
    if (value is! String ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$',
        ).hasMatch(value)) {
      throw const FormatException();
    }
    final parsed = DateTime.parse(value);
    // Reject DateTime.parse's permissive overflow normalization. Instant's
    // nanoseconds are truncated to Dart microseconds, never replaced with now.
    if (!parsed.isUtc ||
        parsed.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
      throw const FormatException();
    }
    return parsed;
  }

  static void _validateDecoded(
    LibreGen1DecodedNfcHistory decoded,
    DateTime observedAt,
  ) {
    if (decoded.scanMinute < 0 ||
        decoded.scanMinute > 0xffff ||
        !decoded.receivedAt.isUtc ||
        decoded.receivedAt != observedAt ||
        decoded.samples.length > 48) {
      throw const FormatException();
    }
    final seen = <int>{};
    var trendCount = 0;
    var historyCount = 0;
    for (final sample in decoded.samples) {
      final reading = sample.reading;
      final minute = reading.sensorMinute;
      if (minute == null ||
          minute < 60 ||
          minute > decoded.scanMinute ||
          !seen.add(minute) ||
          reading.source != CgmRecordSource.vendor ||
          !reading.isDisplayProvisional ||
          !reading.valueMgdl.isFinite ||
          reading.valueMgdl <= 0 ||
          reading.valueMgdl > 0x7fffffff ||
          reading.rawValue != null ||
          reading.qualifier != null ||
          !sample.firstReceivedAt.isUtc ||
          sample.firstReceivedAt != observedAt ||
          reading.recordedAt?.isUtc != true ||
          reading.recordedAt !=
              observedAt.subtract(
                Duration(minutes: decoded.scanMinute - minute),
              )) {
        throw const FormatException();
      }
      switch (sample.origin) {
        case LibreHistoryOrigin.nfcTrend:
          if (historyCount != 0 || minute < decoded.scanMinute - 15) {
            throw const FormatException();
          }
          trendCount++;
        case LibreHistoryOrigin.nfcHistory:
          final newestHistory = ((decoded.scanMinute - 3) ~/ 15) * 15;
          if (minute % 15 != 0 ||
              minute > newestHistory ||
              minute < newestHistory - 31 * 15) {
            throw const FormatException();
          }
          historyCount++;
        case LibreHistoryOrigin.legacyUnknown:
        case LibreHistoryOrigin.bleLive:
        case LibreHistoryOrigin.bleTrend:
        case LibreHistoryOrigin.bleHistory:
          throw const FormatException();
      }
    }
    if (trendCount > 16 || historyCount > 32) {
      throw const FormatException();
    }
  }

  @override
  String toString() => 'LibreGen1FreshNfcHistoryReader(data: <redacted>)';
}
