package com.aidex.aidex_flutter;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;

/** Synthetic injected I/O only; no receiver file, Android API, or radio access. */
public final class LibreGen1StreamingFilePolicyTest {
  private static final int OWNER = 100;
  private static final byte[] ORIGINAL = envelope((byte) 1);
  private static final byte[] REPLACEMENT = envelope((byte) 2);

  public static void main(String[] args) throws Exception {
    onlyPositiveAbsenceReturnsNull();
    readsRequirePrivateBoundedRegularFiles();
    readsRequireExactLengthAndConfirmedClose();
    atomicWritePreservesOldOrNewJournalWithoutRollback();
    writesRejectUnsafeDestinationsAndStagingFiles();
    System.out.println("Libre streaming file policy synthetic checks passed.");
  }

  private static void onlyPositiveAbsenceReturnsNull() throws Exception {
    FakeRead absent = new FakeRead(); absent.absent = true;
    check(LibreGen1StreamingFilePolicy.read(absent, OWNER) == null, "positive absence rejected");
    check(absent.opens == 1 && absent.closes == 0, "absent path opened twice");
    for (String reason : new String[] {"denied", "linked", "unknown", "not-directory"}) {
      FakeRead failed = new FakeRead(); failed.openFailure = reason;
      rejects(() -> LibreGen1StreamingFilePolicy.read(failed, OWNER));
      check(failed.opens == 1, "open failure retried");
    }
    FakeRead parent = new FakeRead(); parent.parent = fileMetadata(30);
    rejects(() -> LibreGen1StreamingFilePolicy.read(parent, OWNER));
    check(parent.opens == 0, "invalid parent reached open");
    FakeRead wrongOwner = new FakeRead(); wrongOwner.parent = metadata(true, false, OWNER + 1, 0700, 0);
    rejects(() -> LibreGen1StreamingFilePolicy.read(wrongOwner, OWNER));
    check(wrongOwner.opens == 0, "wrong parent owner reached open");
  }

  private static void readsRequirePrivateBoundedRegularFiles() throws Exception {
    for (LibreGen1StreamingFilePolicy.Metadata stat : new LibreGen1StreamingFilePolicy.Metadata[] {
        metadata(false, false, OWNER, 0600, 30),
        metadata(true, false, OWNER, 0600, 30),
        metadata(false, true, OWNER + 1, 0600, 30),
        metadata(false, true, OWNER, 0644, 30),
        metadata(false, true, OWNER, 0400, 30), fileMetadata(29), fileMetadata(2049)}) {
      FakeRead access = new FakeRead(); access.stat = stat;
      rejects(() -> LibreGen1StreamingFilePolicy.read(access, OWNER));
      check(access.closes == 1 && access.reads == 0, "invalid descriptor read or leaked");
    }
    for (int size : new int[] {30, 2048}) {
      FakeRead access = new FakeRead(); access.data = new byte[size]; access.stat = fileMetadata(size);
      check(LibreGen1StreamingFilePolicy.read(access, OWNER).length == size, "valid bound rejected");
      check(access.closes == 1, "valid descriptor leaked");
    }
  }

  private static void readsRequireExactLengthAndConfirmedClose() throws Exception {
    for (String failure : new String[] {"short", "growing", "close", "metadata-changed", "read"}) {
      FakeRead access = new FakeRead();
      if (failure.equals("short")) access.data = new byte[29];
      if (failure.equals("growing")) access.data = new byte[31];
      access.closeFailure = failure.equals("close");
      access.metadataChanged = failure.equals("metadata-changed");
      access.readFailure = failure.equals("read");
      rejects(() -> LibreGen1StreamingFilePolicy.read(access, OWNER));
      check(access.closes == 1, "failed read leaked descriptor");
      if (access.receivingBuffer != null) {
        for (byte value : access.receivingBuffer) check(value == 0, "failed read retained ciphertext buffer");
      }
    }
  }

  private static void atomicWritePreservesOldOrNewJournalWithoutRollback() throws Exception {
    FakeWrite good = new FakeWrite();
    LibreGen1StreamingFilePolicy.write(good, OWNER, REPLACEMENT);
    check(Arrays.equals(good.journal, REPLACEMENT) && good.staging == null, "atomic save failed");
    check(good.replaces == 1 && good.syncs == 1 && good.discards == 0, "save sequence changed");
    for (String failure : new String[] {"create", "write", "flush", "sync-file", "close", "replace", "sync-directory"}) {
      FakeWrite access = new FakeWrite(); access.failure = failure;
      rejects(() -> LibreGen1StreamingFilePolicy.write(access, OWNER, REPLACEMENT));
      final byte[] expected = failure.equals("sync-directory") ? REPLACEMENT : ORIGINAL;
      check(Arrays.equals(access.journal, expected), "failed write deleted or rolled back journal");
      check(access.staging == null, "failed write retained staging file");
      check(access.replaces <= 1, "rename retried");
    }
    // A rename may take effect and then report uncertainty. Cleanup touches only the old staging path.
    FakeWrite uncertain = new FakeWrite(); uncertain.failure = "replace-after-effect";
    rejects(() -> LibreGen1StreamingFilePolicy.write(uncertain, OWNER, REPLACEMENT));
    check(Arrays.equals(uncertain.journal, REPLACEMENT) && uncertain.staging == null,
        "uncertain rename rolled back the destination");
    FakeWrite cleanup = new FakeWrite(); cleanup.failure = "write"; cleanup.discardFailure = true;
    rejects(() -> LibreGen1StreamingFilePolicy.write(cleanup, OWNER, REPLACEMENT));
    check(Arrays.equals(cleanup.journal, ORIGINAL) && cleanup.discards == 1,
        "failed cleanup touched known journal or retried");
  }

  private static void writesRejectUnsafeDestinationsAndStagingFiles() throws Exception {
    for (String failure : new String[] {"parent", "existing", "staging", "staging-size", "changed-existing"}) {
      FakeWrite access = new FakeWrite(); access.failure = failure;
      rejects(() -> LibreGen1StreamingFilePolicy.write(access, OWNER, REPLACEMENT));
      check(Arrays.equals(access.journal, ORIGINAL) && access.replaces == 0, "invalid file reached rename");
      check(access.staging == null, "invalid staging not removed");
    }
    for (byte[] invalid : new byte[][] {null, new byte[29], new byte[2049]}) {
      FakeWrite access = new FakeWrite();
      rejects(() -> LibreGen1StreamingFilePolicy.write(access, OWNER, invalid));
      check(access.creates == 0, "invalid envelope created staging");
    }
    FakeWrite absent = new FakeWrite(); absent.journal = null;
    LibreGen1StreamingFilePolicy.write(absent, OWNER, REPLACEMENT);
    check(Arrays.equals(absent.journal, REPLACEMENT), "first save rejected");
  }

  private static final class FakeRead implements LibreGen1StreamingFilePolicy.ReadAccess {
    LibreGen1StreamingFilePolicy.Metadata parent = metadata(true, false, OWNER, 0700, 0);
    LibreGen1StreamingFilePolicy.Metadata stat = fileMetadata(30);
    byte[] data = envelope((byte) 3), receivingBuffer;
    boolean absent, closeFailure, metadataChanged, readFailure;
    String openFailure;
    int opens, closes, reads, metadataReads;
    public LibreGen1StreamingFilePolicy.Metadata directory() { return parent; }
    public LibreGen1StreamingFilePolicy.ReadHandle open() throws Exception {
      opens++;
      if (absent) throw new LibreGen1StreamingFilePolicy.AbsentFile();
      if (openFailure != null) throw new IOException("synthetic " + openFailure);
      final InputStream stream = new ByteArrayInputStream(data) {
        @Override public synchronized int read(byte[] bytes, int offset, int length) {
          receivingBuffer = bytes; reads++;
          if (readFailure) throw new IllegalStateException("synthetic read failure");
          return super.read(bytes, offset, length);
        }
      };
      return new LibreGen1StreamingFilePolicy.ReadHandle() {
        public LibreGen1StreamingFilePolicy.Metadata metadata() {
          return metadataChanged && metadataReads++ > 0 ? fileMetadata(31) : stat;
        }
        public InputStream input() { return stream; }
        public void close() throws Exception { closes++; if (closeFailure) throw new IOException("synthetic close"); }
      };
    }
  }

  private static final class FakeWrite implements LibreGen1StreamingFilePolicy.WriteAccess {
    byte[] journal = ORIGINAL.clone();
    ByteArrayOutputStream staging;
    String failure = "";
    boolean discardFailure;
    int creates, replaces, syncs, discards, existingReads;
    public LibreGen1StreamingFilePolicy.Metadata directory() {
      return metadata(!failure.equals("parent"), false, OWNER, 0700, 0);
    }
    public LibreGen1StreamingFilePolicy.Metadata existing() throws Exception {
      if (failure.equals("existing") || (failure.equals("changed-existing") && existingReads++ > 0)) {
        throw new IOException("synthetic denied");
      }
      return journal == null ? null : fileMetadata(journal.length);
    }
    public LibreGen1StreamingFilePolicy.WriteHandle createExclusive() throws Exception {
      creates++;
      if (failure.equals("create")) throw new IOException("synthetic staging conflict");
      staging = new ByteArrayOutputStream();
      final OutputStream output = new OutputStream() {
        public void write(int value) throws IOException {
          if (failure.equals("write")) throw new IOException("synthetic write");
          staging.write(value);
        }
        public void flush() throws IOException { if (failure.equals("flush")) throw new IOException("synthetic flush"); }
      };
      return new LibreGen1StreamingFilePolicy.WriteHandle() {
        public LibreGen1StreamingFilePolicy.Metadata metadata() {
          if (failure.equals("staging")) return LibreGen1StreamingFilePolicyTest.metadata(false, true, OWNER, 0644, 0);
          return fileMetadata(failure.equals("staging-size") ? 1 : staging.size());
        }
        public OutputStream output() { return output; }
        public void sync() throws Exception { if (failure.equals("sync-file")) throw new IOException("synthetic sync"); }
        public void close() throws Exception { if (failure.equals("close")) throw new IOException("synthetic close"); }
      };
    }
    public void replace() throws Exception {
      replaces++;
      if (failure.equals("replace")) throw new IOException("synthetic rename");
      journal = staging.toByteArray(); staging = null;
      if (failure.equals("replace-after-effect")) throw new IOException("synthetic uncertain rename");
    }
    public void syncDirectory() throws Exception {
      syncs++;
      if (failure.equals("sync-directory")) throw new IOException("synthetic parent sync");
    }
    public void discardStaging() throws Exception {
      discards++;
      if (discardFailure) throw new IOException("synthetic staging cleanup");
      staging = null;
    }
  }

  private static byte[] envelope(byte value) { byte[] result = new byte[30]; Arrays.fill(result, value); return result; }
  private static LibreGen1StreamingFilePolicy.Metadata fileMetadata(long size) {
    return metadata(false, true, OWNER, 0600, size);
  }
  private static LibreGen1StreamingFilePolicy.Metadata metadata(boolean dir, boolean regular, int owner, int mode, long size) {
    return new LibreGen1StreamingFilePolicy.Metadata(dir, regular, owner, mode, size);
  }
  private interface Checked { void run() throws Exception; }
  private static void rejects(Checked action) throws Exception {
    try { action.run(); throw new AssertionError("unsafe file operation accepted"); }
    catch (IOException | IllegalStateException expected) {}
  }
  private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
