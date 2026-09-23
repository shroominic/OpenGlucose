package com.aidex.aidex_flutter;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import android.system.OsConstants;

import java.io.DataInputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Independent, backup-excluded calibration cache. Never opens or changes the receiver journal. */
final class LibreGen1CalibrationStore {
  private static final String KEY_ALIAS = "openglucose_libre_gen1_calibration_v1";
  private static final byte[] AAD = {0x4f, 0x47, 0x43, 0x41, 0x4c, 0x01};
  private final File file;

  LibreGen1CalibrationStore(Context context) {
    file = new File(context.getNoBackupFilesDir(), "libre-gen1-calibration-v1.bin");
  }

  byte[] read() throws Exception {
    requirePrivateDirectory();
    if (!file.exists()) return null;
    byte[] encrypted = null;
    try {
      final FileDescriptor fd = Os.open(file.getAbsolutePath(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
      try (FileInputStream input = new FileInputStream(fd)) {
        final android.system.StructStat stat = Os.fstat(fd);
        if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != android.os.Process.myUid()
            || (stat.st_mode & 0777) != 0600 || stat.st_size < 30 || stat.st_size > 541) {
          throw new IOException("Calibration storage is unavailable.");
        }
        encrypted = new byte[(int) stat.st_size];
        new DataInputStream(input).readFully(encrypted);
        if (input.read() != -1) throw new IOException("Calibration storage is unavailable.");
      }
      if (encrypted[0] != 1) throw new IOException("Calibration storage is unavailable.");
      final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.DECRYPT_MODE, key(false), new GCMParameterSpec(128, Arrays.copyOfRange(encrypted, 1, 13)));
      cipher.updateAAD(AAD);
      return cipher.doFinal(encrypted, 13, encrypted.length - 13);
    } finally { if (encrypted != null) Arrays.fill(encrypted, (byte) 0); }
  }

  void writeVerified(LibreGen1CalibrationEvidence evidence) throws Exception {
    final byte[] clear = evidence.encode();
    byte[] encrypted = null, confirmed = null;
    final File directory = file.getParentFile();
    final File temporary = new File(directory, ".libre-calibration-" + UUID.randomUUID());
    try {
      requirePrivateDirectory();
      if (clear.length > 512) throw new IOException("Calibration storage is unavailable.");
      final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.ENCRYPT_MODE, key(true)); cipher.updateAAD(AAD);
      final byte[] iv = cipher.getIV();
      if (iv.length != 12) throw new IOException("Calibration storage is unavailable.");
      encrypted = cipher.doFinal(clear);
      final FileDescriptor fd = Os.open(temporary.getAbsolutePath(),
          OsConstants.O_WRONLY | OsConstants.O_CREAT | OsConstants.O_EXCL | OsConstants.O_NOFOLLOW, 0600);
      try (FileOutputStream output = new FileOutputStream(fd)) {
        output.write(1); output.write(iv); output.write(encrypted); output.flush(); output.getFD().sync();
      }
      Os.rename(temporary.getAbsolutePath(), file.getAbsolutePath());
      final FileDescriptor parent = Os.open(directory.getAbsolutePath(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
      try {
        if (!OsConstants.S_ISDIR(Os.fstat(parent).st_mode)) throw new IOException("Calibration storage is unavailable.");
        Os.fsync(parent);
      } finally { Os.close(parent); }
      confirmed = read();
      if (!Arrays.equals(clear, confirmed)) throw new IOException("Calibration storage is unavailable.");
    } finally {
      Arrays.fill(clear, (byte) 0);
      if (encrypted != null) Arrays.fill(encrypted, (byte) 0);
      if (confirmed != null) Arrays.fill(confirmed, (byte) 0);
      if (temporary.exists()) temporary.delete();
    }
  }

  private void requirePrivateDirectory() throws Exception {
    final android.system.StructStat stat = Os.lstat(file.getParentFile().getAbsolutePath());
    if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != android.os.Process.myUid()) {
      throw new IOException("Calibration storage is unavailable.");
    }
  }

  private static SecretKey key(boolean create) throws Exception {
    final KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
    final java.security.Key existing = store.getKey(KEY_ALIAS, null);
    if (existing instanceof SecretKey) return (SecretKey) existing;
    if (existing != null || !create) throw new IOException("Calibration storage is unavailable.");
    final KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
    generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
        KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256).build());
    return generator.generateKey();
  }
}
