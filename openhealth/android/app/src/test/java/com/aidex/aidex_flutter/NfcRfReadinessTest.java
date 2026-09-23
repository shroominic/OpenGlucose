package com.aidex.aidex_flutter;

import java.io.File;
import java.nio.file.Files;

/** Standalone JVM checks for distinct host and explicit NFC readiness. */
public final class NfcRfReadinessTest {
  private static final String TARGET =
      "1111111111111111111111111111111111111111111111111111111111111111";

  private NfcRfReadinessTest() {}

  public static void main(String[] arguments) throws Exception {
    explicitAttemptDoesNotDependOnBleEligibility();
    explicitAttemptRequiresEveryExactBinding();
  }

  private static void explicitAttemptDoesNotDependOnBleEligibility()
      throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-readiness-").toFile();
    try {
      final Libre2NfcSetupAttempt attempt = attempt();
      final NfcRfTransactionLeaseBinding binding =
          new NfcRfTransactionLeaseBinding();
      final NfcRfTransactionLease lease =
          NfcRfTransactionLease.tryAcquire(root, "native_explicit_0001");
      check(binding.bindExplicit(attempt, lease), "explicit lease must bind");

      final boolean bleCaptureRfEligible = false;
      check(
          !NfcRfReadiness.isHostReady(
              true,
              true,
              true,
              true,
              bleCaptureRfEligible,
              100L,
              101L,
              6_000L),
          "host-authorized RF must remain blocked when BLE is ineligible");
      check(
          explicitUnclaimedReady(attempt, attempt, binding, true, true),
          "the exact explicit NFC attempt must remain ready without BLE");

      check(
          !attempt.claim(7L, "process_session_1", 12L, 100L, TARGET),
          "an unreserved attempt must not claim any target");
      check(
          attempt.registerTraceReservation(),
          "the exact trace reservation must precede the target claim");
      check(
          attempt.claim(7L, "process_session_1", 12L, 100L, TARGET),
          "the exact attempt must claim its target");
      check(
          NfcRfReadiness.isExplicitClaimedReady(
              true,
              true,
              true,
              true,
              7L,
              7L,
              "process_session_1",
              "process_session_1",
              12L,
              101L,
              TARGET,
              attempt,
              attempt,
              binding,
              true,
              true),
          "the claimed explicit lane must remain authorized without BLE");

      final NfcRfTransactionLease released = binding.takeExplicit(attempt);
      check(released == lease && released.release(), "explicit lease must release");
    } finally {
      root.delete();
    }
  }

  private static void explicitAttemptRequiresEveryExactBinding()
      throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-readiness-").toFile();
    try {
      final Libre2NfcSetupAttempt currentAttempt = attempt();
      final Libre2NfcSetupAttempt staleAttempt =
          new Libre2NfcSetupAttempt(
              "attempt_stale_1", 7L, "process_session_1", 12L, 1_000L);
      final NfcRfTransactionLeaseBinding binding =
          new NfcRfTransactionLeaseBinding();
      final NfcRfTransactionLease lease =
          NfcRfTransactionLease.tryAcquire(root, "native_explicit_0002");
      check(
          binding.bindExplicit(currentAttempt, lease),
          "current explicit lease must bind");

      check(
          !explicitUnclaimedReady(
              currentAttempt, staleAttempt, binding, true, true),
          "a stale attempt object must fail closed");
      check(
          !NfcRfReadiness.isExplicitUnclaimedReady(
              true,
              true,
              true,
              true,
              7L,
              7L,
              "process_session_1",
              "process_session_2",
              12L,
              100L,
              currentAttempt,
              currentAttempt,
              binding,
              true,
              true),
          "a changed Dart process session must fail closed");
      check(
          !explicitUnclaimedReady(
              currentAttempt, currentAttempt, binding, false, true),
          "insufficient trace capacity must fail closed");
      check(
          !explicitUnclaimedReady(
              currentAttempt, currentAttempt, binding, true, false),
          "a host grant or staged grant must fail closed");

      final NfcRfTransactionLease released =
          binding.takeExplicit(currentAttempt);
      check(released == lease && released.release(), "current lease must release");
      check(
          !explicitUnclaimedReady(
              currentAttempt, currentAttempt, binding, true, true),
          "a missing exact explicit lease must fail closed");
    } finally {
      root.delete();
    }
  }

  private static boolean explicitUnclaimedReady(
      Libre2NfcSetupAttempt currentAttempt,
      Libre2NfcSetupAttempt expectedAttempt,
      NfcRfTransactionLeaseBinding binding,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return NfcRfReadiness.isExplicitUnclaimedReady(
        true,
        true,
        true,
        true,
        7L,
        7L,
        "process_session_1",
        "process_session_1",
        12L,
        100L,
        currentAttempt,
        expectedAttempt,
        binding,
        traceCapacityAvailable,
        noHostAuthorizationArtifacts);
  }

  private static Libre2NfcSetupAttempt attempt() {
    return new Libre2NfcSetupAttempt(
        "attempt_current_1", 7L, "process_session_1", 12L, 1_000L);
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
