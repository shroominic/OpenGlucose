package com.aidex.aidex_flutter;

import java.io.IOException;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.Collections;
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

  interface Delivery { void accept(Map<String, Object> value) throws Exception; }

  /** Owned restricted bytes. Delivery is single-use and wipes its borrowed map buffers. */
  static final class FreshHistoryEvidence implements AutoCloseable {
    private final String attemptId;
    private final String bootstrapId;
    private final String observedAtUtc;
    private final long observedAtNanos;
    private final byte[] uid;
    private final byte[] receiverPatch;
    private final byte[] currentPatch;
    private final byte[] fram;
    private boolean closed;

    private FreshHistoryEvidence(String attemptId, String bootstrapId,
        String observedAtUtc, long observedAtNanos, byte[] uid, byte[] receiverPatch,
        byte[] currentPatch, byte[] fram) {
      this.attemptId = attemptId;
      this.bootstrapId = bootstrapId;
      this.observedAtUtc = observedAtUtc;
      this.observedAtNanos = observedAtNanos;
      this.uid = uid.clone();
      this.receiverPatch = receiverPatch.clone();
      this.currentPatch = currentPatch.clone();
      this.fram = fram.clone();
    }

    /**
     * Recheck the exact current receiver and original receipt at point of delivery.
     * The caller separately holds/rechecks its epoch, generation and idle RF owner.
     * The consumer must synchronously encode/copy the map; no mutable buffer is
     * retained after it returns. The method channel uses synchronous encoding.
     */
    void deliver(LibreGen1StreamingJournal.Record receiver, long nowMillis,
        long nowNanos, Delivery delivery) throws IOException {
      final Map<String, Object> value = new HashMap<>();
      try {
        if (closed || receiver == null || !"confirmed".equals(receiver.state)
            || !bootstrapId.equals(receiver.bootstrapId)
            || !Arrays.equals(uid, receiver.uid)
            || !Arrays.equals(receiverPatch, receiver.initialPatchInfo)) {
          throw new IllegalArgumentException();
        }
        requireFresh(observedAtUtc, observedAtNanos, nowMillis, nowNanos);
        // Consume before calling external code. A nested/repeated delivery must fail.
        closed = true;
        value.put("attemptId", attemptId);
        value.put("bootstrapId", bootstrapId);
        value.put("uid", uid);
        value.put("receiverInitialPatchInfo", receiverPatch);
        value.put("currentPatchInfo", currentPatch);
        value.put("encryptedFram", fram);
        value.put("observedAtUtc", observedAtUtc);
        delivery.accept(Collections.unmodifiableMap(value));
      } catch (Exception unavailable) {
        throw unavailable();
      } finally {
        close();
        value.clear();
      }
    }

    @Override public void close() {
      closed = true;
      Arrays.fill(uid, (byte) 0);
      Arrays.fill(receiverPatch, (byte) 0);
      Arrays.fill(currentPatch, (byte) 0);
      Arrays.fill(fram, (byte) 0);
    }

    @Override public String toString() {
      return "LibreGen1FreshHistoryEvidence(data: <redacted>)";
    }
  }

  /**
   * Validates with the existing strict reuse proof, then extracts from that SAME
   * immutable JSON string. It never rereads a file, searches captures, or uses
   * calibration cache state as fresh evidence. An absent receiver is an error.
   */
  static FreshHistoryEvidence readFreshHistory(String sourceJson,
      LibreGen1StreamingJournal.Record receiver, String attemptId, String bootstrapId,
      String nativeSession, String processSession, long versionCode, long lastUpdateTime,
      long nowMillis, long nowNanos) throws IOException {
    byte[] uid = null, patch = null, fram = null;
    try {
      if (receiver == null || !safeToken(bootstrapId)
          || !bootstrapId.equals(receiver.bootstrapId)) throw new IllegalArgumentException();
      if (read(sourceJson, receiver, attemptId, nativeSession, processSession,
          versionCode, lastUpdateTime, nowMillis, nowNanos) == null) {
        throw new IllegalArgumentException();
      }
      final Map<String, Object> source = Libre2ActivationUiProof.parse(sourceJson);
      uid = bytes(source.get("algorithmOrderUidHex"), 8);
      patch = bytes(source.get("patchInfoHex"), 6);
      fram = bytes(source.get("encryptedFramHex"), 344);
      return new FreshHistoryEvidence(attemptId, bootstrapId,
          (String) source.get("observedAtUtc"),
          (Long) source.get("observedAtMonotonicElapsedNanos"),
          uid, receiver.initialPatchInfo, patch, fram);
    } catch (Exception unavailable) {
      throw unavailable();
    } finally {
      if (uid != null) Arrays.fill(uid, (byte) 0);
      if (patch != null) Arrays.fill(patch, (byte) 0);
      if (fram != null) Arrays.fill(fram, (byte) 0);
    }
  }

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
      requireFresh(source.get("observedAtUtc"), source.get("observedAtMonotonicElapsedNanos"),
          nowMillis, nowNanos);
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

  private static void requireFresh(Object observedUtc, Object observedNanos,
      long nowMillis, long nowNanos) {
    if (nowMillis <= 0 || nowNanos <= 0 || !(observedNanos instanceof Long)
        || (Long) observedNanos <= 0 || (Long) observedNanos > nowNanos
        || nowNanos - (Long) observedNanos > MAX_AGE_NANOS
        || !(observedUtc instanceof String)) throw new IllegalArgumentException();
    final long observedMillis = Instant.parse((String) observedUtc).toEpochMilli();
    // Positive instants bound subtraction and preserve the existing skew policy.
    if (observedMillis <= 0
        || (observedMillis > nowMillis && observedMillis - nowMillis > CLOCK_SKEW_MILLIS)
        || (observedMillis <= nowMillis && nowMillis - observedMillis > MAX_AGE_MILLIS)) {
      throw new IllegalArgumentException();
    }
  }

  private static IOException unavailable() {
    return new IOException("Saved receiver verification is unavailable.");
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
