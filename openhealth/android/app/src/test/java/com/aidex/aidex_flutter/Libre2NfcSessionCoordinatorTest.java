package com.aidex.aidex_flutter;

import java.io.IOException;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Offline lifecycle and RF ownership checks. Uses only the existing synthetic fixture. */
public final class Libre2NfcSessionCoordinatorTest {
  private static final String FIRST = "synthetic_attempt_one";
  private static final String SECOND = "synthetic_attempt_two";

  public static void main(String[] arguments) throws Exception {
    startPreflightAndExactStop();
    readsOnceAndReleasesBeforeSuccess();
    pauseBeforeAndDuringRead();
    detachAndLateCallbacks();
    deadlineAndStaleTimers();
    failedCloseAndStopQuarantine();
    transportFailureIsNotSuccess();
    unresolvedLeaseBlocksWithoutReader();
    inFlightRevocationIsNonblockingAndNeverReplays();
    pauseDeliversTerminalButNeverLateSuccess();
    leaseChecksCannotCacheRevokedPermission();
    partialReaderStartRetainsWorkerOwnership();
    System.out.println("Libre read-only coordinator synthetic checks passed.");
  }

  private static void startPreflightAndExactStop() throws Exception {
    Harness h = new Harness();
    fails("nfc_not_foreground", () -> h.coordinator.start(FIRST));
    check(h.leases == 0 && h.starts == 0, "background acquired owner");
    h.coordinator.resume();
    fails("bad_args", () -> h.coordinator.start("short"));
    h.coordinator.start(FIRST);
    fails("nfc_attempt_active", () -> h.coordinator.start(SECOND));
    check(h.coordinator.stop(SECOND).isCompletedExceptionally(), "stale stop accepted");
    check(h.releases == 0 && h.stops == 0, "stale stop released current owner");
    h.coordinator.stop(FIRST).join();
    check(h.releases == 1 && h.stops == 1, "listening stop not confirmed");
    h.coordinator.start(SECOND);
    check(h.starts == 2, "explicit next owner blocked");
    h.coordinator.stop(SECOND).join();
  }

  private static void readsOnceAndReleasesBeforeSuccess() throws Exception {
    Harness h = started();
    Fake tag = new Fake();
    h.callback.detected(tag);
    h.callback.detected(new Fake());
    check(h.work.size() == 1, "duplicate callback started another read");
    h.run();
    check(tag.connects == 1 && tag.closes == 1 && tag.requests == 16, "read sequence changed");
    check(h.last().get("event").equals("metadataRead") && h.last().get("status").equals("active"), "verified result absent");
    check(h.releases == 1 && h.stops == 1, "success preceded cleanup");
    check(h.last().keySet().equals(java.util.Set.of("attemptId", "event", "model", "status")), "raw evidence in event");
    h.coordinator.stop(FIRST).join();
    h.coordinator.start(SECOND);
    check(h.starts == 2, "terminal attempt could not be stopped");
  }

  private static void pauseBeforeAndDuringRead() throws Exception {
    Harness h = started();
    Fake tag = new Fake();
    h.callback.detected(tag);
    h.coordinator.pause();
    h.run();
    check(tag.connects == 0 && tag.requests == 0, "queued RF survived pause");
    check(h.releases == 1 && !hasSuccess(h), "paused attempt retained/returned evidence");
    for (int at = 0; at < 16; at++) {
      final Harness each = started();
      final Fake current = new Fake();
      current.afterRequest = () -> each.coordinator.pause();
      current.cancelAt = at;
      each.callback.detected(current);
      each.run();
      check(current.requests == at + 1 && current.closes == 1, "RF continued after pause");
      check(each.releases == 1 && !hasSuccess(each), "paused read published metadata");
    }
  }

  private static void detachAndLateCallbacks() throws Exception {
    Harness h = started();
    Libre2NfcSessionCoordinator.TagCallback stale = h.callback;
    h.coordinator.detach();
    Fake late = new Fake();
    stale.detected(late);
    check(h.work.isEmpty() && late.connects == 0, "detached callback touched sensor");
    h.coordinator.resume();
    fails("nfc_not_foreground", () -> h.coordinator.start(SECOND));
    Harness fresh = started();
    Libre2NfcSessionCoordinator.TagCallback old = fresh.callback;
    fresh.coordinator.stop(FIRST).join();
    fresh.coordinator.start(SECOND);
    old.detected(new Fake());
    check(fresh.work.isEmpty() && fresh.releases == 1, "stale callback acquired replacement");
  }

  private static void deadlineAndStaleTimers() throws Exception {
    Harness h = started();
    Object old = h.coordinator.binding(FIRST);
    h.now += Libre2NfcSessionCoordinator.ATTEMPT_NANOS;
    h.coordinator.expire(old);
    check(h.releases == 1 && h.stops == 1, "deadline did not stop listening");
    h.coordinator.start(SECOND);
    h.coordinator.expire(old);
    h.coordinator.quarantine(old);
    check(!h.coordinator.isQuarantined() && h.releases == 1, "stale timer changed replacement");
    Fake tag = new Fake();
    h.callback.detected(tag);
    h.now += Libre2NfcSessionCoordinator.ATTEMPT_NANOS;
    h.run();
    check(tag.connects == 0 && !hasSuccess(h), "expired queue touched sensor");
  }

  private static void failedCloseAndStopQuarantine() throws Exception {
    Harness h = started();
    Fake tag = new Fake(); tag.failClose = true;
    h.callback.detected(tag); h.run();
    check(tag.closes == 1 && h.releases == 0 && h.coordinator.isQuarantined(), "unknown close released lease");
    check(h.last().get("reason").equals("cleanupUnconfirmed") && !hasSuccess(h), "close failure looked successful");
    check(h.coordinator.stop(FIRST).isCompletedExceptionally(), "unknown close stop succeeded");
    fails("nfc_cleanup_unconfirmed", () -> h.coordinator.start(SECOND));

    Harness timeout = started();
    Fake pending = new Fake(); timeout.callback.detected(pending);
    CompletableFuture<Void> stop = timeout.coordinator.stop(FIRST);
    check(!stop.isDone(), "stop completed with worker pending");
    timeout.coordinator.quarantine(timeout.coordinator.binding(FIRST));
    timeout.run();
    check(stop.isCompletedExceptionally() && timeout.releases == 0, "late completion cleared quarantine");

    Harness reader = started(); reader.failStop = true;
    check(reader.coordinator.stop(FIRST).isCompletedExceptionally(), "reader close error hidden");
    check(reader.releases == 0 && reader.coordinator.isQuarantined(), "reader close error released owner");
  }

  private static void transportFailureIsNotSuccess() throws Exception {
    for (int at = 0; at < 16; at++) {
      Harness h = started(); Fake tag = new Fake(); tag.failAt = at;
      h.callback.detected(tag); h.run();
      check(tag.requests == at + 1 && tag.closes == 1, "tag loss retried or did not close");
      check(!hasSuccess(h) && h.releases == 1, "tag loss published success");
      check(h.last().get("reason").equals("readFailed"), "native text escaped");
    }
  }

  private static void unresolvedLeaseBlocksWithoutReader() throws Exception {
    Harness h = new Harness(); h.coordinator.resume(); h.blockLease = true;
    fails("nfc_state_blocked", () -> h.coordinator.start(FIRST));
    check(h.starts == 0 && h.releases == 0, "unknown lease altered");
    Harness release = started(); release.failRelease = true;
    check(release.coordinator.stop(FIRST).isCompletedExceptionally(), "uncertain lease release succeeded");
    check(release.coordinator.isQuarantined(), "uncertain release not quarantined");
  }

  private static void inFlightRevocationIsNonblockingAndNeverReplays() throws Exception {
    Harness h = started();
    Fake tag = new Fake();
    CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
    tag.cancelAt = 0;
    tag.afterRequest = () -> {
      entered.countDown();
      try { check(release.await(3, TimeUnit.SECONDS), "test release did not arrive"); }
      catch (InterruptedException error) { throw new AssertionError(error); }
    };
    h.callback.detected(tag);
    Thread reader = new Thread(h::run);
    reader.start();
    check(entered.await(3, TimeUnit.SECONDS), "test read did not enter");
    CompletableFuture<Void> stop = h.coordinator.stop(FIRST);
    check(!stop.isDone(), "in-flight read reported stopped before close");
    h.coordinator.quarantine(h.coordinator.binding(FIRST));
    check(stop.isCompletedExceptionally(), "uncertain read did not quarantine");
    release.countDown();
    reader.join(3_000);
    check(!reader.isAlive(), "late read did not settle");
    check(tag.requests == 1 && tag.closes == 1, "late read continued or closed twice");
    check(h.releases == 0 && !hasSuccess(h), "late close released quarantined owner");
  }

  private static void pauseDeliversTerminalButNeverLateSuccess() throws Exception {
    Harness h = started();
    Object binding = h.coordinator.binding(FIRST);
    h.coordinator.pause();
    h.coordinator.resume();
    check(h.coordinator.acceptsEvent(binding, "failed"), "safe pause lost terminal event");
    check(!h.coordinator.acceptsEvent(binding, "listening"), "paused attempt resumed listening");
    check(!h.coordinator.acceptsEvent(binding, "metadataRead"), "late metadata accepted after pause");
    h.coordinator.start(SECOND);
    check(!h.coordinator.acceptsEvent(binding, "failed"), "old terminal reached replacement");

    Harness completed = started();
    Object success = completed.coordinator.binding(FIRST);
    completed.callback.detected(new Fake()); completed.run();
    check(completed.coordinator.acceptsEvent(success, "metadataRead"), "current success hidden");
    completed.now += Libre2NfcSessionCoordinator.ATTEMPT_NANOS;
    check(!completed.coordinator.acceptsEvent(success, "metadataRead"), "expired success accepted before timer");
    check(!completed.coordinator.acceptsEvent(success, "readingMetadata"), "expired reading accepted before timer");
    completed.coordinator.pause(); completed.coordinator.resume();
    check(completed.coordinator.acceptsEvent(success, "failed"), "completed read retained authority after pause");
    check(!completed.coordinator.acceptsEvent(success, "metadataRead"), "queued success survived pause");
  }

  private static void leaseChecksCannotCacheRevokedPermission() throws Exception {
    Harness baseline = started(); baseline.callback.detected(new Fake()); baseline.run();
    for (int at = 1; at <= baseline.heldChecks; at++) {
      final Harness h = new Harness();
      final Fake tag = new Fake();
      final int[] callsAtRevoke = {-1, -1};
      h.coordinator.resume();
      h.heldHookAt = at;
      h.heldHook = () -> {
        callsAtRevoke[0] = tag.connects; callsAtRevoke[1] = tag.requests;
        h.coordinator.pause();
      };
      try { h.coordinator.start(FIRST); }
      catch (IllegalStateException expected) { check(at == 1, "unexpected start failure"); }
      if (h.callback != null) h.callback.detected(tag);
      h.run();
      if (callsAtRevoke[0] >= 0) {
        check(tag.connects == callsAtRevoke[0] && tag.requests == callsAtRevoke[1], "cached lease check admitted RF after revoke");
        check(!hasSuccess(h), "revoked lease check published success");
      }
    }
  }

  private static void partialReaderStartRetainsWorkerOwnership() throws Exception {
    Harness h = new Harness(); h.coordinator.resume(); h.failStartAfterTag = true;
    fails("nfc_start_failed", () -> h.coordinator.start(FIRST));
    check(h.work.size() == 1 && h.releases == 0, "partial start released a claimed worker lease");
    CompletableFuture<Void> stop = h.coordinator.stop(FIRST);
    check(!stop.isDone(), "partial start stop preceded worker cleanup");
    h.run();
    check(stop.isDone() && !stop.isCompletedExceptionally() && h.releases == 1, "partial start never completed cleanup");
    check(!hasSuccess(h), "partial start published success");
  }

  private static Harness started() throws Exception {
    Harness h = new Harness(); h.coordinator.resume(); h.coordinator.start(FIRST); return h;
  }
  private static boolean hasSuccess(Harness h) {
    return h.events.stream().anyMatch(e -> e.get("event").equals("metadataRead"));
  }
  private static final class Harness implements Libre2NfcSessionCoordinator.Reader, Executor {
    long now = 1; int leases, starts, stops, releases, heldChecks, heldHookAt = -1;
    Runnable heldHook;
    boolean blockLease, failStop, failRelease, failStartAfterTag;
    Libre2NfcSessionCoordinator.TagCallback callback;
    final List<Runnable> work = new ArrayList<>();
    final List<Map<String, Object>> events = new ArrayList<>();
    final Libre2NfcSessionCoordinator coordinator = new Libre2NfcSessionCoordinator(() -> now, () -> {
      leases++;
      if (blockLease) return null;
      return new Libre2NfcSessionCoordinator.Lease() {
        boolean held = true;
        public boolean held() {
          heldChecks++;
          if (heldChecks == heldHookAt && heldHook != null) heldHook.run();
          return held;
        }
        public boolean release() { releases++; if (failRelease) return false; held = false; return true; }
      };
    }, this, this, events::add);
    public void start(Libre2NfcSessionCoordinator.TagCallback callback) throws Exception {
      starts++; this.callback = callback;
      if (failStartAfterTag) {
        callback.detected(new Fake());
        throw new IOException("synthetic partial reader start");
      }
    }
    public void stop() throws Exception { stops++; if (failStop) throw new IOException("synthetic private failure"); }
    public void execute(Runnable task) { work.add(task); }
    void run() { while (!work.isEmpty()) work.remove(0).run(); }
    Map<String, Object> last() { return events.get(events.size() - 1); }
  }
  private static final class Fake implements Libre2Gen1ReadTransaction.Transport {
    final byte[] uid = fixture("UID"), patch = fixture("PATCH"), fram = fixture("ENCRYPTED");
    int connects, closes, requests, failAt = -1, cancelAt = -1;
    boolean failClose;
    Runnable afterRequest;
    public byte[] uid() { return uid.clone(); }
    public int maxTransceiveLength() { return 25; }
    public void connect() { connects++; }
    public byte[] transceive(byte[] request) throws Exception {
      final int index = requests++;
      if (index == failAt) throw new IOException("synthetic private tag failure");
      final byte[] response;
      if (index == 0) {
        check(Arrays.equals(request, new byte[] {2, (byte) 0xa1, 7}), "unexpected non-read frame");
        response = new byte[7]; System.arraycopy(patch, 0, response, 1, 6);
      } else {
        final LibreGen1NfcFrames.Frame frame = LibreGen1NfcFrames.frames().get(index - 1);
        check(Arrays.equals(request, frame.request()), "non-read or reordered frame");
        final int offset = (index - 1) * 24;
        final int length = Math.min(24, fram.length - offset);
        response = new byte[length + 1]; System.arraycopy(fram, offset, response, 1, length);
      }
      if (index == cancelAt && afterRequest != null) afterRequest.run();
      return response;
    }
    public void close() throws Exception { closes++; if (failClose) throw new IOException("synthetic close failure"); }
  }
  private static byte[] fixture(String field) {
    try { Field value = Libre2Gen1ReadTransactionTest.class.getDeclaredField(field); value.setAccessible(true); return ((byte[]) value.get(null)).clone(); }
    catch (Exception error) { throw new AssertionError(error); }
  }
  private interface Throwing { void run() throws Exception; }
  private static void fails(String code, Throwing operation) throws Exception {
    try { operation.run(); throw new AssertionError("expected closed failure"); }
    catch (IllegalStateException error) { check(code.equals(error.getMessage()), "wrong closed failure"); }
  }
  private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
