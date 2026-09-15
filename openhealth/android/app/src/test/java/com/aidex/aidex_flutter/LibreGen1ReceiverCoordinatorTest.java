package com.aidex.aidex_flutter;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** Synthetic-only receiver ownership, exact-target, durability, and recovery tests. */
public final class LibreGen1ReceiverCoordinatorTest {
  private static final byte[] UID = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 7, (byte) 0xe0};
  private static final byte[] PATCH = {(byte) 0x9d, 8, 0x30, 1, 0x34, 0x12};
  private static final byte[] RESPONSE = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
  private static final String SESSION = "0123456789abcdef0123456789abcdef0123456789abcdef";
  private static final String OTHER = "1123456789abcdef0123456789abcdef0123456789abcdef";

  public static void main(String[] args) throws Exception {
    absentAndReadOnly();
    unresolvedAndCorruptRemainBlocked();
    exactOwnerAndIdempotentAcquire();
    durableReservationBeforeReturn();
    unknownLoginConsumesCounterWithoutRollback();
    exactReceiverRechecked();
    ownershipLossAfterWriteBurnsCounter();
    storageFailureRetainsLeaseButPermitsConfirmedClose();
    failedAndUnconfirmedCloseRetainOwner();
    guardRecheckedAroundIo();
    unresolvedRestartBlocks();
    counterExhaustionPreservesReceiver();
    closedMethodArguments();
    System.out.println("Libre Gen1 recorder-free receiver synthetic checks passed.");
  }

  private static void absentAndReadOnly() throws Exception {
    final Fixture empty = new Fixture(false);
    check(empty.core.readBootstrap() == null, "Positive absence must return null");
    check(empty.backend.writes == 0 && empty.leases.acquires == 0, "Read created state");
    fails(() -> empty.core.acquire(SESSION, UUID.randomUUID().toString()));
    check(empty.leases.acquires == 0, "Missing receiver acquired ownership");
    final Fixture f = new Fixture(true);
    final int writes = f.backend.writes;
    final Map<String, Object> bootstrap = f.core.readBootstrap();
    check(bootstrap.size() == 6 && "active".equals(bootstrap.get("lifecycle")), "Wrong bootstrap schema");
    ((byte[]) bootstrap.get("uid"))[0] ^= 1;
    ((byte[]) bootstrap.get("initialPatchInfo"))[0] ^= 1;
    check(Arrays.equals(f.journal.read().uid, UID) && Arrays.equals(f.journal.read().initialPatchInfo, PATCH),
        "Result aliases protected state");
    check(f.backend.writes == writes && f.leases.acquires == 0, "Pure read acquired authority");
    fails(() -> f.core.reserve(SESSION, f.id(), OTHER));
    check(f.journal.read().unlockCount == 0, "Capability/credential read authorized login");
  }

  private static void unresolvedAndCorruptRemainBlocked() throws Exception {
    for (boolean consumed : new boolean[] {false, true}) {
      final Fixture f = new Fixture(false);
      final String id = f.journal.prepare(UID, PATCH, 100, 3).bootstrapId;
      if (consumed) f.journal.commitIntent(id);
      final byte[] before = f.backend.bytes.clone();
      fails(f.core::readBootstrap);
      fails(() -> f.core.acquire(SESSION, id));
      check(Arrays.equals(before, f.backend.bytes) && f.leases.acquires == 0,
          "Pending enrollment was changed or treated as absence");
    }
    final Fixture f = new Fixture(true);
    final String id = f.id();
    f.backend.bytes = new byte[] {1, 2, 3};
    fails(f.core::readBootstrap);
    fails(() -> f.core.acquire(SESSION, id));
    check(Arrays.equals(f.backend.bytes, new byte[] {1, 2, 3}), "Corrupt data erased");
  }

  private static void exactOwnerAndIdempotentAcquire() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    fails(() -> f.core.acquire("bad", id));
    fails(() -> f.core.acquire(SESSION, UUID.randomUUID().toString()));
    check(f.leases.acquires == 0, "Wrong target acquired lease");
    final String token = f.core.acquire(SESSION, id);
    check(token.equals(f.core.acquire(SESSION, id)) && f.leases.acquires == 1, "Duplicate request changed owner");
    fails(() -> f.core.acquire(OTHER, id));
    fails(() -> f.core.reserve(OTHER, id, token));
    fails(() -> f.core.reserve(SESSION, id, OTHER));
    fails(() -> f.core.release(SESSION, UUID.randomUUID().toString(), token, true));
    check(f.leases.releases == 0 && f.journal.read().unlockCount == 0, "Foreign caller changed ownership");
    f.core.release(SESSION, id, token, true);
    fails(() -> f.core.release(SESSION, id, token, true));
    final String next = f.core.acquire(OTHER, id);
    check(!next.equals(token), "Later connection reused an owner token");
    fails(() -> f.core.reserve(SESSION, id, token));
  }

  private static void durableReservationBeforeReturn() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    final String token = f.core.acquire(SESSION, id);
    final byte[] before = f.backend.bytes.clone();
    check(f.core.reserve(SESSION, id, token) == 1, "Incorrect first counter");
    final LibreGen1StreamingJournal restarted = new LibreGen1StreamingJournal(f.backend);
    check(restarted.read().unlockCount == 1 && "unknown".equals(restarted.read().loginOutcome),
        "Reservation not durable before return");
    f.core.mark(SESSION, id, token, 1, "acknowledged");
    fails(() -> f.core.mark(SESSION, id, token, 1, "unknown"));
    final byte[] confirmed = f.backend.bytes.clone();
    f.core.release(SESSION, id, token, true);
    check(Arrays.equals(confirmed, f.backend.bytes) && !Arrays.equals(before, confirmed),
        "Release changed protected receiver/counter");
  }

  private static void unknownLoginConsumesCounterWithoutRollback() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    final String token = f.core.acquire(SESSION, id);
    check(f.core.reserve(SESSION, id, token) == 1, "Counter 1 missing");
    f.core.mark(SESSION, id, token, 1, "unknown");
    check(f.core.reserve(SESSION, id, token) == 2, "Unknown outcome replayed a counter");
    fails(() -> f.core.mark(SESSION, id, token, 1, "acknowledged"));
    check(f.journal.read().unlockCount == 2, "Stale mark rolled back counter");
  }

  private static void exactReceiverRechecked() throws Exception {
    for (int field = 0; field < 6; field++) {
      final Fixture f = new Fixture(true);
      final String id = f.id();
      final String token = f.core.acquire(SESSION, id);
      final LibreGen1StreamingJournal.Record r = f.journal.read();
      final byte[] uid = r.uid.clone();
      final byte[] patch = r.initialPatchInfo.clone();
      if (field == 0) uid[0] ^= 1;
      if (field == 1) patch[4] ^= 1;
      f.backend.bytes = encoded(new LibreGen1StreamingJournal.Record(
          field == 2 ? UUID.randomUUID().toString() : r.bootstrapId, uid, patch,
          field == 3 ? r.streamingBase + 1 : r.streamingBase,
          field == 4 ? 2 : r.lifecycle, r.state,
          field == 5 ? "66:55:44:33:22:12" : r.deviceId, r.unlockCount, r.loginOutcome));
      final int writes = f.backend.writes;
      fails(() -> f.core.reserve(SESSION, id, token));
      check(f.backend.writes == writes, "Credential replacement reserved a counter");
      f.core.release(SESSION, id, token, true);
      check(!f.leases.held, "Confirmed transport close could not release old owner");
    }
  }

  private static void ownershipLossAfterWriteBurnsCounter() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    final String token = f.core.acquire(SESSION, id);
    f.backend.afterWrite = () -> f.leases.held = false;
    fails(() -> f.core.reserve(SESSION, id, token));
    f.backend.afterWrite = null;
    check(f.journal.read().unlockCount == 1, "Post-write ownership loss rolled counter back");
    f.leases.held = true;
    fails(() -> f.core.reserve(SESSION, id, token));
    fails(() -> f.core.release(SESSION, id, token, true));
    check(f.leases.releases == 0, "Lost ownership was revived by a late check");
  }

  private static void storageFailureRetainsLeaseButPermitsConfirmedClose() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    final String token = f.core.acquire(SESSION, id);
    f.backend.failAfterWrite = true;
    fails(() -> f.core.reserve(SESSION, id, token));
    check(f.leases.held, "Storage failure released potentially live BLE owner");
    fails(() -> f.core.reserve(SESSION, id, token));
    f.core.release(SESSION, id, token, true);
    check(!f.leases.held, "Confirmed transport cleanup depends on healthy journal");
    f.backend.failAfterWrite = false;
    check(new LibreGen1StreamingJournal(f.backend).read().unlockCount == 1, "Uncertain persisted counter lost");
    fails(f.core::readBootstrap);
  }

  private static void failedAndUnconfirmedCloseRetainOwner() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    final String token = f.core.acquire(SESSION, id);
    fails(() -> f.core.release(SESSION, id, token, false));
    check(f.leases.releases == 0 && f.leases.held, "No close proof released owner");
    f.leases.failRelease = true;
    fails(() -> f.core.release(SESSION, id, token, true));
    f.leases.failRelease = false;
    fails(() -> f.core.release(SESSION, id, token, true));
    fails(() -> f.core.reserve(SESSION, id, token));
    check(f.leases.held && f.leases.releases == 1, "Uncertain cleanup was automatically retried");
  }

  private static void guardRecheckedAroundIo() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    f.backend.afterRead = () -> f.allowed = false;
    fails(f.core::readBootstrap);
    check(f.leases.acquires == 0, "Read revocation acquired lease");
    f.backend.afterRead = null;
    f.allowed = true;
    f.leases.afterAcquire = () -> f.allowed = false;
    fails(() -> f.core.acquire(SESSION, id));
    check(f.leases.held && f.leases.releases == 0, "Revoked acquire discarded persisted owner");
    f.leases.afterAcquire = null;
    f.allowed = true;
    final String token = f.core.acquire(SESSION, id);
    f.allowed = false;
    fails(() -> f.core.reserve(SESSION, id, token));
    fails(() -> f.core.release(SESSION, id, token, true));
    check(f.leases.held, "Backend exclusion loss released unproven transport");
  }

  private static void unresolvedRestartBlocks() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    final String token = f.core.acquire(SESSION, id);
    f.core.reserve(SESSION, id, token);
    final LibreGen1ReceiverCoordinator restarted = new LibreGen1ReceiverCoordinator(
        new LibreGen1StreamingJournal(f.backend), f.leases, () -> true);
    check(restarted.readBootstrap() != null, "Restricted inspection required ownership");
    fails(() -> restarted.acquire(OTHER, id));
    fails(() -> restarted.release(SESSION, id, token, true));
    check(f.leases.held && f.journal.read().unlockCount == 1, "Restart cleared unknown owner/counter");
  }

  private static void counterExhaustionPreservesReceiver() throws Exception {
    for (boolean baseLimit : new boolean[] {false, true}) {
      final Fixture f = new Fixture(true);
      final LibreGen1StreamingJournal.Record r = f.journal.read();
      f.backend.bytes = encoded(new LibreGen1StreamingJournal.Record(r.bootstrapId, r.uid, r.initialPatchInfo,
          baseLimit ? 0xfffffffeL : 100, 3, "confirmed", r.deviceId, baseLimit ? 1 : 0xffff, "unknown"));
      final String token = f.core.acquire(SESSION, r.bootstrapId);
      final byte[] before = f.backend.bytes.clone();
      fails(() -> f.core.reserve(SESSION, r.bootstrapId, token));
      check(Arrays.equals(before, f.backend.bytes), "Exhaustion reset receiver");
      f.core.release(SESSION, r.bootstrapId, token, true);
    }
  }

  private static void closedMethodArguments() throws Exception {
    final Fixture f = new Fixture(true);
    final String id = f.id();
    fails(() -> f.core.call("activate", null));
    fails(() -> f.core.call("readLibreGen1StreamingBootstrap", new HashMap<>()));
    fails(() -> f.core.call("acquireLibreGen1Receiver", null));
    fails(() -> f.core.call("acquireLibreGen1Receiver", map("sessionId", SESSION)));
    fails(() -> f.core.call("acquireLibreGen1Receiver", map("sessionId", SESSION, "bootstrapId", id, "unexpected", true)));
    fails(() -> f.core.call("acquireLibreGen1Receiver", map("sessionId", 123, "bootstrapId", id)));
    check(f.leases.acquires == 0, "Malformed arguments acquired ownership");
    final String token = (String) f.core.call("acquireLibreGen1Receiver", map("sessionId", SESSION, "bootstrapId", id));
    final Map<String, Object> owner = map("sessionId", SESSION, "bootstrapId", id, "leaseToken", token);
    for (Object invalid : new Object[] {1.0, "1", 0, -1, 65536, 0x100000001L, true}) {
      final Map<String, Object> args = new HashMap<>(owner);
      args.put("unlockCount", invalid);
      args.put("outcome", "acknowledged");
      fails(() -> f.core.call("markLibreGen1LoginOutcome", args));
    }
    final Map<String, Object> extra = new HashMap<>(owner);
    extra.put("transportClosed", true);
    fails(() -> f.core.call("reserveLibreGen1UnlockCount", extra));
    final int count = (Integer) f.core.call("reserveLibreGen1UnlockCount", owner);
    final Map<String, Object> mark = new HashMap<>(owner);
    mark.put("unlockCount", (long) count);
    mark.put("outcome", "connected");
    fails(() -> f.core.call("markLibreGen1LoginOutcome", mark));
    mark.put("outcome", "acknowledged");
    check(f.core.call("markLibreGen1LoginOutcome", mark) == null, "Mark result must be null");
    for (Object invalid : new Object[] {1, "true", false}) {
      final Map<String, Object> args = new HashMap<>(owner);
      args.put("transportClosed", invalid);
      fails(() -> f.core.call("releaseLibreGen1Receiver", args));
    }
    check(f.leases.releases == 0, "Invalid close proof released ownership");
    check(f.core.call("releaseLibreGen1Receiver", extra) == null, "Release result must be null");
  }

  private static Map<String, Object> map(Object... values) {
    final Map<String, Object> result = new HashMap<>();
    for (int i = 0; i < values.length; i += 2) result.put((String) values[i], values[i + 1]);
    return result;
  }

  private static byte[] encoded(LibreGen1StreamingJournal.Record r) throws Exception {
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

  private static final class Fixture {
    final Memory backend = new Memory();
    final LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
    final Leases leases = new Leases();
    boolean allowed = true;
    final LibreGen1ReceiverCoordinator core = new LibreGen1ReceiverCoordinator(journal, leases, () -> allowed);
    Fixture(boolean confirmed) throws Exception {
      if (confirmed) {
        final String id = journal.prepare(UID, PATCH, 100, 3).bootstrapId;
        journal.commitIntent(id);
        journal.confirm(id, RESPONSE, 3, true);
      }
    }
    String id() throws Exception { return journal.read().bootstrapId; }
  }

  private static final class Memory implements LibreGen1StreamingJournal.Backend {
    byte[] bytes;
    int writes;
    boolean failAfterWrite;
    Runnable afterWrite;
    Runnable afterRead;
    public byte[] read() {
      final byte[] result = bytes == null ? null : bytes.clone();
      if (afterRead != null) afterRead.run();
      return result;
    }
    public void write(byte[] value) throws Exception {
      bytes = value == null ? null : value.clone();
      writes++;
      if (afterWrite != null) afterWrite.run();
      if (failAfterWrite) throw new IOException("Synthetic uncertain write");
    }
  }

  private static final class Leases implements LibreGen1ReceiverCoordinator.Leases {
    int acquires;
    int releases;
    boolean held;
    boolean failRelease;
    Runnable afterAcquire;
    public LibreGen1ReceiverCoordinator.Lease acquire(String token) {
      acquires++;
      if (held) return null;
      held = true;
      if (afterAcquire != null) afterAcquire.run();
      return new LibreGen1ReceiverCoordinator.Lease() {
        public boolean held() { return held; }
        public boolean release() {
          releases++;
          if (failRelease) return false;
          held = false;
          return true;
        }
      };
    }
  }

  private interface Action { void run() throws Exception; }
  private static void fails(Action action) throws Exception {
    try { action.run(); throw new AssertionError("Expected fail-closed result"); }
    catch (IOException expected) { }
  }
  private static void check(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
}
