package com.aidex.aidex_flutter;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/** Standalone JVM contract checks for explicit NFC setup attempt ownership. */
public final class Libre2NfcSetupAttemptTest {
  private static final String FIRST_TARGET =
      "1111111111111111111111111111111111111111111111111111111111111111";
  private static final String SECOND_TARGET =
      "2222222222222222222222222222222222222222222222222222222222222222";
  private static final byte[] PATCH_INFO_REQUEST =
      new byte[] {(byte) 0x02, (byte) 0xa1, 0x07};

  private Libre2NfcSetupAttemptTest() {}

  public static void main(String[] arguments) throws Exception {
    firstEligibleTagClaimsExactlyOnce();
    exactSixteenSendAutomatonRejectsEveryMutationAndExtra();
    terminalLossAtEverySendPreventsRetry();
    terminalizationOwnsReservationExactlyOnce();
    preReservationCancellationCannotConsumeReplacementReservation();
    concurrentTerminalizersHaveOneWinner();
    captureProcessGenerationAndExpiryAreBound();
    rejectsUnsafeBindingsAndTargets();
  }

  private static void terminalizationOwnsReservationExactlyOnce() {
    final Libre2NfcSetupAttempt attempt = attempt();
    check(attempt.registerTraceReservation(), "reservation must register once");
    check(
        attempt.claim(7L, "process_session_1", 12L, 99L, FIRST_TARGET),
        "the target must claim the attempt before trace reservation");
    check(
        attempt.hasActiveTraceReservation(),
        "callback appends require the active exact reservation");
    check(
        !attempt.registerTraceReservation(),
        "the same attempt must not own two reservations");
    check(attempt.claimTerminalization(), "first terminalizer must win");
    check(
        !attempt.hasActiveTraceReservation(),
        "a losing callback must not append after terminalization starts");
    check(
        !attempt.claimTerminalization(),
        "a callback and cancellation must not both terminalize");
    check(
        attempt.hasTraceReservationForTerminalization(),
        "the winning terminalizer must observe its exact reservation");
    check(
        attempt.takeTraceReservationForTerminalization(),
        "terminal audit may release the exact reservation once");
    check(
        !attempt.takeTraceReservationForTerminalization(),
        "terminal cleanup must not release a reservation twice");
    check(
        !attempt.consumePatchInfoTransceiveOnce(PATCH_INFO_REQUEST),
        "a terminalized attempt must never authorize another RF send");
  }

  private static void preReservationCancellationCannotConsumeReplacementReservation() {
    final Libre2NfcSetupAttempt cancelled = attempt();
    check(
        cancelled.claimTerminalization(),
        "a listening attempt can be cancelled before tag claim or reservation");
    check(
        !cancelled.takeTraceReservationForTerminalization(),
        "pre-reservation cancellation must not release global trace capacity");

    final Libre2NfcSetupAttempt replacement =
        new Libre2NfcSetupAttempt(
            "attempt_replace_1", 7L, "process_session_1", 12L, 1_000L);
    check(
        replacement.registerTraceReservation(),
        "the replacement must reserve before target claim");
    check(
        replacement.claim(
            7L, "process_session_1", 12L, 99L, SECOND_TARGET),
        "a separate replacement object must keep separate ownership");
    check(
        !cancelled.takeTraceReservationForTerminalization(),
        "a stale cancellation must not consume a replacement reservation");
    check(replacement.claimTerminalization(), "replacement terminalizer must win");
    check(
        replacement.takeTraceReservationForTerminalization(),
        "replacement terminalizer must consume only its own reservation");
  }

  private static void concurrentTerminalizersHaveOneWinner() throws Exception {
    final Libre2NfcSetupAttempt attempt = attempt();
    final CountDownLatch ready = new CountDownLatch(2);
    final CountDownLatch start = new CountDownLatch(1);
    final AtomicInteger winners = new AtomicInteger();
    final Runnable terminalizer =
        () -> {
          ready.countDown();
          try {
            start.await();
          } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError(error);
          }
          if (attempt.claimTerminalization()) {
            winners.incrementAndGet();
          }
        };
    final Thread first = new Thread(terminalizer, "explicit-terminalizer-1");
    final Thread second = new Thread(terminalizer, "explicit-terminalizer-2");
    first.start();
    second.start();
    ready.await();
    start.countDown();
    first.join();
    second.join();
    check(winners.get() == 1, "concurrent terminalizers must have one owner");
  }

  private static void exactSixteenSendAutomatonRejectsEveryMutationAndExtra() {
    final Libre2NfcSetupAttempt attempt = attempt();
    check(
        !attempt.consumePatchInfoTransceiveOnce(PATCH_INFO_REQUEST),
        "an unclaimed attempt must not authorize a send");
    check(attempt.registerTraceReservation(), "trace must reserve before claim");
    check(
        attempt.claim(7L, "process_session_1", 12L, 99L, FIRST_TARGET),
        "the target must claim the attempt before a send");
    check(attempt.bindRfOperationOnce(), "the attempt must bind RF once");
    check(attempt.markConnectedOnce(), "the transport must connect once");
    check(!attempt.markConnectedOnce(), "a second connect must be rejected");
    check(
        !attempt.consumePatchInfoTransceiveOnce(
            new byte[] {(byte) 0x02, (byte) 0xa1, 0x06}),
        "a mutated patch-info request must be rejected");
    check(
        attempt.consumePatchInfoTransceiveOnce(PATCH_INFO_REQUEST),
        "the claimed attempt must authorize its first patch-info send");
    check(
        !attempt.consumePatchInfoTransceiveOnce(PATCH_INFO_REQUEST),
        "the same attempt must reject a second patch-info send");
    check(
        !attempt.consumeFramTransceive(
            0, LibreGen1NfcFrames.frames().get(0).request()),
        "FRAM must stay blocked until patch info is accepted");
    check(
        attempt.acceptKnownGen1Libre2PatchInfo(),
        "a validated Gen1 Libre 2 response must unlock fixed FRAM reads");
    check(
        !attempt.acceptKnownGen1Libre2PatchInfo(),
        "patch acceptance must be one-shot");
    for (int index = 0; index < LibreGen1NfcFrames.REQUEST_COUNT; index += 1) {
      final byte[] exact = LibreGen1NfcFrames.frames().get(index).request();
      final byte[] mutated = exact.clone();
      mutated[mutated.length - 1] ^= 1;
      check(
          !attempt.consumeFramTransceive(index + 1, exact),
          "an out-of-order frame must be rejected");
      check(
          !attempt.consumeFramTransceive(index, mutated),
          "a mutated frame must be rejected");
      check(
          attempt.consumeFramTransceive(index, exact),
          "the exact next frame must be consumed");
      check(
          !attempt.consumeFramTransceive(index, exact),
          "a consumed frame must never be retried");
    }
    check(attempt.completeFramSequence(), "all 15 frames must complete once");
    check(!attempt.completeFramSequence(), "FRAM completion must be one-shot");
    check(
        attempt.recordValidatedLifecycleOnce(),
        "CRC-validated lifecycle must complete once");
    check(
        !attempt.recordValidatedLifecycleOnce(),
        "lifecycle completion must reject every extra transition");
    check(
        attempt.isBindingCurrent(7L, "process_session_1", 12L, 100L),
        "consuming the send must not erase lifecycle authorization");
  }

  private static void terminalLossAtEverySendPreventsRetry() {
    for (int terminalFrame = -1;
        terminalFrame < LibreGen1NfcFrames.REQUEST_COUNT;
        terminalFrame += 1) {
      final Libre2NfcSetupAttempt attempt = claimedConnectedAttempt();
      check(
          attempt.consumePatchInfoTransceiveOnce(PATCH_INFO_REQUEST),
          "patch slot must be consumed before simulated I/O");
      if (terminalFrame >= 0) {
        check(
            attempt.acceptKnownGen1Libre2PatchInfo(),
            "patch response must be accepted before FRAM");
        for (int index = 0; index <= terminalFrame; index += 1) {
          check(
              attempt.consumeFramTransceive(
                  index, LibreGen1NfcFrames.frames().get(index).request()),
              "each frame slot must be consumed before simulated I/O");
        }
      }
      check(attempt.claimTerminalization(), "tag loss must terminalize once");
      check(
          !attempt.consumePatchInfoTransceiveOnce(PATCH_INFO_REQUEST),
          "tag loss after patch must prevent patch retry");
      final int deniedIndex = terminalFrame < 0 ? 0 : terminalFrame;
      check(
          !attempt.consumeFramTransceive(
              deniedIndex,
              LibreGen1NfcFrames.frames().get(deniedIndex).request()),
          "tag loss at each frame must prevent every retry");
    }
  }

  private static void firstEligibleTagClaimsExactlyOnce() {
    final Libre2NfcSetupAttempt attempt = attempt();
    check(attempt.registerTraceReservation(), "trace must reserve before claim");
    check(
        attempt.claim(7L, "process_session_1", 12L, 99L, FIRST_TARGET),
        "first eligible tag must claim the attempt");
    check(attempt.isClaimed(), "claim state must be observable without its UID");
    check(attempt.isClaimedBy(FIRST_TARGET), "claim must bind the target hash");
    check(
        attempt.isClaimedCurrent(
            7L, "process_session_1", 12L, 100L, FIRST_TARGET),
        "the claimed target must retain all lifecycle bindings");
    check(
        !attempt.claim(7L, "process_session_1", 12L, 100L, SECOND_TARGET),
        "a claimed attempt must not accept a second tag");
    check(
        !attempt.isCurrent(7L, "process_session_1", 12L, 100L),
        "a claimed attempt must not remain available");
  }

  private static void captureProcessGenerationAndExpiryAreBound() {
    final Libre2NfcSetupAttempt wrongEpoch = attempt();
    check(wrongEpoch.registerTraceReservation(), "precondition");
    check(
        !wrongEpoch.claim(8L, "process_session_1", 12L, 99L, FIRST_TARGET),
        "capture epoch changes must invalidate the attempt");
    final Libre2NfcSetupAttempt wrongProcess = attempt();
    check(wrongProcess.registerTraceReservation(), "precondition");
    check(
        !wrongProcess.claim(7L, "process_session_2", 12L, 99L, FIRST_TARGET),
        "Dart process changes must invalidate the attempt");
    final Libre2NfcSetupAttempt wrongGeneration = attempt();
    check(wrongGeneration.registerTraceReservation(), "precondition");
    check(
        !wrongGeneration.claim(7L, "process_session_1", 13L, 99L, FIRST_TARGET),
        "RF generation changes must invalidate the attempt");
    final Libre2NfcSetupAttempt expired = attempt();
    check(expired.registerTraceReservation(), "precondition");
    check(
        !expired.claim(7L, "process_session_1", 12L, 1_000L, FIRST_TARGET),
        "the monotonic deadline must be exclusive");
  }

  private static void rejectsUnsafeBindingsAndTargets() {
    expectFailure(
        () -> new Libre2NfcSetupAttempt("short", 7L, "process_session_1", 12L, 1_000L));
    expectFailure(
        () -> new Libre2NfcSetupAttempt("attempt_123", 0L, "process_session_1", 12L, 1_000L));
    check(
        !reservedAttempt().claim(
            7L, "process_session_1", 12L, 99L, "raw-target"),
        "a raw or malformed target identifier must not be accepted");
  }

  private static Libre2NfcSetupAttempt reservedAttempt() {
    final Libre2NfcSetupAttempt attempt = attempt();
    check(attempt.registerTraceReservation(), "test reservation precondition");
    return attempt;
  }

  private static Libre2NfcSetupAttempt claimedConnectedAttempt() {
    final Libre2NfcSetupAttempt attempt = reservedAttempt();
    check(
        attempt.claim(7L, "process_session_1", 12L, 99L, FIRST_TARGET),
        "test target claim precondition");
    check(attempt.bindRfOperationOnce(), "test RF bind precondition");
    check(attempt.markConnectedOnce(), "test connection precondition");
    return attempt;
  }

  private static Libre2NfcSetupAttempt attempt() {
    return new Libre2NfcSetupAttempt(
        "attempt_123", 7L, "process_session_1", 12L, 1_000L);
  }

  private static void expectFailure(Runnable action) {
    try {
      action.run();
      throw new AssertionError("expected fail-closed rejection");
    } catch (IllegalArgumentException expected) {
      // Expected.
    }
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
