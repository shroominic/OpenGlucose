package com.aidex.aidex_flutter;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Synthetic failure injection for restart-safe, read-only lease release. */
public final class Libre2NfcLeaseReleaseTest {
  private Libre2NfcLeaseReleaseTest() {}

  public static void main(String[] arguments) throws Exception {
    successfulDeleteIsLastOperation();
    failureBeforeDeleteRetainsRestartBlocker();
    ownerChangeDuringSyncCannotDelete();
    partialDeletionRetainsRestartBlocker(false);
    partialDeletionRetainsRestartBlocker(true);
  }

  private static void successfulDeleteIsLastOperation() {
    final List<String> operations = new ArrayList<>();
    check(Libre2NfcLeaseRelease.release(new Libre2NfcLeaseRelease.Files() {
      public boolean held() { operations.add("held"); return true; }
      public void syncBeforeDelete() { operations.add("sync"); }
      public boolean removeExactOwner() { operations.add("delete"); return true; }
    }), "exact completed deletion must be success");
    check(operations.equals(Arrays.asList("held", "sync", "held", "delete")),
        "no fallible operation may follow successful deletion");
  }

  private static void failureBeforeDeleteRetainsRestartBlocker() throws Exception {
    final File root = java.nio.file.Files.createTempDirectory("nfc-release-sync-").toFile();
    final NfcRfTransactionLease lease = NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_01");
    check(lease != null, "synthetic lease must acquire");
    try {
      for (int failure = 0; failure < 3; failure++) {
        final int selectedFailure = failure;
        final int[] checks = {0};
        check(!Libre2NfcLeaseRelease.release(new Libre2NfcLeaseRelease.Files() {
          public boolean held() throws Exception {
            if (selectedFailure == checks[0]++) throw new IOException("synthetic check failure");
            return lease.isHeldByThisOwner();
          }
          public void syncBeforeDelete() throws Exception {
            if (selectedFailure == 2) throw new IOException("synthetic sync failure");
          }
          public boolean removeExactOwner() {
            throw new AssertionError("failure must prevent any deletion");
          }
        }), "pre-delete failure must fail closed");
        check(lease.isHeldByThisOwner(), "uncertain release must retain exact owner");
        check(NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_02") == null,
            "fresh process cannot reuse unresolved lease");
      }
    } finally {
      check(lease.release(), "synthetic exact-owner cleanup");
      check(root.delete(), "synthetic root cleanup");
    }
  }

  private static void ownerChangeDuringSyncCannotDelete() throws Exception {
    final File root = java.nio.file.Files.createTempDirectory("nfc-release-owner-").toFile();
    final NfcRfTransactionLease lease = NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_01");
    check(lease != null, "synthetic lease must acquire");
    final File unknown = new File(new File(root, NfcRfTransactionLease.DIRECTORY_NAME), "unknown-owner");
    try {
      check(!Libre2NfcLeaseRelease.release(new Libre2NfcLeaseRelease.Files() {
        public boolean held() { return lease.isHeldByThisOwner(); }
        public void syncBeforeDelete() throws Exception {
          check(unknown.createNewFile(), "synthetic owner conflict");
        }
        public boolean removeExactOwner() {
          throw new AssertionError("changed owner must prevent any deletion");
        }
      }), "owner change during I/O must fail closed");
      check(unknown.isFile(), "unknown entry must remain untouched");
      check(NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_02") == null,
          "unknown owner must block fresh acquisition");
    } finally {
      check(unknown.delete(), "synthetic conflict cleanup");
      check(lease.release(), "synthetic exact-owner cleanup");
      check(root.delete(), "synthetic root cleanup");
    }
  }

  private static void partialDeletionRetainsRestartBlocker(boolean ownerDeleteFails)
      throws Exception {
    final File root = java.nio.file.Files.createTempDirectory("nfc-release-partial-").toFile();
    check(NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_01") != null,
        "synthetic lease must acquire");
    final File directory = new File(root, NfcRfTransactionLease.DIRECTORY_NAME);
    final File owner = new File(directory, NfcRfTransactionLease.OWNER_PREFIX + "synthetic_owner_01");
    // Inject File.delete failures into the real shared primitive without adding
    // a production factory or changing ownership logic used by the recorder.
    final File failingDirectory = new File(directory.getPath()) {
      public boolean delete() { return false; }
    };
    final File failingOwner = new File(owner.getPath()) {
      public boolean delete() { return false; }
    };
    final Constructor<NfcRfTransactionLease> constructor =
        NfcRfTransactionLease.class.getDeclaredConstructor(File.class, File.class);
    constructor.setAccessible(true);
    final NfcRfTransactionLease lease = constructor.newInstance(
        ownerDeleteFails ? directory : failingDirectory, ownerDeleteFails ? failingOwner : owner);
    try {
      check(!Libre2NfcLeaseRelease.release(new Libre2NfcLeaseRelease.Files() {
        public boolean held() { return lease.isHeldByThisOwner(); }
        public void syncBeforeDelete() {}
        public boolean removeExactOwner() { return lease.release(); }
      }), "partial deletion must fail closed");
      check(directory.isDirectory(), "partial deletion must retain directory blocker");
      check(owner.isFile() == ownerDeleteFails, "failure injection must reach expected deletion");
      check(NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_02") == null,
          "new process must reject even an empty unresolved lease directory");
      check(!lease.release(), "uncertain owner must not report a later false success");
    } finally {
      if (owner.exists()) check(owner.delete(), "synthetic owner cleanup");
      check(directory.delete(), "synthetic directory cleanup");
      check(root.delete(), "synthetic root cleanup");
    }
  }

  private static void check(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
}
