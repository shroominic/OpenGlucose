package com.aidex.aidex_flutter;

import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;

/** Offline synthetic read-only proof tests. No Android, files, credentials, or sensor I/O. */
public final class LibreGen1ReceiverReuseProofTest {
  private static final String ATTEMPT = "synthetic_attempt";
  private static final String NATIVE = "synthetic_native";
  private static final String PROCESS = "synthetic_process";
  private static final String BOOTSTRAP = "00000000-0000-4000-8000-000000000001";
  private static final long WALL = Instant.parse("2026-09-06T00:00:00Z").toEpochMilli();
  private static final long MONO = 500_000_000_000L;
  private static final byte[] UID = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 7, (byte) 0xe0};
  private static final byte[] PATCH = {(byte) 0x9d, 8, 0x30, 1, 0x34, 0x12};

  public static void main(String[] arguments) throws Exception {
    sameReceiverAndAbsentReceiver();
    freshBindingsAndStrictShape();
    changedNfcKeyAndAllCrcs();
    uncertainReceiverAndDifferentIdentity();
    freshHistoryDeliveryAndClearing();
    freshHistoryRequiresReceiverAndExactSource();
    freshHistoryRechecksAtDelivery();
    System.out.println("Libre receiver reuse proof synthetic checks passed.");
  }

  private static void sameReceiverAndAbsentReceiver() throws Exception {
    final LibreGen1StreamingJournal.Record receiver = receiver(UID, PATCH, "confirmed");
    for (int lifecycle : new int[] {2, 3}) {
      final Map<String, Object> source = source(lifecycle, PATCH);
      final Map<String, Object> proof = read(source, receiver);
      check(proof.keySet().equals(new HashSet<>(Arrays.asList("attemptId", "event", "model", "lifecycle"))), "open proof shape");
      check(ATTEMPT.equals(proof.get("attemptId")) && "receiverReusable".equals(proof.get("event"))
          && "libre2".equals(proof.get("model")), "uncorrelated proof");
      check((lifecycle == 2 ? "warmingUp" : "active").equals(proof.get("lifecycle")), "lifecycle was inferred from receiver history");
      check(read(source, null) == null, "absent receiver must stay absent");
      check(!proof.toString().contains(receiver.bootstrapId) && !proof.toString().contains(receiver.deviceId)
          && !proof.toString().contains(hex(UID)) && !proof.toString().contains(hex(PATCH)), "private proof output");
    }
    check(receiver.unlockCount == 7 && receiver.streamingBase == 42 && "acknowledged".equals(receiver.loginOutcome), "receiver fields changed");
    check(Arrays.equals(receiver.uid, UID) && Arrays.equals(receiver.initialPatchInfo, PATCH), "receiver bytes changed");
    for (int lifecycle : new int[] {0, 1, 4, 5, 6, 255}) {
      final Map<String, Object> source = source(lifecycle, PATCH);
      rejects(() -> read(source, receiver));
      rejects(() -> read(source, null));
    }
  }

  private static void freshBindingsAndStrictShape() throws Exception {
    for (Object[] replacement : new Object[][] {
        {"schemaVersion", 1L}, {"schemaVersion", 2.0}, {"nativeCaptureSessionId", "other_native"},
        {"processSessionId", "other_process"}, {"captureSessionId", "session-other"},
        {"sourceKind", "other"}, {"explicitAttemptId", "different_attempt"},
        {"versionCode", 2L}, {"lastUpdateTime", 2L}, {"model", "libre2Plus"},
        {"securityGeneration", "gen2"}, {"iso15693ManufacturerPrefix", "e008"},
        {"targetUidSha256", "0".repeat(64)}, {"patchInfoSha256", "0".repeat(64)},
        {"observedAtUtc", "invalid"}, {"observedAtUtc", "2026-09-05T23:57:59.999Z"},
        {"observedAtUtc", "2026-09-06T00:00:05.001Z"},
        {"observedAtMonotonicElapsedNanos", MONO + 1},
        {"observedAtMonotonicElapsedNanos", MONO - 120_000_000_001L},
        {"observedAtMonotonicElapsedNanos", 0L},
        {"algorithmOrderUidHex", "00"}, {"patchInfoHex", "00"}, {"encryptedFramHex", "00"}}) {
      final Map<String, Object> source = source(3, PATCH);
      source.put((String) replacement[0], replacement[1]);
      rejects(() -> read(source, receiver(UID, PATCH, "confirmed")));
      rejects(() -> read(source, null)); // Invalid evidence must never permit fresh enablement.
      rejects(() -> fresh(source, receiver(UID, PATCH, "confirmed"), BOOTSTRAP));
    }
    final Map<String, Object> valid = source(3, PATCH);
    for (String key : valid.keySet()) {
      final Map<String, Object> missing = new LinkedHashMap<>(valid); missing.remove(key);
      rejects(() -> read(missing, null));
      rejects(() -> fresh(missing, receiver(UID, PATCH, "confirmed"), BOOTSTRAP));
    }
    final Map<String, Object> extra = new LinkedHashMap<>(valid); extra.put("unexpected", "private-value-sentinel");
    rejects(() -> read(extra, null));
    rejects(() -> fresh(extra, receiver(UID, PATCH, "confirmed"), BOOTSTRAP));
    final String json = json(valid);
    rejects(() -> readJson("{\"\\u0073chemaVersion\":2," + json.substring(1), null));
    rejects(() -> freshJson("{\"\\u0073chemaVersion\":2," + json.substring(1), receiver(UID, PATCH, "confirmed"), BOOTSTRAP));
    rejects(() -> readJson(json + "{}", null));
    rejects(() -> readJson(" ".repeat(4097), null));
    rejects(() -> LibreGen1ReceiverReuseProof.read(json, null, "other_attempt", NATIVE, PROCESS, 1, 1, WALL, MONO));
    rejects(() -> LibreGen1ReceiverReuseProof.read(json, null, ATTEMPT, "other_native", PROCESS, 1, 1, WALL, MONO));
    rejects(() -> LibreGen1ReceiverReuseProof.read(json, null, ATTEMPT, NATIVE, "other_process", 1, 1, WALL, MONO));
    rejects(() -> LibreGen1ReceiverReuseProof.read(json, null, ATTEMPT, NATIVE, PROCESS, 2, 1, WALL, MONO));
    rejects(() -> LibreGen1ReceiverReuseProof.read(json, null, ATTEMPT, NATIVE, PROCESS, 1, 2, WALL, MONO));
    final Map<String, Object> boundary = source(3, PATCH);
    boundary.put("observedAtUtc", "2026-09-05T23:58:00Z");
    boundary.put("observedAtMonotonicElapsedNanos", MONO - 120_000_000_000L);
    check(read(boundary, receiver(UID, PATCH, "confirmed")) != null, "inclusive existing freshness boundary");
  }

  private static void changedNfcKeyAndAllCrcs() throws Exception {
    final byte[] currentPatch = PATCH.clone(); currentPatch[4] ^= 0x41; currentPatch[5] ^= 0x23;
    final Map<String, Object> current = source(3, currentPatch);
    check(read(current, receiver(UID, PATCH, "confirmed")) != null, "current NFC key mistaken for frozen receiver key");
    final Map<String, Object> oldFram = new LinkedHashMap<>(current); oldFram.put("encryptedFramHex", hex(encrypted(3, PATCH)));
    rejects(() -> read(oldFram, receiver(UID, PATCH, "confirmed")));
    for (int index : new int[] {10, 100, 330}) {
      final byte[] corrupt = encrypted(3, currentPatch); corrupt[index] ^= 1;
      final Map<String, Object> changed = new LinkedHashMap<>(current); changed.put("encryptedFramHex", hex(corrupt));
      rejects(() -> read(changed, receiver(UID, PATCH, "confirmed")));
      rejects(() -> read(changed, null));
      rejects(() -> fresh(changed, receiver(UID, PATCH, "confirmed"), BOOTSTRAP));
    }
    for (int index = 0; index < 4; index++) {
      final byte[] changed = PATCH.clone(); changed[index] ^= 1;
      rejects(() -> read(current, receiver(UID, changed, "confirmed")));
    }
  }

  private static void uncertainReceiverAndDifferentIdentity() throws Exception {
    final Map<String, Object> source = source(3, PATCH);
    for (String state : new String[] {"prepared", "unknown", "invalid"}) {
      rejects(() -> read(source, receiver(UID, PATCH, state)));
    }
    final byte[] otherUid = UID.clone(); otherUid[0] ^= 1;
    rejects(() -> read(source, receiver(otherUid, PATCH, "confirmed")));
  }

  private static LibreGen1StreamingJournal.Record receiver(byte[] uid, byte[] patch, String state) {
    return new LibreGen1StreamingJournal.Record(BOOTSTRAP, uid, patch,
        42, 2, state, "00:11:22:33:44:55", 7, "acknowledged");
  }

  private static void freshHistoryDeliveryAndClearing() throws Exception {
    final byte[] currentPatch = PATCH.clone(); currentPatch[4] ^= 0x41; currentPatch[5] ^= 0x23;
    final Map<String, Object> source = source(3, currentPatch);
    final LibreGen1StreamingJournal.Record receiver = receiver(UID, PATCH, "confirmed");
    final LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence = fresh(source, receiver, BOOTSTRAP);
    final byte[][] owned = evidenceBuffers(evidence);
    final byte[] expectedFram = encrypted(3, currentPatch);
    // Source maps are no longer referenced once their immutable JSON was read.
    source.put("encryptedFramHex", "00");
    source.put("observedAtUtc", "2099-01-01T00:00:00Z");
    final boolean[] called = {false};
    evidence.deliver(receiver, WALL, MONO, value -> {
      called[0] = true;
      check(value.keySet().equals(new HashSet<>(Arrays.asList("attemptId", "bootstrapId", "uid",
          "receiverInitialPatchInfo", "currentPatchInfo", "encryptedFram", "observedAtUtc"))), "open history shape");
      check(ATTEMPT.equals(value.get("attemptId")) && BOOTSTRAP.equals(value.get("bootstrapId")), "history binding changed");
      check(Arrays.equals((byte[]) value.get("uid"), UID), "UID not from verified source");
      check(Arrays.equals((byte[]) value.get("receiverInitialPatchInfo"), PATCH), "frozen receiver patch replaced");
      check(Arrays.equals((byte[]) value.get("currentPatchInfo"), currentPatch), "fresh NFC seed lost");
      check(Arrays.equals((byte[]) value.get("encryptedFram"), expectedFram), "source changed after validation");
      check("2026-09-06T00:00:00Z".equals(value.get("observedAtUtc")), "receipt time was refreshed");
      try { value.put("raw", "forbidden"); throw new AssertionError("mutable evidence map"); }
      catch (UnsupportedOperationException expected) { /* Closed shape cannot be extended. */ }
    });
    check(called[0], "history was not delivered");
    cleared(owned);
    rejects(() -> evidence.deliver(receiver, WALL, MONO, ignored -> { throw new AssertionError("second delivery"); }));
    check(Arrays.equals(receiver.uid, UID) && Arrays.equals(receiver.initialPatchInfo, PATCH)
        && receiver.unlockCount == 7 && receiver.streamingBase == 42, "receiver mutated by history read");
    check(evidence.toString().equals("LibreGen1FreshHistoryEvidence(data: <redacted>)"), "open history diagnostics");

    final LibreGen1ReceiverReuseProof.FreshHistoryEvidence cancelled = fresh(source(3, PATCH), receiver, BOOTSTRAP);
    final byte[][] cancelledBytes = evidenceBuffers(cancelled);
    cancelled.close(); cancelled.close();
    cleared(cancelledBytes);
    rejects(() -> cancelled.deliver(receiver, WALL, MONO, ignored -> { throw new AssertionError("cancelled delivery"); }));

    final LibreGen1ReceiverReuseProof.FreshHistoryEvidence failed = fresh(source(3, PATCH), receiver, BOOTSTRAP);
    final byte[][] failedBytes = evidenceBuffers(failed);
    rejects(() -> failed.deliver(receiver, WALL, MONO, ignored -> { throw new IOException("private-value-sentinel"); }));
    cleared(failedBytes);
  }

  private static void freshHistoryRequiresReceiverAndExactSource() throws Exception {
    final Map<String, Object> source = source(3, PATCH);
    rejects(() -> fresh(source, null, BOOTSTRAP));
    for (String bootstrap : new String[] {"different_bootstrap", "", "invalid/value", "a".repeat(121)}) {
      rejects(() -> fresh(source, receiver(UID, PATCH, "confirmed"), bootstrap));
    }
    for (String state : new String[] {"prepared", "unknown", "invalid"}) {
      rejects(() -> fresh(source, receiver(UID, PATCH, state), BOOTSTRAP));
    }
    final byte[] otherUid = UID.clone(); otherUid[0] ^= 1;
    rejects(() -> fresh(source, receiver(otherUid, PATCH, "confirmed"), BOOTSTRAP));
    for (int lifecycle : new int[] {0, 1, 4, 5, 6, 255}) {
      rejects(() -> fresh(source(lifecycle, PATCH), receiver(UID, PATCH, "confirmed"), BOOTSTRAP));
    }
    for (int lifecycle : new int[] {2, 3}) {
      try (LibreGen1ReceiverReuseProof.FreshHistoryEvidence ignored =
          fresh(source(lifecycle, PATCH), receiver(UID, PATCH, "confirmed"), BOOTSTRAP)) {
        check(ignored != null, "eligible lifecycle rejected");
      }
    }
  }

  private static void freshHistoryRechecksAtDelivery() throws Exception {
    for (long[] now : new long[][] {
        {WALL + 120_001L, MONO}, {WALL, MONO + 120_000_000_001L},
        {WALL - 5_001L, MONO}, {WALL, MONO - 1L}, {0, MONO}, {WALL, 0}}) {
      final LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence =
          fresh(source(3, PATCH), receiver(UID, PATCH, "confirmed"), BOOTSTRAP);
      final byte[][] buffers = evidenceBuffers(evidence);
      rejects(() -> evidence.deliver(receiver(UID, PATCH, "confirmed"), now[0], now[1],
          ignored -> { throw new AssertionError("stale delivery"); }));
      cleared(buffers);
    }
    final LibreGen1ReceiverReuseProof.FreshHistoryEvidence boundary =
        fresh(source(3, PATCH), receiver(UID, PATCH, "confirmed"), BOOTSTRAP);
    boundary.deliver(receiver(UID, PATCH, "confirmed"), WALL + 120_000L, MONO + 120_000_000_000L,
        value -> check("2026-09-06T00:00:00Z".equals(value.get("observedAtUtc")), "boundary receipt refreshed"));
    final byte[] otherUid = UID.clone(); otherUid[0] ^= 1;
    final byte[] otherPatch = PATCH.clone(); otherPatch[5] ^= 1;
    for (LibreGen1StreamingJournal.Record replacement : new LibreGen1StreamingJournal.Record[] {
        null, receiver(UID, PATCH, "unknown"), receiver(otherUid, PATCH, "confirmed"),
        receiver(UID, otherPatch, "confirmed"),
        new LibreGen1StreamingJournal.Record("00000000-0000-4000-8000-000000000002", UID, PATCH,
            42, 2, "confirmed", "00:11:22:33:44:55", 7, "acknowledged")}) {
      final LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence =
          fresh(source(3, PATCH), receiver(UID, PATCH, "confirmed"), BOOTSTRAP);
      final byte[][] buffers = evidenceBuffers(evidence);
      rejects(() -> evidence.deliver(replacement, WALL, MONO,
          ignored -> { throw new AssertionError("changed receiver delivered"); }));
      cleared(buffers);
    }
  }

  private static LibreGen1ReceiverReuseProof.FreshHistoryEvidence fresh(
      Map<String, Object> source, LibreGen1StreamingJournal.Record receiver, String bootstrap) throws IOException {
    return freshJson(json(source), receiver, bootstrap);
  }
  private static LibreGen1ReceiverReuseProof.FreshHistoryEvidence freshJson(
      String source, LibreGen1StreamingJournal.Record receiver, String bootstrap) throws IOException {
    return LibreGen1ReceiverReuseProof.readFreshHistory(source, receiver, ATTEMPT, bootstrap,
        NATIVE, PROCESS, 1, 1, WALL, MONO);
  }
  private static byte[][] evidenceBuffers(LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence) throws Exception {
    final byte[][] result = new byte[4][];
    int index = 0;
    for (String name : new String[] {"uid", "receiverPatch", "currentPatch", "fram"}) {
      final Field field = evidence.getClass().getDeclaredField(name); field.setAccessible(true);
      result[index++] = (byte[]) field.get(evidence);
    }
    return result;
  }
  private static void cleared(byte[][] buffers) {
    for (byte[] bytes : buffers) for (byte value : bytes) check(value == 0, "owned history bytes were retained");
  }
  private static Map<String, Object> source(int lifecycle, byte[] patch) throws Exception {
    final Map<String, Object> value = new LinkedHashMap<>();
    value.put("schemaVersion", 2L); value.put("nativeCaptureSessionId", NATIVE); value.put("processSessionId", PROCESS);
    value.put("captureSessionId", null); value.put("sourceKind", "explicitLibre2Lifecycle"); value.put("explicitAttemptId", ATTEMPT);
    value.put("versionCode", 1L); value.put("lastUpdateTime", 1L);
    value.put("targetUidSha256", hex(MessageDigest.getInstance("SHA-256").digest(UID)));
    value.put("iso15693ManufacturerPrefix", "e007"); value.put("patchInfoSha256", hex(MessageDigest.getInstance("SHA-256").digest(patch)));
    value.put("model", "libre2"); value.put("securityGeneration", "gen1"); value.put("algorithmOrderUidHex", hex(UID));
    value.put("patchInfoHex", hex(patch)); value.put("encryptedFramHex", hex(encrypted(lifecycle, patch)));
    value.put("observedAtUtc", "2026-09-06T00:00:00Z"); value.put("observedAtMonotonicElapsedNanos", MONO);
    return value;
  }
  private static byte[] encrypted(int lifecycle, byte[] patch) throws Exception {
    // Reuse only the existing synthetic generator, never a captured fixture.
    final Method fixture = LibreGen1CalibrationEvidenceTest.class.getDeclaredMethod("encrypted", int.class, byte[].class);
    fixture.setAccessible(true);
    return (byte[]) fixture.invoke(null, lifecycle, patch);
  }
  private static Map<String, Object> read(Map<String, Object> source, LibreGen1StreamingJournal.Record receiver) throws IOException {
    return readJson(json(source), receiver);
  }
  private static Map<String, Object> readJson(String json, LibreGen1StreamingJournal.Record receiver) throws IOException {
    return LibreGen1ReceiverReuseProof.read(json, receiver, ATTEMPT, NATIVE, PROCESS, 1, 1, WALL, MONO);
  }
  private static String json(Map<String, Object> source) {
    final StringBuilder result = new StringBuilder("{");
    source.forEach((key, value) -> {
      if (result.length() > 1) result.append(',');
      result.append('"').append(key).append("\":");
      if (value instanceof String) result.append('"').append(value).append('"'); else result.append(value);
    });
    return result.append('}').toString();
  }
  private interface Checked { void run() throws Exception; }
  private static void rejects(Checked action) throws Exception {
    try { action.run(); throw new AssertionError("Invalid reuse proof accepted"); }
    catch (IOException expected) {
      check(expected.getCause() == null && expected.getMessage().equals("Saved receiver verification is unavailable."), "open error output");
    }
  }
  private static String hex(byte[] bytes) {
    final StringBuilder result = new StringBuilder();
    for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
    return result.toString();
  }
  private static void check(boolean valid, String message) { if (!valid) throw new AssertionError(message); }
}
