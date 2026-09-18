package com.aidex.aidex_flutter;

import java.io.IOException;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

/** Synthetic only: no private files, platform APIs, transport, or GPL calibration arithmetic. */
public final class LibreGen1CalibrationEvidenceTest {
  private static final String ID = "synthetic_bootstrap_1";
  private static final byte[] UID = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 7, (byte) 0xe0};
  private static final byte[] PATCH = {(byte) 0x9d, 8, 0x30, 1, 0x34, 0x12};

  public static void main(String[] arguments) throws Exception {
    exactHistoricalEvidenceAndPrivateSnapshots();
    exactCaptureSchemasAndDuplicateKeys();
    wrongTargetOrAnyCrcFailsClosed();
    persistentCodecIsStrictAndSameBootstrapOnly();
    currentFramPatchIsNotTheFrozenReceiverPatch();
    cacheOutcomesRequireVerifiedStoreCompletion();
    System.out.println("Libre calibration evidence synthetic checks passed.");
  }

  private static void exactHistoricalEvidenceAndPrivateSnapshots() throws Exception {
    for (int lifecycle : new int[] {0, 1, 2, 3, 4, 5, 6, 255}) {
      // Historical lifecycle is not emitted or treated as current health state.
      final byte[] uid = UID.clone(), patch = PATCH.clone(), fram = encrypted(lifecycle);
      try (LibreGen1CalibrationEvidence value = LibreGen1CalibrationEvidence.verified(ID, uid, patch, fram)) {
        Arrays.fill(uid, (byte) 0); Arrays.fill(patch, (byte) 0); Arrays.fill(fram, (byte) 0);
        check(Arrays.equals(value.uid(), UID), "input UID alias");
        check(Arrays.equals(value.receiverInitialPatchInfo(), PATCH), "input receiver patch alias");
        check(Arrays.equals(value.calibrationPatchInfo(), PATCH), "input calibration patch alias");
        check(Arrays.equals(value.encryptedFram(), encrypted(lifecycle)), "input FRAM alias");
        Arrays.fill(value.uid(), (byte) 0); Arrays.fill(value.encryptedFram(), (byte) 0);
        check(Arrays.equals(value.uid(), UID), "output UID alias");
        check(Arrays.equals(value.encryptedFram(), encrypted(lifecycle)), "output FRAM alias");
        check(value.toString().equals("LibreCalibrationEvidence(<redacted>)"), "unsafe diagnostic");
      }
    }
    final LibreGen1CalibrationEvidence closed = LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, encrypted(3));
    closed.close(); closed.close();
    rejects(() -> closed.uid()); rejects(() -> closed.receiverInitialPatchInfo());
    rejects(() -> closed.calibrationPatchInfo());
    rejects(() -> closed.encryptedFram()); rejects(() -> closed.encode());
  }

  private static void exactCaptureSchemasAndDuplicateKeys() throws Exception {
    for (boolean explicit : new boolean[] {false, true}) {
      final Map<String, Object> source = capture(explicit);
      try (LibreGen1CalibrationEvidence value = parse(source, UID, PATCH)) {
        check(value.bootstrapId.equals(ID), "bootstrap binding missing");
        check(Arrays.equals(value.encryptedFram(), encrypted(3)), "capture bytes changed");
      }
      for (String key : source.keySet()) {
        final Map<String, Object> missing = new LinkedHashMap<>(source); missing.remove(key);
        rejects(() -> parse(missing, UID, PATCH));
      }
      for (String raw : new String[] {"rawPacket", "reading", "lifecycle", "sourcePath"}) {
        final Map<String, Object> extra = new LinkedHashMap<>(source); extra.put(raw, "private-value-sentinel");
        rejects(() -> parse(extra, UID, PATCH));
      }
      final String json = json(source);
      rejects(() -> LibreGen1CalibrationEvidence.fromCapture(json.replaceFirst("\\{", "{\"schemaVersion\":1,"), ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.fromCapture("{\"\\u0073chemaVersion\":1," + json.substring(1), ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.fromCapture(json + "{}", ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.fromCapture(" ".repeat(4097), ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.fromCapture(json.replace("\"gen1\"", "[]"), ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.fromCapture(json.replace("\"gen1\"", "{}"), ID, UID, PATCH));
    }
    for (Object[] change : new Object[][] {
        {"schemaVersion", 3L}, {"model", "libre2Plus"}, {"securityGeneration", "gen2"},
        {"iso15693ManufacturerPrefix", "e008"}, {"nativeCaptureSessionId", "short"},
        {"processSessionId", "bad token"}, {"versionCode", 0L}, {"lastUpdateTime", -1L},
        {"observedAtMonotonicElapsedNanos", "1"}, {"observedAtUtc", "invalid"},
        {"targetUidSha256", "0".repeat(64)}, {"patchInfoSha256", "0".repeat(64)},
        {"encryptedFramHex", "0".repeat(686)}, {"algorithmOrderUidHex", hex(UID).toUpperCase()},
        {"sourceKind", "other"}, {"explicitAttemptId", "bad token"}, {"captureSessionId", "session-20260905T000000Z-synthetic"}}) {
      final Map<String, Object> changed = capture(true); changed.put((String) change[0], change[1]);
      rejects(() -> parse(changed, UID, PATCH));
    }
    final Map<String, Object> missingSession = capture(false); missingSession.put("captureSessionId", null);
    rejects(() -> parse(missingSession, UID, PATCH));
    final String explicit = json(capture(true));
    rejects(() -> LibreGen1CalibrationEvidence.fromCapture("{\"\\u0073ourceKind\":\"explicitLibre2Lifecycle\"," + explicit.substring(1), ID, UID, PATCH));
  }

  private static void wrongTargetOrAnyCrcFailsClosed() throws Exception {
    final byte[] wrongUid = UID.clone(), wrongPatch = PATCH.clone(); wrongUid[0] ^= 1; wrongPatch[3] ^= 1;
    rejects(() -> parse(capture(true), wrongUid, PATCH));
    rejects(() -> parse(capture(true), UID, wrongPatch));
    for (int index : new int[] {10, 100, 330}) {
      final byte[] bad = encrypted(3); bad[index] ^= 1;
      final Map<String, Object> source = capture(true); source.put("encryptedFramHex", hex(bad));
      rejects(() -> parse(source, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, bad));
    }
    rejects(() -> LibreGen1CalibrationEvidence.verified("short", UID, PATCH, encrypted(3)));
    rejects(() -> LibreGen1CalibrationEvidence.verified(ID, new byte[8], PATCH, encrypted(3)));
    rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, new byte[6], encrypted(3)));
    rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, new byte[345]));
  }

  private static void persistentCodecIsStrictAndSameBootstrapOnly() throws Exception {
    try (LibreGen1CalibrationEvidence source = LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, encrypted(3))) {
      final byte[] encoded = source.encode();
      check(encoded.length <= 512, "unbounded record");
      try (LibreGen1CalibrationEvidence restored = LibreGen1CalibrationEvidence.decode(encoded, ID, UID, PATCH)) {
        check(Arrays.equals(restored.encryptedFram(), source.encryptedFram()), "persistent round trip");
      }
      final byte[] wrongUid = UID.clone(), wrongPatch = PATCH.clone(); wrongUid[0] ^= 1; wrongPatch[5] ^= 1;
      rejects(() -> LibreGen1CalibrationEvidence.decode(encoded, "different_bootstrap_2", UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.decode(encoded, ID, wrongUid, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.decode(encoded, ID, UID, wrongPatch));
      rejects(() -> LibreGen1CalibrationEvidence.decode(Arrays.copyOf(encoded, encoded.length + 1), ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.decode(Arrays.copyOf(encoded, encoded.length - 1), ID, UID, PATCH));
      rejects(() -> LibreGen1CalibrationEvidence.decode(new byte[513], ID, UID, PATCH));
      final byte[] badVersion = encoded.clone(); badVersion[3] = 3;
      rejects(() -> LibreGen1CalibrationEvidence.decode(badVersion, ID, UID, PATCH));
      for (int offset : new int[] {10, 100, 330}) {
        final byte[] corrupt = encoded.clone(); corrupt[corrupt.length - 344 + offset] ^= 1;
        rejects(() -> LibreGen1CalibrationEvidence.decode(corrupt, ID, UID, PATCH));
      }
    }
  }

  private static void currentFramPatchIsNotTheFrozenReceiverPatch() throws Exception {
    final byte[] currentPatch = PATCH.clone(); currentPatch[4] ^= 0x41; currentPatch[5] ^= 0x23;
    final byte[] currentFram = encrypted(3, currentPatch);
    final byte[] receiverSnapshot = PATCH.clone(), currentSnapshot = currentPatch.clone();
    try (LibreGen1CalibrationEvidence evidence = LibreGen1CalibrationEvidence.verified(
        ID, UID, receiverSnapshot, currentSnapshot, currentFram)) {
      Arrays.fill(receiverSnapshot, (byte) 0); Arrays.fill(currentSnapshot, (byte) 0);
      check(Arrays.equals(evidence.receiverInitialPatchInfo(), PATCH), "frozen receiver changed");
      check(Arrays.equals(evidence.calibrationPatchInfo(), currentPatch), "current NFC patch lost");
      Arrays.fill(evidence.receiverInitialPatchInfo(), (byte) 0);
      Arrays.fill(evidence.calibrationPatchInfo(), (byte) 0);
      check(Arrays.equals(evidence.receiverInitialPatchInfo(), PATCH), "receiver getter alias");
      check(Arrays.equals(evidence.calibrationPatchInfo(), currentPatch), "current getter alias");
      final byte[] encoded = evidence.encode();
      check(encoded[3] == 2 && encoded.length <= 512, "new codec version missing");
      for (int repeat = 0; repeat < 2; repeat++) {
        try (LibreGen1CalibrationEvidence decoded = LibreGen1CalibrationEvidence.decode(encoded, ID, UID, PATCH)) {
          check(Arrays.equals(decoded.receiverInitialPatchInfo(), PATCH), "codec overwrote receiver");
          check(Arrays.equals(decoded.calibrationPatchInfo(), currentPatch), "codec lost current patch");
          check(Arrays.equals(decoded.encryptedFram(), currentFram), "codec changed FRAM");
        }
      }
      rejects(() -> LibreGen1CalibrationEvidence.decode(encoded, ID, UID, currentPatch));
      final byte[] wrongUid = UID.clone(); wrongUid[0] ^= 1;
      rejects(() -> LibreGen1CalibrationEvidence.decode(encoded, ID, wrongUid, PATCH));
      final byte[] swapped = encoded.clone();
      final int patchOffset = encoded.length - 344 - 12;
      System.arraycopy(currentPatch, 0, swapped, patchOffset, 6);
      System.arraycopy(PATCH, 0, swapped, patchOffset + 6, 6);
      rejects(() -> LibreGen1CalibrationEvidence.decode(swapped, ID, UID, PATCH));
    }
    // Old data remains readable only when its single patch is the exact
    // frozen receiver patch. Query does not rewrite it or guess a new key.
    final ByteArrayOutputStream legacyBytes = new ByteArrayOutputStream();
    final DataOutputStream legacy = new DataOutputStream(legacyBytes);
    legacy.writeInt(1); legacy.writeUTF(ID); legacy.write(UID); legacy.write(PATCH); legacy.write(encrypted(3));
    legacy.flush();
    try (LibreGen1CalibrationEvidence old = LibreGen1CalibrationEvidence.decode(legacyBytes.toByteArray(), ID, UID, PATCH)) {
      check(Arrays.equals(old.receiverInitialPatchInfo(), PATCH), "legacy receiver lost");
      check(Arrays.equals(old.calibrationPatchInfo(), PATCH), "legacy key guessed");
      try (LibreGen1CalibrationEvidence upgraded = LibreGen1CalibrationEvidence.decode(old.encode(), ID, UID, PATCH)) {
        check(Arrays.equals(upgraded.encryptedFram(), encrypted(3)), "legacy roll forward changed FRAM");
      }
    }
    rejects(() -> LibreGen1CalibrationEvidence.decode(legacyBytes.toByteArray(), ID, UID, currentPatch));
    for (int index = 0; index < 4; index++) {
      final byte[] changedPrefix = currentPatch.clone(); changedPrefix[index] ^= 1;
      rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, changedPrefix, encrypted(3, changedPrefix)));
      final Map<String, Object> changedCapture = capture(true, changedPrefix);
      rejects(() -> parse(changedCapture, UID, PATCH));
    }
    rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, currentPatch, encrypted(3)));
    rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, PATCH, currentFram));
    for (int offset : new int[] {10, 100, 330}) {
      final byte[] corrupt = currentFram.clone(); corrupt[offset] ^= 1;
      rejects(() -> LibreGen1CalibrationEvidence.verified(ID, UID, PATCH, currentPatch, corrupt));
    }
    for (boolean explicit : new boolean[] {false, true}) {
      try (LibreGen1CalibrationEvidence captured = parse(capture(explicit, currentPatch), UID, PATCH)) {
        check(Arrays.equals(captured.receiverInitialPatchInfo(), PATCH), "capture changed receiver");
        check(Arrays.equals(captured.calibrationPatchInfo(), currentPatch), "capture key not same-read");
        check(Arrays.equals(captured.encryptedFram(), currentFram), "capture FRAM not same-read");
      }
    }
    final LibreGen1StreamingJournal.Record receiver = new LibreGen1StreamingJournal.Record(
        ID, UID, PATCH, 1, 3, "confirmed", "02:00:00:00:00:01", 7, "acknowledged");
    final int[] writes = {0};
    check(LibreGen1CalibrationPersistence.preserve(receiver, UID, currentPatch, currentFram, evidence -> {
      writes[0]++;
      try (LibreGen1CalibrationEvidence readback = LibreGen1CalibrationEvidence.decode(evidence.encode(), ID, UID, PATCH)) {
        check(Arrays.equals(readback.calibrationPatchInfo(), currentPatch), "saved wrong FRAM key");
      }
    }) == LibreGen1CalibrationPersistence.Result.SAVED, "same-sensor updated key not saved");
    check(writes[0] == 1 && receiver.unlockCount == 7 && Arrays.equals(receiver.initialPatchInfo, PATCH),
        "preserve changed receiver or retried");
  }

  private static void cacheOutcomesRequireVerifiedStoreCompletion() throws Exception {
    final LibreGen1StreamingJournal.Record receiver = new LibreGen1StreamingJournal.Record(
        ID, UID, PATCH, 1, 3, "confirmed", "02:00:00:00:00:01", 1, "acknowledged");
    final byte[] fram = encrypted(3);
    final int[] writes = {0};
    final LibreGen1CalibrationEvidence[] borrowed = {null};
    final LibreGen1CalibrationPersistence.VerifiedWriter writer = evidence -> {
      writes[0]++;
      borrowed[0] = evidence;
      final byte[] persisted = evidence.encode();
      try (LibreGen1CalibrationEvidence readback = LibreGen1CalibrationEvidence.decode(
          persisted, ID, UID, PATCH)) {
        check(Arrays.equals(readback.encryptedFram(), fram), "incorrect verified readback");
      } finally { Arrays.fill(persisted, (byte) 0); }
    };
    check(LibreGen1CalibrationPersistence.preserve(receiver, UID, PATCH, fram, writer)
        == LibreGen1CalibrationPersistence.Result.SAVED, "verified cache not saved");
    check(writes[0] == 1, "save retried");
    rejects(() -> borrowed[0].encryptedFram());
    check(LibreGen1CalibrationPersistence.preserve(null, UID, PATCH, fram, writer)
        == LibreGen1CalibrationPersistence.Result.RECEIVER_UNAVAILABLE, "missing receiver mislabeled");
    final LibreGen1StreamingJournal.Record pending = new LibreGen1StreamingJournal.Record(
        ID, UID, PATCH, 1, 3, "unknown", "", 0, "none");
    check(LibreGen1CalibrationPersistence.preserve(pending, UID, PATCH, fram, writer)
        == LibreGen1CalibrationPersistence.Result.RECEIVER_UNAVAILABLE, "unconfirmed receiver written");
    final byte[] differentUid = UID.clone(), differentPatch = PATCH.clone();
    differentUid[0] ^= 1; differentPatch[3] ^= 1;
    check(LibreGen1CalibrationPersistence.preserve(receiver, differentUid, PATCH, fram, writer)
        == LibreGen1CalibrationPersistence.Result.RECEIVER_MISMATCH, "wrong target written");
    check(LibreGen1CalibrationPersistence.preserve(receiver, UID, differentPatch, fram, writer)
        == LibreGen1CalibrationPersistence.Result.RECEIVER_MISMATCH, "wrong patch written");
    for (int offset : new int[] {10, 100, 330}) {
      final byte[] corrupt = fram.clone(); corrupt[offset] ^= 1;
      check(LibreGen1CalibrationPersistence.preserve(receiver, UID, PATCH, corrupt, writer)
          == LibreGen1CalibrationPersistence.Result.INVALID_EVIDENCE, "invalid CRC written");
    }
    check(writes[0] == 1, "skipped or invalid evidence reached store");
    for (boolean failReadback : new boolean[] {false, true}) {
      final int[] failedWrites = {0};
      final LibreGen1CalibrationPersistence.Result result = LibreGen1CalibrationPersistence.preserve(
          receiver, UID, PATCH, fram, evidence -> {
            failedWrites[0]++;
            if (failReadback) {
              final byte[] persisted = evidence.encode();
              try {
                persisted[persisted.length - 1] ^= 1;
                LibreGen1CalibrationEvidence.decode(persisted, ID, UID, PATCH).close();
              } finally { Arrays.fill(persisted, (byte) 0); }
            }
            throw new IOException("private-value-sentinel");
          });
      check(result == LibreGen1CalibrationPersistence.Result.STORAGE_FAILED, "failed save reported saved");
      check(failedWrites[0] == 1, "failed save retried");
    }
    for (LibreGen1CalibrationPersistence.Result result : LibreGen1CalibrationPersistence.Result.values()) {
      check(result.outcome.matches("saved|skipped|failed"), "open outcome vocabulary");
      check(result.reason.matches("[A-Za-z]{1,32}"), "unbounded private reason");
      check(!result.toString().contains(ID) && !result.toString().contains("private-value-sentinel"), "private outcome");
    }
    check(receiver.unlockCount == 1 && receiver.loginOutcome.equals("acknowledged"), "receiver mutated");
    check(Arrays.equals(receiver.uid, UID) && Arrays.equals(receiver.initialPatchInfo, PATCH), "receiver bytes changed");
  }

  private static LibreGen1CalibrationEvidence parse(Map<String, Object> source, byte[] uid, byte[] patch) throws Exception {
    return LibreGen1CalibrationEvidence.fromCapture(json(source), ID, uid, patch);
  }
  private static Map<String, Object> capture(boolean explicit) throws Exception {
    return capture(explicit, PATCH);
  }
  private static Map<String, Object> capture(boolean explicit, byte[] patch) throws Exception {
    final Map<String, Object> source = new LinkedHashMap<>();
    source.put("schemaVersion", explicit ? 2L : 1L);
    source.put("nativeCaptureSessionId", "old_native_session"); source.put("processSessionId", "old_process_session");
    source.put("captureSessionId", explicit ? null : "session-20260901T000000Z-synthetic");
    source.put("versionCode", 1L); source.put("lastUpdateTime", 1L);
    source.put("targetUidSha256", hex(MessageDigest.getInstance("SHA-256").digest(UID)));
    source.put("iso15693ManufacturerPrefix", "e007");
    source.put("patchInfoSha256", hex(MessageDigest.getInstance("SHA-256").digest(patch)));
    source.put("model", "libre2"); source.put("securityGeneration", "gen1");
    source.put("algorithmOrderUidHex", hex(UID)); source.put("patchInfoHex", hex(patch));
    source.put("encryptedFramHex", hex(encrypted(3, patch))); source.put("observedAtUtc", "2026-09-01T00:00:00Z");
    source.put("observedAtMonotonicElapsedNanos", 1L);
    if (explicit) { source.put("sourceKind", "explicitLibre2Lifecycle"); source.put("explicitAttemptId", "synthetic_attempt"); }
    return source;
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
  private static byte[] encrypted(int lifecycle) throws Exception {
    return encrypted(lifecycle, PATCH);
  }
  private static byte[] encrypted(int lifecycle, byte[] patch) throws Exception {
    // Use the existing MIT primitive to generate a wholly synthetic fixture.
    // The production helper is separately checked against its pinned vectors.
    final byte[] clear = new byte[344];
    for (int i = 0; i < clear.length; i++) clear[i] = (byte) (i * 73 + 19);
    clear[4] = (byte) lifecycle;
    for (int[] region : new int[][] {{0, 24}, {24, 320}, {320, 344}}) {
      int crc = 0xffff;
      for (int i = region[0] + 2; i < region[1]; i++) {
        crc ^= clear[i] & 255;
        for (int bit = 0; bit < 8; bit++) crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0x8408 : crc >>> 1;
      }
      int reversed = 0;
      for (int bit = 0; bit < 16; bit++) { reversed = reversed << 1 | crc & 1; crc >>>= 1; }
      clear[region[0]] = (byte) reversed; clear[region[0] + 1] = (byte) (reversed >>> 8);
    }
    final Method prepare = LibreGen1Activation.class.getDeclaredMethod("prepareVariables", byte[].class, int.class, int.class);
    final Method process = LibreGen1Activation.class.getDeclaredMethod("processCrypto", int[].class);
    final Method words = LibreGen1Activation.class.getDeclaredMethod("wordsToLittleEndian", int[].class);
    prepare.setAccessible(true); process.setAccessible(true); words.setAccessible(true);
    final byte[] result = new byte[344];
    for (int block = 0; block < 43; block++) {
      final int argument = ((patch[4] & 255) | ((patch[5] & 255) << 8)) ^ 0x44;
      final int[] seed = (int[]) prepare.invoke(null, UID, block, argument);
      final int[] processed = (int[]) process.invoke(null, (Object) seed);
      final byte[] key = (byte[]) words.invoke(null, (Object) processed);
      for (int i = 0; i < 8; i++) result[block * 8 + i] = (byte) (clear[block * 8 + i] ^ key[i]);
      Arrays.fill(seed, 0); Arrays.fill(processed, 0); Arrays.fill(key, (byte) 0);
    }
    Arrays.fill(clear, (byte) 0); return result;
  }
  private interface Checked { void run() throws Exception; }
  private static void rejects(Checked action) throws Exception {
    try { action.run(); throw new AssertionError("Invalid evidence accepted"); }
    catch (IOException | IllegalArgumentException | IllegalStateException expected) {
      check(expected.getCause() == null, "private error cause retained");
      check(!expected.toString().contains("private-value-sentinel"), "private exception leaked");
    }
  }
  private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
  private static String hex(byte[] bytes) {
    final StringBuilder result = new StringBuilder();
    for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
    return result.toString();
  }
}
