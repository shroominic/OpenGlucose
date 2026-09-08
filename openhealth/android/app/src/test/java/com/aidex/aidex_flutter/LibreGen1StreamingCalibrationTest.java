package com.aidex.aidex_flutter;

import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Arrays;

/** Synthetic evidence only. No files, platform APIs, sensor commands, or glucose arithmetic. */
public final class LibreGen1StreamingCalibrationTest {
  private static final byte[] UID = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 7, (byte) 0xe0};
  private static final byte[] PATCH = {(byte) 0x9d, 8, 0x30, 1, 0x34, 0x12};

  public static void main(String[] args) throws Exception {
    firstSetupPersistsAfterConfirmationAndSurvivesVolatileLoss();
    unknownOrUnreleasedCompletionCannotWrite();
    exactReceiverAndPatchRolesStayBound();
    everyTerminalPathIsSingleUseAndWiped();
    invalidReadsNeverProducePendingEvidence();
    System.out.println("Libre first-stream calibration synthetic checks passed.");
  }

  private static void firstSetupPersistsAfterConfirmationAndSurvivesVolatileLoss() throws Exception {
    for (int lifecycle : new int[] {2, 3}) {
      MemoryBackend backend = new MemoryBackend();
      LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
      byte[] fram = encrypted(lifecycle, PATCH);
      int[] writes = {0};
      check(LibreGen1CalibrationPersistence.preserve(null, UID, PATCH, fram, e -> writes[0]++)
          == LibreGen1CalibrationPersistence.Result.RECEIVER_UNAVAILABLE, "first read should have no receiver");
      LibreGen1StreamingJournal.Record prepared = journal.prepare(UID, PATCH, 42, lifecycle);
      LibreGen1StreamingCalibration pending = LibreGen1StreamingCalibration.fromRead(prepared, PATCH, fram);
      check(pending.lifecycle() == lifecycle, "wrong read lifecycle");
      Arrays.fill(fram, (byte) 0);
      journal.commitIntent(prepared.bootstrapId);
      journal.confirm(prepared.bootstrapId, new byte[] {0, 1, 0, 0, 0, 0, 2}, lifecycle, true);
      LibreGen1StreamingJournal.Record confirmed = journal.read();
      byte[][] saved = {null};
      check(pending.preserveAfterConfirmation(confirmed, true, evidence -> {
        writes[0]++;
        saved[0] = evidence.encode();
      }) == LibreGen1CalibrationPersistence.Result.SAVED, "first streaming cache missing");
      check(writes[0] == 1, "cache retried");
      LibreGen1StreamingJournal.Record restored = new LibreGen1StreamingJournal(backend).read();
      try (LibreGen1CalibrationEvidence cache = LibreGen1CalibrationEvidence.decode(
          saved[0], restored.bootstrapId, restored.uid, restored.initialPatchInfo)) {
        check(Arrays.equals(cache.encryptedFram(), encrypted(lifecycle, PATCH)), "volatile loss changed cache");
        check(Arrays.equals(cache.receiverInitialPatchInfo(), PATCH), "receiver patch changed");
      }
      check(restored.state.equals("confirmed") && restored.unlockCount == 0
          && restored.loginOutcome.equals("none"), "cache changed journal or counter");
      checkWiped(pending);
    }
  }

  private static void unknownOrUnreleasedCompletionCannotWrite() throws Exception {
    for (String state : new String[] {"prepared", "unknown", "confirmed"}) {
      for (boolean released : new boolean[] {false, true}) {
        if (state.equals("confirmed") && released) continue;
        LibreGen1StreamingJournal.Record prepared = prepared();
        LibreGen1StreamingCalibration pending = LibreGen1StreamingCalibration.fromRead(prepared, PATCH, encrypted(3, PATCH));
        int[] writes = {0};
        LibreGen1CalibrationPersistence.Result result = pending.preserveAfterConfirmation(
            record(prepared, state, prepared.bootstrapId, UID, PATCH), released, e -> writes[0]++);
        check(result != LibreGen1CalibrationPersistence.Result.SAVED && writes[0] == 0,
            "unconfirmed completion wrote cache");
        checkWiped(pending);
      }
    }
  }

  private static void exactReceiverAndPatchRolesStayBound() throws Exception {
    LibreGen1StreamingJournal.Record prepared = prepared();
    byte[] current = PATCH.clone(); current[4] ^= 0x21; current[5] ^= 0x17;
    LibreGen1StreamingCalibration pending = LibreGen1StreamingCalibration.fromRead(prepared, current, encrypted(3, current));
    byte[] expectedCurrent = current.clone(); Arrays.fill(current, (byte) 0);
    check(pending.preserveAfterConfirmation(record(prepared, "confirmed", prepared.bootstrapId, UID, PATCH), true, evidence -> {
      check(Arrays.equals(evidence.receiverInitialPatchInfo(), PATCH), "frozen receiver overwritten");
      check(Arrays.equals(evidence.calibrationPatchInfo(), expectedCurrent), "current FRAM key lost");
      try (LibreGen1CalibrationEvidence decoded = LibreGen1CalibrationEvidence.decode(
          evidence.encode(), prepared.bootstrapId, UID, PATCH)) {
        check(Arrays.equals(decoded.calibrationPatchInfo(), expectedCurrent), "wrong persisted key");
      }
    }) == LibreGen1CalibrationPersistence.Result.SAVED, "split patch evidence rejected");
    byte[] wrongUid = UID.clone(), wrongPatch = PATCH.clone(); wrongUid[0] ^= 1; wrongPatch[5] ^= 1;
    for (LibreGen1StreamingJournal.Record other : new LibreGen1StreamingJournal.Record[] {
        record(prepared, "confirmed", "different_bootstrap", UID, PATCH),
        record(prepared, "confirmed", prepared.bootstrapId, wrongUid, PATCH),
        record(prepared, "confirmed", prepared.bootstrapId, UID, wrongPatch)}) {
      LibreGen1StreamingCalibration candidate = LibreGen1StreamingCalibration.fromRead(prepared, PATCH, encrypted(3, PATCH));
      check(candidate.preserveAfterConfirmation(other, true, e -> { throw new AssertionError("wrong receiver written"); })
          == LibreGen1CalibrationPersistence.Result.RECEIVER_MISMATCH, "receiver binding lost");
      checkWiped(candidate);
    }
  }

  private static void everyTerminalPathIsSingleUseAndWiped() throws Exception {
    LibreGen1StreamingJournal.Record prepared = prepared();
    LibreGen1StreamingCalibration pending = LibreGen1StreamingCalibration.fromRead(prepared, PATCH, encrypted(3, PATCH));
    int[] writes = {0};
    check(pending.preserveAfterConfirmation(record(prepared, "confirmed", prepared.bootstrapId, UID, PATCH), true, e -> {
      writes[0]++; throw new IOException("synthetic private error");
    }) == LibreGen1CalibrationPersistence.Result.STORAGE_FAILED, "write failure called saved");
    check(pending.preserveAfterConfirmation(record(prepared, "confirmed", prepared.bootstrapId, UID, PATCH), true, e -> writes[0]++)
        == LibreGen1CalibrationPersistence.Result.INVALID_EVIDENCE && writes[0] == 1, "write retried");
    checkWiped(pending);
    pending = LibreGen1StreamingCalibration.fromRead(prepared, PATCH, encrypted(3, PATCH));
    pending.close(); pending.close(); checkWiped(pending);
    check(pending.toString().equals("LibreStreamingCalibration(<redacted>)"), "private evidence exposed");
  }

  private static void invalidReadsNeverProducePendingEvidence() throws Exception {
    LibreGen1StreamingJournal.Record prepared = prepared();
    for (int offset : new int[] {10, 100, 330}) {
      byte[] bad = encrypted(3, PATCH); bad[offset] ^= 1;
      rejects(() -> LibreGen1StreamingCalibration.fromRead(prepared, PATCH, bad));
    }
    for (int lifecycle : new int[] {0, 1, 4, 5, 6, 255}) {
      byte[] bad = encrypted(lifecycle, PATCH);
      rejects(() -> LibreGen1StreamingCalibration.fromRead(prepared, PATCH, bad));
    }
    byte[] wrong = PATCH.clone(); wrong[3] ^= 1;
    rejects(() -> LibreGen1StreamingCalibration.fromRead(prepared, wrong, encrypted(3, wrong)));
    rejects(() -> LibreGen1StreamingCalibration.fromRead(null, PATCH, encrypted(3, PATCH)));
    rejects(() -> LibreGen1StreamingCalibration.fromRead(prepared, PATCH, new byte[343]));
  }

  private static LibreGen1StreamingJournal.Record prepared() throws Exception {
    return new LibreGen1StreamingJournal(new MemoryBackend()).prepare(UID, PATCH, 42, 3);
  }
  private static LibreGen1StreamingJournal.Record record(LibreGen1StreamingJournal.Record source,
      String state, String id, byte[] uid, byte[] patch) {
    return new LibreGen1StreamingJournal.Record(id, uid, patch, source.streamingBase, 3,
        state, state.equals("confirmed") ? "02:00:00:00:00:01" : "", 0, "none");
  }
  private static byte[] encrypted(int lifecycle, byte[] patch) throws Exception {
    // Reuse the existing wholly synthetic MIT fixture generator, never capture files.
    Method method = LibreGen1CalibrationEvidenceTest.class.getDeclaredMethod("encrypted", int.class, byte[].class);
    method.setAccessible(true);
    return (byte[]) method.invoke(null, lifecycle, patch);
  }
  private static void checkWiped(LibreGen1StreamingCalibration value) throws Exception {
    for (String name : new String[] {"uid", "receiverPatch", "currentPatch", "fram"}) {
      Field field = LibreGen1StreamingCalibration.class.getDeclaredField(name); field.setAccessible(true);
      for (byte b : (byte[]) field.get(value)) check(b == 0, "restricted buffer retained");
    }
    rejects(() -> value.lifecycle());
  }
  private static final class MemoryBackend implements LibreGen1StreamingJournal.Backend {
    byte[] bytes;
    public byte[] read() { return bytes == null ? null : bytes.clone(); }
    public void write(byte[] value) { bytes = value == null ? null : value.clone(); }
  }
  private interface Checked { void run() throws Exception; }
  private static void rejects(Checked action) throws Exception {
    try { action.run(); throw new AssertionError("invalid evidence accepted"); }
    catch (IllegalArgumentException | IllegalStateException expected) {}
  }
  private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
