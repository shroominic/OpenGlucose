package com.aidex.aidex_flutter;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.UUID;

/** Pure durable state machine. Any uncertain backend write permanently latches this instance. */
final class LibreGen1StreamingJournal {
  interface Backend {
    byte[] read() throws Exception;
    void write(byte[] bytes) throws Exception;
  }

  static final class Record {
    final String bootstrapId;
    final byte[] uid;
    final byte[] initialPatchInfo;
    final long streamingBase;
    final int lifecycle;
    final String state;
    final String deviceId;
    final int unlockCount;
    final String loginOutcome;

    Record(String id, byte[] uid, byte[] patch, long base, int lifecycle,
        String state, String deviceId, int count, String outcome) {
      this.bootstrapId = id;
      this.uid = uid.clone();
      this.initialPatchInfo = patch.clone();
      this.streamingBase = base;
      this.lifecycle = lifecycle;
      this.state = state;
      this.deviceId = deviceId;
      this.unlockCount = count;
      this.loginOutcome = outcome;
    }

    @Override public String toString() { return "LibreStreamingRecord(<redacted>)"; }
  }

  private final Backend backend;
  private boolean failed;

  LibreGen1StreamingJournal(Backend backend) { this.backend = backend; }

  synchronized Record prepare(byte[] uid, byte[] patch, long base, int lifecycle)
      throws Exception {
    LibreGen1Streaming.requireInputs(uid, patch, base);
    LibreGen1Streaming.requireLifecycle(lifecycle);
    if (read() != null) throw new IOException("Streaming journal already exists.");
    final Record record = new Record(UUID.randomUUID().toString(), uid, patch, base,
        lifecycle, "prepared", "", 0, "none");
    persist(record);
    return record;
  }

  synchronized Record read() throws Exception {
    requireHealthy();
    final byte[] bytes = backend.read();
    if (bytes == null) return null;
    try { return decode(bytes); } finally { Arrays.fill(bytes, (byte) 0); }
  }

  synchronized void abortPrepared(String id) throws Exception {
    final Record current = exact(id);
    if (!current.state.equals("prepared")) throw new IOException("Streaming outcome is unresolved.");
    persist(null);
  }

  synchronized void commitIntent(String id) throws Exception {
    final Record current = exact(id);
    if (!current.state.equals("prepared")) throw new IOException("Streaming intent already consumed.");
    persist(copy(current, "unknown", "", 0, "none"));
  }

  synchronized void confirm(String id, byte[] response, int observedLifecycle,
      boolean closedAuditedAndReleased) throws Exception {
    if (!closedAuditedAndReleased) throw new IOException("Streaming RF cleanup is unresolved.");
    final Record current = exact(id);
    if (!current.state.equals("unknown")) throw new IOException("No streaming intent.");
    LibreGen1Streaming.requireLifecycle(observedLifecycle);
    persist(new Record(current.bootstrapId, current.uid, current.initialPatchInfo,
        current.streamingBase, observedLifecycle, "confirmed", LibreGen1Streaming.deviceId(response), 0, "none"));
  }

  synchronized int reserve(String id) throws Exception {
    final Record current = exact(id);
    if (!current.state.equals("confirmed") || current.unlockCount >= 0xffff
        || current.streamingBase + current.unlockCount + 1 > 0xffffffffL) {
      throw new IOException("Login counter unavailable.");
    }
    final int count = current.unlockCount + 1;
    persist(copy(current, "confirmed", current.deviceId, count, "unknown"));
    return count;
  }

  synchronized void mark(String id, int count, String outcome) throws Exception {
    final Record current = exact(id);
    if (!current.state.equals("confirmed") || count < 1 || count != current.unlockCount
        || !(outcome.equals("acknowledged") || outcome.equals("unknown"))) {
      throw new IOException("Stale login outcome.");
    }
    if (current.loginOutcome.equals("acknowledged") && !outcome.equals("acknowledged")) {
      throw new IOException("Login acknowledgement cannot regress.");
    }
    persist(copy(current, current.state, current.deviceId, count, outcome));
  }

  private Record exact(String id) throws Exception {
    final Record record = read();
    if (record == null || !record.bootstrapId.equals(id)) throw new IOException("Stale streaming bootstrap.");
    return record;
  }

  private static Record copy(Record r, String state, String address, int count, String outcome) {
    return new Record(r.bootstrapId, r.uid, r.initialPatchInfo, r.streamingBase,
        r.lifecycle, state, address, count, outcome);
  }

  private void persist(Record record) throws Exception {
    requireHealthy();
    final byte[] bytes = record == null ? null : encode(record);
    byte[] confirmed = null;
    try {
      backend.write(bytes);
      confirmed = backend.read();
      if (!Arrays.equals(bytes, confirmed)) throw new IOException("Streaming durability verification failed.");
    } catch (Exception failure) {
      failed = true;
      throw new IOException("Streaming storage failed closed.");
    } finally {
      if (bytes != null) Arrays.fill(bytes, (byte) 0);
      if (confirmed != null) Arrays.fill(confirmed, (byte) 0);
    }
  }

  private void requireHealthy() throws IOException {
    if (failed) throw new IOException("Streaming storage requires recovery.");
  }

  private static byte[] encode(Record r) throws IOException {
    final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    final DataOutputStream out = new DataOutputStream(bytes);
    out.writeInt(1);
    out.writeUTF(r.bootstrapId);
    out.write(r.uid);
    out.write(r.initialPatchInfo);
    out.writeLong(r.streamingBase);
    out.writeInt(r.lifecycle);
    out.writeUTF(r.state);
    out.writeUTF(r.deviceId);
    out.writeInt(r.unlockCount);
    out.writeUTF(r.loginOutcome);
    out.flush();
    return bytes.toByteArray();
  }

  private static Record decode(byte[] bytes) throws IOException {
    if (bytes.length > 1024) throw new IOException("Invalid streaming storage.");
    final DataInputStream input = new DataInputStream(new ByteArrayInputStream(bytes));
    if (input.readInt() != 1) throw new IOException("Unsupported streaming schema.");
    final String id = input.readUTF();
    final byte[] uid = new byte[8];
    final byte[] patch = new byte[6];
    input.readFully(uid);
    input.readFully(patch);
    final long base = input.readLong();
    final int lifecycle = input.readInt();
    final String state = input.readUTF();
    final String address = input.readUTF();
    final int count = input.readInt();
    final String outcome = input.readUTF();
    try {
      LibreGen1Streaming.requireInputs(uid, patch, base);
      LibreGen1Streaming.requireLifecycle(lifecycle);
      UUID.fromString(id);
      if (input.available() != 0 || count < 0 || count > 0xffff
          || base + count > 0xffffffffL
          || !(state.equals("prepared") || state.equals("unknown") || state.equals("confirmed"))
          || !(outcome.equals("none") || outcome.equals("unknown") || outcome.equals("acknowledged"))
          || (count == 0) != outcome.equals("none")
          || (state.equals("confirmed")
              ? !address.matches("[0-9A-F]{2}(:[0-9A-F]{2}){5}")
              : !address.isEmpty() || count != 0)) {
        throw new IOException("Invalid streaming record.");
      }
      return new Record(id, uid, patch, base, lifecycle, state, address, count, outcome);
    } catch (IllegalArgumentException failure) {
      throw new IOException("Invalid streaming record.");
    } finally {
      Arrays.fill(uid, (byte) 0);
      Arrays.fill(patch, (byte) 0);
    }
  }
}
