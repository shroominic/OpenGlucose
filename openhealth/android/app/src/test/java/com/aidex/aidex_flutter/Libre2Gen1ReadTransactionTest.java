package com.aidex.aidex_flutter;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Synthetic-only extraction checks; no phone, filesystem, or sensor access. */
public final class Libre2Gen1ReadTransactionTest {
  private static final byte[] UID = hex("0011223344556677");
  private static final byte[] PATCH = hex("9d0830013412");
  // Same wholly synthetic encrypted fixture as gen1_security_test.dart.
  private static final byte[] ENCRYPTED = hex(
      "fbd6e447b519369a3bfe1348b837c3820b31c742fe1c595f"
      + "f557302d47328c477e07b30886ce3e4548a3c4873fe0cb5d"
      + "38ec900db9cb51c08ea8e7a200e5c45883377e52eb8c8bac"
      + "355309dd5222fe34851c5d571489e46933582a382d27b1f1d"
      + "a81737b94e269176c258474ad4c1c8f1cea507eabe706122a"
      + "2ea7519249930ab82fca59886099de8ecb3d56b14e6cc6be"
      + "04e95cf765f61b88c01e334e4b2303cb329d168fb79101fd"
      + "96ea99369964198dd9be13b0b2fe843b9dc9bc099c6b1c36"
      + "02504ce2f524e8806627c35b5b5170302973491df04b2d866"
      + "d0426245e1eb53b67deab0083aa318dc329a4392ddfa9fd0c"
      + "fdae3f86c534cbc80a810628502cdbcf7f933c695bf8ed2b8"
      + "89c0547aee0dde45c96436c343deb20abf9fa42e125a8d228"
      + "dc3bbe53279e765f538290a63fee390bd904bb3ca2587d7c7"
      + "6bd95a93a359ee58656fce6cee3869209ef52935653c9c683"
      + "a9f9890b");

  public static void main(String[] arguments) throws Exception {
    exactReadOnlySequenceAndEvidence();
    validatesEveryLifecycleAndCrcRegion();
    rejectsMalformedResponsesAndUnsupportedFamilies();
    rejectsTargetChangesAtEveryExchange();
    revocationStopsEveryBoundary();
    closeAndTransportFailuresNeverPublishOrRetry();
    validatesInputsAndCapacity();
    System.out.println("Libre Gen1 read-only extraction synthetic checks passed.");
  }

  private static void exactReadOnlySequenceAndEvidence() throws Exception {
    final Fake transport = new Fake();
    final byte[] callerUid = UID.clone();
    final byte[] callerPatch = PATCH.clone();
    final Libre2Gen1ReadTransaction transaction = new Libre2Gen1ReadTransaction(callerUid, callerPatch);
    Arrays.fill(callerUid, (byte) 0);
    Arrays.fill(callerPatch, (byte) 0);
    final Libre2Gen1ReadTransaction.VerifiedRead evidence = transaction.run(transport, transport);
    check(transport.connects == 1 && transport.closes == 1, "transport ownership changed");
    check(transport.requests.size() == 16, "read count changed");
    check(Arrays.equals(transport.requests.get(0), hex("02a107")), "patch read changed");
    for (int i = 0; i < 15; i++) {
      check(Arrays.equals(transport.requests.get(i + 1), LibreGen1NfcFrames.frames().get(i).request()),
          "non-read or reordered request");
    }
    check(evidence.lifecycle().equals("active"), "wrong lifecycle");
    check(!evidence.authorizesStateChange(), "read proof authorized write");
    check(Arrays.equals(evidence.uid(), UID) && Arrays.equals(evidence.initialPatchInfo(), PATCH),
        "input snapshots lost");
    check(Arrays.equals(evidence.encryptedFram(), ENCRYPTED), "encrypted FRAM changed");
    Arrays.fill(evidence.encryptedFram(), (byte) 0);
    check(Arrays.equals(evidence.encryptedFram(), ENCRYPTED), "mutable evidence escaped");
    check(evidence.toString().equals("LibreVerifiedRead(<redacted>)"), "unsafe diagnostic");
    assertWiped(transport);
    evidence.close();
    evidence.close();
    try { evidence.uid(); throw new AssertionError("closed evidence readable"); }
    catch (IllegalStateException expected) { }
    fail(Libre2Gen1ReadTransaction.Failure.alreadyUsed, () -> transaction.run(transport, transport));
    check(transport.requests.size() == 16 && transport.closes == 1, "completed read retried");
  }

  private static void validatesEveryLifecycleAndCrcRegion() throws Exception {
    final String[] states = {"unknown", "notActivated", "warmingUp", "active", "expired", "shutdown", "failure", "unknown"};
    for (int i = 0; i < states.length; i++) {
      final Fake transport = new Fake();
      transport.fram = encryptedForLifecycle(i);
      try (Libre2Gen1ReadTransaction.VerifiedRead evidence = fresh().run(transport, transport)) {
        check(evidence.lifecycle().equals(states[i]), "closed lifecycle mapping changed");
      }
    }
    for (int index : new int[] {10, 100, 330}) {
      final Fake transport = new Fake();
      transport.fram[index] ^= 1;
      fail(Libre2Gen1ReadTransaction.Failure.invalidFram, () -> fresh().run(transport, transport));
      check(transport.closes == 1 && transport.requests.size() == 16, "CRC failure cleanup changed");
      assertWiped(transport);
    }
  }

  private static void rejectsMalformedResponsesAndUnsupportedFamilies() throws Exception {
    for (int step = 0; step < 16; step++) {
      for (int mode = 1; mode <= 4; mode++) {
        final Fake transport = new Fake();
        transport.invalidAt = step;
        transport.invalidMode = mode;
        fail(Libre2Gen1ReadTransaction.Failure.invalidResponse, () -> fresh().run(transport, transport));
        check(transport.requests.size() == step + 1 && transport.closes == 1, "malformed response continued");
        assertWiped(transport);
      }
    }
    for (String patch : new String[] {"c60931010000", "2b0a39010000", "000000000000"}) {
      final Fake transport = new Fake();
      transport.patch = hex(patch);
      fail(Libre2Gen1ReadTransaction.Failure.unsupportedPatch, () -> fresh().run(transport, transport));
      check(transport.requests.size() == 1, "unsupported family read FRAM");
    }
    final Fake changedPatch = new Fake();
    changedPatch.patch[5] ^= 1;
    fail(Libre2Gen1ReadTransaction.Failure.targetChanged,
        () -> new Libre2Gen1ReadTransaction(UID, PATCH).run(changedPatch, changedPatch));
    check(changedPatch.requests.size() == 1, "changed initial patch continued");
  }

  private static void rejectsTargetChangesAtEveryExchange() throws Exception {
    final Fake initiallyWrong = new Fake();
    initiallyWrong.target[0] ^= 1;
    fail(Libre2Gen1ReadTransaction.Failure.targetChanged, () -> fresh().run(initiallyWrong, initiallyWrong));
    check(initiallyWrong.connects == 0 && initiallyWrong.closes == 0, "wrong target opened");
    for (int step = 0; step < 16; step++) {
      final Fake transport = new Fake();
      transport.changeTargetAt = step;
      fail(Libre2Gen1ReadTransaction.Failure.targetChanged, () -> fresh().run(transport, transport));
      check(transport.requests.size() == step + 1 && transport.closes == 1, "changed target continued");
      assertWiped(transport);
    }
  }

  private static void revocationStopsEveryBoundary() throws Exception {
    final Fake baseline = new Fake();
    fresh().run(baseline, baseline).close();
    for (int checkIndex = 1; checkIndex <= baseline.guardChecks; checkIndex++) {
      final Fake transport = new Fake();
      transport.rejectGuardAt = checkIndex;
      final Libre2Gen1ReadTransaction transaction = fresh();
      fail(Libre2Gen1ReadTransaction.Failure.authorizationChanged, () -> transaction.run(transport, transport));
      check(transport.closes == transport.connects, "revoked read left open transport");
      check(transport.guardChecks == checkIndex, "revoked guard continued");
      final int sends = transport.requests.size();
      fail(Libre2Gen1ReadTransaction.Failure.alreadyUsed, () -> transaction.run(transport, transport));
      check(transport.requests.size() == sends, "revoked instance retried");
      assertWiped(transport);
    }
  }

  private static void closeAndTransportFailuresNeverPublishOrRetry() throws Exception {
    for (int step = 0; step < 16; step++) {
      final Fake transport = new Fake();
      transport.failAt = step;
      final Libre2Gen1ReadTransaction transaction = fresh();
      fail(Libre2Gen1ReadTransaction.Failure.transportFailed, () -> transaction.run(transport, transport));
      fail(Libre2Gen1ReadTransaction.Failure.alreadyUsed, () -> transaction.run(transport, transport));
      check(transport.requests.size() == step + 1 && transport.closes == 1, "unknown read retried");
    }
    final Fake connectFailed = new Fake();
    connectFailed.failConnect = true;
    fail(Libre2Gen1ReadTransaction.Failure.transportFailed, () -> fresh().run(connectFailed, connectFailed));
    check(connectFailed.closes == 1 && connectFailed.requests.isEmpty(), "partial connect not closed");
    for (boolean alsoFailRead : new boolean[] {false, true}) {
      final Fake transport = new Fake();
      transport.failClose = true;
      if (alsoFailRead) transport.failAt = 2;
      final Libre2Gen1ReadTransaction transaction = fresh();
      fail(Libre2Gen1ReadTransaction.Failure.closeUnconfirmed, () -> transaction.run(transport, transport));
      fail(Libre2Gen1ReadTransaction.Failure.alreadyUsed, () -> transaction.run(transport, transport));
      check(transport.closes == 1, "uncertain close retried");
      assertWiped(transport);
    }
  }

  private static void validatesInputsAndCapacity() throws Exception {
    for (int length : new int[] {0, 7, 9}) {
      try { new Libre2Gen1ReadTransaction(new byte[length], null); throw new AssertionError("invalid UID accepted"); }
      catch (IllegalArgumentException expected) { }
    }
    try { new Libre2Gen1ReadTransaction(UID, new byte[5]); throw new AssertionError("invalid patch accepted"); }
    catch (IllegalArgumentException expected) { }
    final Fake transport = new Fake();
    transport.capacity = 24;
    fail(Libre2Gen1ReadTransaction.Failure.transportUnavailable, () -> fresh().run(transport, transport));
    check(transport.connects == 0 && transport.requests.isEmpty(), "insufficient capacity touched sensor");
    fail(Libre2Gen1ReadTransaction.Failure.transportUnavailable, () -> fresh().run(null, transport));
    fail(Libre2Gen1ReadTransaction.Failure.transportUnavailable, () -> fresh().run(transport, null));
  }

  private static final class Fake implements Libre2Gen1ReadTransaction.Transport, Libre2Gen1ReadTransaction.Guard {
    byte[] target = UID.clone();
    byte[] patch = PATCH.clone();
    byte[] fram = ENCRYPTED.clone();
    final List<byte[]> requests = new ArrayList<>();
    final List<byte[]> responses = new ArrayList<>();
    final List<byte[]> requestReferences = new ArrayList<>();
    int connects, closes, guardChecks;
    int capacity = 25, invalidAt = -1, invalidMode, changeTargetAt = -1, failAt = -1, rejectGuardAt = -1;
    boolean failConnect, failClose;

    @Override public byte[] uid() { return target.clone(); }
    @Override public int maxTransceiveLength() { return capacity; }
    @Override public void connect() throws Exception {
      connects++;
      if (failConnect) throw new IOException("synthetic private connect detail");
    }
    @Override public byte[] transceive(byte[] request) throws Exception {
      final int step = requests.size();
      requests.add(request.clone());
      requestReferences.add(request);
      if (step == failAt) throw new IOException("synthetic private read detail");
      byte[] response;
      if (step == 0) {
        response = new byte[7];
        System.arraycopy(patch, 0, response, 1, 6);
      } else {
        final LibreGen1NfcFrames.Frame frame = LibreGen1NfcFrames.frames().get(step - 1);
        response = new byte[1 + frame.blockCount() * 8];
        System.arraycopy(fram, frame.startBlock() * 8, response, 1, response.length - 1);
      }
      if (step == invalidAt) {
        if (invalidMode == 1) response = null;
        if (invalidMode == 2) response = Arrays.copyOf(response, response.length - 1);
        if (invalidMode == 3) response = Arrays.copyOf(response, response.length + 1);
        if (invalidMode == 4) response[0] = 1;
      }
      if (step == changeTargetAt) target[0] ^= 1;
      if (response != null) responses.add(response);
      return response;
    }
    @Override public void close() throws Exception {
      closes++;
      if (failClose) throw new IOException("synthetic private close detail");
    }
    @Override public void requireCurrent() throws Exception {
      guardChecks++;
      if (guardChecks == rejectGuardAt) throw new IOException("synthetic private guard detail");
    }
  }

  private interface Action { void run() throws Exception; }
  private static void fail(Libre2Gen1ReadTransaction.Failure expected, Action action) throws Exception {
    try { action.run(); throw new AssertionError("expected " + expected); }
    catch (Libre2Gen1ReadTransaction.ReadException failure) {
      check(failure.failure == expected, "wrong closed failure: " + failure.failure);
      check(failure.getCause() == null && !failure.toString().contains("private"), "raw native error leaked");
    }
  }
  private static Libre2Gen1ReadTransaction fresh() { return new Libre2Gen1ReadTransaction(UID, null); }
  private static void assertWiped(Fake transport) {
    for (byte[] response : transport.responses) check(allZero(response), "response retained");
    for (byte[] request : transport.requestReferences) check(allZero(request), "request retained");
  }
  private static boolean allZero(byte[] bytes) {
    for (byte b : bytes) if (b != 0) return false;
    return true;
  }
  private static void check(boolean condition, String reason) { if (!condition) throw new AssertionError(reason); }
  private static byte[] hex(String value) {
    final byte[] bytes = new byte[value.length() / 2];
    for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
    return bytes;
  }
  private static byte[] encryptedForLifecycle(int lifecycle) {
    final byte[] original = clearFram(3), wanted = clearFram(lifecycle), result = ENCRYPTED.clone();
    for (int i = 0; i < result.length; i++) result[i] ^= original[i] ^ wanted[i];
    return result;
  }
  private static byte[] clearFram(int lifecycle) {
    final byte[] value = new byte[344];
    for (int i = 0; i < value.length; i++) value[i] = (byte) (i * 73 + 19);
    value[4] = (byte) lifecycle;
    for (int[] region : new int[][] {{0, 24}, {24, 320}, {320, 344}}) {
      int crc = 0xffff;
      for (int i = region[0] + 2; i < region[1]; i++) {
        crc ^= value[i] & 255;
        for (int bit = 0; bit < 8; bit++) crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0x8408 : crc >>> 1;
      }
      int reversed = 0;
      for (int bit = 0; bit < 16; bit++) { reversed = reversed << 1 | crc & 1; crc >>>= 1; }
      value[region[0]] = (byte) reversed;
      value[region[0] + 1] = (byte) (reversed >>> 8);
    }
    return value;
  }
}
