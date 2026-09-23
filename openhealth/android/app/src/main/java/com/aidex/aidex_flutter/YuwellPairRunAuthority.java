package com.aidex.aidex_flutter;

import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/** One-use V1140 authorization; no pairing operation is initiated here. */
final class YuwellPairRunAuthority {
  private static final String PACKAGE_NAME = "com.openglucose.app";
  private static final long LIFETIME_MILLIS = 30_000L;
  private static final Pattern HASH = Pattern.compile("[0-9a-f]{64}");
  interface Backend {
    String aliasFor(String storageKey) throws Exception;
    boolean contains(String alias) throws Exception;
    String read(String alias) throws Exception;
    void write(String alias, String record) throws Exception;
    String newNonce();
    InstalledIdentity installedIdentity() throws Exception;
    long wallTimeMillis();
    long elapsedRealtimeMillis();
  }

  static final class ExpectedBuild {
    final String packageName;
    final String signerSha256;
    final long versionCode;
    final String receiptSha256;

    ExpectedBuild(String packageName, String signerSha256, long versionCode, String receiptSha256) {
      this.packageName = packageName;
      this.signerSha256 = signerSha256;
      this.versionCode = versionCode;
      this.receiptSha256 = receiptSha256;
    }
  }

  static final class InstalledIdentity {
    final String packageName;
    final String signerSha256;
    final long versionCode;
    final int uid;
    final boolean debuggable;

    InstalledIdentity(String packageName, String signerSha256, long versionCode, int uid, boolean debuggable) {
      this.packageName = packageName;
      this.signerSha256 = signerSha256;
      this.versionCode = versionCode;
      this.uid = uid;
      this.debuggable = debuggable;
    }
  }

  static final class Claim {
    final String runNonce;
    final long expiresAtUtcMillis;

    Claim(String runNonce, long expiresAtUtcMillis) {
      this.runNonce = runNonce;
      this.expiresAtUtcMillis = expiresAtUtcMillis;
    }
  }

  static final class ProcessState {
    boolean attempted;
    String liveAlias;
    String liveNonce;
    String originalRecord;
    long elapsedAtClaim;
    long elapsedDeadline;

    void close() {
      liveAlias = null;
      liveNonce = null;
      originalRecord = null;
    }
  }
  static final class ConflictException extends Exception {}
  static final class RejectedException extends Exception {}
  static final class StoreException extends Exception {}

  private final Backend backend;
  private final Object storeLock;
  private final YuwellStoreHealth health;
  private final ProcessState processState;

  YuwellPairRunAuthority(Backend backend, Object storeLock, YuwellStoreHealth health, ProcessState processState) {
    this.backend = backend;
    this.storeLock = storeLock;
    this.health = health;
    this.processState = processState;
  }

  Claim claim(String storageKey, long observedAtUtcMillis, ExpectedBuild expected) throws Exception {
    synchronized (storeLock) {
      healthy();
      if (!validKey(storageKey) || expected == null
          || !PACKAGE_NAME.equals(expected.packageName)
          || !hash(expected.signerSha256) || !hash(expected.receiptSha256)
          || expected.versionCode <= 0 || observedAtUtcMillis < 0) {
        throw new RejectedException();
      }
      final InstalledIdentity identity;
      try {
        identity = backend.installedIdentity();
      } catch (Exception error) {
        throw new RejectedException();
      }
      if (identity == null || !PACKAGE_NAME.equals(identity.packageName)
          || !expected.signerSha256.equals(identity.signerSha256)
          || expected.versionCode != identity.versionCode || identity.uid < 0
          || identity.debuggable) {
        throw new RejectedException();
      }
      final long now = backend.wallTimeMillis();
      final long elapsed = backend.elapsedRealtimeMillis();
      final long age;
      final long expires;
      final long deadline;
      try {
        age = Math.subtractExact(now, observedAtUtcMillis);
        expires = Math.addExact(observedAtUtcMillis, LIFETIME_MILLIS);
        deadline = Math.addExact(elapsed, LIFETIME_MILLIS - age);
      } catch (ArithmeticException error) {
        throw new RejectedException();
      }
      if (now < 0 || elapsed < 0 || age < 0 || age > LIFETIME_MILLIS) {
        throw new RejectedException();
      }
      if (processState.attempted) throw new ConflictException();
      processState.attempted = true;
      processState.close();
      final String alias;
      try {
        alias = backend.aliasFor(storageKey);
        if (backend.contains(alias)) throw new ConflictException();
      } catch (ConflictException error) {
        throw error;
      } catch (Exception error) {
        throw new StoreException();
      }
      final String nonce;
      try {
        nonce = backend.newNonce();
      } catch (Exception error) {
        throw new StoreException();
      }
      if (!hash(nonce)) throw new StoreException();
      final String record = encode("claimed", nonce, identity, expected,
          observedAtUtcMillis, now, expires);
      try {
        backend.write(alias, record);
        if (!record.equals(backend.read(alias))) throw new StoreException();
      } catch (Exception error) {
        health.poison();
        processState.close();
        throw new StoreException();
      }
      processState.liveAlias = alias;
      processState.liveNonce = nonce;
      processState.originalRecord = record;
      processState.elapsedAtClaim = elapsed;
      processState.elapsedDeadline = deadline;
      return new Claim(nonce, expires);
    }
  }

  boolean consume(String runNonce, String storageKey) throws Exception {
    synchronized (storeLock) {
      if (health.isPoisoned() || !hash(runNonce) || !validKey(storageKey)
          || processState.liveAlias == null || !runNonce.equals(processState.liveNonce)) {
        return false;
      }
      final String alias;
      try {
        alias = backend.aliasFor(storageKey);
      } catch (Exception error) {
        processState.close();
        return false;
      }
      if (!alias.equals(processState.liveAlias)) return false;
      final String persisted;
      try {
        persisted = backend.read(alias);
      } catch (Exception error) {
        processState.close();
        return false;
      }
      final String[] fields = parseClaimed(persisted);
      if (fields == null || !persisted.equals(processState.originalRecord)) {
        processState.close();
        return false;
      }
      final InstalledIdentity actual;
      try {
        actual = backend.installedIdentity();
      } catch (Exception error) {
        processState.close();
        return false;
      }
      if (actual == null || actual.debuggable || actual.uid != Integer.parseInt(fields[6])
          || actual.versionCode != Long.parseLong(fields[5])
          || !actual.packageName.equals(fields[3])
          || !actual.signerSha256.equals(fields[4])) {
        processState.close();
        return false;
      }
      final long wall = backend.wallTimeMillis();
      final long elapsed = backend.elapsedRealtimeMillis();
      if (wall < Long.parseLong(fields[9]) || wall > Long.parseLong(fields[10])
          || elapsed < processState.elapsedAtClaim || elapsed > processState.elapsedDeadline) {
        processState.close();
        return false;
      }
      processState.close();
      fields[1] = "spent";
      final String spent = String.join("\n", fields);
      try {
        backend.write(alias, spent);
        if (!spent.equals(backend.read(alias))) throw new StoreException();
      } catch (Exception error) {
        health.poison();
        throw new StoreException();
      }
      return true;
    }
  }

  private void healthy() throws StoreException {
    if (health.isPoisoned()) throw new StoreException();
  }

  private static String encode(String state, String nonce, InstalledIdentity identity,
      ExpectedBuild expected, long observed, long created, long expires) {
    return String.join("\n", "1", state, nonce, identity.packageName,
        identity.signerSha256, Long.toString(identity.versionCode),
        Integer.toString(identity.uid), expected.receiptSha256,
        Long.toString(observed), Long.toString(created), Long.toString(expires));
  }

  private static String[] parseClaimed(String record) {
    if (record == null || record.getBytes(StandardCharsets.UTF_8).length > 64 * 1024) return null;
    final String[] fields = record.split("\n", -1);
    if (fields.length != 11 || !"1".equals(fields[0]) || !"claimed".equals(fields[1])
        || !hash(fields[2]) || !PACKAGE_NAME.equals(fields[3]) || !hash(fields[4])
        || !hash(fields[7])) return null;
    try {
      long version = Long.parseLong(fields[5]);
      int uid = Integer.parseInt(fields[6]);
      long observed = Long.parseLong(fields[8]);
      long created = Long.parseLong(fields[9]);
      long expires = Long.parseLong(fields[10]);
      if (version <= 0 || uid < 0 || observed < 0 || created < observed
          || expires != Math.addExact(observed, LIFETIME_MILLIS)
          || created > expires || !Long.toString(version).equals(fields[5])
          || !Integer.toString(uid).equals(fields[6])
          || !Long.toString(observed).equals(fields[8])
          || !Long.toString(created).equals(fields[9])
          || !Long.toString(expires).equals(fields[10])) return null;
    } catch (NumberFormatException | ArithmeticException error) {
      return null;
    }
    return fields;
  }

  private static boolean hash(String value) {
    return value != null && HASH.matcher(value).matches();
  }

  private static boolean validKey(String value) {
    if (value == null || value.trim().isEmpty()) return false;
    int length = value.getBytes(StandardCharsets.UTF_8).length;
    return length > 0 && length <= 4096;
  }
}
