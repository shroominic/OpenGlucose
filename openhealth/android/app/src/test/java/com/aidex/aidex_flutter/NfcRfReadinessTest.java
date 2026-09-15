package com.aidex.aidex_flutter;

import java.io.File;
import java.nio.file.Files;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Standalone JVM checks for distinct host and explicit NFC readiness. */
public final class NfcRfReadinessTest {
  private static final String TARGET =
      "1111111111111111111111111111111111111111111111111111111111111111";

  private NfcRfReadinessTest() {}

  public static void main(String[] arguments) throws Exception {
    explicitAttemptDoesNotDependOnBleEligibility();
    explicitAttemptRequiresEveryExactBinding();
    successfulReadWaitsForCallbackDrain();
    failedCleanupCannotDeliverSuccess();
    callbackCompletionIsSingleUse();
  }

  private static void successfulReadWaitsForCallbackDrain() throws Exception {
    final NfcRfReadiness.CallbackCompletion completion =
        new NfcRfReadiness.CallbackCompletion();
    final CountDownLatch readCompleted = new CountDownLatch(1);
    final CountDownLatch allowCallbackDrain = new CountDownLatch(1);
    final AtomicBoolean callbackActive = new AtomicBoolean(true);
    final AtomicBoolean buffersCleared = new AtomicBoolean(false);
    final AtomicBoolean successDelivered = new AtomicBoolean(false);
    final AtomicReference<Throwable> failure = new AtomicReference<>();
    final Thread callback = new Thread(() -> {
      try {
        completion.defer(() -> {
          // This models an immediate fresh-evidence query from the delivered
          // metadata event. The callback-active guard remains strict.
          check(!callbackActive.get(), "success must follow callback drain");
          check(buffersCleared.get(), "read buffers must be cleared before success");
          successDelivered.set(true);
        });
        readCompleted.countDown();
        check(allowCallbackDrain.await(5, TimeUnit.SECONDS), "callback drain gate timed out");
        buffersCleared.set(true);
        completion.finish(() -> callbackActive.set(false));
      } catch (Throwable error) {
        failure.set(error);
      }
    }, "synthetic-nfc-callback");
    callback.start();
    try {
      check(readCompleted.await(5, TimeUnit.SECONDS), "read completion gate timed out");
      check(callbackActive.get(), "the gated callback must still be active");
      check(!successDelivered.get(), "metadata must not overtake callback cleanup");
    } finally {
      allowCallbackDrain.countDown();
      callback.join(5_000L);
    }
    check(!callback.isAlive(), "the synthetic callback must finish");
    if (failure.get() != null) throw new AssertionError("callback handoff failed", failure.get());
    check(successDelivered.get(), "success must be delivered after confirmed drain");
  }

  private static void failedCleanupCannotDeliverSuccess() {
    final NfcRfReadiness.CallbackCompletion completion =
        new NfcRfReadiness.CallbackCompletion();
    final AtomicBoolean delivered = new AtomicBoolean(false);
    completion.defer(() -> delivered.set(true));
    try {
      completion.finish(() -> { throw new IllegalStateException("synthetic cleanup failure"); });
      throw new AssertionError("cleanup failure must propagate");
    } catch (IllegalStateException expected) {
      check(!delivered.get(), "failed cleanup must suppress success");
    }
    completion.finish(() -> {});
    check(!delivered.get(), "a failed cleanup cannot later replay success");
  }

  private static void callbackCompletionIsSingleUse() {
    final NfcRfReadiness.CallbackCompletion completion =
        new NfcRfReadiness.CallbackCompletion();
    final AtomicInteger deliveries = new AtomicInteger();
    final AtomicInteger cleanups = new AtomicInteger();
    completion.defer(() -> {
      deliveries.incrementAndGet();
      completion.finish(cleanups::incrementAndGet);
    });
    completion.finish(cleanups::incrementAndGet);
    completion.finish(cleanups::incrementAndGet);
    check(deliveries.get() == 1 && cleanups.get() == 1, "completion and drain must be single-use");
    try {
      completion.defer(deliveries::incrementAndGet);
      throw new AssertionError("a finished callback cannot accept another completion");
    } catch (IllegalStateException expected) {
      check(deliveries.get() == 1, "late completion must not be delivered");
    }
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
