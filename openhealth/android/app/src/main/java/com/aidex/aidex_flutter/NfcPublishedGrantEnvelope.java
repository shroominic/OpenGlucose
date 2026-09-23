package com.aidex.aidex_flutter;

import java.util.Map;

/** Pure validation for a published host NFC authorization envelope. */
final class NfcPublishedGrantEnvelope {
  enum Kind {
    PATCH_INFO,
    GEN1_FRAM_READ,
    GEN1_ACTIVATION,
  }

  private static final String LOWER_SHA256 = "^[0-9a-f]{64}$";
  private static final String CAPTURE_SESSION =
      "^session-[A-Za-z0-9-]{10,80}$";

  private NfcPublishedGrantEnvelope() {}

  static boolean isCurrentAndUnexpired(
      Kind kind,
      Map<String, ?> fields,
      int schemaVersion,
      String operation,
      String nonce,
      String nativeCaptureSessionId,
      String processSessionId,
      long versionCode,
      long lastUpdateTime,
      String manufacturerPrefix,
      long nowEpochMillis,
      long maxClockSkewMillis,
      long maxStandardLifetimeMillis,
      long maxGen1FramReadLifetimeMillis) {
    if (kind == null
        || fields == null
        || integer(fields, "schemaVersion") != schemaVersion
        || !operation.equals(string(fields, "operation"))
        || !nonce.equals(string(fields, "nonce"))
        || !nativeCaptureSessionId.equals(
            string(fields, "nativeCaptureSessionId"))
        || !processSessionId.equals(string(fields, "processSessionId"))
        || integer(fields, "versionCode") != versionCode
        || integer(fields, "lastUpdateTime") != lastUpdateTime
        || !matches(fields, "targetUidSha256", LOWER_SHA256)
        || !manufacturerPrefix.equals(
            string(fields, "iso15693ManufacturerPrefix"))
        || !matches(fields, "sessionId", CAPTURE_SESSION)) {
      return false;
    }

    final long maxLifetimeMillis =
        kind == Kind.GEN1_FRAM_READ
            ? maxGen1FramReadLifetimeMillis
            : maxStandardLifetimeMillis;
    final Long issuedAt = nullableInteger(fields, "issuedAtEpochMillis");
    final Long expiresAt = nullableInteger(fields, "expiresAtEpochMillis");
    if (issuedAt == null
        || expiresAt == null
        || issuedAt <= 0L
        || issuedAt > nowEpochMillis + maxClockSkewMillis
        || expiresAt <= nowEpochMillis
        || expiresAt <= issuedAt
        || expiresAt - issuedAt > maxLifetimeMillis) {
      return false;
    }

    switch (kind) {
      case PATCH_INFO:
        return fields.size() == 12;
      case GEN1_FRAM_READ:
        return fields.size() == 13
            && matches(fields, "patchInfoSha256", LOWER_SHA256);
      case GEN1_ACTIVATION:
        return fields.size() == 20
            && matches(fields, "patchInfoSha256", LOWER_SHA256)
            && "libre2".equals(string(fields, "model"))
            && "gen1".equals(string(fields, "securityGeneration"))
            && matches(fields, "attemptId", "^activation-[0-9a-f]{32}$")
            && matches(fields, "sourceFramCaptureSha256", LOWER_SHA256)
            && matches(fields, "sourceEncryptedFramSha256", LOWER_SHA256)
            && "notActivated".equals(
                string(fields, "validatedLifecycle"))
            && matches(fields, "plannedRequestSha256", LOWER_SHA256);
      default:
        return false;
    }
  }

  private static boolean matches(
      Map<String, ?> fields, String key, String pattern) {
    final String value = string(fields, key);
    return value != null && value.matches(pattern);
  }

  private static String string(Map<String, ?> fields, String key) {
    final Object value = fields.get(key);
    return value instanceof String ? (String) value : null;
  }

  private static long integer(Map<String, ?> fields, String key) {
    final Long value = nullableInteger(fields, key);
    return value == null ? Long.MIN_VALUE : value;
  }

  private static Long nullableInteger(Map<String, ?> fields, String key) {
    final Object value = fields.get(key);
    if (!(value instanceof Byte)
        && !(value instanceof Short)
        && !(value instanceof Integer)
        && !(value instanceof Long)) {
      return null;
    }
    return ((Number) value).longValue();
  }
}
