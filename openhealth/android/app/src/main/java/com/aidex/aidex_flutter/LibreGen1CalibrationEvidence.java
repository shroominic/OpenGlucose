package com.aidex.aidex_flutter;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Restricted historical factory evidence. This cannot authorize RF or establish current state. */
final class LibreGen1CalibrationEvidence implements AutoCloseable {
  private static final Set<String> V1_KEYS = new HashSet<>(Arrays.asList(
      "schemaVersion", "nativeCaptureSessionId", "processSessionId", "captureSessionId",
      "versionCode", "lastUpdateTime", "targetUidSha256", "iso15693ManufacturerPrefix",
      "patchInfoSha256", "model", "securityGeneration", "algorithmOrderUidHex",
      "patchInfoHex", "encryptedFramHex", "observedAtUtc", "observedAtMonotonicElapsedNanos"));
  private static final Set<String> V2_KEYS = new HashSet<>(V1_KEYS);
  static { V2_KEYS.add("sourceKind"); V2_KEYS.add("explicitAttemptId"); }

  final String bootstrapId;
  private final byte[] uid;
  private final byte[] receiverPatch;
  private final byte[] calibrationPatch;
  private final byte[] fram;
  private boolean closed;

  private LibreGen1CalibrationEvidence(String id, byte[] uid, byte[] receiverPatch,
      byte[] calibrationPatch, byte[] fram) {
    if (id == null || !id.matches("[A-Za-z0-9_-]{16,128}")
        || uid == null || uid.length != 8 || (uid[6] & 255) != 7 || (uid[7] & 255) != 0xe0
        || !matchesReceiverPatch(receiverPatch, calibrationPatch)) {
      throw new IllegalArgumentException("Calibration evidence is unavailable.");
    }
    // Only the exact Gen1 Libre 2 allowlist is accepted. All three FRAM CRCs
    // are checked, but the historical lifecycle byte is deliberately ignored.
    LibreGen1Activation.validatedLifecycle(uid, calibrationPatch, fram);
    bootstrapId = id;
    this.uid = uid.clone(); this.receiverPatch = receiverPatch.clone();
    this.calibrationPatch = calibrationPatch.clone(); this.fram = fram.clone();
  }

  static LibreGen1CalibrationEvidence verified(String id, byte[] uid, byte[] patch, byte[] fram) {
    return verified(id, uid, patch, patch, fram);
  }

  static LibreGen1CalibrationEvidence verified(String id, byte[] uid, byte[] receiverPatch,
      byte[] calibrationPatch, byte[] fram) {
    return new LibreGen1CalibrationEvidence(id, uid, receiverPatch, calibrationPatch, fram);
  }

  /** Only the FRAM key bytes may differ; receiver identity/type/security/region stay fixed. */
  static boolean matchesReceiverPatch(byte[] receiverPatch, byte[] calibrationPatch) {
    if (receiverPatch == null || calibrationPatch == null
        || receiverPatch.length != 6 || calibrationPatch.length != 6) return false;
    for (int i = 0; i < 4; i++) if (receiverPatch[i] != calibrationPatch[i]) return false;
    return true;
  }

  static LibreGen1CalibrationEvidence fromCapture(String json, String id,
      byte[] expectedUid, byte[] expectedPatch) throws Exception {
    byte[] uid = null, patch = null, fram = null;
    try {
      final Map<String, Object> value = Libre2ActivationUiProof.parse(json);
      final boolean v1 = Long.valueOf(1).equals(value.get("schemaVersion"));
      final boolean v2 = Long.valueOf(2).equals(value.get("schemaVersion"));
      if ((!v1 && !v2) || !value.keySet().equals(v1 ? V1_KEYS : V2_KEYS)
          || !"libre2".equals(value.get("model")) || !"gen1".equals(value.get("securityGeneration"))
          || !"e007".equals(value.get("iso15693ManufacturerPrefix"))
          || !matches(value, "nativeCaptureSessionId", "[A-Za-z0-9_-]{8,120}")
          || !matches(value, "processSessionId", "[A-Za-z0-9_-]{8,120}")
          || (v1 ? !matches(value, "captureSessionId", "session-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{1,32}")
              : value.get("captureSessionId") != null
                  || !"explicitLibre2Lifecycle".equals(value.get("sourceKind"))
                  || !matches(value, "explicitAttemptId", "[A-Za-z0-9_-]{8,120}"))) {
        throw new IllegalArgumentException();
      }
      for (String key : new String[] {"versionCode", "lastUpdateTime", "observedAtMonotonicElapsedNanos"}) {
        if (!(value.get(key) instanceof Long) || (Long) value.get(key) <= 0) throw new IllegalArgumentException();
      }
      if (!(value.get("observedAtUtc") instanceof String)
          || Instant.parse((String) value.get("observedAtUtc")).toEpochMilli() <= 0) throw new IllegalArgumentException();
      uid = hex(value.get("algorithmOrderUidHex"), 8);
      patch = hex(value.get("patchInfoHex"), 6);
      fram = hex(value.get("encryptedFramHex"), 344);
      if (!Arrays.equals(uid, expectedUid) || !matchesReceiverPatch(expectedPatch, patch)
          || !sha256(uid).equals(value.get("targetUidSha256"))
          || !sha256(patch).equals(value.get("patchInfoSha256"))) throw new IllegalArgumentException();
      return verified(id, uid, expectedPatch, patch, fram);
    } catch (Exception invalid) {
      // Never retain a cause containing a private field or parser input.
      throw new IOException("Calibration evidence is unavailable.");
    } finally { wipe(uid); wipe(patch); wipe(fram); }
  }

  byte[] encode() throws IOException {
    requireOpen();
    final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    final DataOutputStream out = new DataOutputStream(bytes);
    // The protected envelope/key/file stay unchanged. Version 2 separates the
    // frozen BLE receiver patch from the current NFC FRAM decryption patch.
    out.writeInt(2); out.writeUTF(bootstrapId); out.write(uid);
    out.write(receiverPatch); out.write(calibrationPatch); out.write(fram);
    out.flush();
    return bytes.toByteArray();
  }

  static LibreGen1CalibrationEvidence decode(byte[] encoded, String id,
      byte[] expectedUid, byte[] expectedPatch) throws IOException {
    byte[] uid = new byte[8], receiverPatch = new byte[6], calibrationPatch = new byte[6], fram = new byte[344];
    try {
      if (encoded == null || encoded.length > 512) throw new IllegalArgumentException();
      final DataInputStream in = new DataInputStream(new ByteArrayInputStream(encoded));
      final int version = in.readInt();
      if ((version != 1 && version != 2) || !in.readUTF().equals(id)) throw new IllegalArgumentException();
      in.readFully(uid); in.readFully(receiverPatch);
      if (version == 2) in.readFully(calibrationPatch);
      else System.arraycopy(receiverPatch, 0, calibrationPatch, 0, 6);
      in.readFully(fram);
      if (in.available() != 0 || !Arrays.equals(uid, expectedUid) || !Arrays.equals(receiverPatch, expectedPatch)) {
        throw new IllegalArgumentException();
      }
      return verified(id, uid, receiverPatch, calibrationPatch, fram);
    } catch (Exception invalid) {
      throw new IOException("Calibration evidence is unavailable.");
    } finally { wipe(uid); wipe(receiverPatch); wipe(calibrationPatch); wipe(fram); }
  }

  byte[] uid() { requireOpen(); return uid.clone(); }
  byte[] receiverInitialPatchInfo() { requireOpen(); return receiverPatch.clone(); }
  byte[] calibrationPatchInfo() { requireOpen(); return calibrationPatch.clone(); }
  byte[] encryptedFram() { requireOpen(); return fram.clone(); }
  private void requireOpen() { if (closed) throw new IllegalStateException("Calibration evidence is closed."); }
  @Override public void close() { closed = true; wipe(uid); wipe(receiverPatch); wipe(calibrationPatch); wipe(fram); }
  @Override public String toString() { return "LibreCalibrationEvidence(<redacted>)"; }
  private static void wipe(byte[] bytes) { if (bytes != null) Arrays.fill(bytes, (byte) 0); }
  private static boolean matches(Map<String, Object> map, String key, String pattern) {
    return map.get(key) instanceof String && ((String) map.get(key)).matches(pattern);
  }
  private static byte[] hex(Object value, int length) {
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
    finally { wipe(digest); }
    return result.toString();
  }
}
