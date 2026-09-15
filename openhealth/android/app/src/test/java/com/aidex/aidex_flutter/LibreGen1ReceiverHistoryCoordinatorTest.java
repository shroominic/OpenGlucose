package com.aidex.aidex_flutter;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.lang.reflect.Field;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;

/** Pure synthetic read-purpose checks. No Android, capture files or private inputs. */
public final class LibreGen1ReceiverHistoryCoordinatorTest {
  private static final String FIRST = "synthetic_history_one", SECOND = "synthetic_history_two";
  private static final byte[] UID = fixture("UID"), PATCH = fixture("PATCH"), FRAM = fixture("ENCRYPTED");
  static { UID[6] = 7; UID[7] = (byte) 0xe0; }

  public static void main(String[] args) throws Exception {
    closedCapabilitiesAndArguments();
    absentUnknownAndWrongReceiverDoNotAcquire();
    exactReadStopAndOneUseHandoff();
    frozenSeedIsNotCurrentSeed();
    exactIdentityAtEveryReadAndDelivery();
    cleanupMustFinishBeforeHandoff();
    cancellationPauseDetachAndStaleCallbacks();
    expiryAndReplacementWipeEvidence();
    failedDeliveryWipesOwnedBuffers();
    failedCloseReaderAndLeaseStayQuarantined();
    sharedLeaseBlocksBleAndHistoryWithoutCounterWrites();
    inFlightTimeoutCannotBecomeAValidLateRead();
    newLeaseBlocksDeliveryAndKeepsUnknownOwner();
    pauseRevokesAdmissionBeforeBlockedJournalReturns();
    System.out.println("Libre recorder-free receiver history synthetic checks passed.");
  }

  private static void closedCapabilitiesAndArguments() throws Exception {
    Map<String, Object> caps = LibreGen1ReceiverHistoryCoordinator.capabilities(true);
    check(caps.keySet().equals(Set.of("schemaVersion", "backend", "readAvailable", "activationAvailable",
        "streamingAvailable", "receiverAvailable", "rawCapture")), "capability keys changed");
    check(caps.get("schemaVersion").equals(1) && caps.get("backend").equals("receiverHistory"), "capability identity changed");
    for (String key : List.of("activationAvailable", "streamingAvailable", "receiverAvailable", "rawCapture")) {
      check(Boolean.FALSE.equals(caps.get(key)), "capability grants unrelated authority");
    }
    check(Boolean.FALSE.equals(LibreGen1ReceiverHistoryCoordinator.capabilities(false).get("readAvailable")), "unavailable capability open");
    for (Object invalid : new Object[] {null, Map.of(), Map.of("attemptId", FIRST),
        Map.of("attemptId", FIRST, "bootstrapId", "short"),
        Map.of("attemptId", FIRST, "bootstrapId", "x".repeat(121)),
        Map.of("attemptId", FIRST, "bootstrapId", "valid_token", "activate", true),
        Map.of("attemptId", 7, "bootstrapId", "valid_token")}) {
      fails(() -> LibreGen1ReceiverHistoryCoordinator.target(invalid));
    }
    LibreGen1ReceiverHistoryCoordinator.target(Map.of("attemptId", "a".repeat(8), "bootstrapId", "b".repeat(120)));
  }

  private static void absentUnknownAndWrongReceiverDoNotAcquire() throws Exception {
    for (String state : new String[] {"absent", "prepared", "unknown", "corrupt", "wrong"}) {
      Harness h = new Harness();
      if (state.equals("absent")) h.backend.bytes = null;
      if (state.equals("prepared") || state.equals("unknown")) h.mutate("state", state);
      if (state.equals("corrupt")) h.backend.bytes = new byte[] {1, 2, 3};
      byte[] before = h.backend.bytes == null ? null : h.backend.bytes.clone();
      Map<String, Object> target = state.equals("wrong") ? h.args(FIRST, UUID.randomUUID().toString()) : h.args(FIRST);
      fails(() -> h.core.start(target));
      check(h.starts == 0 && !h.leaseHeld && h.acquires == 0, "invalid receiver acquired RF");
      check(Arrays.equals(before, h.backend.bytes) && h.backend.writes == 0, "invalid receiver changed storage");
    }
    Harness background = new Harness(); background.core.pause();
    fails(() -> background.core.start(background.args(FIRST)));
    check(background.acquires == 0, "background acquired lease");
  }

  private static void exactReadStopAndOneUseHandoff() throws Exception {
    Harness h = started(); byte[] before = h.backend.bytes.clone();
    Fake tag = new Fake(); h.callback.detected(tag); h.callback.detected(new Fake()); h.run();
    check(tag.connects == 1 && tag.requests == 16 && tag.closes == 1, "read sequence repeated or changed");
    check(h.stops == 1 && h.releases == 1 && !h.leaseHeld && h.successes() == 1, "metadata preceded confirmed cleanup");
    // A premature consumer fails closed and consumes the proof; use a second
    // independent fixture for the valid stop-before-read order.
    fails(() -> h.core.deliver(h.args(FIRST), value -> { throw new AssertionError("premature read"); }));
    h.core.stop(h.args(FIRST)).join();
    fails(() -> h.core.deliver(h.args(FIRST), value -> { throw new AssertionError("proof reused"); }));

    Harness valid = readAndStopped();
    final Map<String, Object> result = valid.take(FIRST);
    check(result.keySet().equals(Set.of("attemptId", "bootstrapId", "uid", "receiverInitialPatchInfo",
        "currentPatchInfo", "encryptedFram", "observedAtUtc")), "handoff schema changed");
    check(Arrays.equals(UID, (byte[]) result.get("uid")) && Arrays.equals(FRAM, (byte[]) result.get("encryptedFram")), "evidence changed");
    check(result.get("observedAtUtc").equals(valid.utc.toString()), "receipt invented");
    fails(() -> valid.take(FIRST));
    valid.core.stop(valid.args(FIRST)).join();
    check(valid.successes() == 1 && valid.failures() == 0, "normal stop revoked terminal success");
    check(Arrays.equals(before, h.backend.bytes) && h.backend.writes == 0, "read touched receiver bytes");
  }

  private static void frozenSeedIsNotCurrentSeed() throws Exception {
    Harness h = new Harness(); byte[] frozen = PATCH.clone(); frozen[4] ^= 0x55; frozen[5] ^= 0x33;
    h.mutate("patch", frozen); h.start(FIRST); h.callback.detected(new Fake()); h.run();
    h.core.stop(h.args(FIRST)).join(); Map<String, Object> result = h.take(FIRST);
    check(Arrays.equals(frozen, (byte[]) result.get("receiverInitialPatchInfo")), "frozen receiver seed replaced");
    check(Arrays.equals(PATCH, (byte[]) result.get("currentPatchInfo")), "current read seed replaced by cache");
    check(Arrays.equals(frozen, h.journal.read().initialPatchInfo), "read rewrote frozen seed");
    for (int byteIndex = 0; byteIndex < 4; byteIndex++) {
      Harness bad = new Harness(); byte[] patch = PATCH.clone(); patch[byteIndex] ^= 1;
      if (byteIndex < 3) { bad.mutate("patch", patch); fails(() -> bad.start(FIRST)); }
      else { bad.mutate("patch", patch); bad.start(FIRST); bad.callback.detected(new Fake()); bad.run(); }
      check(bad.successes() == 0 && bad.backend.writes == 0, "model/family mismatch accepted");
    }
  }

  private static void exactIdentityAtEveryReadAndDelivery() throws Exception {
    for (int at = 0; at < 16; at++) {
      Harness h = started(); Fake tag = new Fake(); tag.at = at; tag.hook = () -> h.mutate("base", 101L);
      h.callback.detected(tag); h.run();
      check(tag.requests == at + 1 && tag.closes == 1 && h.successes() == 0, "changed receiver permitted another RF call");
    }
    for (String field : new String[] {"uid", "patch", "base", "lifecycle", "device", "bootstrap", "count", "state"}) {
      Harness h = readAndStopped();
      Object value = switch (field) {
        case "uid" -> new byte[] {1, 2, 3, 4, 5, 6, 7, (byte) 0xe0};
        case "patch" -> new byte[] {(byte) 0x9d, 8, 0x30, 1, 2, 3};
        case "base" -> 101L; case "lifecycle" -> 2; case "device" -> "00:11:22:33:44:77";
        case "bootstrap" -> UUID.randomUUID().toString(); case "count" -> 1; default -> "unknown";
      };
      h.mutate(field, value); byte[] before = h.backend.bytes.clone();
      fails(() -> h.take(FIRST));
      check(Arrays.equals(before, h.backend.bytes), "delivery repaired changed receiver");
    }
    Harness release = started(); release.afterRelease = () -> release.mutate("base", 102L);
    release.callback.detected(new Fake()); release.run();
    check(release.successes() == 0 && release.releases == 1, "binding was not checked after exact release");
  }

  private static void cleanupMustFinishBeforeHandoff() throws Exception {
    Harness h = started(); Fake tag = new Fake(); h.callback.detected(tag);
    CompletableFuture<Void> stopped = h.core.stop(h.args(FIRST));
    check(!stopped.isDone(), "queued worker is not transport close proof");
    h.run(); stopped.join(); check(tag.connects == 0 && h.successes() == 0, "cancelled queued worker ran");
    fails(() -> h.take(FIRST));
    Harness ready = started(); ready.onSuccess = () -> {
      check(ready.releases == 1 && !ready.leaseHeld && ready.stops == 1, "success listener beat cleanup");
    };
    ready.callback.detected(new Fake()); ready.run(); ready.core.stop(ready.args(FIRST)).join(); ready.take(FIRST);
  }

  private static void cancellationPauseDetachAndStaleCallbacks() throws Exception {
    for (String mode : new String[] {"discard", "pause", "detach"}) {
      Harness h = started(); Fake tag = new Fake(); tag.at = 3; tag.hook = () -> {
        if (mode.equals("discard")) h.core.discard(h.args(FIRST));
        else if (mode.equals("pause")) h.core.pause(); else h.core.detach();
      };
      h.callback.detected(tag); h.run();
      h.core.stop(h.args(FIRST)).join();
      check(tag.requests == 4 && tag.closes == 1 && h.successes() == 0 && h.releases == 1, "cancellation escaped fence");
      fails(() -> h.take(FIRST));
      if (mode.equals("detach")) { h.core.resume(); fails(() -> h.start(SECOND)); }
    }
    Harness h = readAndStopped(); Libre2NfcSessionCoordinator.TagCallback stale = h.callback;
    h.start(SECOND); stale.detected(new Fake());
    check(h.work.isEmpty(), "old callback started new read");
    fails(() -> h.core.stop(h.args(FIRST)).join());
    check(h.leaseHeld, "stale stop removed current owner");
    fails(() -> h.core.discard(h.args(FIRST)));
    h.callback.detected(new Fake()); h.run(); h.core.stop(h.args(SECOND)).join(); h.take(SECOND);
  }

  private static void expiryAndReplacementWipeEvidence() throws Exception {
    for (String mode : new String[] {"mono", "wall", "rollback", "monoRollback", "pause", "detach", "discard", "timer"}) {
      Harness h = readAndStopped(); Object attempt = field(h.core, "current"); byte[] retained = (byte[]) field(attempt, "fram");
      switch (mode) {
        case "mono" -> h.now += 120_000_000_000L;
        case "wall" -> h.utc = h.utc.plusSeconds(120);
        case "rollback" -> h.utc = h.utc.minusSeconds(6);
        case "monoRollback" -> h.now--;
        case "pause" -> h.core.pause(); case "detach" -> h.core.detach();
        case "discard" -> h.core.discard(h.args(FIRST)); case "timer" -> h.core.expire(h.binding);
      }
      fails(() -> h.take(FIRST)); check(allZero(retained), "expired/cancelled proof retained bytes");
    }
    Harness h = readAndStopped(); byte[] retained = (byte[]) field(field(h.core, "current"), "fram");
    Object old = h.binding; h.start(SECOND);
    check(allZero(retained), "replacement kept earlier proof");
    h.core.expire(old); check(h.leaseHeld, "stale deadline released replacement");
    h.core.stop(h.args(SECOND)).join();
  }

  private static void failedDeliveryWipesOwnedBuffers() throws Exception {
    Harness h = readAndStopped(); List<byte[]> transferred = new ArrayList<>();
    try {
      h.core.deliver(h.args(FIRST), value -> {
        for (Object item : value.values()) if (item instanceof byte[]) transferred.add((byte[]) item);
        throw new IllegalArgumentException("synthetic encoder failure");
      });
      throw new AssertionError("expected encoding failure");
    } catch (IllegalArgumentException expected) { }
    check(transferred.size() == 4 && transferred.stream().allMatch(LibreGen1ReceiverHistoryCoordinatorTest::allZero), "encoding failure retained arrays");
    fails(() -> h.take(FIRST));
    Harness revoked = readAndStopped(); revoked.allowed = false;
    fails(() -> revoked.take(FIRST));
  }

  private static void failedCloseReaderAndLeaseStayQuarantined() throws Exception {
    for (String mode : new String[] {"transport", "reader", "lease", "lostOwner"}) {
      Harness h = started(); Fake tag = new Fake();
      tag.failClose = mode.equals("transport"); h.failStop = mode.equals("reader"); h.failRelease = mode.equals("lease");
      if (mode.equals("lostOwner")) { tag.at = 2; tag.hook = () -> h.exactOwner = false; }
      h.callback.detected(tag); h.run();
      check(h.core.isQuarantined() && h.leaseHeld && h.successes() == 0, "uncertain cleanup released ownership");
      check(h.core.stop(h.args(FIRST)).isCompletedExceptionally(), "uncertain stop succeeded");
      fails(() -> h.take(FIRST)); fails(() -> h.start(SECOND));
    }
  }

  private static void sharedLeaseBlocksBleAndHistoryWithoutCounterWrites() throws Exception {
    Harness h = new Harness(); LibreGen1ReceiverCoordinator ble = new LibreGen1ReceiverCoordinator(h.journal, h::lease, () -> true);
    String session = "0123456789abcdef0123456789abcdef";
    String token = ble.acquire(session, h.bootstrap); byte[] before = h.backend.bytes.clone();
    fails(() -> h.start(FIRST)); check(h.starts == 0 && h.leaseHeld, "BLE owner overwritten");
    ble.release(session, h.bootstrap, token, true); h.start(SECOND);
    fails(() -> ble.acquire(session, h.bootstrap));
    h.callback.detected(new Fake()); h.run(); h.core.stop(h.args(SECOND)).join(); h.take(SECOND);
    check(h.backend.writes == 0 && Arrays.equals(before, h.backend.bytes), "history changed counter/receiver bytes");
    Harness unknown = new Harness(); unknown.leaseHeld = true; unknown.exactOwner = false;
    fails(() -> unknown.start(FIRST)); check(unknown.starts == 0 && unknown.leaseHeld, "legacy/partial owner recovered");
  }

  private static void inFlightTimeoutCannotBecomeAValidLateRead() throws Exception {
    Harness h = started(); Fake tag = new Fake(); CountDownLatch entered = new CountDownLatch(1), proceed = new CountDownLatch(1);
    tag.at = 0; tag.hook = () -> { entered.countDown(); check(proceed.await(3, TimeUnit.SECONDS), "test release missing"); };
    h.callback.detected(tag); Thread worker = new Thread(h::run); worker.start();
    check(entered.await(3, TimeUnit.SECONDS), "test request did not start");
    CompletableFuture<Void> stop = h.core.stop(h.args(FIRST)); check(!stop.isDone(), "in-flight read reported stopped");
    h.core.quarantine(h.binding); proceed.countDown(); worker.join(3000);
    check(!worker.isAlive() && stop.isCompletedExceptionally() && h.leaseHeld && h.releases == 0, "late close undid quarantine");
    check(tag.requests == 1 && tag.closes == 1 && h.successes() == 0, "late callback resumed read");
    fails(() -> h.take(FIRST));
  }

  private static void newLeaseBlocksDeliveryAndKeepsUnknownOwner() throws Exception {
    Harness h = readAndStopped(); h.leaseHeld = true; h.exactOwner = false;
    int releases = h.releases;
    fails(() -> h.take(FIRST));
    check(h.leaseHeld && h.releases == releases, "handoff deleted a later unknown lease");
  }

  private static void pauseRevokesAdmissionBeforeBlockedJournalReturns() throws Exception {
    Harness h = started(); Fake tag = new Fake(); h.callback.detected(tag);
    CountDownLatch entered = new CountDownLatch(1), proceed = new CountDownLatch(1);
    h.backend.readHook = () -> {
      entered.countDown(); check(proceed.await(3, TimeUnit.SECONDS), "test journal release missing");
    };
    Thread worker = new Thread(h::run); worker.start();
    check(entered.await(3, TimeUnit.SECONDS), "test journal did not enter");
    Thread pause = new Thread(h.core::pause); pause.start();
    // Wait only for the atomic revocation, not for the intentionally blocked
    // buffer/reader cleanup. No sleep or arbitrary wall-clock race is needed.
    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
    Object nfc = field(h.core, "nfc"); Object attempt = field(nfc, "active");
    while (!(Boolean) field(attempt, "revoked") && System.nanoTime() < deadline) Thread.yield();
    check((Boolean) field(attempt, "revoked"), "pause waited for storage before revoking RF");
    proceed.countDown(); worker.join(3000); pause.join(3000);
    check(!worker.isAlive() && !pause.isAlive() && tag.connects == 0 && tag.requests == 0,
        "blocked storage admitted RF after pause");
    check(h.successes() == 0 && h.releases == 1, "paused storage callback retained authority");
  }

  private static Harness started() throws Exception { Harness h = new Harness(); h.start(FIRST); return h; }
  private static Harness readAndStopped() throws Exception {
    Harness h = started(); h.callback.detected(new Fake()); h.run(); h.core.stop(h.args(FIRST)).join(); return h;
  }
  private static final class Harness implements Libre2NfcSessionCoordinator.Reader, Executor {
    final Backend backend = new Backend(); final LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
    final String bootstrap = UUID.randomUUID().toString();
    final List<Runnable> work = new ArrayList<>(); final List<Map<String, Object>> events = new ArrayList<>();
    final LibreGen1ReceiverHistoryCoordinator core;
    long now = 100; Instant utc = Instant.parse("2026-01-01T00:00:00.123456789Z");
    boolean allowed = true, leaseHeld, exactOwner = true, failStop, failRelease;
    int starts, stops, acquires, releases; Object binding; Runnable afterRelease, onSuccess;
    Libre2NfcSessionCoordinator.TagCallback callback;
    Harness() throws Exception {
      backend.bytes = encode(new LibreGen1StreamingJournal.Record(bootstrap, UID, PATCH, 100, 3,
          "confirmed", "00:11:22:33:44:55", 0, "none"));
      core = new LibreGen1ReceiverHistoryCoordinator(journal, this::lease, () -> allowed, () -> !leaseHeld,
          () -> now, () -> utc, this, this, event -> {
            events.add(event);
            if (event.get("event").equals("metadataRead") && onSuccess != null) onSuccess.run();
          });
      core.resume();
    }
    LibreGen1ReceiverCoordinator.Lease lease(String token) {
      acquires++; if (leaseHeld) return null; leaseHeld = true; exactOwner = true;
      return new LibreGen1ReceiverCoordinator.Lease() {
        public boolean held() { return leaseHeld && exactOwner; }
        public boolean release() {
          if (!held() || failRelease) return false;
          releases++; leaseHeld = false; if (afterRelease != null) afterRelease.run(); return true;
        }
      };
    }
    void start(String id) throws Exception { binding = core.start(args(id)); core.bindDeadline(binding); }
    public void start(Libre2NfcSessionCoordinator.TagCallback callback) { starts++; this.callback = callback; }
    public void stop() throws Exception { stops++; if (failStop) throw new IOException("synthetic stop failure"); }
    public void execute(Runnable action) { work.add(action); }
    void run() { while (!work.isEmpty()) work.remove(0).run(); }
    long successes() { return events.stream().filter(e -> e.get("event").equals("metadataRead")).count(); }
    long failures() { return events.stream().filter(e -> e.get("event").equals("failed")).count(); }
    Map<String, Object> args(String id) { return args(id, bootstrap); }
    Map<String, Object> args(String id, String owner) { return Map.of("attemptId", id, "bootstrapId", owner); }
    Map<String, Object> take(String id) throws Exception {
      Map<String, Object> copy = new HashMap<>();
      core.deliver(args(id), value -> value.forEach((key, item) -> copy.put(key, item instanceof byte[] ? ((byte[]) item).clone() : item)));
      return copy;
    }
    void mutate(String field, Object value) {
      try {
        LibreGen1StreamingJournal.Record r = journal.read();
        backend.bytes = encode(new LibreGen1StreamingJournal.Record(
            field.equals("bootstrap") ? (String) value : r.bootstrapId,
            field.equals("uid") ? (byte[]) value : r.uid,
            field.equals("patch") ? (byte[]) value : r.initialPatchInfo,
            field.equals("base") ? (Long) value : r.streamingBase,
            field.equals("lifecycle") ? (Integer) value : r.lifecycle,
            field.equals("state") ? (String) value : r.state,
            field.equals("state") ? "" : field.equals("device") ? (String) value : r.deviceId,
            field.equals("count") ? (Integer) value : r.unlockCount,
            field.equals("count") ? "unknown" : r.loginOutcome));
      } catch (Exception failure) { throw new AssertionError(failure); }
    }
  }
  private static final class Backend implements LibreGen1StreamingJournal.Backend {
    byte[] bytes; int writes; Throwing readHook;
    public byte[] read() throws Exception {
      Throwing hook = readHook; readHook = null; if (hook != null) hook.run();
      return bytes == null ? null : bytes.clone();
    }
    public void write(byte[] value) { writes++; throw new AssertionError("history must never write receiver storage"); }
  }
  private static final class Fake implements Libre2Gen1ReadTransaction.Transport {
    int requests, connects, closes, at = -1; boolean failClose; Throwing hook;
    public byte[] uid() { return UID.clone(); }
    public int maxTransceiveLength() { return 25; }
    public void connect() { connects++; }
    public byte[] transceive(byte[] request) throws Exception {
      final int index = requests++; final byte[] result;
      if (index == 0) {
        check(Arrays.equals(request, new byte[] {2, (byte) 0xa1, 7}), "new NFC command");
        result = new byte[7]; System.arraycopy(PATCH, 0, result, 1, 6);
      } else {
        check(index <= 15 && Arrays.equals(request, LibreGen1NfcFrames.frames().get(index - 1).request()), "new/replayed NFC command");
        int offset = (index - 1) * 24, length = Math.min(24, FRAM.length - offset);
        result = new byte[length + 1]; System.arraycopy(FRAM, offset, result, 1, length);
      }
      if (index == at && hook != null) hook.run(); return result;
    }
    public void close() throws Exception { closes++; if (failClose) throw new IOException("synthetic close failure"); }
  }
  private static byte[] encode(LibreGen1StreamingJournal.Record r) throws Exception {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(); DataOutputStream out = new DataOutputStream(bytes);
    out.writeInt(1); out.writeUTF(r.bootstrapId); out.write(r.uid); out.write(r.initialPatchInfo);
    out.writeLong(r.streamingBase); out.writeInt(r.lifecycle); out.writeUTF(r.state); out.writeUTF(r.deviceId);
    out.writeInt(r.unlockCount); out.writeUTF(r.loginOutcome); out.flush(); return bytes.toByteArray();
  }
  private static byte[] fixture(String name) {
    try { return ((byte[]) field(null, Libre2Gen1ReadTransactionTest.class, name)).clone(); }
    catch (Exception failure) { throw new AssertionError(failure); }
  }
  private static Object field(Object value, String name) throws Exception { return field(value, value.getClass(), name); }
  private static Object field(Object value, Class<?> type, String name) throws Exception {
    Field field = type.getDeclaredField(name); field.setAccessible(true); return field.get(value);
  }
  private static boolean allZero(byte[] value) { for (byte item : value) if (item != 0) return false; return true; }
  private interface Throwing { void run() throws Exception; }
  private static void fails(Throwing action) throws Exception {
    try { action.run(); throw new AssertionError("expected closed failure"); }
    catch (IllegalStateException | java.util.concurrent.CompletionException | IOException expected) { }
  }
  private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
