package com.aidex.aidex_flutter;

import android.content.Context;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;

import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;

/** Durable exact-owner lease shared with NFC and the private capture harness. */
final class LibreGen1ReceiverLease {
  private LibreGen1ReceiverLease() {}

  /** Positive read-only absence check; unknown/partial/symlink leases are never idle. */
  static boolean idle(Context context) {
    final File directory = new File(context.getFilesDir(), "protocol-captures");
    try {
      requireDirectory(directory);
      try { Os.lstat(new File(directory, NfcRfTransactionLease.DIRECTORY_NAME).getAbsolutePath()); }
      catch (ErrnoException absent) {
        if (absent.errno != OsConstants.ENOENT) return false;
        requireDirectory(directory);
        return true;
      }
    } catch (Exception unavailable) { return false; }
    return false;
  }

  static LibreGen1ReceiverCoordinator.Lease acquire(Context context, String token) throws Exception {
    final File appFiles = context.getFilesDir();
    final File directory = new File(appFiles, "protocol-captures");
    try { Os.mkdir(directory.getAbsolutePath(), 0700); }
    catch (ErrnoException error) { if (error.errno != OsConstants.EEXIST) throw error; }
    requireDirectory(directory);
    syncDirectory(appFiles);
    // Historical captures and completed journals stay untouched. An existing
    // lease of any kind, including an empty/partial one, blocks this acquire.
    final NfcRfTransactionLease lease = NfcRfTransactionLease.tryAcquire(directory, token);
    if (lease == null) return null;
    final File leaseDirectory = new File(directory, NfcRfTransactionLease.DIRECTORY_NAME);
    final File ownerFile = new File(leaseDirectory, NfcRfTransactionLease.OWNER_PREFIX + token);
    final LibreGen1ReceiverCoordinator.Lease result = new LibreGen1ReceiverCoordinator.Lease() {
      public boolean held() {
        try {
          requireDirectory(directory);
          requireDirectory(leaseDirectory);
          checkOwnerFile(ownerFile, false);
          return lease.isHeldByThisOwner();
        } catch (Exception failure) { return false; }
      }

      public boolean release() {
        return Libre2NfcLeaseRelease.release(new Libre2NfcLeaseRelease.Files() {
          public boolean held() { return owned(); }
          public void syncBeforeDelete() throws Exception { syncDirectory(directory); }
          public boolean removeExactOwner() { return lease.release(); }
        });
      }

      private boolean owned() { return held(); }
    };
    Libre2NfcLeaseAcquisition.persist(new Libre2NfcLeaseAcquisition.Files() {
      public boolean held() { return result.held(); }
      public void syncOwner() throws Exception { checkOwnerFile(ownerFile, true); }
      public void syncLeaseDirectory() throws Exception { syncDirectory(leaseDirectory); }
      public void syncCaptureDirectory() throws Exception { syncDirectory(directory); }
      public void syncAppFilesDirectory() throws Exception { syncDirectory(appFiles); }
    });
    return result;
  }

  private static void requireDirectory(File directory) throws Exception {
    final StructStat stat = Os.lstat(directory.getAbsolutePath());
    requireDirectory(stat);
  }

  private static void requireDirectory(StructStat stat) throws IOException {
    if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != android.os.Process.myUid()
        || (stat.st_mode & 0777) != 0700) throw new IOException("Receiver lease directory unavailable.");
  }

  private static void syncDirectory(File directory) throws Exception {
    final FileDescriptor fd = Os.open(directory.getAbsolutePath(),
        OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW | OsConstants.O_NONBLOCK, 0);
    try {
      requireDirectory(Os.fstat(fd));
      Os.fsync(fd);
    } finally { Os.close(fd); }
  }

  private static void checkOwnerFile(File file, boolean sync) throws Exception {
    final FileDescriptor fd = Os.open(file.getAbsolutePath(),
        OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW | OsConstants.O_NONBLOCK, 0);
    try {
      final StructStat stat = Os.fstat(fd);
      if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != android.os.Process.myUid()
          || (stat.st_mode & 0777) != 0600 || stat.st_size != 0) {
        throw new IOException("Receiver lease owner unavailable.");
      }
      if (sync) Os.fsync(fd);
    } finally { Os.close(fd); }
  }
}
