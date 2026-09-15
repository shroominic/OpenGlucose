package com.aidex.aidex_flutter;

/**
 * Readiness policy for the two intentionally separate NFC RF lanes.
 *
 * <p>Host-authorized protocol work depends on a fresh, healthy BLE capture
 * status. An explicit Libre 2 setup attempt is an app-owned NFC interaction,
 * so it depends on the exact attempt and RF lease instead of BLE scanner
 * eligibility.
 */
final class NfcRfReadiness {
  private NfcRfReadiness() {}

  /** One callback-thread handoff. A successful read cannot precede callback cleanup. */
  static final class CallbackCompletion {
    private Runnable pending;
    private boolean finished;

    void defer(Runnable completion) {
      if (completion == null || pending != null || finished) {
        throw new IllegalStateException("NFC callback completion is unavailable.");
      }
      pending = completion;
    }

    void finish(Runnable cleanup) {
      if (finished) return;
      finished = true;
      final Runnable completion = pending;
      pending = null;
      // Keep completion suppressed if cleanup fails. Do not weaken the fresh
      // evidence query's independent callback-active and ownership checks.
      cleanup.run();
      if (completion != null) completion.run();
    }
  }

  static boolean isHostReady(
      boolean captureRequested,
      boolean resumed,
      boolean captureReady,
      boolean captureWritable,
      boolean bleCaptureRfEligible,
      long lastBleEligibleStatusElapsedRealtimeNanos,
      long nowElapsedRealtimeNanos,
      long maxBleRfStatusAgeNanos) {
    return captureRequested
        && resumed
        && captureReady
        && captureWritable
        && bleCaptureRfEligible
        && lastBleEligibleStatusElapsedRealtimeNanos > 0L
        && nowElapsedRealtimeNanos >= lastBleEligibleStatusElapsedRealtimeNanos
        && nowElapsedRealtimeNanos - lastBleEligibleStatusElapsedRealtimeNanos
            <= maxBleRfStatusAgeNanos;
  }

  static boolean isExplicitUnclaimedReady(
      boolean captureRequested,
      boolean resumed,
      boolean captureReady,
      boolean captureWritable,
      long expectedCaptureEpoch,
      long currentCaptureEpoch,
      String expectedDartProcessSessionId,
      String currentDartProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos,
      Libre2NfcSetupAttempt currentAttempt,
      Libre2NfcSetupAttempt expectedAttempt,
      NfcRfTransactionLeaseBinding leaseBinding,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return isExplicitBaseReady(
            captureRequested,
            resumed,
            captureReady,
            captureWritable,
            expectedCaptureEpoch,
            currentCaptureEpoch,
            expectedDartProcessSessionId,
            currentDartProcessSessionId,
            currentAttempt,
            expectedAttempt,
            leaseBinding,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts)
        && expectedAttempt.isCurrent(
            expectedCaptureEpoch,
            expectedDartProcessSessionId,
            expectedRfAuthorizationGeneration,
            nowElapsedRealtimeNanos);
  }

  static boolean isExplicitClaimedReady(
      boolean captureRequested,
      boolean resumed,
      boolean captureReady,
      boolean captureWritable,
      long expectedCaptureEpoch,
      long currentCaptureEpoch,
      String expectedDartProcessSessionId,
      String currentDartProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos,
      String targetUidSha256,
      Libre2NfcSetupAttempt currentAttempt,
      Libre2NfcSetupAttempt expectedAttempt,
      NfcRfTransactionLeaseBinding leaseBinding,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return isExplicitBaseReady(
            captureRequested,
            resumed,
            captureReady,
            captureWritable,
            expectedCaptureEpoch,
            currentCaptureEpoch,
            expectedDartProcessSessionId,
            currentDartProcessSessionId,
            currentAttempt,
            expectedAttempt,
            leaseBinding,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts)
        && expectedAttempt.isClaimedCurrent(
            expectedCaptureEpoch,
            expectedDartProcessSessionId,
            expectedRfAuthorizationGeneration,
            nowElapsedRealtimeNanos,
            targetUidSha256);
  }

  static boolean isExplicitBindingReady(
      boolean captureRequested,
      boolean resumed,
      boolean captureReady,
      boolean captureWritable,
      long expectedCaptureEpoch,
      long currentCaptureEpoch,
      String expectedDartProcessSessionId,
      String currentDartProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos,
      Libre2NfcSetupAttempt currentAttempt,
      Libre2NfcSetupAttempt expectedAttempt,
      NfcRfTransactionLeaseBinding leaseBinding,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return isExplicitBaseReady(
            captureRequested,
            resumed,
            captureReady,
            captureWritable,
            expectedCaptureEpoch,
            currentCaptureEpoch,
            expectedDartProcessSessionId,
            currentDartProcessSessionId,
            currentAttempt,
            expectedAttempt,
            leaseBinding,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts)
        && expectedAttempt.isBindingCurrent(
            expectedCaptureEpoch,
            expectedDartProcessSessionId,
            expectedRfAuthorizationGeneration,
            nowElapsedRealtimeNanos);
  }

  private static boolean isExplicitBaseReady(
      boolean captureRequested,
      boolean resumed,
      boolean captureReady,
      boolean captureWritable,
      long expectedCaptureEpoch,
      long currentCaptureEpoch,
      String expectedDartProcessSessionId,
      String currentDartProcessSessionId,
      Libre2NfcSetupAttempt currentAttempt,
      Libre2NfcSetupAttempt expectedAttempt,
      NfcRfTransactionLeaseBinding leaseBinding,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return captureRequested
        && resumed
        && captureReady
        && captureWritable
        && expectedCaptureEpoch == currentCaptureEpoch
        && expectedDartProcessSessionId != null
        && expectedDartProcessSessionId.equals(currentDartProcessSessionId)
        && expectedAttempt != null
        && currentAttempt == expectedAttempt
        && leaseBinding != null
        && leaseBinding.isHeldByExplicitAttempt(expectedAttempt)
        && traceCapacityAvailable
        && noHostAuthorizationArtifacts;
  }
}
