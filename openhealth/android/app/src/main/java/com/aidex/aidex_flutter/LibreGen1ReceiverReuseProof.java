package com.aidex.aidex_flutter;

import java.io.IOException;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Pure, fresh explicit-read proof. It neither authorizes RF nor changes receiver state. */
final class LibreGen1ReceiverReuseProof {
  private static final long MAX_AGE_NANOS = 120_000_000_000L;
  private static final long MAX_AGE_MILLIS = 120_000L;
  private static final long CLOCK_SKEW_MILLIS = 5_000L;
  private static final Set<String> KEYS = new HashSet<>(Arrays.asList(
      "schemaVersion", "nativeCaptureSessionId", "processSessionId", "captureSessionId",
      "sourceKind", "explicitAttemptId", "versionCode", "lastUpdateTime",
      "targetUidSha256", "iso15693ManufacturerPrefix", "patchInfoSha256", "model",
      "securityGeneration", "algorithmOrderUidHex", "patchInfoHex", "encryptedFramHex",
      "observedAtUtc", "observedAtMonotonicElapsedNanos"));

  private LibreGen1ReceiverReuseProof() {}

  /** Null means only a proven fresh eligible read and an absent receiver, never a failed check. */
  static Map<String, Object> read(String sourceJson, LibreGen1StreamingJournal.Record receiver,
      String attemptId, String nativeSession, String processSession, long versionCode,
      long lastUpdateTime, long nowMillis, long nowNanos) throws IOException {
    byte[] uid = null, patch = null, fram = null;
    try {
      final Map<String, Object> source = Libre2ActivationUiProof.parse(sourceJson);
      if (!source.keySet().equals(KEYS) || !Long.valueOf(2).equals(source.get("schemaVersion"))
          || !safeToken(attemptId) || !safeToken(nativeSession) || !safeToken(processSession)
          || versionCode <= 0 || lastUpdateTime <= 0 || nowMillis <= 0 || nowNanos <= 0
          || !attemptId.equals(source.get("explicitAttemptId"))
          || !nativeSession.equals(source.get("nativeCaptureSessionId"))
          || !processSession.equals(source.get("processSessionId"))
          || !Long.valueOf(versionCode).equals(source.get("versionCode"))
          || !Long.valueOf(lastUpdateTime).equals(source.get("lastUpdateTime"))
          || source.get("captureSessionId") != null
          || !"explicitLibre2Lifecycle".equals(source.get("sourceKind"))
          || !"libre2".equals(source.get("model"))
          || !"gen1".equals(source.get("securityGeneration"))
          || !"e007".equals(source.get("iso15693ManufacturerPrefix"))) {
        throw new IllegalArgumentException();
      }
      final Object observed = source.get("observedAtMonotonicElapsedNanos");
      if (!(observed instanceof Long) || (Long) observed <= 0 || (Long) observed > nowNanos
          || nowNanos - (Long) observed > MAX_AGE_NANOS
          || !(source.get("observedAtUtc") instanceof String)) throw new IllegalArgumentException();
      final long observedMillis = Instant.parse((String) source.get("observedAtUtc")).toEpochMilli();
      // Positive instants bound subtraction and reject wall-clock rollback beyond the existing skew.
      if (observedMillis <= 0
          || (observedMillis > nowMillis && observedMillis - nowMillis > CLOCK_SKEW_MILLIS)
          || (observedMillis <= nowMillis && nowMillis - observedMillis > MAX_AGE_MILLIS)) {
        throw new IllegalArgumentException();
      }
      uid = bytes(source.get("algorithmOrderUidHex"), 8);
      patch = bytes(source.get("patchInfoHex"), 6);
      fram = bytes(source.get("encryptedFramHex"), 344);
      if ((uid[6] & 255) != 7 || (uid[7] & 255) != 0xe0
          || !sha256(uid).equals(source.get("targetUidSha256"))
          || !sha256(patch).equals(source.get("patchInfoSha256"))) throw new IllegalArgumentException();
      // The fresh NFC patch, not the frozen login patch, decrypts this exact FRAM.
      final int lifecycle = LibreGen1Activation.validatedLifecycle(uid, patch, fram);
      LibreGen1Streaming.requireLifecycle(lifecycle);
      if (receiver == null) return null;
      if (!"confirmed".equals(receiver.state) || !Arrays.equals(uid, receiver.uid)
          || !LibreGen1CalibrationEvidence.matchesReceiverPatch(receiver.initialPatchInfo, patch)) {
        throw new IllegalArgumentException();
      }
      final Map<String, Object> proof = new HashMap<>();
      proof.put("attemptId", attemptId);
      proof.put("event", "receiverReusable");
      proof.put("model", "libre2");
      proof.put("lifecycle", LibreGen1Activation.closedLifecycleName(lifecycle));
      return proof;
    } catch (Exception unavailable) {
      // Do not retain a parser, hash, identity, or private record in a cause/message.
      throw new IOException("Saved receiver verification is unavailable.");
    } finally {
      if (uid != null) Arrays.fill(uid, (byte) 0);
      if (patch != null) Arrays.fill(patch, (byte) 0);
      if (fram != null) Arrays.fill(fram, (byte) 0);
    }
  }

  private static boolean safeToken(String value) {
    return value != null && value.matches("[A-Za-z0-9_-]{8,120}");
  }

  private static byte[] bytes(Object value, int length) {
    if (!(value instanceof String) || !((String) value).matches("[0-9a-f]{" + length * 2 + "}")) {
      throw new IllegalArgumentException();
    }
    final byte[] bytes = new byte[length];
    for (int i = 0; i < length; i++) bytes[i] = (byte) Integer.parseInt(((String) value).substring(i * 2, i * 2 + 2), 16);
    return bytes;
  }

  private static String sha256(byte[] bytes) throws Exception {
    final byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
    final StringBuilder result = new StringBuilder();
    try { for (byte value : digest) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255)); }
    finally { Arrays.fill(digest, (byte) 0); }
    return result.toString();
  }
}
