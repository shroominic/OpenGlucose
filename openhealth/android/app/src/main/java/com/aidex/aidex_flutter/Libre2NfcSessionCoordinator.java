package com.aidex.aidex_flutter;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicInteger;

/** A single foreground, read-only NFC owner with an optional restricted read recipient. */
final class Libre2NfcSessionCoordinator {
  interface Clock { long nowNanos(); }
  interface Lease { boolean held(); boolean release(); }
  interface LeaseProvider { Lease acquire() throws Exception; }
  interface Reader {
    void start(TagCallback callback) throws Exception;
    void stop() throws Exception;
  }
  interface TagCallback { void detected(Libre2Gen1ReadTransaction.Transport transport); }
  interface Events { void emit(Map<String, Object> event); }
  /** Optional restricted read recipient. The default setup reader has none. */
  interface ReadPolicy {
    boolean current();
    Libre2Gen1ReadTransaction transaction();
    void stage(Libre2Gen1ReadTransaction.VerifiedRead evidence) throws Exception;
    /** Called only after transport/reader cleanup; true permits a success event. */
    boolean complete(boolean cleanSuccess);
  }
  interface ReadPolicies { ReadPolicy forAttempt(String id) throws Exception; }

  static final long ATTEMPT_NANOS = 120_000_000_000L;
  private final Object stateLock = new Object();
  private final Object rfLock = new Object();
  private final Clock clock;
  private final LeaseProvider leases;
  private final Reader reader;
  private final Executor worker;
  private final Events events;
  private final ReadPolicies policies;
  private volatile Attempt active;
  private volatile Attempt lastTerminal;
  private volatile boolean foreground;
  private volatile boolean detached;
  private volatile boolean quarantined;
  private volatile long generation;

  private static final class Attempt {
    final String id;
    final long generation;
    final long deadline;
    final Lease lease;
    final ReadPolicy policy;
    final CompletableFuture<Void> stopped = new CompletableFuture<>();
    volatile boolean revoked;
    // 0 idle, 1 admitted physical call, 2 revoked, 3 admitted then revoked.
    final AtomicInteger admission = new AtomicInteger();
    boolean claimed;
    boolean readerStopped;
    boolean transportDone;
    boolean terminal;
    boolean finishing;
    Attempt(String id, long generation, long deadline, Lease lease, ReadPolicy policy) {
      this.id = id; this.generation = generation; this.deadline = deadline; this.lease = lease;
      this.policy = policy;
    }
  }

  Libre2NfcSessionCoordinator(Clock clock, LeaseProvider leases, Reader reader,
      Executor worker, Events events) {
    this(clock, leases, reader, worker, events, null);
  }

  Libre2NfcSessionCoordinator(Clock clock, LeaseProvider leases, Reader reader,
      Executor worker, Events events, ReadPolicies policies) {
    this.clock = clock; this.leases = leases; this.reader = reader;
    this.worker = worker; this.events = events;
    this.policies = policies;
  }

  void resume() { if (!detached) foreground = true; }

  Object start(String id) throws Exception {
    synchronized (stateLock) {
      if (id == null || !id.matches("[A-Za-z0-9_-]{8,120}")) throw closed("bad_args");
      if (detached || !foreground) throw closed("nfc_not_foreground");
      if (quarantined) throw closed("nfc_cleanup_unconfirmed");
      if (active != null) throw closed("nfc_attempt_active");
      final long now = clock.nowNanos();
      if (now < 0 || now > Long.MAX_VALUE - ATTEMPT_NANOS) throw closed("nfc_unavailable");
      final ReadPolicy policy = policies == null ? null : policies.forAttempt(id);
      if (policy != null && !policy.current()) throw closed("nfc_state_blocked");
      final Lease lease = leases.acquire();
      if (lease == null) throw closed("nfc_state_blocked");
      if (!lease.held()) { quarantined = true; throw closed("nfc_cleanup_unconfirmed"); }
      if (detached || !foreground || clock.nowNanos() < now
          || clock.nowNanos() >= now + ATTEMPT_NANOS) {
        if (!lease.release()) quarantined = true;
        throw closed(quarantined ? "nfc_cleanup_unconfirmed" : "nfc_not_foreground");
      }
      final Attempt attempt = new Attempt(id, ++generation, now + ATTEMPT_NANOS, lease, policy);
      active = attempt;
      try {
        reader.start(transport -> claim(attempt, transport));
        if (!attempt.claimed && !attempt.terminal) publish(attempt, "listening", null, null);
        return attempt;
      } catch (Exception failure) {
        revoke(attempt);
        stopReader(attempt);
        // A callback may have been claimed before reader registration failed.
        // Its worker still owns completion/close even though no new RF may admit.
        if (!attempt.claimed) attempt.transportDone = true;
        finish(attempt, "readFailed", null);
        throw closed(quarantined ? "nfc_cleanup_unconfirmed" : "nfc_start_failed");
      }
    }
  }

  CompletableFuture<Void> stop(String id) {
    synchronized (stateLock) {
      final Attempt attempt = active;
      if (attempt == null) return CompletableFuture.completedFuture(null);
      if (!attempt.id.equals(id)) return failed("nfc_attempt_mismatch");
      revoke(attempt);
      if (attempt.stopped.isDone()) {
        if (!quarantined) {
          // A completed restricted read keeps its one-use handoff across an
          // exact stop. The setup-only reader retains its existing event flow.
          if (attempt.policy == null) publish(attempt, "failed", "readFailed", null);
          lastTerminal = attempt;
          active = null;
        }
        return attempt.stopped;
      }
      stopReader(attempt);
      if (!attempt.claimed) attempt.transportDone = true;
      if (attempt.transportDone) finish(attempt, null, null);
      return attempt.stopped;
    }
  }

  void pause() {
    // Revocation is nonblocking even if a native transceive is still in flight.
    suspendAdmission();
    final Attempt attempt = active;
    if (attempt != null) {
      revoke(attempt);
      stop(attempt.id);
    }
  }

  /** Revoke RF admission before waiting for any policy/storage/cleanup lock. */
  void suspendAdmission() {
    foreground = false;
    final Attempt attempt = active;
    if (attempt != null) revoke(attempt);
  }

  void revokeAdmission(Object binding) {
    final Attempt attempt = active;
    if (attempt != null && attempt == binding) revoke(attempt);
  }

  void detach() { detached = true; pause(); }

  Object binding(String id) {
    final Attempt attempt = active;
    return attempt != null && attempt.id.equals(id) ? attempt : null;
  }

  boolean acceptsEvent(Object binding, String event) {
    if (!(binding instanceof Attempt)) return false;
    final Attempt attempt = (Attempt) binding;
    if (detached || attempt.generation != generation) return false;
    if ("failed".equals(event)) {
      return active == attempt || (active == null && lastTerminal == attempt);
    }
    final long now = clock.nowNanos();
    return active == attempt && !attempt.revoked && foreground && !quarantined
        && now >= 0 && now < attempt.deadline;
  }

  void expire(Object binding) {
    final Attempt attempt = active;
    if (attempt != null && attempt == binding && clock.nowNanos() >= attempt.deadline) {
      revoke(attempt);
      stop(attempt.id);
    }
  }

  void quarantine(Object binding) {
    synchronized (stateLock) {
      final Attempt attempt = active;
      if (attempt == null || attempt != binding || attempt.stopped.isDone()) return;
      revoke(attempt);
      quarantined = true;
      stopReader(attempt);
      publish(attempt, "failed", "cleanupUnconfirmed", null);
      attempt.stopped.completeExceptionally(closed("nfc_cleanup_unconfirmed"));
      if (attempt.policy != null) attempt.policy.complete(false);
      // The exact lease remains on disk, including after a late successful close.
    }
  }

  boolean isQuarantined() { return quarantined; }

  private void claim(Attempt attempt, Libre2Gen1ReadTransaction.Transport transport) {
    synchronized (stateLock) {
      if (!eligible(attempt) || attempt.claimed || transport == null) return;
      attempt.claimed = true;
      publish(attempt, "tagDetected", null, null);
      try { worker.execute(() -> read(attempt, transport)); }
      catch (RuntimeException rejected) {
        attempt.transportDone = true;
        finish(attempt, "readFailed", null);
      }
    }
  }

  private void read(Attempt attempt, Libre2Gen1ReadTransaction.Transport raw) {
    String lifecycle = null;
    String failure = null;
    byte[] uid = null;
    final Libre2Gen1ReadTransaction.Transport guarded = new Libre2Gen1ReadTransaction.Transport() {
      public byte[] uid() throws Exception { synchronized (rfLock) { requireCurrent(attempt); return raw.uid(); } }
      public int maxTransceiveLength() throws Exception { synchronized (rfLock) { requireCurrent(attempt); return raw.maxTransceiveLength(); } }
      public void connect() throws Exception {
        synchronized (rfLock) {
          admit(attempt);
          try { raw.connect(); } finally { releaseAdmission(attempt); }
        }
      }
      public byte[] transceive(byte[] request) throws Exception {
        synchronized (rfLock) {
          admit(attempt);
          try { return raw.transceive(request); } finally { releaseAdmission(attempt); }
        }
      }
      public void close() throws Exception { synchronized (rfLock) { raw.close(); } }
    };
    try {
      synchronized (rfLock) { requireCurrent(attempt); uid = raw.uid(); }
      synchronized (stateLock) { publish(attempt, "readingMetadata", null, null); }
      try (Libre2Gen1ReadTransaction.VerifiedRead evidence =
          (attempt.policy == null ? new Libre2Gen1ReadTransaction(uid, null)
              : attempt.policy.transaction()).run(guarded, () -> {
            synchronized (rfLock) { requireCurrent(attempt); }
          })) {
        lifecycle = evidence.lifecycle();
        if (attempt.policy != null) attempt.policy.stage(evidence);
        // The setup-only constructor exposes only a closed lifecycle. An
        // injected policy may retain read evidence, never write authority.
      }
    } catch (Libre2Gen1ReadTransaction.ReadException error) {
      failure = error.failure == Libre2Gen1ReadTransaction.Failure.closeUnconfirmed
          ? "cleanupUnconfirmed" : "readFailed";
    } catch (Exception error) {
      failure = "readFailed";
    } finally {
      if (uid != null) Arrays.fill(uid, (byte) 0);
      synchronized (stateLock) {
        attempt.transportDone = true;
        finish(attempt, failure, lifecycle);
      }
    }
  }

  private boolean eligible(Attempt attempt) {
    // held() can perform filesystem I/O. Never use a fence/time sample taken
    // before it as permission to start a physical operation afterwards.
    if (!bindingCurrent(attempt) || !attempt.lease.held()
        || (attempt.policy != null && !attempt.policy.current())) return false;
    return bindingCurrent(attempt);
  }

  private boolean bindingCurrent(Attempt attempt) {
    final long now = clock.nowNanos();
    return active == attempt && !attempt.revoked && !quarantined && !detached
        && foreground && attempt.generation == generation && now >= 0 && now < attempt.deadline;
  }

  private void admit(Attempt attempt) throws Exception {
    requireCurrent(attempt);
    // This CAS is the physical-call admission linearization point. Pause can
    // revoke without waiting on a blocked transceive: a pre-admission revoke
    // prevents this call; a post-admission revoke permits only the already
    // admitted in-flight call and requires its close before successful stop.
    if (!attempt.admission.compareAndSet(0, 1)) throw closed("nfc_authorization_changed");
    if (!bindingCurrent(attempt)) {
      releaseAdmission(attempt);
      throw closed("nfc_authorization_changed");
    }
  }

  private static void releaseAdmission(Attempt attempt) {
    if (!attempt.admission.compareAndSet(1, 0)) attempt.admission.compareAndSet(3, 2);
  }

  private static void revoke(Attempt attempt) {
    attempt.revoked = true;
    attempt.admission.getAndUpdate(value -> value == 1 ? 3 : 2);
  }

  private void requireCurrent(Attempt attempt) throws Exception {
    if (!eligible(attempt)) throw closed("nfc_authorization_changed");
  }

  private void stopReader(Attempt attempt) {
    if (attempt.readerStopped) return;
    attempt.readerStopped = true;
    try { reader.stop(); }
    catch (Exception error) { quarantined = true; }
  }

  private void finish(Attempt attempt, String failure, String lifecycle) {
    if (active != attempt || attempt.finishing || !attempt.transportDone) return;
    attempt.finishing = true;
    final boolean wasEligible = eligible(attempt);
    stopReader(attempt);
    if ("cleanupUnconfirmed".equals(failure)) quarantined = true;
    if (!quarantined && !attempt.lease.release()) quarantined = true;
    if (quarantined) {
      if (attempt.policy != null) attempt.policy.complete(false);
      publish(attempt, "failed", "cleanupUnconfirmed", null);
      attempt.stopped.completeExceptionally(closed("nfc_cleanup_unconfirmed"));
      return;
    }
    boolean successful = !attempt.terminal && wasEligible && !attempt.revoked && foreground && !detached
        && clock.nowNanos() < attempt.deadline && lifecycle != null && failure == null;
    // Install any restricted handoff before synchronous success listeners run.
    // It is never installed on an uncertain close or failed exact lease release.
    if (attempt.policy != null) successful = attempt.policy.complete(successful) && successful;
    if (successful) {
      publish(attempt, "metadataRead", null, lifecycle);
    } else if (!attempt.terminal) {
      publish(attempt, "failed", failure == null ? "readFailed" : failure, null);
    }
    attempt.terminal = true;
    lastTerminal = attempt;
    attempt.stopped.complete(null);
    if (attempt.revoked) active = null;
  }

  private void publish(Attempt attempt, String event, String reason, String lifecycle) {
    if (active != attempt || detached) return;
    final Map<String, Object> value = new HashMap<>();
    value.put("attemptId", attempt.id); value.put("event", event);
    if (reason != null) value.put("reason", reason);
    if (lifecycle != null) { value.put("model", "libre2"); value.put("status", lifecycle); }
    events.emit(Collections.unmodifiableMap(value));
  }

  private static IllegalStateException closed(String code) { return new IllegalStateException(code); }
  private static CompletableFuture<Void> failed(String code) {
    final CompletableFuture<Void> future = new CompletableFuture<>();
    future.completeExceptionally(closed(code));
    return future;
  }
}
