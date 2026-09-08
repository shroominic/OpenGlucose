package com.aidex.aidex_flutter;

import java.util.HashMap;
import java.util.Map;

/** Standalone JVM checks for stale published NFC grant reconciliation. */
public final class NfcPublishedGrantEnvelopeTest {
  private static final long NOW = 1_000_000L;
  private static final String SHA =
      "1111111111111111111111111111111111111111111111111111111111111111";

  private NfcPublishedGrantEnvelopeTest() {}

  public static void main(String[] arguments) {
    preservesCurrentFramGrant();
    preservesFiveMinuteFramGrant();
    rejectsFramGrantOverFiveMinutes();
    rejectsExpiredFramGrant();
    rejectsUnreadableOrMalformedGrantFields();
    rejectsCrossSessionGrant();
    preservesCurrentActivationGrant();
    rejectsFiveMinuteActivationGrant();
    rejectsFiveMinutePatchGrant();
  }

  private static void preservesCurrentFramGrant() {
    check(
        validate(
            NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ,
            framGrant(NOW - 1_000L, NOW + 89_000L)),
        "a current exact FRAM grant must be preserved");
  }

  private static void preservesFiveMinuteFramGrant() {
    final long issuedAt = NOW - 1_000L;
    check(
        validate(
            NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ,
            framGrant(issuedAt, issuedAt + 300_000L)),
        "an exact five-minute FRAM read grant must be preserved");
  }

  private static void rejectsFramGrantOverFiveMinutes() {
    final long issuedAt = NOW - 1_000L;
    check(
        !validate(
            NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ,
            framGrant(issuedAt, issuedAt + 300_001L)),
        "a FRAM read grant over five minutes must fail closed");
  }

  private static void rejectsExpiredFramGrant() {
    check(
        !validate(
            NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ,
            framGrant(NOW - 91_000L, NOW - 1_000L)),
        "an expired FRAM grant must be removable before explicit setup");
  }

  private static void rejectsUnreadableOrMalformedGrantFields() {
    final Map<String, Object> malformed =
        framGrant(NOW - 1_000L, NOW + 89_000L);
    malformed.put("expiresAtEpochMillis", "not-an-integer");
    check(
        !validate(NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ, malformed),
        "a read-invalid grant must be removable");

    final Map<String, Object> extraField =
        framGrant(NOW - 1_000L, NOW + 89_000L);
    extraField.put("unexpected", true);
    check(
        !validate(NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ, extraField),
        "an envelope with unknown fields must fail closed");
  }

  private static void rejectsCrossSessionGrant() {
    final Map<String, Object> grant =
        framGrant(NOW - 1_000L, NOW + 89_000L);
    grant.put("processSessionId", "process_session_other");
    check(
        !validate(NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ, grant),
        "a cross-session grant must not block a new explicit attempt");
  }

  private static void preservesCurrentActivationGrant() {
    final Map<String, Object> grant =
        activationGrant(NOW - 1_000L, NOW + 89_000L);
    check(
        validate(
            NfcPublishedGrantEnvelope.Kind.GEN1_ACTIVATION,
            grant),
        "a current state-changing grant must never be reconciled away");
  }

  private static void rejectsFiveMinuteActivationGrant() {
    final long issuedAt = NOW - 1_000L;
    check(
        !validate(
            NfcPublishedGrantEnvelope.Kind.GEN1_ACTIVATION,
            activationGrant(issuedAt, issuedAt + 300_000L)),
        "activation must keep the existing short maximum lifetime");
  }

  private static void rejectsFiveMinutePatchGrant() {
    final long issuedAt = NOW - 1_000L;
    check(
        !validate(
            NfcPublishedGrantEnvelope.Kind.PATCH_INFO,
            patchGrant(issuedAt, issuedAt + 300_000L)),
        "patch probes must keep the existing short maximum lifetime");
  }

  private static Map<String, Object> activationGrant(
      long issuedAt, long expiresAt) {
    final Map<String, Object> grant = framGrant(issuedAt, expiresAt);
    grant.put("operation", "target_unverified_gen1_activation");
    grant.put("model", "libre2");
    grant.put("securityGeneration", "gen1");
    grant.put("attemptId", "activation-11111111111111111111111111111111");
    grant.put("sourceFramCaptureSha256", SHA);
    grant.put("sourceEncryptedFramSha256", SHA);
    grant.put("validatedLifecycle", "notActivated");
    grant.put("plannedRequestSha256", SHA);
    return grant;
  }

  private static Map<String, Object> patchGrant(
      long issuedAt, long expiresAt) {
    final Map<String, Object> grant = framGrant(issuedAt, expiresAt);
    grant.remove("patchInfoSha256");
    grant.put("operation", "target_unverified_patch_info_probe");
    return grant;
  }

  private static Map<String, Object> framGrant(long issuedAt, long expiresAt) {
    final Map<String, Object> grant = new HashMap<>();
    grant.put("schemaVersion", 1);
    grant.put("nonce", "grant_nonce_current");
    grant.put("nativeCaptureSessionId", "native_session_current");
    grant.put("processSessionId", "process_session_current");
    grant.put("versionCode", 22L);
    grant.put("lastUpdateTime", 1234L);
    grant.put("targetUidSha256", SHA);
    grant.put("iso15693ManufacturerPrefix", "e007");
    grant.put("patchInfoSha256", SHA);
    grant.put("operation", "target_unverified_gen1_fram_read");
    grant.put("sessionId", "session-20260902T010203Z-test");
    grant.put("issuedAtEpochMillis", issuedAt);
    grant.put("expiresAtEpochMillis", expiresAt);
    return grant;
  }

  private static boolean validate(
      NfcPublishedGrantEnvelope.Kind kind, Map<String, Object> grant) {
    final String operation =
        kind == NfcPublishedGrantEnvelope.Kind.GEN1_ACTIVATION
            ? "target_unverified_gen1_activation"
            : kind == NfcPublishedGrantEnvelope.Kind.PATCH_INFO
                ? "target_unverified_patch_info_probe"
                : "target_unverified_gen1_fram_read";
    return NfcPublishedGrantEnvelope.isCurrentAndUnexpired(
        kind,
        grant,
        1,
        operation,
        "grant_nonce_current",
        "native_session_current",
        "process_session_current",
        22L,
        1234L,
        "e007",
        NOW,
        5_000L,
        120_000L,
        300_000L);
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
