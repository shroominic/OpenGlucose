package com.aidex.aidex_flutter;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;
import android.os.Process;
import android.os.SystemClock;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import javax.crypto.SecretKey;

/**
 * Durable, app-private storage for Yuwell CT5 credentials and write intents.
 *
 * <p>Sensor-derived storage keys are HMACed with a non-exportable Android
 * Keystore key before they are used as SharedPreferences keys. Values are
 * encrypted with a separate non-exportable AES-GCM key. Journal mutations use
 * synchronous, verified commits so an awaited Dart call is a durability
 * boundary before any state-changing BLE write. If a commit fails, an
 * irreversible process-wide latch blocks all further access. A process restart
 * then recovers only the last disk-backed state.
 */
final class YuwellSecureStoreBridge {
  static final String CHANNEL_NAME = "com.openglucose/yuwell_secure_store";

  private static final String ANDROID_KEY_STORE = "AndroidKeyStore";
  private static final String PREFERENCES_NAME =
      "openglucose_yuwell_ct5_secure_v2";
  private static final String AES_KEY_ALIAS =
      "openglucose_yuwell_ct5_aes_gcm_v2";
  private static final String HMAC_KEY_ALIAS =
      "openglucose_yuwell_ct5_hmac_sha256_v2";
  private static final String CREDENTIAL_PREFIX = "credential.";
  private static final String INTENT_PREFIX = "intent.";
  private static final String PAIR_RUN_PREFIX = "v1140_pair_run.";
  private static final byte ENVELOPE_VERSION = 1;
  private static final int GCM_IV_BYTES = 12;
  private static final int GCM_TAG_BITS = 128;
  private static final int RANDOM_NONCE_BYTES = 32;
  private static final int MAX_STORAGE_KEY_BYTES = 4096;
  private static final int MAX_CREDENTIAL_BYTES = 64 * 1024;
  private static final int MAX_ENVELOPE_BYTES = 128 * 1024;

  private static final Pattern TOKEN_PATTERN =
      Pattern.compile(
          "^ct5\\.intent\\.v2\\.([0-9a-f]{64})\\.([0-9a-f]{64})$");
  private static final Set<String> OPERATIONS =
      Collections.unmodifiableSet(
          new HashSet<>(
              Arrays.asList(
                  "setDate",
                  "setCommunicationId",
                  "configure",
                  "initialize",
                  "lowPower")));
  private static final Set<String> STATES =
      Collections.unmodifiableSet(
          new HashSet<>(Arrays.asList("prepared", "transmitted", "unknown")));
  // MainActivity normally creates one bridge. The static lock also protects
  // against multiple Flutter engines in the same application process.
  private static final Object STORE_LOCK = new Object();
  private static final YuwellStoreHealth STORE_HEALTH =
      new YuwellStoreHealth();
  private static final YuwellPairRunAuthority.ProcessState PAIR_RUN_STATE =
      new YuwellPairRunAuthority.ProcessState();

  private final Context applicationContext;
  private final SharedPreferences preferences;
  private final SecureRandom secureRandom;
  private final YuwellWriteJournal writeJournal;
  private final YuwellPairRunAuthority pairRunAuthority;

  YuwellSecureStoreBridge(Context context) {
    applicationContext = context.getApplicationContext();
    preferences =
        applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE);
    secureRandom = new SecureRandom();
    writeJournal =
        new YuwellWriteJournal(
            new YuwellWriteJournal.Backend() {
              @Override
              public String aliasFor(String storageKey) throws Exception {
                return storageAlias(storageKey);
              }

              @Override
              public boolean contains(String alias) {
                return preferences.contains(INTENT_PREFIX + alias);
              }

              @Override
              public String read(String alias) throws Exception {
                return readEncrypted(INTENT_PREFIX + alias, "intent", alias);
              }

              @Override
              public void write(String alias, String record) throws Exception {
                writeEncrypted(INTENT_PREFIX + alias, "intent", alias, record);
              }

              @Override
              public void remove(String alias) throws Exception {
                commitOrThrow(
                    preferences.edit().remove(INTENT_PREFIX + alias));
              }

              @Override
              public String newNonce() {
                final byte[] bytes = new byte[RANDOM_NONCE_BYTES];
                secureRandom.nextBytes(bytes);
                return hex(bytes);
              }
            });
    pairRunAuthority =
        new YuwellPairRunAuthority(
            new YuwellPairRunAuthority.Backend() {
              @Override
              public String aliasFor(String storageKey) throws Exception {
                return storageAlias(storageKey);
              }

              @Override
              public boolean contains(String alias) {
                return preferences.contains(PAIR_RUN_PREFIX + alias);
              }

              @Override
              public String read(String alias) throws Exception {
                return readEncrypted(PAIR_RUN_PREFIX + alias, "v1140_pair_run", alias);
              }

              @Override
              public void write(String alias, String record) throws Exception {
                writeEncrypted(PAIR_RUN_PREFIX + alias, "v1140_pair_run", alias, record);
              }

              @Override
              public String newNonce() {
                final byte[] bytes = new byte[RANDOM_NONCE_BYTES];
                secureRandom.nextBytes(bytes);
                return hex(bytes);
              }

              @Override
              public YuwellPairRunAuthority.InstalledIdentity installedIdentity()
                  throws Exception {
                return readInstalledIdentity();
              }

              @Override
              public long wallTimeMillis() {
                return System.currentTimeMillis();
              }

              @Override
              public long elapsedRealtimeMillis() {
                return SystemClock.elapsedRealtime();
              }
            },
            STORE_LOCK,
            STORE_HEALTH,
            PAIR_RUN_STATE);
  }

  void register(BinaryMessenger messenger) {
    new MethodChannel(messenger, CHANNEL_NAME)
        .setMethodCallHandler(this::handleMethodCall);
  }

  private void handleMethodCall(MethodCall call, MethodChannel.Result result) {
    try {
      requireStoreHealthy();
      switch (call.method) {
        case "readV1140AppIdentity":
          requireExactKeys(call.arguments);
          result.success(identityMap(readInstalledIdentity()));
          return;
        case "claimV1140Run":
          requireExactKeys(call.arguments, "storageKey", "observedAtUtcMillis",
              "expectedPackageName", "expectedSignerSha256", "expectedVersionCode",
              "receiptSha256");
          final YuwellPairRunAuthority.Claim claim = pairRunAuthority.claim(
              requireStorageKey(call.arguments),
              requireLong(call.arguments, "observedAtUtcMillis"),
              new YuwellPairRunAuthority.ExpectedBuild(
                  requireString(call.arguments, "expectedPackageName"),
                  requireString(call.arguments, "expectedSignerSha256"),
                  requireLong(call.arguments, "expectedVersionCode"),
                  requireString(call.arguments, "receiptSha256")));
          final Map<String, Object> claimResult = new HashMap<>();
          claimResult.put("runNonce", claim.runNonce);
          claimResult.put("expiresAtUtcMillis", claim.expiresAtUtcMillis);
          result.success(claimResult);
          return;
        case "consumeV1140Run":
          requireExactKeys(call.arguments, "runNonce", "storageKey");
          result.success(pairRunAuthority.consume(
              requireString(call.arguments, "runNonce"),
              requireStorageKey(call.arguments)));
          return;
        case "readCredential":
          result.success(readCredential(requireStorageKey(call.arguments)));
          return;
        case "writeCredential":
          writeCredential(
              requireStorageKey(call.arguments),
              requireCredential(call.arguments));
          result.success(null);
          return;
        case "deleteCredential":
          deleteCredential(requireStorageKey(call.arguments));
          result.success(null);
          return;
        case "hasUnresolved":
          result.success(hasUnresolved(requireStorageKey(call.arguments)));
          return;
        case "readUnresolved":
          result.success(readUnresolved(requireStorageKey(call.arguments)));
          return;
        case "prepare":
          result.success(
              prepare(
                  requireStorageKey(call.arguments),
                  requireOperation(call.arguments)));
          return;
        case "markTransmitted":
          markTransmitted(requireToken(call.arguments));
          result.success(null);
          return;
        case "markCompleted":
          markCompleted(requireToken(call.arguments));
          result.success(null);
          return;
        case "markUnknown":
          markUnknown(requireToken(call.arguments));
          result.success(null);
          return;
        case "cancelPrepared":
          cancelPrepared(requireToken(call.arguments));
          result.success(null);
          return;
        case "resolveRecovered":
          resolveRecovered(
              requireToken(call.arguments),
              requireExpectedOperation(call.arguments),
              requireExpectedState(call.arguments));
          result.success(null);
          return;
        case "replaceRecoveredWithPrepared":
          result.success(
              replaceRecoveredWithPrepared(
                  requireToken(call.arguments),
                  requireStorageKey(call.arguments),
                  requireOperation(call.arguments),
                  requireExpectedOperation(call.arguments),
                  requireExpectedState(call.arguments)));
          return;
        default:
          result.notImplemented();
      }
    } catch (BadArgumentsException error) {
      result.error("bad_args", "Invalid Yuwell secure-store request.", null);
    } catch (YuwellWriteJournal.ConflictException error) {
      result.error("conflict", "Yuwell write journal is unresolved.", null);
    } catch (YuwellPairRunAuthority.ConflictException error) {
      result.error("run_conflict", "V1140 run claim is unavailable.", null);
    } catch (YuwellPairRunAuthority.RejectedException error) {
      result.error("run_rejected", "V1140 run claim was rejected.", null);
    } catch (Exception error) {
      // Do not forward exception text or details. Crypto providers and storage
      // decoders can include private material in diagnostic messages.
      result.error(
          "secure_store_failed",
          "Yuwell secure storage failed closed.",
          null);
    }
  }

  private YuwellPairRunAuthority.InstalledIdentity readInstalledIdentity()
      throws Exception {
    final String packageName = applicationContext.getPackageName();
    final PackageManager manager = applicationContext.getPackageManager();
    final int flags = Build.VERSION.SDK_INT >= 28
        ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
    final PackageInfo info = manager.getPackageInfo(packageName, flags);
    final Signature[] signers = Build.VERSION.SDK_INT >= 28
        ? (info.signingInfo == null ? null : info.signingInfo.getApkContentsSigners())
        : info.signatures;
    if (signers == null || signers.length != 1 || signers[0] == null) {
      throw new StoreException();
    }
    final byte[] certificate = signers[0].toByteArray();
    if (certificate == null || certificate.length == 0) throw new StoreException();
    final long version = Build.VERSION.SDK_INT >= 28
        ? info.getLongVersionCode() : info.versionCode;
    if (version <= 0) throw new StoreException();
    final String signerHash = hex(MessageDigest.getInstance("SHA-256").digest(certificate));
    final ApplicationInfo appInfo = applicationContext.getApplicationInfo();
    if (appInfo == null) throw new StoreException();
    return new YuwellPairRunAuthority.InstalledIdentity(
        packageName, signerHash, version, Process.myUid(),
        (appInfo.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0);
  }

  private static Map<String, Object> identityMap(
      YuwellPairRunAuthority.InstalledIdentity identity) {
    final Map<String, Object> result = new HashMap<>();
    result.put("packageName", identity.packageName);
    result.put("signerSha256", identity.signerSha256);
    result.put("versionCode", identity.versionCode);
    result.put("uid", identity.uid);
    result.put("debuggable", identity.debuggable);
    return result;
  }

  private static void requireExactKeys(Object arguments, String... keys)
      throws BadArgumentsException {
    if (!(arguments instanceof Map<?, ?>)) throw new BadArgumentsException();
    final Map<?, ?> map = (Map<?, ?>) arguments;
    if (map.size() != keys.length) throw new BadArgumentsException();
    for (String key : keys) {
      if (!map.containsKey(key)) throw new BadArgumentsException();
    }
  }

  private static long requireLong(Object arguments, String key)
      throws BadArgumentsException {
    final Object value = ((Map<?, ?>) arguments).get(key);
    if (!(value instanceof Long) && !(value instanceof Integer)) {
      throw new BadArgumentsException();
    }
    return ((Number) value).longValue();
  }

  private String readCredential(String storageKey)
      throws GeneralSecurityException, StoreException {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      final String alias = storageAlias(storageKey);
      return readEncrypted(CREDENTIAL_PREFIX + alias, "credential", alias);
    }
  }

  private void writeCredential(String storageKey, String credential)
      throws GeneralSecurityException, StoreException {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      final String alias = storageAlias(storageKey);
      writeEncrypted(
          CREDENTIAL_PREFIX + alias, "credential", alias, credential);
    }
  }

  private void deleteCredential(String storageKey)
      throws GeneralSecurityException, StoreException {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      final String alias = storageAlias(storageKey);
      commitOrThrow(preferences.edit().remove(CREDENTIAL_PREFIX + alias));
    }
  }

  private boolean hasUnresolved(String storageKey) throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      // Presence alone is unresolved. A corrupt encrypted value must continue
      // to block activation rather than being deleted or treated as absent.
      return writeJournal.hasUnresolved(storageKey);
    }
  }

  private Map<String, Object> readUnresolved(String storageKey)
      throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      final YuwellWriteJournal.Snapshot snapshot =
          writeJournal.readUnresolved(storageKey);
      if (snapshot == null) {
        return null;
      }
      final Map<String, Object> result = new HashMap<>();
      result.put("token", snapshot.token);
      result.put("operation", snapshot.operation);
      result.put("state", snapshot.state);
      return result;
    }
  }

  private String prepare(String storageKey, String operation)
      throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      return writeJournal.prepare(storageKey, operation);
    }
  }

  private void markTransmitted(String token) throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      writeJournal.markTransmitted(token);
    }
  }

  private void markCompleted(String token) throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      writeJournal.markCompleted(token);
    }
  }

  private void markUnknown(String token) throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      writeJournal.markUnknown(token);
    }
  }

  private void cancelPrepared(String token) throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      writeJournal.cancelPrepared(token);
    }
  }

  private void resolveRecovered(
      String token, String expectedOperation, String expectedState)
      throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      writeJournal.resolveRecovered(token, expectedOperation, expectedState);
    }
  }

  private String replaceRecoveredWithPrepared(
      String token,
      String storageKey,
      String operation,
      String expectedOperation,
      String expectedState)
      throws Exception {
    synchronized (STORE_LOCK) {
      requireStoreHealthy();
      return writeJournal.replaceRecoveredWithPrepared(
          token, storageKey, operation, expectedOperation, expectedState);
    }
  }

  private String readEncrypted(String preferenceKey, String kind, String alias)
      throws GeneralSecurityException, StoreException {
    final String envelope;
    try {
      envelope = preferences.getString(preferenceKey, null);
    } catch (ClassCastException error) {
      throw new StoreException();
    }
    if (envelope == null) {
      return null;
    }
    final byte[] packed;
    try {
      packed =
          Base64.decode(
              envelope,
              Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING);
    } catch (IllegalArgumentException error) {
      throw new StoreException();
    }
    if (packed.length < 2 + GCM_IV_BYTES + 16
        || packed.length > MAX_ENVELOPE_BYTES
        || packed[0] != ENVELOPE_VERSION
        || (packed[1] & 0xff) != GCM_IV_BYTES) {
      throw new StoreException();
    }

    final byte[] iv = Arrays.copyOfRange(packed, 2, 2 + GCM_IV_BYTES);
    final byte[] ciphertext =
        Arrays.copyOfRange(packed, 2 + GCM_IV_BYTES, packed.length);
    final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(
        Cipher.DECRYPT_MODE,
        encryptionKey(),
        new javax.crypto.spec.GCMParameterSpec(GCM_TAG_BITS, iv));
    cipher.updateAAD(aad(kind, alias));
    final byte[] clear = cipher.doFinal(ciphertext);
    if (clear.length > MAX_CREDENTIAL_BYTES) {
      throw new StoreException();
    }
    return new String(clear, StandardCharsets.UTF_8);
  }

  private void writeEncrypted(
      String preferenceKey, String kind, String alias, String cleartext)
      throws GeneralSecurityException, StoreException {
    final byte[] clear = cleartext.getBytes(StandardCharsets.UTF_8);
    if (clear.length == 0 || clear.length > MAX_CREDENTIAL_BYTES) {
      throw new StoreException();
    }
    final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, encryptionKey());
    final byte[] iv = cipher.getIV();
    if (iv == null || iv.length != GCM_IV_BYTES) {
      throw new StoreException();
    }
    cipher.updateAAD(aad(kind, alias));
    final byte[] ciphertext = cipher.doFinal(clear);
    final ByteBuffer packed =
        ByteBuffer.allocate(2 + iv.length + ciphertext.length);
    packed.put(ENVELOPE_VERSION);
    packed.put((byte) iv.length);
    packed.put(iv);
    packed.put(ciphertext);
    final String envelope =
        Base64.encodeToString(
            packed.array(),
            Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING);
    commitOrThrow(preferences.edit().putString(preferenceKey, envelope));
  }

  private String storageAlias(String storageKey)
      throws GeneralSecurityException {
    final byte[] storageBytes = storageKey.getBytes(StandardCharsets.UTF_8);
    final byte[] domain = "yuwell-anytime-5p\u0000".getBytes(StandardCharsets.UTF_8);
    final Mac hmac = Mac.getInstance("HmacSHA256");
    hmac.init(aliasKey());
    hmac.update(domain);
    return hex(hmac.doFinal(storageBytes));
  }

  private SecretKey encryptionKey() throws GeneralSecurityException {
    return getOrCreateKey(AES_KEY_ALIAS, true);
  }

  private SecretKey aliasKey() throws GeneralSecurityException {
    return getOrCreateKey(HMAC_KEY_ALIAS, false);
  }

  private SecretKey getOrCreateKey(String keyAlias, boolean encryption)
      throws GeneralSecurityException {
    final KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
    try {
      keyStore.load(null);
    } catch (java.io.IOException error) {
      throw new GeneralSecurityException(error);
    }
    final java.security.Key existing = keyStore.getKey(keyAlias, null);
    if (existing != null) {
      if (!(existing instanceof SecretKey)) {
        throw new GeneralSecurityException("Unexpected secure-key type.");
      }
      return (SecretKey) existing;
    }

    final String algorithm =
        encryption ? KeyProperties.KEY_ALGORITHM_AES : KeyProperties.KEY_ALGORITHM_HMAC_SHA256;
    final KeyGenerator generator =
        KeyGenerator.getInstance(algorithm, ANDROID_KEY_STORE);
    final KeyGenParameterSpec.Builder builder =
        new KeyGenParameterSpec.Builder(
            keyAlias,
            encryption
                ? KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT
                : KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
            .setKeySize(256);
    if (encryption) {
      builder
          .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
          .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
          .setRandomizedEncryptionRequired(true);
    } else {
      builder.setDigests(KeyProperties.DIGEST_SHA256);
    }
    generator.init(builder.build());
    return generator.generateKey();
  }

  private static byte[] aad(String kind, String alias) {
    return ("openglucose-yuwell-ct5-v2\u0000" + kind + "\u0000" + alias)
        .getBytes(StandardCharsets.UTF_8);
  }

  private static void commitOrThrow(SharedPreferences.Editor editor)
      throws StoreException {
    final boolean committed;
    try {
      committed = editor.commit();
    } catch (RuntimeException error) {
      STORE_HEALTH.poison();
      throw new StoreException();
    }
    if (!committed) {
      // SharedPreferences can expose the attempted mutation in memory even
      // when disk persistence reports failure. Do not trust any later read in
      // this process. Restart before recovering the last disk-backed state.
      STORE_HEALTH.poison();
      throw new StoreException();
    }
  }

  private static void requireStoreHealthy() throws StoreException {
    if (STORE_HEALTH.isPoisoned()) {
      throw new StoreException();
    }
  }

  private static String requireStorageKey(Object arguments)
      throws BadArgumentsException {
    final String value = requireString(arguments, "storageKey");
    final int byteLength = value.getBytes(StandardCharsets.UTF_8).length;
    if (value.trim().isEmpty()
        || byteLength == 0
        || byteLength > MAX_STORAGE_KEY_BYTES) {
      throw new BadArgumentsException();
    }
    return value;
  }

  private static String requireCredential(Object arguments)
      throws BadArgumentsException {
    final String value = requireString(arguments, "credential");
    final int byteLength = value.getBytes(StandardCharsets.UTF_8).length;
    if (byteLength == 0 || byteLength > MAX_CREDENTIAL_BYTES) {
      throw new BadArgumentsException();
    }
    return value;
  }

  private static String requireOperation(Object arguments)
      throws BadArgumentsException {
    return requireOperation(arguments, "operation");
  }

  private static String requireExpectedOperation(Object arguments)
      throws BadArgumentsException {
    return requireOperation(arguments, "expectedOperation");
  }

  private static String requireOperation(Object arguments, String key)
      throws BadArgumentsException {
    final String operation = requireString(arguments, key);
    if (!OPERATIONS.contains(operation)) {
      throw new BadArgumentsException();
    }
    return operation;
  }

  private static String requireExpectedState(Object arguments)
      throws BadArgumentsException {
    final String state = requireString(arguments, "expectedState");
    if (!STATES.contains(state)) {
      throw new BadArgumentsException();
    }
    return state;
  }

  private static String requireToken(Object arguments)
      throws BadArgumentsException {
    final String token = requireString(arguments, "token");
    if (!TOKEN_PATTERN.matcher(token).matches()) {
      throw new BadArgumentsException();
    }
    return token;
  }

  private static String requireString(Object arguments, String key)
      throws BadArgumentsException {
    if (!(arguments instanceof Map<?, ?>)) {
      throw new BadArgumentsException();
    }
    final Object value = ((Map<?, ?>) arguments).get(key);
    if (!(value instanceof String)) {
      throw new BadArgumentsException();
    }
    return (String) value;
  }

  private static String hex(byte[] value) {
    final char[] alphabet = "0123456789abcdef".toCharArray();
    final char[] output = new char[value.length * 2];
    for (int index = 0; index < value.length; index++) {
      final int current = value[index] & 0xff;
      output[index * 2] = alphabet[current >>> 4];
      output[index * 2 + 1] = alphabet[current & 0x0f];
    }
    return new String(output);
  }

  private static final class BadArgumentsException extends Exception {}

  private static final class StoreException extends Exception {}
}
