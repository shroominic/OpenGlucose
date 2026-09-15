package com.aidex.aidex_flutter;

/** Release ordering for a durably acquired, read-only RF ownership lease. */
final class Libre2NfcLeaseRelease {
  private Libre2NfcLeaseRelease() {}

  interface Files {
    boolean held() throws Exception;
    void syncBeforeDelete() throws Exception;

    /**
     * Removes only the exact owner's entry and lease directory. Successful
     * directory deletion is the final success point: implementations must not
     * perform another fallible operation after it. A partial deletion must leave
     * the lease directory in place, so a later process cannot acquire it.
     */
    boolean removeExactOwner() throws Exception;
  }

  static boolean release(Files files) {
    try {
      if (!files.held()) return false;
      files.syncBeforeDelete();
      // The sync may perform blocking I/O. Do not reuse its earlier owner check.
      if (!files.held()) return false;
      return files.removeExactOwner();
    } catch (Exception error) {
      return false;
    }
  }
}
