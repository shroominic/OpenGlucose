package com.aidex.aidex_flutter;

import java.time.Instant;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** Volatile, one-use history evidence for an exact already-confirmed receiver. */
final class LibreGen1ReceiverHistoryCoordinator {
  interface WallClock { Instant now(); }
  private final LibreGen1StreamingJournal journal;
  private final LibreGen1ReceiverCoordinator.Guard guard;
  private final Libre2NfcSessionCoordinator.Clock clock;
  private final WallClock wall;
  private final LibreGen1ReceiverCoordinator.Guard idle;
  private final Libre2NfcSessionCoordinator nfc;
  private volatile Attempt current;
  private volatile boolean resumed;
  private volatile boolean detached;

  LibreGen1ReceiverHistoryCoordinator(LibreGen1StreamingJournal journal,
      LibreGen1ReceiverCoordinator.Leases leases, LibreGen1ReceiverCoordinator.Guard guard,
      LibreGen1ReceiverCoordinator.Guard idle,
      Libre2NfcSessionCoordinator.Clock clock, WallClock wall,
      Libre2NfcSessionCoordinator.Reader reader, Executor worker,
      Libre2NfcSessionCoordinator.Events events) {
    this.journal = journal; this.guard = guard; this.idle = idle; this.clock = clock; this.wall = wall;
    nfc = new Libre2NfcSessionCoordinator(clock, () -> {
      final Attempt attempt = current;
      if (attempt == null || !attempt.current()) throw closed("nfc_state_blocked");
      // This owner is never installed in the BLE receiver coordinator. Thus
      // it cannot reserve a login counter or confer state-changing authority.
      final LibreGen1ReceiverCoordinator.Lease lease = leases.acquire(UUID.randomUUID().toString());
      if (lease == null) return null;
      return new Libre2NfcSessionCoordinator.Lease() {
        public boolean held() { return lease.held(); }
        public boolean release() { return lease.release(); }
      };
    }, reader, worker, events, id -> {
      final Attempt attempt = current;
      if (attempt == null || !attempt.id.equals(id)) throw closed("nfc_state_blocked");
      return attempt;
    });
  }

  static Map<String, Object> capabilities(boolean available) {
    final Map<String, Object> result = new HashMap<>();
    result.put("schemaVersion", 1); result.put("backend", "receiverHistory");
    result.put("readAvailable", available); result.put("activationAvailable", false);
    result.put("streamingAvailable", false); result.put("receiverAvailable", false);
    result.put("rawCapture", false);
    return result;
  }

  void resume() { if (!detached) { resumed = true; nfc.resume(); } }
  void pause() {
    resumed = false;
    nfc.suspendAdmission();
    final Attempt attempt = current;
    if (attempt != null) attempt.discard();
    nfc.pause();
  }
  void detach() { detached = true; pause(); nfc.detach(); }

  Object start(Object arguments) throws Exception {
    final String[] target = target(arguments);
    if (!available()) throw closed("nfc_not_foreground");
    if (nfc.isQuarantined()) throw closed("nfc_cleanup_unconfirmed");
    final Attempt previous = current;
    if (previous != null && nfc.binding(previous.id) != null) throw closed("nfc_attempt_active");
    if (previous != null) previous.discard();
    current = null;
    LibreGen1StreamingJournal.Record record = null;
    try {
      record = journal.read();
      requireConfirmed(record);
      if (!record.bootstrapId.equals(target[1]) || !available()) throw closed("nfc_state_blocked");
      final Attempt attempt = new Attempt(target[0], record);
      current = attempt;
      try {
        final Object binding = nfc.start(attempt.id);
        // Keep the timer's opaque owner even if a synchronous terminal
        // listener already completed stop before start returned.
        attempt.nativeBinding = binding;
        return binding;
      } catch (Exception failure) {
        attempt.nativeBinding = nfc.binding(attempt.id);
        attempt.discard(); throw failure;
      }
    } finally { clear(record); }
  }

  CompletableFuture<Void> stop(Object arguments) throws Exception {
    final String[] target = target(arguments);
    final Attempt attempt = exact(target);
    if (attempt == null) return CompletableFuture.completedFuture(null);
    nfc.revokeAdmission(nfc.binding(attempt.id));
    final CompletableFuture<Void> result = nfc.stop(attempt.id);
    return result.whenComplete((ignored, failure) -> {
      synchronized (attempt) {
        if (failure != null) attempt.discard();
        else attempt.stopConfirmed = true;
      }
    });
  }

  /** Memory revocation only. A caller still has to await stop for RF cleanup. */
  void discard(Object arguments) throws Exception {
    final Attempt attempt = exact(target(arguments));
    if (attempt != null) {
      nfc.revokeAdmission(nfc.binding(attempt.id));
      attempt.discard();
    }
  }

  /** Encoding must be synchronous. Every transferred array is wiped afterward. */
  void deliver(Object arguments, Consumer<Map<String, Object>> delivery) throws Exception {
    final Attempt attempt = exact(target(arguments));
    if (attempt == null) throw closed("libre_history_evidence_unavailable");
    synchronized (attempt) {
      Map<String, Object> result = null;
      try {
        if (!attempt.ready || !attempt.stopConfirmed || !idle.allowed() || !attempt.current()
            || !attempt.fresh()) throw closed("libre_history_evidence_unavailable");
        result = new HashMap<>();
        result.put("attemptId", attempt.id); result.put("bootstrapId", attempt.bootstrapId);
        result.put("uid", attempt.uid.clone());
        result.put("receiverInitialPatchInfo", attempt.patch.clone());
        result.put("currentPatchInfo", attempt.readPatch.clone());
        result.put("encryptedFram", attempt.fram.clone());
        result.put("observedAtUtc", attempt.observedAt.toString());
        // Recheck after copying, then consume before handing the result off.
        if (!idle.allowed() || !attempt.current() || !attempt.fresh() || !idle.allowed()) {
          throw closed("libre_history_evidence_unavailable");
        }
        attempt.discard();
        delivery.accept(result);
      } finally {
        attempt.discard();
        if (result != null) for (Object value : result.values()) {
          if (value instanceof byte[]) Arrays.fill((byte[]) value, (byte) 0);
        }
      }
    }
  }

  Object binding(String id) { return nfc.binding(id); }
  boolean acceptsEvent(Object binding, String event) { return nfc.acceptsEvent(binding, event); }
  void expire(Object binding) {
    final Attempt attempt = current;
    // A timer carries the original owner, never just a caller-controlled ID.
    if (attempt != null && attempt.nativeBinding == binding) {
      nfc.revokeAdmission(binding);
      attempt.discard();
      nfc.expire(binding);
    }
  }
  void bindDeadline(Object binding) {
    final Attempt attempt = current;
    if (attempt != null && nfc.binding(attempt.id) == binding) attempt.nativeBinding = binding;
  }
  void quarantine(Object binding) { nfc.quarantine(binding); }
  boolean isQuarantined() { return nfc.isQuarantined(); }

  private Attempt exact(String[] target) {
    final Attempt attempt = current;
    if (attempt == null) return null;
    if (!attempt.id.equals(target[0]) || !attempt.bootstrapId.equals(target[1])) {
      throw closed("nfc_attempt_mismatch");
    }
    return attempt;
  }

  private boolean available() {
    try { return resumed && !detached && guard.allowed(); }
    catch (RuntimeException failure) { return false; }
  }

  static String[] target(Object arguments) {
    if (!(arguments instanceof Map)) throw closed("bad_args");
    final Map<?, ?> value = (Map<?, ?>) arguments;
    if (value.size() != 2 || !value.containsKey("attemptId") || !value.containsKey("bootstrapId")) {
      throw closed("bad_args");
    }
    final String[] result = new String[2];
    int index = 0;
    for (String key : new String[] {"attemptId", "bootstrapId"}) {
      final Object token = value.get(key);
      if (!(token instanceof String) || !((String) token).matches("[A-Za-z0-9_-]{8,120}")) {
        throw closed("bad_args");
      }
      result[index++] = (String) token;
    }
    return result;
  }

  private final class Attempt implements Libre2NfcSessionCoordinator.ReadPolicy {
    final String id, bootstrapId, deviceId, loginOutcome;
    final byte[] uid, patch;
    final long base;
    final int lifecycle, count;
    volatile Object nativeBinding;
    boolean discarded, ready, stopConfirmed;
    byte[] readPatch, fram;
    Instant observedAt;
    long observedNanos;

    Attempt(String id, LibreGen1StreamingJournal.Record record) {
      this.id = id; bootstrapId = record.bootstrapId; deviceId = record.deviceId;
      uid = record.uid.clone(); patch = record.initialPatchInfo.clone();
      base = record.streamingBase; lifecycle = record.lifecycle;
      count = record.unlockCount; loginOutcome = record.loginOutcome;
    }

    public synchronized boolean current() {
      if (discarded || current != this || !available()) return false;
      LibreGen1StreamingJournal.Record record = null;
      try {
        record = journal.read();
        requireConfirmed(record);
        return !discarded && current == this && available()
            && bootstrapId.equals(record.bootstrapId) && deviceId.equals(record.deviceId)
            && Arrays.equals(uid, record.uid) && Arrays.equals(patch, record.initialPatchInfo)
            && base == record.streamingBase && lifecycle == record.lifecycle
            && count == record.unlockCount && loginOutcome.equals(record.loginOutcome);
      } catch (Exception failure) { return false; }
      finally { clear(record); }
    }

    public synchronized Libre2Gen1ReadTransaction transaction() {
      if (!current()) throw closed("nfc_state_blocked");
      return Libre2Gen1ReadTransaction.forReceiver(uid, patch);
    }

    public synchronized void stage(Libre2Gen1ReadTransaction.VerifiedRead evidence) {
      if (!current()) throw closed("nfc_state_blocked");
      readPatch = evidence.initialPatchInfo();
      fram = evidence.encryptedFram();
      observedAt = wall.now(); observedNanos = clock.nowNanos();
      if (!fresh() || !current()) { discard(); throw closed("nfc_state_blocked"); }
    }

    public synchronized boolean complete(boolean cleanSuccess) {
      if (!cleanSuccess || fram == null || !current() || !fresh()) { discard(); return false; }
      ready = true;
      return true;
    }

    synchronized boolean fresh() {
      if (observedAt == null || observedNanos < 0) return false;
      try {
        final long now = clock.nowNanos();
        final Instant utc = wall.now();
        return now >= observedNanos && now - observedNanos < Libre2NfcSessionCoordinator.ATTEMPT_NANOS
            && !utc.isBefore(observedAt.minusSeconds(5)) && utc.isBefore(observedAt.plusSeconds(120));
      } catch (RuntimeException unavailable) { return false; }
    }

    synchronized void discard() {
      discarded = true; ready = false;
      Arrays.fill(uid, (byte) 0); Arrays.fill(patch, (byte) 0);
      if (readPatch != null) Arrays.fill(readPatch, (byte) 0);
      if (fram != null) Arrays.fill(fram, (byte) 0);
      readPatch = null; fram = null; observedAt = null;
    }

    @Override public String toString() { return "LibreReceiverHistoryAttempt(<redacted>)"; }
  }

  private static void requireConfirmed(LibreGen1StreamingJournal.Record record) {
    if (record == null || !"confirmed".equals(record.state)
        || record.uid[6] != 7 || record.uid[7] != (byte) 0xe0) throw closed("nfc_state_blocked");
    final byte[] patch = record.initialPatchInfo;
    final int signature = (patch[0] & 255) << 16 | (patch[1] & 255) << 8 | patch[2] & 255;
    if (signature != 0x9d0830 && signature != 0xc50930 && signature != 0x7f0e30) {
      throw closed("nfc_state_blocked");
    }
  }

  private static void clear(LibreGen1StreamingJournal.Record record) {
    if (record != null) {
      Arrays.fill(record.uid, (byte) 0); Arrays.fill(record.initialPatchInfo, (byte) 0);
    }
  }
  private static IllegalStateException closed(String code) { return new IllegalStateException(code); }
}
