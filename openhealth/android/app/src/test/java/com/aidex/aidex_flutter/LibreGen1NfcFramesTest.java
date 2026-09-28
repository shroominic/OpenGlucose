package com.aidex.aidex_flutter;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Standalone JVM contract checks. Run with {@code javac} and {@code java}. */
public final class LibreGen1NfcFramesTest {
  private LibreGen1NfcFramesTest() {}

  public static void main(String[] arguments) {
    verifiesExactCoverageAndFrames();
    verifiesResponseValidationAndAssembly();
    rejectsStatusAndLengthFailures();
  }

  private static void verifiesExactCoverageAndFrames() {
    final List<LibreGen1NfcFrames.Frame> frames = LibreGen1NfcFrames.frames();
    check(frames.size() == 15, "expected 15 frames");
    int expectedStart = 0;
    for (int index = 0; index < frames.size(); index += 1) {
      final LibreGen1NfcFrames.Frame frame = frames.get(index);
      final int expectedCount = index == 14 ? 1 : 3;
      check(frame.startBlock() == expectedStart, "gap or overlap in block coverage");
      check(frame.blockCount() == expectedCount, "unexpected block count");
      check(
          Arrays.equals(
              frame.request(),
              new byte[] {
                (byte) 0x02,
                (byte) 0x23,
                (byte) expectedStart,
                (byte) (expectedCount - 1),
              }),
          "unexpected read-multiple frame");
      expectedStart += expectedCount;
    }
    check(expectedStart == 43, "coverage must end after block 42");
  }

  private static void verifiesResponseValidationAndAssembly() {
    final List<byte[]> payloads = new ArrayList<>();
    int nextValue = 0;
    for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
      final byte[] response = new byte[1 + (frame.blockCount() * 8)];
      response[0] = 0;
      for (int index = 1; index < response.length; index += 1) {
        response[index] = (byte) nextValue;
        nextValue += 1;
      }
      payloads.add(frame.payloadFromResponse(response));
    }
    final byte[] fram = LibreGen1NfcFrames.concatenatePayloads(payloads);
    check(fram.length == 344, "FRAM must be exactly 344 bytes");
    for (int index = 0; index < fram.length; index += 1) {
      check(fram[index] == (byte) index, "FRAM concatenation changed ordering");
    }
  }

  private static void rejectsStatusAndLengthFailures() {
    for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
      final int exactLength = 1 + (frame.blockCount() * 8);
      expectFailure(
          () -> frame.payloadFromResponse(new byte[exactLength - 1]));
      expectFailure(
          () -> frame.payloadFromResponse(new byte[exactLength + 1]));
      final byte[] errorResponse = new byte[exactLength];
      errorResponse[0] = 1;
      expectFailure(() -> frame.payloadFromResponse(errorResponse));
    }
    expectFailure(() -> LibreGen1NfcFrames.concatenatePayloads(new ArrayList<>()));
  }

  private static void expectFailure(Runnable action) {
    try {
      action.run();
      throw new AssertionError("expected failure");
    } catch (IllegalArgumentException expected) {
      // Expected fail-closed result.
    }
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
