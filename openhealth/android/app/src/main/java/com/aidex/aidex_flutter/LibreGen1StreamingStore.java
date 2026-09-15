package com.aidex.aidex_flutter;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.UUID;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Keystore-encrypted, backup-excluded receiver bootstrap and counter journal. */
final class LibreGen1StreamingStore implements LibreGen1StreamingJournal.Backend {
  private static final String KEY_ALIAS = "openglucose_libre_gen1_streaming_v1";
  private static final byte[] AAD = {0x4f, 0x47, 0x4c, 0x32, 0x01};
  private static LibreGen1StreamingJournal instance;
  private final File file;

  private LibreGen1StreamingStore(Context context) {
    file = new File(context.getNoBackupFilesDir(), "libre-gen1-streaming-v1.bin");
  }

  static synchronized LibreGen1StreamingJournal journal(Context context) {
    if (instance == null) {
      instance = new LibreGen1StreamingJournal(new LibreGen1StreamingStore(context));
    }
    return instance;
  }

  @Override public byte[] read() throws Exception {
    final byte[] encrypted = LibreGen1StreamingFilePolicy.read(new NativeFiles(), android.os.Process.myUid());
    if (encrypted == null) return null;
    try {
      if (encrypted[0] != 1) throw new IOException("Unsupported streaming envelope.");
      final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.DECRYPT_MODE, key(false),
          new GCMParameterSpec(128, Arrays.copyOfRange(encrypted, 1, 13)));
      cipher.updateAAD(AAD);
      return cipher.doFinal(encrypted, 13, encrypted.length - 13);
    } finally { Arrays.fill(encrypted, (byte) 0); }
  }

  @Override public void write(byte[] bytes) throws Exception {
    final NativeFiles files = new NativeFiles();
    final int owner = android.os.Process.myUid();
    LibreGen1StreamingFilePolicy.requireDirectory(files.directory(), owner);
    if (bytes == null) {
      // The existing journal permits this only for an unconsumed prepared attempt.
      // Do not turn a denied, linked, or malformed file into apparent absence.
      final LibreGen1StreamingFilePolicy.Metadata existing = files.existing();
      if (existing != null) {
        LibreGen1StreamingFilePolicy.requireFile(existing, owner,
            LibreGen1StreamingFilePolicy.MIN_ENVELOPE_BYTES, LibreGen1StreamingFilePolicy.MAX_ENVELOPE_BYTES);
        Os.remove(file.getAbsolutePath());
      }
      files.syncDirectory();
      return;
    }
    if (bytes.length == 0 || bytes.length > 1024) throw new IOException("Invalid streaming record.");
    final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, key(true));
    cipher.updateAAD(AAD);
    final byte[] iv = cipher.getIV();
    if (iv.length != 12) throw new IOException("Invalid streaming IV.");
    final byte[] encrypted = cipher.doFinal(bytes);
    final byte[] envelope = new byte[1 + iv.length + encrypted.length];
    try {
      envelope[0] = 1;
      System.arraycopy(iv, 0, envelope, 1, iv.length);
      System.arraycopy(encrypted, 0, envelope, 1 + iv.length, encrypted.length);
      LibreGen1StreamingFilePolicy.write(files, owner, envelope);
    } finally {
      Arrays.fill(envelope, (byte) 0);
      Arrays.fill(encrypted, (byte) 0);
    }
  }

  /** No path-following Java file checks. Only ENOENT is a positive absent result. */
  private final class NativeFiles implements LibreGen1StreamingFilePolicy.ReadAccess,
      LibreGen1StreamingFilePolicy.WriteAccess {
    private final File directory = file.getParentFile();
    private final File temporary = new File(directory, ".libre-streaming-" + UUID.randomUUID());

    public LibreGen1StreamingFilePolicy.Metadata directory() throws Exception {
      return metadata(Os.lstat(directory.getAbsolutePath()));
    }

    public LibreGen1StreamingFilePolicy.Metadata existing() throws Exception {
      try { return metadata(Os.lstat(file.getAbsolutePath())); }
      catch (ErrnoException failure) {
        if (failure.errno == OsConstants.ENOENT) return null;
        throw failure;
      }
    }

    public LibreGen1StreamingFilePolicy.ReadHandle open() throws Exception {
      final FileDescriptor fd;
      try {
        // NONBLOCK prevents a substituted FIFO from hanging before the descriptor type check.
        fd = Os.open(file.getAbsolutePath(),
            OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW | OsConstants.O_NONBLOCK, 0);
      } catch (ErrnoException failure) {
        if (failure.errno == OsConstants.ENOENT) throw new LibreGen1StreamingFilePolicy.AbsentFile();
        throw failure;
      }
      final FileInputStream input = new FileInputStream(fd);
      return new LibreGen1StreamingFilePolicy.ReadHandle() {
        public LibreGen1StreamingFilePolicy.Metadata metadata() throws Exception {
          return NativeFiles.this.metadata(Os.fstat(fd));
        }
        public InputStream input() { return input; }
        public void close() throws Exception { input.close(); }
      };
    }

    public LibreGen1StreamingFilePolicy.WriteHandle createExclusive() throws Exception {
      final FileDescriptor fd = Os.open(temporary.getAbsolutePath(),
          OsConstants.O_WRONLY | OsConstants.O_CREAT | OsConstants.O_EXCL | OsConstants.O_NOFOLLOW, 0600);
      final FileOutputStream output = new FileOutputStream(fd);
      return new LibreGen1StreamingFilePolicy.WriteHandle() {
        public LibreGen1StreamingFilePolicy.Metadata metadata() throws Exception {
          return NativeFiles.this.metadata(Os.fstat(fd));
        }
        public OutputStream output() { return output; }
        public void sync() throws Exception { output.getFD().sync(); }
        public void close() throws Exception { output.close(); }
      };
    }

    public void replace() throws Exception {
      Os.rename(temporary.getAbsolutePath(), file.getAbsolutePath());
    }

    public void syncDirectory() throws Exception {
      final FileDescriptor fd = Os.open(directory.getAbsolutePath(),
          OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW | OsConstants.O_NONBLOCK, 0);
      try {
        LibreGen1StreamingFilePolicy.requireDirectory(metadata(Os.fstat(fd)), android.os.Process.myUid());
        Os.fsync(fd);
      } finally { Os.close(fd); }
    }

    public void discardStaging() throws Exception {
      try { Os.remove(temporary.getAbsolutePath()); }
      catch (ErrnoException failure) { if (failure.errno != OsConstants.ENOENT) throw failure; }
    }

    private LibreGen1StreamingFilePolicy.Metadata metadata(StructStat stat) {
      return new LibreGen1StreamingFilePolicy.Metadata(OsConstants.S_ISDIR(stat.st_mode),
          OsConstants.S_ISREG(stat.st_mode), stat.st_uid, stat.st_mode & 0777, stat.st_size);
    }
  }

  private static SecretKey key(boolean allowCreate) throws Exception {
    final KeyStore store = KeyStore.getInstance("AndroidKeyStore");
    store.load(null);
    final java.security.Key existing = store.getKey(KEY_ALIAS, null);
    if (existing instanceof SecretKey) return (SecretKey) existing;
    if (existing != null || !allowCreate) throw new java.io.IOException("Streaming key unavailable.");
    final KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
    generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
        KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256).build());
    return generator.generateKey();
  }
}
