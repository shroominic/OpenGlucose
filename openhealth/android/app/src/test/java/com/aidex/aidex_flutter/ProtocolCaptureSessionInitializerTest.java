package com.aidex.aidex_flutter;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Standalone checks for private recorder initialization and optional NFC. */
public final class ProtocolCaptureSessionInitializerTest {
  private ProtocolCaptureSessionInitializerTest() {}

  public static void main(String[] arguments) throws Exception {
    recorderStartsWithoutNfc("disabled", true, true, false);
    recorderStartsWithoutNfc("absent", false, true, false);
    recorderStartsWithoutNfc("permission missing", true, false, true);
    readyNfcRetainsReaderUpdate();
    storageFailureRollsBackBeforeCaptureIsRequested();
    statusFailureRollsBackAndPreservesOriginalError();
    rollbackFailureDoesNotHideInitializationFailure();
    System.out.println("Private capture session initialization checks passed.");
  }

  private static void recorderStartsWithoutNfc(
      String scenario, boolean adapterPresent, boolean permission, boolean enabled)
      throws Exception {
    final Capture capture = new Capture(adapterPresent, permission, enabled);
    capture.initialize();
    check(capture.ready, scenario + ": private recorder must initialize");
    check(capture.readerStarts == 0, scenario + ": reader must remain off");
    check(
        capture.events.equals(Arrays.asList("prepare", "request", "reader", "status")),
        scenario + ": storage and capture request must precede status");
  }

  private static void readyNfcRetainsReaderUpdate() throws Exception {
    final Capture capture = new Capture(true, true, true);
    capture.initialize();
    check(capture.ready, "available NFC must not prevent recorder readiness");
    check(capture.readerStarts == 1, "ready reader update must still run once");
  }

  private static void storageFailureRollsBackBeforeCaptureIsRequested() {
    final Capture capture = new Capture(false, false, false);
    final IOException failure = new IOException("private storage unavailable");
    capture.storageFailure = failure;
    check(failureFrom(capture) == failure, "storage failure must retain its identity");
    check(!capture.ready, "failed storage must not establish a ready recorder");
    check(!capture.requested, "failed storage must not leave capture requested");
    check(capture.readerStarts == 0, "failed storage must not enable NFC");
    check(
        capture.events.equals(Arrays.asList("prepare", "rollback")),
        "failed storage must prevent request, reader and status publication");
  }

  private static void statusFailureRollsBackAndPreservesOriginalError() {
    final Capture capture = new Capture(true, true, true);
    final IllegalStateException failure = new IllegalStateException("status unavailable");
    capture.statusFailure = failure;
    check(failureFrom(capture) == failure, "status failure must retain its identity");
    check(!capture.ready && !capture.requested, "status failure must roll back readiness");
    check(!capture.readerActive, "status failure must stop an enabled reader");
    check(
        capture.events.equals(
            Arrays.asList("prepare", "request", "reader", "status", "rollback")),
        "status failure must trigger rollback after reader update");
  }

  private static void rollbackFailureDoesNotHideInitializationFailure() {
    final Capture capture = new Capture(true, true, true);
    final IOException failure = new IOException("private storage unavailable");
    final IllegalStateException cleanupFailure = new IllegalStateException("cleanup unavailable");
    capture.storageFailure = failure;
    capture.cleanupFailure = cleanupFailure;
    check(failureFrom(capture) == failure, "cleanup must not replace the primary failure");
    check(
        failure.getSuppressed().length == 1 && failure.getSuppressed()[0] == cleanupFailure,
        "cleanup failure must remain attached to the primary failure");
  }

  private static Throwable failureFrom(Capture capture) {
    try {
      capture.initialize();
    } catch (IOException | RuntimeException error) {
      return error;
    }
    throw new AssertionError("initialization unexpectedly succeeded");
  }

  private static void check(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }

  private static final class Capture {
    final boolean adapterPresent;
    final boolean permission;
    final boolean enabled;
    final List<String> events = new ArrayList<>();
    IOException storageFailure;
    RuntimeException statusFailure;
    RuntimeException cleanupFailure;
    boolean prepared;
    boolean requested;
    boolean ready;
    boolean readerActive;
    int readerStarts;

    Capture(boolean adapterPresent, boolean permission, boolean enabled) {
      this.adapterPresent = adapterPresent;
      this.permission = permission;
      this.enabled = enabled;
    }

    void initialize() throws IOException {
      ProtocolCaptureSessionInitializer.initialize(
          () -> {
            events.add("prepare");
            if (storageFailure != null) throw storageFailure;
            prepared = true;
          },
          () -> {
            events.add("request");
            check(prepared, "capture request requires private storage");
            requested = true;
          },
          () -> {
            events.add("reader");
            // The native reader callback retains this hardware gate.
            if (requested && adapterPresent && permission && enabled) {
              readerStarts += 1;
              readerActive = true;
            }
          },
          () -> {
            events.add("status");
            check(prepared && requested, "status requires the prepared private session");
            if (statusFailure != null) throw statusFailure;
            ready = true;
          },
          () -> {
            events.add("rollback");
            prepared = false;
            requested = false;
            ready = false;
            readerActive = false;
            if (cleanupFailure != null) throw cleanupFailure;
          });
    }
  }
}
