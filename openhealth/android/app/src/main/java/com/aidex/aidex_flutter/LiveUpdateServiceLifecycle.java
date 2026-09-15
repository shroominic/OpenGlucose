package com.aidex.aidex_flutter;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/** Process-local service ownership, never restored from notification preferences. */
final class LiveUpdateServiceLifecycle {
  static final long START_TIMEOUT_MILLIS = 10_000;
  enum Failure { CANCELLED, START_FAILED, TIMED_OUT }

  interface Completion { void complete(Failure failure); }
  interface Clock { long nowMillis(); }

  static final class Operation {
    final String incarnation;
    final long epoch;
    final boolean statusOnly;
    final long startDeadlineMillis;
    private Completion completion;

    Operation(String incarnation, long epoch, boolean statusOnly,
        long startDeadlineMillis, Completion completion) {
      this.incarnation = incarnation;
      this.epoch = epoch;
      this.statusOnly = statusOnly;
      this.startDeadlineMillis = startDeadlineMillis;
      this.completion = completion;
    }
  }

  private final String incarnation;
  private final Clock clock;
  private long epoch;
  private Operation active;

  LiveUpdateServiceLifecycle(String incarnation, Clock clock) {
    if (incarnation == null || incarnation.isEmpty() || clock == null) {
      throw new IllegalArgumentException();
    }
    this.incarnation = incarnation;
    this.clock = clock;
  }

  synchronized Operation begin(boolean statusOnly, Completion completion) {
    invalidate();
    if (epoch == Long.MAX_VALUE) throw new IllegalStateException("Service epoch exhausted.");
    active = new Operation(incarnation, ++epoch, statusOnly,
        Math.addExact(clock.nowMillis(), START_TIMEOUT_MILLIS), completion);
    return active;
  }

  synchronized Operation current() { return active; }

  synchronized Operation admit(String token, long requestedEpoch, boolean statusOnly) {
    if (active == null || !active.incarnation.equals(token)
        || active.epoch != requestedEpoch || active.statusOnly != statusOnly) return null;
    return beforeForeground(active) ? active : null;
  }

  synchronized boolean beforeForeground(Operation operation) {
    if (active != operation) return false;
    // A delayed main looper can deliver onStartCommand before its overdue
    // Handler timer. Admission and the actual effect must check elapsed time.
    if (startupExpired(operation)) {
      fail(operation, Failure.TIMED_OUT);
      return false;
    }
    return true;
  }

  synchronized boolean started(Operation operation) {
    if (!beforeForeground(operation)) return false;
    complete(operation, null);
    return true;
  }

  synchronized boolean fail(Operation operation, Failure failure) {
    if (active != operation) return false;
    active = null;
    complete(operation, failure);
    return true;
  }

  synchronized boolean timeout(Operation operation) {
    // An acknowledged service does not expire when its old startup timer fires.
    return active == operation && startupExpired(operation)
        && fail(operation, Failure.TIMED_OUT);
  }

  private boolean startupExpired(Operation operation) {
    return operation.completion != null && clock.nowMillis() >= operation.startDeadlineMillis;
  }

  synchronized void invalidate() {
    final Operation previous = active;
    active = null;
    if (previous != null) complete(previous, Failure.CANCELLED);
  }

  private void complete(Operation operation, Failure failure) {
    final Completion callback = operation.completion;
    operation.completion = null;
    if (callback != null) callback.complete(failure);
  }

  static Map<String, Object> connectionStatusPayload() {
    final HashMap<String, Object> payload = new HashMap<>();
    payload.put("connectionStatusOnly", true);
    payload.put("sensorName", "OpenGlucose");
    payload.put("stageCode", "connection");
    payload.put("stageLabel", "Sensor connection");
    payload.put("valueText", "--");
    payload.put("unitText", "");
    payload.put("lastReadingText", "--");
    payload.put("lifeText", "");
    payload.put("detailText", "Sensor connection service is running");
    payload.put("trendSymbol", "");
    payload.put("deltaText", "");
    payload.put("isStale", true);
    return Collections.unmodifiableMap(payload);
  }
}
