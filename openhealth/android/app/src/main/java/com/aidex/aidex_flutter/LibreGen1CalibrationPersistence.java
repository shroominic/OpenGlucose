package com.aidex.aidex_flutter;

import java.util.Arrays;

/** Closed save diagnostics only. These outcomes do not change the NFC read result. */
final class LibreGen1CalibrationPersistence {
  enum Result {
    SAVED("saved", "verifiedReadback"),
    CAPTURE_UNAVAILABLE("skipped", "captureUnavailable"),
    RECEIVER_UNAVAILABLE("skipped", "receiverUnavailable"),
    RECEIVER_MISMATCH("skipped", "receiverMismatch"),
    RECEIVER_READ_FAILED("failed", "receiverReadFailed"),
    INVALID_EVIDENCE("failed", "invalidEvidence"),
    STORAGE_FAILED("failed", "storageFailed");

    final String outcome;
    final String reason;
    Result(String outcome, String reason) { this.outcome = outcome; this.reason = reason; }
  }

  interface VerifiedWriter {
    /** Returns only after durable write and exact decrypted readback verification. */
    void writeVerified(LibreGen1CalibrationEvidence evidence) throws Exception;
  }

  private LibreGen1CalibrationPersistence() {}

  static Result preserve(LibreGen1StreamingJournal.Record receiver,
      byte[] uid, byte[] patch, byte[] fram, VerifiedWriter writer) {
    if (receiver == null || !"confirmed".equals(receiver.state)) return Result.RECEIVER_UNAVAILABLE;
    if (!Arrays.equals(uid, receiver.uid)
        || !LibreGen1CalibrationEvidence.matchesReceiverPatch(receiver.initialPatchInfo, patch)) {
      return Result.RECEIVER_MISMATCH;
    }
    final LibreGen1CalibrationEvidence evidence;
    try {
      evidence = LibreGen1CalibrationEvidence.verified(
          receiver.bootstrapId, uid, receiver.initialPatchInfo, patch, fram);
    } catch (RuntimeException invalid) {
      return Result.INVALID_EVIDENCE;
    }
    try (LibreGen1CalibrationEvidence owned = evidence) {
      writer.writeVerified(owned);
      return Result.SAVED;
    } catch (Exception unavailable) {
      // A write, fsync, rename or readback exception never reports saved.
      // Do not retain exception messages or causes in the diagnostic.
      return Result.STORAGE_FAILED;
    }
  }
}
