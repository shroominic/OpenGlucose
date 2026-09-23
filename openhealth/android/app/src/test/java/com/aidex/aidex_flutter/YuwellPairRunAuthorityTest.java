package com.aidex.aidex_flutter;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

/** Synthetic standalone JVM behavior checks; Android crypto is outside this harness. */
public final class YuwellPairRunAuthorityTest {
  private static final String KEY = "synthetic-target";
  private static final String NONCE = repeat('a');
  private static final String SIGNER = repeat('b');
  private static final String RECEIPT = repeat('c');
  private static final long NOW = 1_800_000_000_000L;

  private YuwellPairRunAuthorityTest() {}

  public static void main(String[] args) throws Exception {
    claimAndConsumeExactlyOnce();
    twoEnginesShareOneAttempt();
    freshInstanceAndRestartCannotReplay();
    wrongNonceAndKeyNeverConsume();
    sameNonceAlteredBindingCannotSpend();
    identityMismatchNeverGrants();
    selectorAndNativeClockBounds();
    retainedCorruptRecordBlocksClaim();
    failedClaimReturnsNoCapability();
    failedSpendCannotAuthorizeIdentity();
    readbackMismatchPoisonsSharedStore();
    noImplicitResetOrRecovery();
  }

  private static void claimAndConsumeExactlyOnce() throws Exception {
    Fixture f = new Fixture();
    YuwellPairRunAuthority.Claim claim = f.first.claim(KEY, NOW - 1000, f.expected);
    check(claim.expiresAtUtcMillis == NOW + 29000, "expiry derives from observation");
    check(f.disk.size() == 1 && f.backend.writes == 1, "claim is committed once");
    check(f.first.consume(claim.runNonce, KEY), "first consume succeeds");
    check(!f.second.consume(claim.runNonce, KEY), "second engine cannot consume");
    check(f.backend.writes == 2 && f.disk.size() == 1, "spent barrier remains");
    check(f.disk.values().iterator().next().split("\\n", -1)[1].equals("spent"), "state is spent");
  }

  private static void twoEnginesShareOneAttempt() throws Exception {
    Fixture f = new Fixture();
    CountDownLatch ready = new CountDownLatch(2);
    CountDownLatch start = new CountDownLatch(1);
    AtomicReference<YuwellPairRunAuthority.Claim> one = new AtomicReference<>();
    AtomicReference<YuwellPairRunAuthority.Claim> two = new AtomicReference<>();
    AtomicReference<Throwable> errorOne = new AtomicReference<>();
    AtomicReference<Throwable> errorTwo = new AtomicReference<>();
    Thread a = new Thread(() -> raceClaim(f.first, KEY, f.expected, ready, start, one, errorOne));
    Thread b = new Thread(() -> raceClaim(f.second, "other-target", f.expected, ready, start, two, errorTwo));
    a.start(); b.start(); ready.await(); start.countDown(); a.join(); b.join();
    check((one.get() == null) != (two.get() == null), "one process claim wins");
    check((errorOne.get() instanceof YuwellPairRunAuthority.ConflictException)
        != (errorTwo.get() instanceof YuwellPairRunAuthority.ConflictException), "loser conflicts");
    String key = one.get() != null ? KEY : "other-target";
    String nonce = one.get() != null ? one.get().runNonce : two.get().runNonce;
    CountDownLatch consumeReady = new CountDownLatch(2);
    CountDownLatch consumeStart = new CountDownLatch(1);
    AtomicReference<Boolean> c1 = new AtomicReference<>();
    AtomicReference<Boolean> c2 = new AtomicReference<>();
    Thread ca = new Thread(() -> raceConsume(f.first, nonce, key, consumeReady, consumeStart, c1));
    Thread cb = new Thread(() -> raceConsume(f.second, nonce, key, consumeReady, consumeStart, c2));
    ca.start(); cb.start(); consumeReady.await(); consumeStart.countDown(); ca.join(); cb.join();
    check(Boolean.TRUE.equals(c1.get()) != Boolean.TRUE.equals(c2.get()), "one consume wins");
    check(f.backend.writes == 2, "race commits claim and spend once each");
  }

  private static void freshInstanceAndRestartCannotReplay() throws Exception {
    Fixture f = new Fixture();
    String nonce = f.claim().runNonce;
    expect(YuwellPairRunAuthority.ConflictException.class, () -> f.second.claim(KEY, NOW, f.expected));
    Fixture restarted = f.restart();
    check(!restarted.first.consume(nonce, KEY), "restart has no live claim");
    expect(YuwellPairRunAuthority.ConflictException.class, () -> restarted.first.claim(KEY, NOW, restarted.expected));
    check(f.first.consume(nonce, KEY), "original live claim may still spend");
    Fixture afterSpend = f.restart();
    check(!afterSpend.first.consume(nonce, KEY), "spent restart cannot consume");
    expect(YuwellPairRunAuthority.ConflictException.class, () -> afterSpend.first.claim(KEY, NOW, afterSpend.expected));
  }

  private static void wrongNonceAndKeyNeverConsume() throws Exception {
    Fixture f = new Fixture();
    String nonce = f.claim().runNonce;
    check(!f.second.consume(repeat('d'), KEY), "wrong nonce denied");
    check(!f.second.consume(nonce, "other-target"), "wrong key denied");
    check(f.backend.writes == 1 && f.disk.size() == 1, "wrong selectors do not spend");
    check(f.first.consume(nonce, KEY), "correct selector remains eligible");
  }

  private static void sameNonceAlteredBindingCannotSpend() throws Exception {
    String[] replacements = {Long.toString(NOW - 2), Long.toString(NOW + 29999),
        "com.other.app", repeat('d'), "124", "10002", repeat('e'), Long.toString(NOW + 1)};
    int[] fields = {8, 10, 3, 4, 5, 6, 7, 9};
    for (int index = 0; index < fields.length; index++) {
      Fixture f = new Fixture();
      String nonce = f.claim().runNonce;
      String[] lines = f.disk.get("alias:" + KEY).split("\\n", -1);
      lines[fields[index]] = replacements[index];
      if (fields[index] == 8) lines[10] = Long.toString(NOW + 29998);
      if (fields[index] == 10) lines[8] = Long.toString(NOW - 1);
      if (fields[index] == 9) f.backend.wall = NOW + 1;
      f.disk.put("alias:" + KEY, String.join("\n", lines));
      f.backend.memory.putAll(f.disk);
      check(!f.first.consume(nonce, KEY), "altered binding cannot spend");
      check(f.backend.writes == 1, "altered binding has no spent write");
    }
  }

  private static void identityMismatchNeverGrants() throws Exception {
    YuwellPairRunAuthority.InstalledIdentity[] wrong = {
      new YuwellPairRunAuthority.InstalledIdentity("com.other.app", SIGNER, 123, 10001, false),
      new YuwellPairRunAuthority.InstalledIdentity("com.openglucose.app", repeat('d'), 123, 10001, false),
      new YuwellPairRunAuthority.InstalledIdentity("com.openglucose.app", SIGNER, 124, 10001, false),
      new YuwellPairRunAuthority.InstalledIdentity("com.openglucose.app", SIGNER, 123, 10001, true)
    };
    for (YuwellPairRunAuthority.InstalledIdentity identity : wrong) {
      Fixture f = new Fixture(); f.backend.identity = identity;
      expect(YuwellPairRunAuthority.RejectedException.class, () -> f.claim());
      check(f.backend.writes == 0 && f.backend.nonces == 0, "wrong identity never grants");
    }
    Fixture readerFailure = new Fixture(); readerFailure.backend.failIdentity = true;
    expect(YuwellPairRunAuthority.RejectedException.class, () -> readerFailure.claim());
    check(readerFailure.backend.writes == 0 && readerFailure.backend.nonces == 0, "signer reader failure denies");
    for (YuwellPairRunAuthority.InstalledIdentity identity : new YuwellPairRunAuthority.InstalledIdentity[] {
      wrong[0], wrong[1], wrong[2], wrong[3],
      new YuwellPairRunAuthority.InstalledIdentity("com.openglucose.app", SIGNER, 123, 10002, false)}) {
      Fixture f = new Fixture(); String nonce = f.claim().runNonce; f.backend.identity = identity;
      check(!f.first.consume(nonce, KEY), "changed installed identity denies spend");
      check(f.backend.writes == 1 && f.disk.size() == 1, "claim remains retained");
    }
  }

  private static void selectorAndNativeClockBounds() throws Exception {
    for (long observed : new long[] {NOW + 1, NOW - 30001, Long.MAX_VALUE, -1}) {
      Fixture f = new Fixture();
      expect(YuwellPairRunAuthority.RejectedException.class, () -> f.first.claim(KEY, observed, f.expected));
      check(f.backend.writes == 0 && f.backend.nonces == 0, "invalid time never grants");
    }
    for (long age : new long[] {0, 30000}) {
      Fixture f = new Fixture(); String nonce = f.first.claim(KEY, NOW - age, f.expected).runNonce;
      check(f.first.consume(nonce, KEY), "inclusive wall and elapsed deadlines");
    }
    Fixture elapsedOverflow = new Fixture(); elapsedOverflow.backend.elapsed = Long.MAX_VALUE;
    expect(YuwellPairRunAuthority.RejectedException.class, () -> elapsedOverflow.claim());
    check(elapsedOverflow.backend.writes == 0 && elapsedOverflow.backend.nonces == 0,
        "elapsed deadline overflow never grants");
    Fixture rollback = new Fixture(); String rollbackNonce = rollback.claim().runNonce;
    rollback.backend.wall = NOW - 1;
    check(!rollback.first.consume(rollbackNonce, KEY), "wall rollback denies");
    Fixture elapsed = new Fixture(); String elapsedNonce = elapsed.claim().runNonce;
    elapsed.backend.elapsed += 30001;
    check(!elapsed.first.consume(elapsedNonce, KEY), "elapsed expiry denies");
    Fixture wall = new Fixture(); String wallNonce = wall.claim().runNonce;
    wall.backend.wall += 30001;
    check(!wall.first.consume(wallNonce, KEY), "wall expiry denies");
  }

  private static void retainedCorruptRecordBlocksClaim() throws Exception {
    Fixture f = new Fixture(); f.disk.put("alias:" + KEY, "future-schema"); f.backend.memory.putAll(f.disk);
    expect(YuwellPairRunAuthority.ConflictException.class, () -> f.claim());
    check("future-schema".equals(f.disk.get("alias:" + KEY)), "corrupt record retained");
    Fixture g = new Fixture(); String nonce = g.claim().runNonce;
    g.disk.put("alias:" + KEY, "malformed"); g.backend.memory.putAll(g.disk);
    check(!g.first.consume(nonce, KEY), "malformed read denies");
    check(g.backend.writes == 1, "malformed read does not spend");
  }

  private static void failedClaimReturnsNoCapability() throws Exception {
    for (Mode mode : new Mode[] {Mode.BEFORE, Mode.DISK_THEN_THROW, Mode.MEMORY_THEN_THROW}) {
      Fixture f = new Fixture(); f.backend.mode = mode;
      expect(YuwellPairRunAuthority.StoreException.class, () -> f.claim());
      check(f.health.isPoisoned(), "ambiguous claim poisons health");
      expect(YuwellPairRunAuthority.StoreException.class, () -> f.second.claim("other-target", NOW, f.expected));
      check(!f.second.consume(NONCE, KEY), "failed claim has no live capability");
      if (mode == Mode.DISK_THEN_THROW) {
        Fixture restarted = f.restart();
        expect(YuwellPairRunAuthority.ConflictException.class, () -> restarted.claim());
      }
    }
  }

  private static void failedSpendCannotAuthorizeIdentity() throws Exception {
    for (Mode mode : new Mode[] {Mode.BEFORE, Mode.DISK_THEN_THROW, Mode.MEMORY_THEN_THROW}) {
      Fixture f = new Fixture(); String nonce = f.claim().runNonce; f.backend.mode = mode;
      expect(YuwellPairRunAuthority.StoreException.class, () -> f.first.consume(nonce, KEY));
      check(f.health.isPoisoned(), "ambiguous spend poisons health");
      check(!f.second.consume(nonce, KEY), "failed spend cannot authorize again");
      Fixture restarted = f.restart();
      check(!restarted.first.consume(nonce, KEY), "restart has no live grant");
      expect(YuwellPairRunAuthority.ConflictException.class, () -> restarted.claim());
    }
  }

  private static void readbackMismatchPoisonsSharedStore() throws Exception {
    Fixture claim = new Fixture(); claim.backend.staleAtWrite = 1;
    expect(YuwellPairRunAuthority.StoreException.class, () -> claim.claim());
    check(claim.health.isPoisoned(), "claim readback mismatch poisons");
    Fixture spend = new Fixture(); String nonce = spend.claim().runNonce;
    spend.backend.staleAtWrite = 2;
    expect(YuwellPairRunAuthority.StoreException.class, () -> spend.first.consume(nonce, KEY));
    check(spend.health.isPoisoned(), "spend readback mismatch poisons");
  }

  private static void noImplicitResetOrRecovery() throws Exception {
    Fixture f = new Fixture(); String nonce = f.claim().runNonce;
    check(f.first.consume(nonce, KEY), "spend succeeded");
    Fixture restarted = f.restart();
    expect(YuwellPairRunAuthority.ConflictException.class, () -> restarted.claim());
    check(restarted.disk.size() == 1, "run record remains retained");
  }

  private static void raceClaim(YuwellPairRunAuthority authority, String key,
      YuwellPairRunAuthority.ExpectedBuild expected, CountDownLatch ready, CountDownLatch start,
      AtomicReference<YuwellPairRunAuthority.Claim> result, AtomicReference<Throwable> error) {
    ready.countDown();
    try { start.await(); result.set(authority.claim(key, NOW, expected)); }
    catch (Throwable failure) { error.set(failure); }
  }

  private static void raceConsume(YuwellPairRunAuthority authority, String nonce, String key,
      CountDownLatch ready, CountDownLatch start, AtomicReference<Boolean> result) {
    ready.countDown();
    try { start.await(); result.set(authority.consume(nonce, key)); }
    catch (Throwable failure) { result.set(false); }
  }

  private enum Mode { SUCCESS, BEFORE, DISK_THEN_THROW, MEMORY_THEN_THROW }

  private static final class FakeBackend implements YuwellPairRunAuthority.Backend {
    final Map<String, String> disk;
    final Map<String, String> memory = new HashMap<>();
    Mode mode = Mode.SUCCESS;
    long wall = NOW;
    long elapsed = 100000;
    int writes;
    int aliases;
    int nonces;
    boolean failIdentity;
    int staleAtWrite;
    YuwellPairRunAuthority.InstalledIdentity identity =
        new YuwellPairRunAuthority.InstalledIdentity("com.openglucose.app", SIGNER, 123, 10001, false);

    FakeBackend(Map<String, String> disk) { this.disk = disk; memory.putAll(disk); }
    public String aliasFor(String key) { aliases++; return "alias:" + key; }
    public boolean contains(String alias) { return memory.containsKey(alias); }
    public String read(String alias) { return writes == staleAtWrite ? "stale" : memory.get(alias); }
    public void write(String alias, String record) throws Exception {
      writes++;
      switch (mode) {
        case BEFORE: throw new Exception("synthetic before write");
        case DISK_THEN_THROW: disk.put(alias, record); memory.put(alias, record); throw new Exception("synthetic after disk");
        case MEMORY_THEN_THROW: memory.put(alias, record); throw new Exception("synthetic memory only");
        default: disk.put(alias, record); memory.put(alias, record);
      }
    }
    public String newNonce() { nonces++; return NONCE; }
    public YuwellPairRunAuthority.InstalledIdentity installedIdentity() throws Exception {
      if (failIdentity) throw new Exception("synthetic signer failure");
      return identity;
    }
    public long wallTimeMillis() { return wall; }
    public long elapsedRealtimeMillis() { return elapsed; }
  }

  private static final class Fixture {
    final Map<String, String> disk;
    final Object lock = new Object();
    final YuwellStoreHealth health = new YuwellStoreHealth();
    final YuwellPairRunAuthority.ProcessState process = new YuwellPairRunAuthority.ProcessState();
    final FakeBackend backend;
    final YuwellPairRunAuthority.ExpectedBuild expected =
        new YuwellPairRunAuthority.ExpectedBuild("com.openglucose.app", SIGNER, 123, RECEIPT);
    final YuwellPairRunAuthority first;
    final YuwellPairRunAuthority second;

    Fixture() { this(new HashMap<>()); }
    Fixture(Map<String, String> disk) {
      this.disk = disk;
      backend = new FakeBackend(disk);
      first = new YuwellPairRunAuthority(backend, lock, health, process);
      second = new YuwellPairRunAuthority(backend, lock, health, process);
    }
    YuwellPairRunAuthority.Claim claim() throws Exception { return first.claim(KEY, NOW, expected); }
    Fixture restart() { return new Fixture(disk); }
  }

  private interface Action { void run() throws Exception; }
  private static void expect(Class<? extends Throwable> type, Action action) throws Exception {
    try { action.run(); }
    catch (Throwable error) {
      if (type.isInstance(error)) return;
      throw new AssertionError("unexpected fixed failure type", error);
    }
    throw new AssertionError("expected fixed failure");
  }
  private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
  private static String repeat(char value) { return String.valueOf(value).repeat(64); }
}
