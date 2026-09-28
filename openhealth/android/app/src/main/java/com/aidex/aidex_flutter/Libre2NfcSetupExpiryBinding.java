package com.aidex.aidex_flutter;

/** Exact-attempt ownership for one pending explicit NFC setup expiry. */
final class Libre2NfcSetupExpiryBinding {
  private Libre2NfcSetupAttempt attempt;
  private Runnable expiry;

  synchronized boolean isEmpty() {
    return attempt == null && expiry == null;
  }

  synchronized boolean bind(
      Libre2NfcSetupAttempt expectedAttempt, Runnable expectedExpiry) {
    if (expectedAttempt == null
        || expectedExpiry == null
        || !isEmpty()) {
      return false;
    }
    attempt = expectedAttempt;
    expiry = expectedExpiry;
    return true;
  }

  synchronized Runnable take(Libre2NfcSetupAttempt expectedAttempt) {
    if (expectedAttempt == null || attempt != expectedAttempt) {
      return null;
    }
    final Runnable result = expiry;
    attempt = null;
    expiry = null;
    return result;
  }
}
