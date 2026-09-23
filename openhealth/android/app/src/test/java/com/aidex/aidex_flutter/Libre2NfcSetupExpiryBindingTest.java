package com.aidex.aidex_flutter;

/** Standalone JVM checks for exact explicit-expiry ownership. */
public final class Libre2NfcSetupExpiryBindingTest {
  private Libre2NfcSetupExpiryBindingTest() {}

  public static void main(String[] arguments) {
    oldStopCannotCancelReplacementExpiry();
    oldFailureCannotCancelReplacementExpiry();
    oldNaturalCompletionCannotCancelReplacementExpiry();
  }

  private static void oldStopCannotCancelReplacementExpiry() {
    staleWinnerCannotTakeReplacement("stop");
  }

  private static void oldFailureCannotCancelReplacementExpiry() {
    staleWinnerCannotTakeReplacement("failure");
  }

  private static void oldNaturalCompletionCannotCancelReplacementExpiry() {
    staleWinnerCannotTakeReplacement("natural completion");
  }

  private static void staleWinnerCannotTakeReplacement(String lifecycle) {
    final Libre2NfcSetupExpiryBinding binding =
        new Libre2NfcSetupExpiryBinding();
    final Libre2NfcSetupAttempt oldAttempt = attempt("attempt_old_1");
    final Libre2NfcSetupAttempt replacement = attempt("attempt_new_1");
    final Runnable oldExpiry = () -> {};
    final Runnable replacementExpiry = () -> {};

    check(binding.bind(oldAttempt, oldExpiry), "old expiry must bind");
    check(binding.take(oldAttempt) == oldExpiry, "old expiry must release");
    check(
        binding.bind(replacement, replacementExpiry),
        "replacement expiry must bind");
    check(
        binding.take(oldAttempt) == null,
        "old " + lifecycle + " must not take replacement expiry");
    check(
        binding.take(replacement) == replacementExpiry,
        "replacement must retain its exact expiry");
    check(binding.isEmpty(), "exact replacement take must clear binding");
  }

  private static Libre2NfcSetupAttempt attempt(String id) {
    return new Libre2NfcSetupAttempt(
        id, 7L, "process_session_1", 12L, 1_000L);
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
