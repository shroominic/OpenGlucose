package com.aidex.aidex_flutter;

import java.util.HashMap;
import java.util.Map;

/** Synthetic read-only proof validation; no device identifiers or health fixtures. */
public final class Libre2ActivationUiProofTest {
  private static final long NOW = 1788652800000L;
  private static final String HASH = "a".repeat(64);
  private static final String ATTEMPT = "synthetic_nfc_attempt";

  public static void main(String[] arguments) {
    verifiedProofOnly();
    historicalDoesNotClaimCurrentBindings();
    exactSourceBindings();
    strictScalarParser();
    System.out.println("Libre activation UI proof synthetic checks passed.");
  }

  private static void verifiedProofOnly() {
    final Map<String, Object> proof = journal();
    check(Libre2ActivationUiProof.verified(proof, NOW), "Verified record rejected");
    for (String key : proof.keySet()) {
      final Map<String, Object> missing = new HashMap<>(proof);
      missing.remove(key);
      check(!Libre2ActivationUiProof.verified(missing, NOW), "Missing journal field accepted");
      final Map<String, Object> malformed = new HashMap<>(proof);
      malformed.put(key, new Object());
      check(!Libre2ActivationUiProof.verified(malformed, NOW), "Mistyped journal field accepted");
    }
    for (String state : new String[] {"prepared", "transmit_intent_committed", "response_received", "unknown_outcome"}) {
      final Map<String, Object> changed = new HashMap<>(proof);
      changed.put("state", state);
      check(!Libre2ActivationUiProof.verified(changed, NOW), "Unverified state accepted");
    }
    for (String key : new String[] {"outcome", "lifecycle", "operation"}) {
      final Map<String, Object> changed = new HashMap<>(proof);
      changed.put(key, "unknown");
      check(!Libre2ActivationUiProof.verified(changed, NOW), "Unproven outcome accepted");
    }
    final Map<String, Object> extra = new HashMap<>(proof);
    extra.put("rawValue", "forbidden");
    check(!Libre2ActivationUiProof.verified(extra, NOW), "Extra journal field accepted");
    final Map<String, Object> future = new HashMap<>(proof);
    future.put("updatedAtUtc", "2099-01-01T00:00:00Z");
    check(!Libre2ActivationUiProof.verified(future, NOW), "Future journal accepted");
  }

  private static void historicalDoesNotClaimCurrentBindings() {
    final Map<String, Object> previousBuild = journal();
    previousBuild.put("versionCode", 5L);
    check(Libre2ActivationUiProof.verified(previousBuild, NOW), "Historical verification lost on rebuild");
    check(!bindings(previousBuild, source()), "Historical result was treated as current sensor binding");
  }

  private static void exactSourceBindings() {
    check(bindings(journal(), source()), "Exact source was rejected");
    final Map<String, Object> source = source();
    for (String key : new String[] {"schemaVersion", "sourceKind", "explicitAttemptId", "model",
        "securityGeneration", "iso15693ManufacturerPrefix", "nativeCaptureSessionId",
        "processSessionId", "versionCode", "lastUpdateTime", "captureSessionId", "patchInfoSha256"}) {
      final Map<String, Object> altered = new HashMap<>(source);
      altered.put(key, "wrong");
      check(!bindings(journal(), altered), "Mismatched source was accepted");
    }
    final Map<String, Object> changed = journal();
    changed.put("sourceFramCaptureSha256", "b".repeat(64));
    check(!bindings(changed, source), "Replaced source artifact was accepted");
    check(!Libre2ActivationUiProof.currentBindings(journal(), source, "other_attempt",
        "synthetic_native", "synthetic_process", 40, 1000, HASH), "Unrelated UI attempt accepted");
  }

  private static boolean bindings(Map<String, Object> journal, Map<String, Object> source) {
    return Libre2ActivationUiProof.currentBindings(journal, source, ATTEMPT,
        "synthetic_native", "synthetic_process", 40, 1000, HASH);
  }

  private static void strictScalarParser() {
    final Map<String, Object> result = Libre2ActivationUiProof.parse(" {\"text\":\"hello\",\"n\":12,\"nullable\":null} ");
    check(result.get("n").equals(12L) && result.containsKey("nullable"), "Scalar JSON mismatch");
    for (String malformed : new String[] {
        "{\"state\":\"verified\",\"state\":\"unknown\"}",
        "{\"state\":\"verified\",\"st\\u0061te\":\"unknown\"}",
        "{\"n\":01}", "{\"n\":1.0}", "{\"n\":1e3}", "{\"n\":true}",
        "{\"n\":[]}", "{\"n\":{}}", "{\"n\":null,}", "{\"n\":1} trailing",
        "{\"n\":9223372036854775808}", "{unquoted:1}", "{'single':1}",
        "{\"n\":\"bad\\x\"}", "{\"n\":\"line\nfeed\"}", " ".repeat(4097)}) {
      boolean rejected = false;
      try { Libre2ActivationUiProof.parse(malformed); }
      catch (IllegalArgumentException expected) { rejected = true; }
      check(rejected, "Malformed JSON was accepted");
    }
  }

  private static Map<String, Object> journal() {
    final Map<String, Object> value = new HashMap<>();
    value.put("schemaVersion", 1L);
    value.put("operation", "target_unverified_gen1_activation");
    value.put("attemptId", "activation-" + "0".repeat(32));
    value.put("state", "post_state_verified");
    value.put("outcome", "verified");
    value.put("nativeCaptureSessionId", "synthetic_native");
    value.put("processSessionId", "synthetic_process");
    value.put("versionCode", 40L);
    value.put("lastUpdateTime", 1000L);
    value.put("captureSessionId", "session-synthetic-1234");
    value.put("patchInfoSha256", HASH);
    value.put("plannedRequestSha256", HASH);
    value.put("sourceFramCaptureSha256", HASH);
    value.put("sourceEncryptedFramSha256", HASH);
    value.put("lifecycle", "warmingUp");
    value.put("updatedAtUtc", "2026-09-05T00:00:00Z");
    value.put("updatedAtMonotonicElapsedNanos", 123456L);
    return value;
  }

  private static Map<String, Object> source() {
    final Map<String, Object> value = new HashMap<>();
    value.put("schemaVersion", 2L);
    value.put("nativeCaptureSessionId", "synthetic_native");
    value.put("processSessionId", "synthetic_process");
    value.put("captureSessionId", "session-synthetic-1234");
    value.put("sourceKind", "explicitLibre2Lifecycle");
    value.put("explicitAttemptId", ATTEMPT);
    value.put("versionCode", 40L);
    value.put("lastUpdateTime", 1000L);
    value.put("targetUidSha256", HASH);
    value.put("iso15693ManufacturerPrefix", "e007");
    value.put("patchInfoSha256", HASH);
    value.put("model", "libre2");
    value.put("securityGeneration", "gen1");
    value.put("algorithmOrderUidHex", "synthetic");
    value.put("patchInfoHex", "synthetic");
    value.put("encryptedFramHex", "synthetic");
    value.put("observedAtUtc", "2026-09-05T00:00:00Z");
    value.put("observedAtMonotonicElapsedNanos", 123000L);
    return value;
  }

  private static void check(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
}
