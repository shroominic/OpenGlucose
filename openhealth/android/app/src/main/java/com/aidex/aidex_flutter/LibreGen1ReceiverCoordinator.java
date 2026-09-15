package com.aidex.aidex_flutter;

import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** Recorder-free access to an existing receiver. No enrollment or RF commands. */
final class LibreGen1ReceiverCoordinator {
  interface Guard { boolean allowed(); }
  interface Lease {
    boolean held();
    boolean release();
  }
  interface Leases { Lease acquire(String token) throws Exception; }

  private final LibreGen1StreamingJournal journal;
  private final Leases leases;
  private final Guard guard;
  private Binding binding;

  /** Ownership remains present after an uncertain close; capability is not RF proof. */
  synchronized boolean hasBinding() { return binding != null; }

  LibreGen1ReceiverCoordinator(LibreGen1StreamingJournal journal, Leases leases, Guard guard) {
    this.journal = journal;
    this.leases = leases;
    this.guard = guard;
  }

  /** Closed channel dispatch kept pure so argument rejection is tested offline. */
  Object call(String method, Object arguments) throws Exception {
    if ("readLibreGen1StreamingBootstrap".equals(method)) {
      if (arguments != null) throw unavailable();
      return readBootstrap();
    }
    final boolean acquire = "acquireLibreGen1Receiver".equals(method);
    final boolean reserve = "reserveLibreGen1UnlockCount".equals(method);
    final boolean mark = "markLibreGen1LoginOutcome".equals(method);
    if (!acquire && !reserve && !mark && !"releaseLibreGen1Receiver".equals(method)) throw unavailable();
    final Map<?, ?> args = acquire ? arguments(arguments, "sessionId", "bootstrapId")
        : reserve ? arguments(arguments, "sessionId", "bootstrapId", "leaseToken")
        : mark ? arguments(arguments, "sessionId", "bootstrapId", "leaseToken", "unlockCount", "outcome")
        : arguments(arguments, "sessionId", "bootstrapId", "leaseToken", "transportClosed");
    final String sessionId = token(args, "sessionId");
    final String bootstrapId = token(args, "bootstrapId");
    if (acquire) return acquire(sessionId, bootstrapId);
    final String leaseToken = token(args, "leaseToken");
    if (reserve) return reserve(sessionId, bootstrapId, leaseToken);
    if (mark) {
      final Object count = args.get("unlockCount");
      final Object outcome = args.get("outcome");
      if (!(count instanceof Integer || count instanceof Long) || !(outcome instanceof String)) throw unavailable();
      final long countValue = ((Number) count).longValue();
      if (countValue < 1 || countValue > 0xffff
          || !("unknown".equals(outcome) || "acknowledged".equals(outcome))) throw unavailable();
      mark(sessionId, bootstrapId, leaseToken, (int) countValue, (String) outcome);
    } else {
      if (!(args.get("transportClosed") instanceof Boolean)) throw unavailable();
      release(sessionId, bootstrapId, leaseToken, (Boolean) args.get("transportClosed"));
    }
    return null;
  }

  /** Restricted credential read. Its result cannot reserve counters or grant RF ownership. */
  synchronized Map<String, Object> readBootstrap() throws Exception {
    requireAllowed();
    final LibreGen1StreamingJournal.Record record = journal.read();
    try {
      requireAllowed();
      if (record == null) return null;
      requireConfirmed(record);
      final Map<String, Object> value = new HashMap<>();
      value.put("bootstrapId", record.bootstrapId);
      value.put("deviceId", record.deviceId);
      value.put("uid", record.uid.clone());
      value.put("initialPatchInfo", record.initialPatchInfo.clone());
      value.put("streamingBase", record.streamingBase);
      value.put("lifecycle", LibreGen1Activation.closedLifecycleName(record.lifecycle));
      return value;
    } finally { clear(record); }
  }

  /** Acquired before BLE connect; the same owner must survive link recovery. */
  synchronized String acquire(String sessionId, String bootstrapId) throws Exception {
    requireToken(sessionId);
    requireToken(bootstrapId);
    requireAllowed();
    if (binding != null) {
      // An exact duplicate request may recover a response lost in the app. It
      // cannot create a new owner or take over another connection.
      if (!binding.sessionId.equals(sessionId) || !binding.bootstrapId.equals(bootstrapId)) {
        throw unavailable();
      }
      requireBinding(sessionId, bootstrapId, binding.token);
      return binding.token;
    }
    final LibreGen1StreamingJournal.Record record = journal.read();
    try {
      requireAllowed();
      requireConfirmed(record);
      if (!record.bootstrapId.equals(bootstrapId)) throw unavailable();
      final String token = UUID.randomUUID().toString();
      final Lease lease = leases.acquire(token);
      if (lease == null) throw unavailable();
      // Retain the owner even if the next check fails. No late callback may
      // discard an acquired lease after a possible RF handoff.
      binding = new Binding(sessionId, token, record, lease);
      requireBinding(sessionId, bootstrapId, token);
      return token;
    } finally { clear(record); }
  }

  synchronized int reserve(String sessionId, String bootstrapId, String token) throws Exception {
    requireBinding(sessionId, bootstrapId, token);
    final int count = journal.reserve(bootstrapId);
    // Ownership loss during durable storage burns this counter; never return
    // or roll it back for a later attempt.
    requireBinding(sessionId, bootstrapId, token);
    return count;
  }

  synchronized void mark(String sessionId, String bootstrapId, String token,
      int count, String outcome) throws Exception {
    requireBinding(sessionId, bootstrapId, token);
    journal.mark(bootstrapId, count, outcome);
    requireBinding(sessionId, bootstrapId, token);
  }

  /**
   * The app adapter calls this only after its exact BLE transport close
   * completes. Pause, detached listeners, failed connect, and timeouts are not
   * close proof. Native storage cannot establish physical BLE teardown itself.
   */
  synchronized void release(String sessionId, String bootstrapId, String token,
      boolean transportClosed) throws Exception {
    requireAllowed();
    requireOwner(sessionId, bootstrapId, token);
    if (!transportClosed) throw unavailable();
    requireLease();
    // A broken receiver journal does not prevent confirmed transport cleanup.
    // Its contents remain untouched and the next restore still fails closed.
    if (!binding.lease.release()) {
      binding.quarantined = true;
      throw unavailable();
    }
    binding.clear();
    binding = null;
  }

  private void requireBinding(String sessionId, String bootstrapId, String token) throws Exception {
    requireAllowed();
    requireOwner(sessionId, bootstrapId, token);
    requireLease();
    final LibreGen1StreamingJournal.Record current = journal.read();
    try {
      requireAllowed();
      requireConfirmed(current);
      if (!binding.matches(current)) throw unavailable();
      requireLease();
    } finally { clear(current); }
  }

  private void requireOwner(String sessionId, String bootstrapId, String token) throws IOException {
    requireToken(sessionId);
    requireToken(bootstrapId);
    requireToken(token);
    if (binding == null || binding.quarantined || !binding.sessionId.equals(sessionId)
        || !binding.bootstrapId.equals(bootstrapId) || !binding.token.equals(token)) throw unavailable();
  }

  private void requireLease() throws IOException {
    if (!binding.lease.held()) {
      binding.quarantined = true;
      throw unavailable();
    }
  }

  private void requireAllowed() throws IOException { if (!guard.allowed()) throw unavailable(); }

  private static void requireConfirmed(LibreGen1StreamingJournal.Record record) throws IOException {
    if (record == null || !"confirmed".equals(record.state)) throw unavailable();
  }

  static void requireToken(String token) throws IOException {
    if (token == null || !token.matches("[A-Za-z0-9_-]{16,128}")) throw unavailable();
  }

  static Map<?, ?> arguments(Object value, String... keys) throws IOException {
    if (!(value instanceof Map)) throw unavailable();
    final Map<?, ?> map = (Map<?, ?>) value;
    if (map.size() != keys.length || !map.keySet().containsAll(Arrays.asList(keys))) throw unavailable();
    return map;
  }

  static String token(Map<?, ?> args, String key) throws IOException {
    final Object token = args.get(key);
    if (!(token instanceof String)) throw unavailable();
    requireToken((String) token);
    return (String) token;
  }

  private static IOException unavailable() { return new IOException("Libre receiver is unavailable."); }

  private static void clear(LibreGen1StreamingJournal.Record record) {
    if (record != null) {
      Arrays.fill(record.uid, (byte) 0);
      Arrays.fill(record.initialPatchInfo, (byte) 0);
    }
  }

  private static final class Binding {
    final String sessionId;
    final String token;
    final String bootstrapId;
    final String deviceId;
    final byte[] uid;
    final byte[] patch;
    final long base;
    final int lifecycle;
    final Lease lease;
    boolean quarantined;

    Binding(String sessionId, String token, LibreGen1StreamingJournal.Record record, Lease lease) {
      this.sessionId = sessionId;
      this.token = token;
      bootstrapId = record.bootstrapId;
      deviceId = record.deviceId;
      uid = record.uid.clone();
      patch = record.initialPatchInfo.clone();
      base = record.streamingBase;
      lifecycle = record.lifecycle;
      this.lease = lease;
    }

    boolean matches(LibreGen1StreamingJournal.Record record) {
      return bootstrapId.equals(record.bootstrapId) && deviceId.equals(record.deviceId)
          && Arrays.equals(uid, record.uid) && Arrays.equals(patch, record.initialPatchInfo)
          && base == record.streamingBase && lifecycle == record.lifecycle;
    }

    void clear() { Arrays.fill(uid, (byte) 0); Arrays.fill(patch, (byte) 0); }
  }
}
