package com.aidex.aidex_flutter;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import android.system.OsConstants;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
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
    if (!file.exists()) return null;
    final byte[] encrypted;
    try (FileInputStream input = new FileInputStream(file)) {
      if (input.getChannel().size() < 30 || input.getChannel().size() > 2048) {
        throw new java.io.IOException("Invalid encrypted streaming record.");
      }
      encrypted = new byte[(int) input.getChannel().size()];
      new java.io.DataInputStream(input).readFully(encrypted);
    }
    if (encrypted[0] != 1) throw new java.io.IOException("Unsupported streaming envelope.");
    final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.DECRYPT_MODE, key(false),
        new GCMParameterSpec(128, Arrays.copyOfRange(encrypted, 1, 13)));
    cipher.updateAAD(AAD);
    return cipher.doFinal(encrypted, 13, encrypted.length - 13);
  }

  @Override public void write(byte[] bytes) throws Exception {
    final File directory = file.getParentFile();
    if (bytes == null) {
      if (file.exists() && !file.delete()) throw new java.io.IOException("Streaming deletion failed.");
      syncDirectory(directory);
      return;
    }
    final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, key(true));
    cipher.updateAAD(AAD);
    final byte[] iv = cipher.getIV();
    if (iv.length != 12) throw new java.io.IOException("Invalid streaming IV.");
    final byte[] encrypted = cipher.doFinal(bytes);
    final File temporary = new File(directory, ".libre-streaming-" + UUID.randomUUID());
    try {
      if (!temporary.createNewFile()) throw new java.io.IOException("Streaming staging conflict.");
      Os.chmod(temporary.getAbsolutePath(), 0600);
      try (FileOutputStream output = new FileOutputStream(temporary)) {
        output.write(1);
        output.write(iv);
        output.write(encrypted);
        output.flush();
        output.getFD().sync();
      }
      Os.rename(temporary.getAbsolutePath(), file.getAbsolutePath());
      syncDirectory(directory);
    } finally {
      if (temporary.exists()) temporary.delete();
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

  private static void syncDirectory(File directory) throws Exception {
    final FileDescriptor descriptor = Os.open(directory.getAbsolutePath(), OsConstants.O_RDONLY, 0);
    try { Os.fsync(descriptor); } finally { Os.close(descriptor); }
  }
}
