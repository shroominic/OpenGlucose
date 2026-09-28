package com.aidex.aidex_flutter;

import java.io.File;
import java.nio.file.Files;

/** Standalone JVM checks for exact attempt-to-lease ownership. */
public final class NfcRfTransactionLeaseBindingTest {
  private NfcRfTransactionLeaseBindingTest() {}

  public static void main(String[] arguments) throws Exception {
    staleAttemptCannotReleaseReopenedAttempt();
    hostAndExplicitOwnershipStayDistinct();
    maintenancePromotionRequiresExactLaneOrAttempt();
  }

  private static void staleAttemptCannotReleaseReopenedAttempt()
      throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-binding-").toFile();
    try {
      final NfcRfTransactionLeaseBinding binding =
          new NfcRfTransactionLeaseBinding();
      final Libre2NfcSetupAttempt attemptA = attempt("attempt_A_123");
      final NfcRfTransactionLease leaseA =
          NfcRfTransactionLease.tryAcquire(root, "native_owner_A001");
      check(binding.bindExplicit(attemptA, leaseA), "attempt A must bind");
      final NfcRfTransactionLease stoppedA = binding.takeExplicit(attemptA);
      check(stoppedA == leaseA && stoppedA.release(), "stopping A releases A");

      final Libre2NfcSetupAttempt attemptB = attempt("attempt_B_123");
      final NfcRfTransactionLease leaseB =
          NfcRfTransactionLease.tryAcquire(root, "native_owner_B001");
      check(binding.bindExplicit(attemptB, leaseB), "attempt B must bind");

      check(
          binding.takeExplicit(attemptA) == null,
          "stale A unwind must not take B's lease");
      check(
          binding.isHeldByExplicitAttempt(attemptB),
          "B must remain authorized after stale A unwind");
      final NfcRfTransactionLease completedB =
          binding.takeExplicit(attemptB);
      check(
          completedB == leaseB && completedB.release(),
          "B must release only its own lease");
    } finally {
      root.delete();
    }
  }

  private static void hostAndExplicitOwnershipStayDistinct()
      throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-binding-").toFile();
    try {
      final NfcRfTransactionLeaseBinding binding =
          new NfcRfTransactionLeaseBinding();
      final NfcRfTransactionLease hostLease =
          NfcRfTransactionLease.tryAcquire(root, "native_host_0001");
      check(binding.bindHost(hostLease), "host lease must bind");
      check(
          binding.isHeldByHost(hostLease),
          "host lease must require its exact token");
      check(
          binding.takeExplicit(attempt("attempt_C_123")) == null,
          "an explicit attempt cannot take a host lease");
      final NfcRfTransactionLease released = binding.takeHost(hostLease);
      check(
          released == hostLease && released.release(),
          "host release must require exact host lease identity");
    } finally {
      root.delete();
    }
  }

  private static void maintenancePromotionRequiresExactLaneOrAttempt()
      throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-binding-").toFile();
    try {
      final NfcRfTransactionLeaseBinding binding =
          new NfcRfTransactionLeaseBinding();
      final Libre2NfcSetupAttempt attemptA = attempt("attempt_D_123");
      final Libre2NfcSetupAttempt attemptB = attempt("attempt_E_123");
      final NfcRfTransactionLease explicitLease =
          NfcRfTransactionLease.tryAcquire(root, "native_owner_D001");
      check(binding.bindExplicit(attemptA, explicitLease), "attempt D must bind");
      check(
          binding.claimExplicitForMaintenance(attemptB) == null,
          "a stale attempt cannot promote the current explicit lease");
      check(
          binding.claimHostForMaintenance(explicitLease) == null,
          "the host lane cannot promote an explicit lease");
      final NfcRfTransactionLease promotedExplicit =
          binding.claimExplicitForMaintenance(attemptA);
      check(
          promotedExplicit == explicitLease
              && binding.isHeldByMaintenance(explicitLease),
          "the exact explicit attempt can promote its own lease");
      check(
          binding.takeMaintenance(explicitLease) == explicitLease
              && explicitLease.release(),
          "the exact maintenance token releases the promoted lease");

      final NfcRfTransactionLease hostLease =
          NfcRfTransactionLease.tryAcquire(root, "native_host_0002");
      check(binding.bindHost(hostLease), "second host lease must bind");
      check(
          binding.claimExplicitForMaintenance(attemptA) == null,
          "an explicit attempt cannot promote a host lease");
      check(
          binding.claimHostForMaintenance(explicitLease) == null,
          "an old host token cannot promote the current host lease");
      check(
          binding.claimHostForMaintenance(hostLease) == hostLease
              && binding.isHeldByMaintenance(hostLease),
          "the exact host lane can promote its lease");
      check(
          binding.takeMaintenance(explicitLease) == null,
          "an old maintenance token cannot take the current lease");
      check(
          binding.takeMaintenance(hostLease) == hostLease
              && hostLease.release(),
          "the current maintenance token releases the host lease");
    } finally {
      root.delete();
    }
  }

  private static Libre2NfcSetupAttempt attempt(String attemptId) {
    return new Libre2NfcSetupAttempt(
        attemptId, 7L, "process_session_1", 12L, 1_000L);
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
