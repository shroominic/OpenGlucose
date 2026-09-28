package com.aidex.aidex_flutter;

import java.io.IOException;
import java.util.Arrays;

/** Offline golden, exact-send, durability, and replay-boundary checks. */
public final class LibreGen1StreamingTest {
  private static final byte[] UID = hex("0011223344556677");
  private static final byte[] PATCH = hex("9d0830013412");
  private static final byte[] RESPONSE = hex("00112233445566");

  public static void main(String[] arguments) throws Exception {
    goldenAndShape();
    exactSequence();
    journalTransitions();
    failedWritesStayClosed();
    cleanupMustPrecedeBootstrap();
    durableCountersAndBounds();
    concurrentReservationsAreUnique();
    System.out.println("Libre Gen1 streaming synthetic checks passed.");
  }

  private static void goldenAndShape() throws Exception {
    check(Arrays.equals(LibreGen1Streaming.request(UID, PATCH, 0x12345678L),
        hex("02a1661e78563412bbd4c70e")), "Dart streaming golden mismatch");
    check(LibreGen1Streaming.deviceId(RESPONSE).equals("66:55:44:33:22:11"), "Response byte order mismatch");
    fails(() -> LibreGen1Streaming.deviceId(hex("01112233445566")));
    fails(() -> LibreGen1Streaming.deviceId(new byte[6]));
    fails(() -> LibreGen1Streaming.deviceId(new byte[8]));
    fails(() -> LibreGen1Streaming.deviceId(new byte[7]));
    fails(() -> LibreGen1Streaming.deviceId(hex("00ffffffffffff")));
    fails(() -> LibreGen1Streaming.request(new byte[7], PATCH, 1));
    fails(() -> LibreGen1Streaming.request(UID, hex("c60931010000"), 1));
    fails(() -> LibreGen1Streaming.request(UID, PATCH, -1));
    fails(() -> LibreGen1Streaming.request(UID, PATCH, 0x100000000L));
    for (int lifecycle : new int[] {0, 1, 4, 5, 6, 255}) {
      fails(() -> LibreGen1Streaming.requireLifecycle(lifecycle));
    }
  }

  private static void exactSequence() throws Exception {
    final byte[] enable = LibreGen1Streaming.request(UID, PATCH, 123);
    final LibreGen1Streaming.Sequence sequence = new LibreGen1Streaming.Sequence(enable);
    check(!sequence.consume(enable), "Enable was allowed before lifecycle");
    check(!sequence.consume(LibreGen1NfcFrames.frames().get(0).request()), "Skipped patch read");
    check(sequence.consume(hex("02a107")), "Patch read refused");
    check(!sequence.consume(hex("02a107")), "Duplicate patch read accepted");
    for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
      final byte[] changed = frame.request();
      changed[0] ^= 1;
      check(!sequence.consume(changed), "Changed request accepted");
      check(sequence.consume(frame.request()), "Fixed read refused");
      check(!sequence.consume(frame.request()), "Duplicate read accepted");
    }
    check(!sequence.consume(enable), "Enable accepted before CRC lifecycle proof");
    fails(() -> sequence.verifyLifecycle(1));
    sequence.verifyLifecycle(2);
    fails(() -> sequence.verifyLifecycle(2));
    final byte[] changed = enable.clone();
    changed[4] ^= 1;
    check(!sequence.consume(changed), "Changed streaming base accepted");
    check(sequence.consume(enable), "Exact enable refused");
    check(!sequence.consume(enable), "Enable retry accepted after uncertain transport");
    check(!sequence.consume(hex("02a107")), "Eighteenth send accepted");
  }

  private static void journalTransitions() throws Exception {
    final Memory backend = new Memory();
    final LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
    check(journal.read() == null, "Unexpected bootstrap");
    fails(() -> journal.prepare(UID, PATCH, 0, 1));
    final LibreGen1StreamingJournal.Record prepared = journal.prepare(UID, PATCH, 123, 2);
    check(backend.writes == 1, "Base was not durable before return");
    check(journal.read().streamingBase == 123, "Base not preserved");
    fails(() -> journal.reserve(prepared.bootstrapId));
    fails(() -> journal.confirm(prepared.bootstrapId, RESPONSE, 2, true));
    fails(() -> journal.prepare(UID, PATCH, 456, 2));
    journal.abortPrepared(prepared.bootstrapId);
    final LibreGen1StreamingJournal.Record next = journal.prepare(UID, PATCH, 456, 2);
    journal.commitIntent(next.bootstrapId);
    fails(() -> journal.commitIntent(next.bootstrapId));
    fails(() -> journal.abortPrepared(next.bootstrapId));
    final LibreGen1StreamingJournal restarted = new LibreGen1StreamingJournal(backend);
    check(restarted.read().state.equals("unknown"), "Unknown send was not retained across restart");
    fails(() -> restarted.prepare(UID, PATCH, 789, 2));
    fails(() -> restarted.confirm(next.bootstrapId, hex("01112233445566"), 2, true));
    check(restarted.read().state.equals("unknown"), "Malformed response changed journal");
    restarted.confirm(next.bootstrapId, RESPONSE, 3, true);
    check(restarted.read().state.equals("confirmed") && restarted.read().lifecycle == 3,
        "Confirmed bootstrap lost observed lifecycle");
    fails(() -> restarted.confirm(next.bootstrapId, RESPONSE, 3, true));
    fails(() -> restarted.reserve(prepared.bootstrapId));
    check(!restarted.read().toString().contains("66:55"), "Record diagnostic leaks address");
  }

  private static void failedWritesStayClosed() throws Exception {
    for (int failureMode : new int[] {1, 2, 3}) {
      final Memory backend = new Memory();
      final LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
      final LibreGen1StreamingJournal.Record prepared = journal.prepare(UID, PATCH, 123, 2);
      backend.failureMode = failureMode;
      fails(() -> journal.commitIntent(prepared.bootstrapId));
      backend.failureMode = 0;
      fails(journal::read);
      fails(() -> journal.abortPrepared(prepared.bootstrapId));
      final LibreGen1StreamingJournal restarted = new LibreGen1StreamingJournal(backend);
      if (failureMode == 2) {
        check(restarted.read().state.equals("unknown"), "Lost ACK must retain consumed intent");
        fails(() -> restarted.prepare(UID, PATCH, 124, 2));
      }
    }
  }

  private static void durableCountersAndBounds() throws Exception {
    final Memory backend = new Memory();
    final LibreGen1StreamingJournal journal = confirmed(backend, 100);
    final String id = journal.read().bootstrapId;
    check(journal.reserve(id) == 1, "First count must be 1");
    check(journal.read().loginOutcome.equals("unknown"), "Reservation must begin unknown");
    final LibreGen1StreamingJournal restarted = new LibreGen1StreamingJournal(backend);
    check(restarted.reserve(id) == 2, "Unknown login count was reused");
    fails(() -> restarted.mark(id, 1, "acknowledged"));
    restarted.mark(id, 2, "acknowledged");
    fails(() -> restarted.mark(id, 2, "unknown"));
    check(restarted.reserve(id) == 3, "Acknowledged count was reused");
    restarted.mark(id, 3, "unknown");
    final LibreGen1StreamingJournal exhausted = confirmed(new Memory(), 0xffffffffL);
    fails(() -> exhausted.reserve(exhausted.read().bootstrapId));
    final LibreGen1StreamingJournal counterBound = confirmed(new Memory(), 0);
    final String boundId = counterBound.read().bootstrapId;
    for (int i = 1; i <= 0xffff; i += 1) check(counterBound.reserve(boundId) == i, "Counter sequence changed");
    fails(() -> counterBound.reserve(boundId));
  }

  private static void cleanupMustPrecedeBootstrap() throws Exception {
    for (int failedStep : new int[] {0, 1, 2}) {
      final Memory backend = new Memory();
      final LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
      final String id = journal.prepare(UID, PATCH, 100, 2).bootstrapId;
      journal.commitIntent(id);
      final int[] releases = {0};
      final boolean complete = LibreGen1Streaming.completeTransport(
          failedStep != 0, failedStep != 1, () -> { releases[0] += 1; return false; });
      check(!complete, "Failed close/audit/release must block bootstrap");
      check(releases[0] == (failedStep == 2 ? 1 : 0), "Failed close/audit released the lease");
      fails(() -> journal.confirm(id, RESPONSE, 2, complete));
      check(journal.read().state.equals("unknown"), "Failed cleanup promoted bootstrap");
      fails(() -> journal.reserve(id));
      fails(() -> journal.abortPrepared(id));
    }
    check(LibreGen1Streaming.completeTransport(true, true, () -> true), "Proven cleanup refused");
  }

  private static void concurrentReservationsAreUnique() throws Exception {
    final LibreGen1StreamingJournal journal = confirmed(new Memory(), 100);
    final String id = journal.read().bootstrapId;
    final java.util.Set<Integer> counts = java.util.Collections.synchronizedSet(new java.util.HashSet<>());
    final java.util.List<Throwable> errors = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    final Thread[] workers = new Thread[8];
    for (int i = 0; i < workers.length; i += 1) {
      workers[i] = new Thread(() -> {
        try { counts.add(journal.reserve(id)); } catch (Throwable failure) { errors.add(failure); }
      });
      workers[i].start();
    }
    for (Thread worker : workers) worker.join();
    check(errors.isEmpty() && counts.size() == workers.length && journal.read().unlockCount == 8,
        "Concurrent reservations reused a counter");
  }

  private static LibreGen1StreamingJournal confirmed(Memory backend, long base) throws Exception {
    final LibreGen1StreamingJournal journal = new LibreGen1StreamingJournal(backend);
    final LibreGen1StreamingJournal.Record prepared = journal.prepare(UID, PATCH, base, 2);
    journal.commitIntent(prepared.bootstrapId);
    journal.confirm(prepared.bootstrapId, RESPONSE, 2, true);
    return journal;
  }

  private static final class Memory implements LibreGen1StreamingJournal.Backend {
    byte[] data;
    int writes;
    int failureMode;
    public byte[] read() { return data == null ? null : data.clone(); }
    public void write(byte[] bytes) throws IOException {
      writes += 1;
      if (failureMode == 1) throw new IOException();
      if (failureMode != 3) data = bytes == null ? null : bytes.clone();
      if (failureMode == 2) throw new IOException();
    }
  }

  private interface Action { void run() throws Exception; }
  private static void fails(Action action) throws Exception {
    try { action.run(); } catch (Exception expected) { return; }
    throw new AssertionError("Expected rejection");
  }
  private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
  private static byte[] hex(String input) {
    final byte[] result = new byte[input.length() / 2];
    for (int i = 0; i < result.length; i += 1) result[i] = (byte) Integer.parseInt(input.substring(i * 2, i * 2 + 2), 16);
    return result;
  }
}
