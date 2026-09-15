// SPDX-License-Identifier: MIT
// This adapter links a separately GPL-licensed decoder. See ADR 0004.
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_libre2_glucose/cgm_libre2_glucose.dart';
import 'package:flutter/foundation.dart';

import 'libre_gen1_secure_store.dart';
import 'libre_gen1_fresh_nfc_history.dart';
import 'libre_nfc_history.dart';

typedef LibreCalibrationReader =
    Future<LibreGen1CalibrationEvidence?> Function(
      LibreGen1StreamingBootstrap bootstrap,
    );

/// Imported only by the explicit full-UI bench entry point, never normal main.
final class PrivateLibreGlucoseDecoderProvider
    implements LibreGen1GlucoseDecoderProvider, LibreGen1NfcHistoryDecoder {
  PrivateLibreGlucoseDecoderProvider({LibreCalibrationReader? readEvidence})
    : _readEvidence =
          readEvidence ?? LibreGen1SecureStore().readCalibrationEvidence;

  final LibreCalibrationReader _readEvidence;

  @override
  LibreGen1DecodedNfcHistory decodeFreshNfc(
    LibreGen1FreshNfcEvidence evidence,
  ) {
    try {
      final scan = decodeLibre2Gen1EncryptedNfcFram(
        uid: evidence.uid,
        currentPatchInfo: evidence.currentPatchInfo,
        encryptedFram: evidence.encryptedFram,
      );
      final samples = <LibreNfcHistorySample>[];
      final minutes = <int>{};
      // Prefer the newest trend slot when both rings contain the same minute.
      // No cached BLE coefficients or native calibration read is involved.
      for (final sample in [...scan.trend, ...scan.history]) {
        final glucose = sample.glucoseMgDl;
        if (sample.rejection != null ||
            glucose == null ||
            !minutes.add(sample.sensorMinute)) {
          continue;
        }
        samples.add(
          LibreNfcHistorySample(
            reading: CgmReading(
              valueMgdl: glucose.toDouble(),
              source: CgmRecordSource.vendor,
              sensorMinute: sample.sensorMinute,
              recordedAt: evidence.observedAtUtc.subtract(
                Duration(minutes: scan.sensorAgeMinutes - sample.sensorMinute),
              ),
              isDisplayProvisional: true,
            ),
            firstReceivedAt: evidence.observedAtUtc,
            origin: sample.isHistory
                ? LibreHistoryOrigin.nfcHistory
                : LibreHistoryOrigin.nfcTrend,
          ),
        );
      }
      return LibreGen1DecodedNfcHistory(
        scanMinute: scan.sensorAgeMinutes,
        receivedAt: evidence.observedAtUtc,
        samples: samples,
      );
    } catch (_) {
      throw const LibreGen1FreshNfcHistoryException(
        LibreGen1FreshNfcFailure.invalidDecodedHistory,
      );
    }
  }

  @override
  Future<LibreGen1GlucoseDecoder?> prepare(
    LibreGen1StreamingBootstrap bootstrap,
  ) async {
    try {
      final evidence = await _readEvidence(
        bootstrap,
      ).timeout(const Duration(seconds: 15));
      if (evidence == null) return null;
      if (evidence.bootstrapId != bootstrap.bootstrapId ||
          !listEquals(evidence.uid, bootstrap.uid.value.bytes) ||
          !listEquals(
            evidence.receiverInitialPatchInfo,
            bootstrap.initialPatchInfo.value.bytes,
          )) {
        return null;
      }
      // Native and Dart store validate identity; the pure decoder independently
      // validates model, FRAM shape, all CRCs, lifetime and factory fields.
      return _BoundDecoder(
        Libre2Gen1GlucoseDecoder.fromEncryptedFram(
          uid: evidence.uid,
          // The decoder parameter is historical naming: FRAM needs its own
          // NFC patch seed, not the frozen Bluetooth login credential.
          initialPatchInfo: evidence.calibrationPatchInfo,
          encryptedFram: evidence.encryptedFram,
        ),
      );
    } catch (_) {
      // Missing calibration must not interrupt a healthy Bluetooth stream.
      // Never publish raw coefficients, bytes or exception text.
      return null;
    }
  }
}

final class _BoundDecoder implements LibreGen1GlucoseDecoder {
  const _BoundDecoder(this._decoder);
  final Libre2Gen1GlucoseDecoder _decoder;

  @override
  LibreGen1GlucoseResult decode({
    required List<int> encryptedPacket,
    required DateTime receivedAt,
  }) {
    final packet = _decoder.decodeEncryptedBle(encryptedPacket);
    final sample = packet.current;
    return LibreGen1GlucoseResult(
      sensorAgeMinutes: packet.sensorAgeMinutes,
      sampleAgeMinutes: sample.sensorMinute,
      glucoseMgdl: sample.glucoseMgDl?.toDouble(),
      expectedLifetimeMinutes: _decoder.maxLifeMinutes,
      rejection: _rejection(sample.rejection),
      // Keep every older slot, including rejected slots and overlap between
      // trend/history minutes. The receiving driver owns acceptance and
      // durable deduplication; none of these entries is the current sample.
      historySamples: List<LibreGen1GlucoseHistorySample>.unmodifiable([
        for (final older in packet.samples.skip(1))
          LibreGen1GlucoseHistorySample(
            sampleAgeMinutes: older.sensorMinute,
            kind: older.isHistory
                ? LibreGen1BleHistoryKind.history
                : LibreGen1BleHistoryKind.trend,
            glucoseMgdl: older.glucoseMgDl?.toDouble(),
            rejection: _rejection(older.rejection),
          ),
      ]),
    );
  }
}

LibreGen1GlucoseRejection? _rejection(
  Libre2Gen1GlucoseRejection? rejection,
) => switch (rejection) {
  null => null,
  Libre2Gen1GlucoseRejection.warmingUp => LibreGen1GlucoseRejection.warmingUp,
  Libre2Gen1GlucoseRejection.sensorError =>
    LibreGen1GlucoseRejection.noCurrentSample,
  _ => LibreGen1GlucoseRejection.invalidData,
};
