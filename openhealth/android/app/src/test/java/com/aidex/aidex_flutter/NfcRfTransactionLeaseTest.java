package com.aidex.aidex_flutter;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;

/** Standalone JVM checks for process-safe NFC RF lease ownership. */
public final class NfcRfTransactionLeaseTest {
  private NfcRfTransactionLeaseTest() {}

  public static void main(String[] arguments) throws Exception {
    oneOwnerAcquiresAtomically();
    releaseCannotDeleteAnotherOwnerEntry();
    rejectsUnsafeOwnerTokens();
  }

  private static void oneOwnerAcquiresAtomically() throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-lease-").toFile();
    try {
      final NfcRfTransactionLease first =
          NfcRfTransactionLease.tryAcquire(root, "native_owner_0001");
      check(first != null && first.isHeldByThisOwner(), "first owner must acquire");
      check(
          NfcRfTransactionLease.tryAcquire(root, "native_owner_0002") == null,
          "a second owner must be rejected atomically");
      check(first.release(), "the exact owner must release");
      final NfcRfTransactionLease second =
          NfcRfTransactionLease.tryAcquire(root, "native_owner_0002");
      check(second != null && second.release(), "release must permit a later owner");
    } finally {
      root.delete();
    }
  }

  private static void releaseCannotDeleteAnotherOwnerEntry() throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-lease-").toFile();
    try {
      final NfcRfTransactionLease lease =
          NfcRfTransactionLease.tryAcquire(root, "native_owner_0001");
      check(lease != null, "lease must acquire");
      final File directory =
          new File(root, NfcRfTransactionLease.DIRECTORY_NAME);
      final File foreignOwner =
          new File(directory, NfcRfTransactionLease.OWNER_PREFIX + "foreign_owner_0002");
      check(foreignOwner.createNewFile(), "test foreign owner must be created");
      check(!lease.release(), "release must fail closed for an unknown entry");
      check(foreignOwner.isFile(), "release must preserve another owner entry");
      check(foreignOwner.delete(), "test foreign owner cleanup");
      check(lease.release(), "exact ownership must release after conflict removal");
    } finally {
      root.delete();
    }
  }

  private static void rejectsUnsafeOwnerTokens() throws Exception {
    final File root = Files.createTempDirectory("nfc-rf-lease-").toFile();
    try {
      expectFailure(() -> NfcRfTransactionLease.tryAcquire(root, "../unsafe"));
    } finally {
      root.delete();
    }
  }

  private static void expectFailure(ThrowingAction action) throws Exception {
    try {
      action.run();
      throw new AssertionError("expected fail-closed rejection");
    } catch (IOException expected) {
      // Expected.
    }
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }

  private interface ThrowingAction {
    void run() throws Exception;
  }
}
