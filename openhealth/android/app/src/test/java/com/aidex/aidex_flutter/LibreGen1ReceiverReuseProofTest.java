package com.aidex.aidex_flutter;

import java.io.IOException;
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
  private static final long WALL = Instant.parse("2026-09-06T00:00:00Z").toEpochMilli();
  private static final long MONO = 500_000_000_000L;
  private static final byte[] UID = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 7, (byte) 0xe0};
  private static final byte[] PATCH = {(byte) 0x9d, 8, 0x30, 1, 0x34, 0x12};

  public static void main(String[] arguments) throws Exception {
    sameReceiverAndAbsentReceiver();
    freshBindingsAndStrictShape();
    changedNfcKeyAndAllCrcs();
    uncertainReceiverAndDifferentIdentity();
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
    }
    final Map<String, Object> valid = source(3, PATCH);
    for (String key : valid.keySet()) {
      final Map<String, Object> missing = new LinkedHashMap<>(valid); missing.remove(key);
      rejects(() -> read(missing, null));
    }
    final Map<String, Object> extra = new LinkedHashMap<>(valid); extra.put("unexpected", "private-value-sentinel");
    rejects(() -> read(extra, null));
    final String json = json(valid);
    rejects(() -> readJson("{\"\\u0073chemaVersion\":2," + json.substring(1), null));
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
    return new LibreGen1StreamingJournal.Record("00000000-0000-4000-8000-000000000001", uid, patch,
        42, 2, state, "00:11:22:33:44:55", 7, "acknowledged");
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
