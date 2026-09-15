package com.aidex.aidex_flutter;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Synthetic acquisition barriers. No transport or sensor is used. */
public final class Libre2NfcLeaseAcquisitionTest {
  private Libre2NfcLeaseAcquisitionTest() {}

  public static void main(String[] arguments) throws Exception {
    persistInDependencyOrder();
    eachFailurePreventsOwnershipReturn();
    changedOwnerAfterSyncPreventsOwnershipReturn();
  }

  private static void persistInDependencyOrder() throws Exception {
    final List<String> calls = new ArrayList<>();
    Libre2NfcLeaseAcquisition.persist(new Actions(calls));
    check(calls.equals(Arrays.asList("held", "owner", "lease", "capture", "appFiles", "held")),
        "persist owner and every parent link before returning RF ownership");
  }

  private static void eachFailurePreventsOwnershipReturn() throws Exception {
    for (int failure = 0; failure < 6; failure++) {
      final File root = java.nio.file.Files.createTempDirectory("nfc-acquire-barrier-").toFile();
      final NfcRfTransactionLease lease = NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_01");
      check(lease != null, "synthetic lease must acquire");
      final int selectedFailure = failure;
      final List<String> calls = new ArrayList<>();
      try {
        try {
          Libre2NfcLeaseAcquisition.persist(new Actions(calls) {
            void record(String value) throws Exception {
              super.record(value);
              if (calls.size() == selectedFailure + 1) throw new IOException("synthetic sync failure");
            }
          });
          throw new AssertionError("failed persistence must not return RF ownership");
        } catch (IOException expected) {
          check(calls.size() == failure + 1, "no persistence work may follow failure");
          check(lease.isHeldByThisOwner(), "failure must not remove or rewrite the lease");
          check(NfcRfTransactionLease.tryAcquire(root, "synthetic_owner_02") == null,
              "fresh acquisition must reject the unresolved blocker");
        }
      } finally {
        check(lease.release(), "synthetic exact-owner cleanup");
        check(root.delete(), "synthetic root cleanup");
      }
    }
  }

  private static void changedOwnerAfterSyncPreventsOwnershipReturn() throws Exception {
    final List<String> calls = new ArrayList<>();
    try {
      Libre2NfcLeaseAcquisition.persist(new Actions(calls) {
        public boolean held() throws Exception {
          record("held");
          return calls.size() == 1;
        }
      });
      throw new AssertionError("changed owner must not return RF ownership");
    } catch (IOException expected) {
      check(calls.size() == 6, "the final ownership check must run after all I/O");
    }
  }

  private static class Actions implements Libre2NfcLeaseAcquisition.Files {
    final List<String> calls;
    Actions(List<String> calls) { this.calls = calls; }
    void record(String value) throws Exception { calls.add(value); }
    public boolean held() throws Exception { record("held"); return true; }
    public void syncOwner() throws Exception { record("owner"); }
    public void syncLeaseDirectory() throws Exception { record("lease"); }
    public void syncCaptureDirectory() throws Exception { record("capture"); }
    public void syncAppFilesDirectory() throws Exception { record("appFiles"); }
  }

  private static void check(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
}
