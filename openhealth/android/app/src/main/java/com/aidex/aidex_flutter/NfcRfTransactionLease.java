package com.aidex.aidex_flutter;

import java.io.File;
import java.io.IOException;

/**
 * One process-safe, app-private NFC RF ownership lease.
 *
 * <p>The directory creation is the atomic acquisition point shared with the
 * host capture harness. Release removes only the exact owner file created by
 * this lease and never recursively removes an unknown owner's files.
 */
final class NfcRfTransactionLease {
  static final String DIRECTORY_NAME = "nfc-rf-transaction.lease";
  static final String OWNER_PREFIX = "owner-";

  private final File directory;
  private final File ownerFile;
  private boolean released;

  private NfcRfTransactionLease(File directory, File ownerFile) {
    this.directory = directory;
    this.ownerFile = ownerFile;
  }

  static NfcRfTransactionLease tryAcquire(
      File captureDirectory, String ownerToken) throws IOException {
    if (captureDirectory == null
        || !captureDirectory.isDirectory()
        || ownerToken == null
        || !ownerToken.matches("^[A-Za-z0-9_-]{8,120}$")) {
      throw new IOException("Invalid NFC RF lease binding.");
    }
    final File leaseDirectory =
        new File(captureDirectory, DIRECTORY_NAME);
    if (!leaseDirectory.mkdir()) {
      return null;
    }
    final File owner =
        new File(leaseDirectory, OWNER_PREFIX + ownerToken);
    boolean acquired = false;
    try {
      restrictDirectory(leaseDirectory);
      if (!owner.createNewFile()) {
        throw new IOException("Could not create NFC RF lease owner.");
      }
      restrictFile(owner);
      acquired = true;
      return new NfcRfTransactionLease(leaseDirectory, owner);
    } finally {
      if (!acquired) {
        if (owner.exists()) {
          owner.delete();
        }
        leaseDirectory.delete();
      }
    }
  }

  synchronized boolean release() {
    if (released) {
      return true;
    }
    final String[] entries = directory.list();
    if (!ownerFile.isFile()
        || entries == null
        || entries.length != 1
        || !ownerFile.getName().equals(entries[0])) {
      return false;
    }
    if (!ownerFile.delete() || !directory.delete()) {
      return false;
    }
    released = true;
    return true;
  }

  synchronized boolean isHeldByThisOwner() {
    if (released || !ownerFile.isFile() || !directory.isDirectory()) {
      return false;
    }
    final String[] entries = directory.list();
    return entries != null
        && entries.length == 1
        && ownerFile.getName().equals(entries[0]);
  }

  private static void restrictDirectory(File directory) throws IOException {
    directory.setReadable(false, false);
    directory.setWritable(false, false);
    directory.setExecutable(false, false);
    if (!directory.setReadable(true, true)
        || !directory.setWritable(true, true)
        || !directory.setExecutable(true, true)) {
      throw new IOException("Could not protect NFC RF lease directory.");
    }
  }

  private static void restrictFile(File file) throws IOException {
    file.setReadable(false, false);
    file.setWritable(false, false);
    file.setExecutable(false, false);
    if (!file.setReadable(true, true) || !file.setWritable(true, true)) {
      throw new IOException("Could not protect NFC RF lease owner.");
    }
  }
}
