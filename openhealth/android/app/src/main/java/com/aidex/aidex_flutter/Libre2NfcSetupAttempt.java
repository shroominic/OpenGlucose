package com.aidex.aidex_flutter;

import java.util.Arrays;

/**
 * One explicit, user-started Libre 2 NFC setup attempt.
 *
 * <p>The attempt is separate from Flutter event-listener ownership. It is
 * bound to one native capture epoch, one Dart process session, and one RF
 * authorization generation. The first eligible tag atomically consumes the
 * attempt and binds it to that tag's redacted identity.
 */
final class Libre2NfcSetupAttempt {
  private final String scanAttemptId;
  private final long captureEpoch;
  private final String processSessionId;
  private final long rfAuthorizationGeneration;
  private final long expiresAtElapsedRealtimeNanos;

  private String claimedTargetUidSha256;
  private ProtocolStage protocolStage = ProtocolStage.LISTENING;
  private int nextFramFrameIndex;
  private boolean traceReservationActive;
  private boolean terminalizationClaimed;

  private enum ProtocolStage {
    LISTENING,
    TRACE_RESERVED,
    CLAIMED,
    RF_BOUND,
    CONNECTED,
    PATCH_INFO_SENT,
    PATCH_INFO_ACCEPTED,
    FRAM_READING,
    FRAM_COMPLETE,
    LIFECYCLE_VALIDATED,
  }

  Libre2NfcSetupAttempt(
      String scanAttemptId,
      long captureEpoch,
      String processSessionId,
      long rfAuthorizationGeneration,
      long expiresAtElapsedRealtimeNanos) {
    if (scanAttemptId == null
        || !scanAttemptId.matches("^[A-Za-z0-9_-]{8,120}$")
        || processSessionId == null
        || !processSessionId.matches("^[A-Za-z0-9_-]{8,120}$")
        || captureEpoch < 1L
        || rfAuthorizationGeneration < 0L
        || expiresAtElapsedRealtimeNanos < 1L) {
      throw new IllegalArgumentException("Invalid NFC setup attempt binding.");
    }
    this.scanAttemptId = scanAttemptId;
    this.captureEpoch = captureEpoch;
    this.processSessionId = processSessionId;
    this.rfAuthorizationGeneration = rfAuthorizationGeneration;
    this.expiresAtElapsedRealtimeNanos = expiresAtElapsedRealtimeNanos;
  }

  String scanAttemptId() {
    return scanAttemptId;
  }

  long captureEpoch() {
    return captureEpoch;
  }

  String processSessionId() {
    return processSessionId;
  }

  long rfAuthorizationGeneration() {
    return rfAuthorizationGeneration;
  }

  long expiresAtElapsedRealtimeNanos() {
    return expiresAtElapsedRealtimeNanos;
  }

  synchronized boolean isCurrent(
      long expectedCaptureEpoch,
      String expectedProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos) {
    return claimedTargetUidSha256 == null
        && isBindingCurrent(
            expectedCaptureEpoch,
            expectedProcessSessionId,
            expectedRfAuthorizationGeneration,
            nowElapsedRealtimeNanos);
  }

  synchronized boolean isBindingCurrent(
      long expectedCaptureEpoch,
      String expectedProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos) {
    return captureEpoch == expectedCaptureEpoch
        && processSessionId.equals(expectedProcessSessionId)
        && rfAuthorizationGeneration == expectedRfAuthorizationGeneration
        && !terminalizationClaimed
        && nowElapsedRealtimeNanos >= 0L
        && nowElapsedRealtimeNanos < expiresAtElapsedRealtimeNanos;
  }

  synchronized boolean claim(
      long expectedCaptureEpoch,
      String expectedProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos,
      String targetUidSha256) {
    if (targetUidSha256 == null
        || !targetUidSha256.matches("^[0-9a-f]{64}$")
        || protocolStage != ProtocolStage.TRACE_RESERVED
        || !isCurrent(
            expectedCaptureEpoch,
            expectedProcessSessionId,
            expectedRfAuthorizationGeneration,
            nowElapsedRealtimeNanos)) {
      return false;
    }
    claimedTargetUidSha256 = targetUidSha256;
    protocolStage = ProtocolStage.CLAIMED;
    return true;
  }

  synchronized boolean isClaimedBy(String targetUidSha256) {
    return claimedTargetUidSha256 != null
        && claimedTargetUidSha256.equals(targetUidSha256);
  }

  synchronized boolean isClaimed() {
    return claimedTargetUidSha256 != null;
  }

  /** Registers the exact trace reservation before the target claim is consumed. */
  synchronized boolean registerTraceReservation() {
    if (claimedTargetUidSha256 != null
        || traceReservationActive
        || terminalizationClaimed
        || protocolStage != ProtocolStage.LISTENING) {
      return false;
    }
    traceReservationActive = true;
    protocolStage = ProtocolStage.TRACE_RESERVED;
    return true;
  }

  synchronized boolean bindRfOperationOnce() {
    if (protocolStage != ProtocolStage.CLAIMED
        || terminalizationClaimed) {
      return false;
    }
    protocolStage = ProtocolStage.RF_BOUND;
    return true;
  }

  synchronized boolean markConnectedOnce() {
    if (protocolStage != ProtocolStage.RF_BOUND || terminalizationClaimed) {
      return false;
    }
    protocolStage = ProtocolStage.CONNECTED;
    return true;
  }

  synchronized boolean consumePatchInfoTransceiveOnce(byte[] request) {
    if (protocolStage != ProtocolStage.CONNECTED
        || terminalizationClaimed
        || !Arrays.equals(request, new byte[] {(byte) 0x02, (byte) 0xa1, 0x07})) {
      return false;
    }
    protocolStage = ProtocolStage.PATCH_INFO_SENT;
    return true;
  }

  synchronized boolean acceptKnownGen1Libre2PatchInfo() {
    if (protocolStage != ProtocolStage.PATCH_INFO_SENT
        || terminalizationClaimed) {
      return false;
    }
    protocolStage = ProtocolStage.PATCH_INFO_ACCEPTED;
    return true;
  }

  synchronized boolean consumeFramTransceive(int frameIndex, byte[] request) {
    if ((protocolStage != ProtocolStage.PATCH_INFO_ACCEPTED
            && protocolStage != ProtocolStage.FRAM_READING)
        || terminalizationClaimed
        || frameIndex != nextFramFrameIndex
        || frameIndex < 0
        || frameIndex >= LibreGen1NfcFrames.REQUEST_COUNT
        || !Arrays.equals(
            request, LibreGen1NfcFrames.frames().get(frameIndex).request())) {
      return false;
    }
    nextFramFrameIndex += 1;
    protocolStage = ProtocolStage.FRAM_READING;
    return true;
  }

  synchronized boolean completeFramSequence() {
    if (protocolStage != ProtocolStage.FRAM_READING
        || nextFramFrameIndex != LibreGen1NfcFrames.REQUEST_COUNT
        || terminalizationClaimed) {
      return false;
    }
    protocolStage = ProtocolStage.FRAM_COMPLETE;
    return true;
  }

  synchronized boolean recordValidatedLifecycleOnce() {
    if (protocolStage != ProtocolStage.FRAM_COMPLETE
        || terminalizationClaimed) {
      return false;
    }
    protocolStage = ProtocolStage.LIFECYCLE_VALIDATED;
    return true;
  }

  synchronized boolean hasActiveTraceReservation() {
    return traceReservationActive && !terminalizationClaimed;
  }

  synchronized boolean claimTerminalization() {
    if (terminalizationClaimed) {
      return false;
    }
    terminalizationClaimed = true;
    return true;
  }

  synchronized boolean hasTraceReservationForTerminalization() {
    return terminalizationClaimed && traceReservationActive;
  }

  synchronized boolean takeTraceReservationForTerminalization() {
    if (!terminalizationClaimed || !traceReservationActive) {
      return false;
    }
    traceReservationActive = false;
    return true;
  }

  synchronized boolean isTerminalized() {
    return terminalizationClaimed;
  }

  synchronized boolean isClaimedCurrent(
      long expectedCaptureEpoch,
      String expectedProcessSessionId,
      long expectedRfAuthorizationGeneration,
      long nowElapsedRealtimeNanos,
      String targetUidSha256) {
    return isClaimedBy(targetUidSha256)
        && isBindingCurrent(
            expectedCaptureEpoch,
            expectedProcessSessionId,
            expectedRfAuthorizationGeneration,
            nowElapsedRealtimeNanos);
  }
}
