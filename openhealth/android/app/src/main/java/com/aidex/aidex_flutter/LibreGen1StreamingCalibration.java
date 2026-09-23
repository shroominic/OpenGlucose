package com.aidex.aidex_flutter;

import java.util.Arrays;

/** Single-use, private evidence from the existing streaming transaction's FRAM read. */
final class LibreGen1StreamingCalibration implements AutoCloseable {
  private final String bootstrapId;
  private final byte[] uid;
  private final byte[] receiverPatch;
  private final byte[] currentPatch;
  private final byte[] fram;
  private final int lifecycle;
  private boolean closed;

  private LibreGen1StreamingCalibration(LibreGen1StreamingJournal.Record prepared,
      byte[] patch, byte[] encryptedFram) {
    if (prepared == null || !"prepared".equals(prepared.state)
        || !LibreGen1CalibrationEvidence.matchesReceiverPatch(prepared.initialPatchInfo, patch)) {
      throw new IllegalArgumentException("Streaming calibration is unavailable.");
    }
    final int validated = LibreGen1Activation.validatedLifecycle(prepared.uid, patch, encryptedFram);
    LibreGen1Streaming.requireLifecycle(validated);
    bootstrapId = prepared.bootstrapId;
    uid = prepared.uid.clone();
    receiverPatch = prepared.initialPatchInfo.clone();
    currentPatch = patch.clone();
    fram = encryptedFram.clone();
    lifecycle = validated;
  }

  static LibreGen1StreamingCalibration fromRead(LibreGen1StreamingJournal.Record prepared,
      byte[] currentPatch, byte[] encryptedFram) {
    return new LibreGen1StreamingCalibration(prepared, currentPatch, encryptedFram);
  }

  synchronized int lifecycle() {
    if (closed) throw new IllegalStateException("Streaming calibration is unavailable.");
    return lifecycle;
  }

  /** The native caller must hold its epoch/RF guard and prove close, audit, and lease release. */
  synchronized LibreGen1CalibrationPersistence.Result preserveAfterConfirmation(
      LibreGen1StreamingJournal.Record confirmed, boolean completionVerified,
      LibreGen1CalibrationPersistence.VerifiedWriter writer) {
    if (closed) return LibreGen1CalibrationPersistence.Result.INVALID_EVIDENCE;
    try {
      if (!completionVerified) return LibreGen1CalibrationPersistence.Result.CAPTURE_UNAVAILABLE;
      if (confirmed == null || !bootstrapId.equals(confirmed.bootstrapId)
          || !Arrays.equals(uid, confirmed.uid)
          || !Arrays.equals(receiverPatch, confirmed.initialPatchInfo)) {
        return LibreGen1CalibrationPersistence.Result.RECEIVER_MISMATCH;
      }
      return LibreGen1CalibrationPersistence.preserve(confirmed, uid, currentPatch, fram, writer);
    } finally { close(); }
  }

  @Override public synchronized void close() {
    closed = true;
    Arrays.fill(uid, (byte) 0);
    Arrays.fill(receiverPatch, (byte) 0);
    Arrays.fill(currentPatch, (byte) 0);
    Arrays.fill(fram, (byte) 0);
  }

  @Override public String toString() { return "LibreStreamingCalibration(<redacted>)"; }
}
