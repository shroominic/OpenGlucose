package com.aidex.aidex_flutter;

import java.io.IOException;

/** Read-only lane persistence barrier; must finish before the first RF call. */
final class Libre2NfcLeaseAcquisition {
  private Libre2NfcLeaseAcquisition() {}

  interface Files {
    boolean held() throws Exception;
    void syncOwner() throws Exception;
    void syncLeaseDirectory() throws Exception;
    void syncCaptureDirectory() throws Exception;
    void syncAppFilesDirectory() throws Exception;
  }

  static void persist(Files files) throws Exception {
    if (!files.held()) throw new IOException("NFC lease ownership unavailable.");
    files.syncOwner();
    files.syncLeaseDirectory();
    files.syncCaptureDirectory();
    files.syncAppFilesDirectory();
    if (!files.held()) throw new IOException("NFC lease ownership unavailable.");
    // An error leaves the lease untouched. Never return an RF owner or clean up
    // a partially persisted blocker on this path.
  }
}
