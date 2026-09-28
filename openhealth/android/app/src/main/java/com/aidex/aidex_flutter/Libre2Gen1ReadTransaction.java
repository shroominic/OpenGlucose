package com.aidex.aidex_flutter;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * One injected, read-only Gen1 transaction. This class has no Android, file,
 * activation, streaming-enable, retry, or glucose-output behavior.
 *
 * <p>The future platform owner must validate the ISO15693 manufacturer, own
 * the exact NFC lease, and enforce foreground/generation/deadline eligibility
 * in Guard. A successful result is read evidence, never write authorization.
 * Existing debug capture is deliberately not wired to this extraction yet.
 */
final class Libre2Gen1ReadTransaction {
  /**
   * The Android adapter must serialize actual connect/transceive calls with
   * its native ownership lock and recheck eligibility inside that lock. The
   * separate pre/post Guard calls here do not form an atomic RF mutex.
   */
  interface Transport {
    /** Returns the UID in the same byte order as the expected native UID. */
    byte[] uid() throws Exception;
    int maxTransceiveLength() throws Exception;
    void connect() throws Exception;
    /** Transfers ownership of the response array to this transaction. */
    byte[] transceive(byte[] request) throws Exception;
    void close() throws Exception;
  }

  interface Guard {
    /** Throws if the exact owner, foreground state, generation, or lease expired. */
    void requireCurrent() throws Exception;
  }

  enum Failure {
    alreadyUsed, authorizationChanged, targetChanged, transportUnavailable,
    transportFailed, unsupportedPatch, invalidResponse, invalidFram, closeUnconfirmed
  }

  static final class ReadException extends Exception {
    final Failure failure;
    ReadException(Failure failure) {
      super("Libre read failed: " + failure.name());
      this.failure = failure;
    }
  }

  /** Restricted native evidence. Do not forward its byte getters to UI or logs. */
  static final class VerifiedRead implements AutoCloseable {
    private final byte[] uid;
    private final byte[] patch;
    private final byte[] encryptedFram;
    private final String lifecycle;
    private boolean closed;

    private VerifiedRead(byte[] uid, byte[] patch, byte[] fram, int lifecycle) {
      this.uid = uid.clone();
      this.patch = patch.clone();
      this.encryptedFram = fram.clone();
      this.lifecycle = LibreGen1Activation.closedLifecycleName(lifecycle);
    }

    synchronized byte[] uid() { requireOpen(); return uid.clone(); }
    synchronized byte[] initialPatchInfo() { requireOpen(); return patch.clone(); }
    synchronized byte[] encryptedFram() { requireOpen(); return encryptedFram.clone(); }
    synchronized String lifecycle() { requireOpen(); return lifecycle; }
    boolean authorizesStateChange() { return false; }

    private void requireOpen() {
      if (closed) throw new IllegalStateException("Libre read evidence is closed.");
    }

    @Override public synchronized void close() {
      closed = true;
      Arrays.fill(uid, (byte) 0);
      Arrays.fill(patch, (byte) 0);
      Arrays.fill(encryptedFram, (byte) 0);
    }

    @Override public String toString() { return "LibreVerifiedRead(<redacted>)"; }
  }

  private final byte[] expectedUid;
  private final byte[] expectedPatch;
  private boolean used;

  Libre2Gen1ReadTransaction(byte[] expectedUid, byte[] expectedPatch) {
    if (expectedUid == null || expectedUid.length != 8
        || (expectedPatch != null && expectedPatch.length != 6)) {
      throw new IllegalArgumentException("Invalid Libre read binding.");
    }
    this.expectedUid = expectedUid.clone();
    this.expectedPatch = expectedPatch == null ? null : expectedPatch.clone();
  }

  /**
   * Sends exactly one patch-info read and fifteen fixed FRAM reads. Failed or
   * cancelled instances cannot be rerun. Close failure overrides any apparent
   * success and must quarantine the platform owner's lease.
   */
  VerifiedRead run(Transport transport, Guard guard) throws ReadException {
    synchronized (this) {
      if (used) throw new ReadException(Failure.alreadyUsed);
      used = true;
    }
    final List<byte[]> payloads = new ArrayList<>();
    byte[] patch = null;
    byte[] fram = null;
    boolean closeRequired = false;
    try {
      if (transport == null || guard == null) throw new ReadException(Failure.transportUnavailable);
      requireCurrent(transport, guard);
      if (transport.maxTransceiveLength() < LibreGen1NfcFrames.MAX_RESPONSE_BYTES) {
        throw new ReadException(Failure.transportUnavailable);
      }
      requireCurrent(transport, guard);
      // A connect exception can mean the transport partially opened.
      closeRequired = true;
      transport.connect();
      byte[] response = exchange(transport, guard, new byte[] {0x02, (byte) 0xa1, 0x07});
      try {
        if (response == null || response.length != 7 || (response[0] & 1) != 0) {
          throw new ReadException(Failure.invalidResponse);
        }
        patch = Arrays.copyOfRange(response, 1, 7);
      } finally { wipe(response); }
      // Same closed Libre 2 Gen1 allowlist as LibreGen1Activation. Plus/Gen2
      // remain excluded even though other offline helpers can classify them.
      final int signature = (patch[0] & 255) << 16 | (patch[1] & 255) << 8 | patch[2] & 255;
      if (signature != 0x9d0830 && signature != 0xc50930 && signature != 0x7f0e30) {
        throw new ReadException(Failure.unsupportedPatch);
      }
      if (expectedPatch != null && !Arrays.equals(expectedPatch, patch)) {
        throw new ReadException(Failure.targetChanged);
      }
      for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
        response = exchange(transport, guard, frame.request());
        try {
          try { payloads.add(frame.payloadFromResponse(response)); }
          catch (IllegalArgumentException invalid) { throw new ReadException(Failure.invalidResponse); }
        } finally { wipe(response); }
      }
      fram = LibreGen1NfcFrames.concatenatePayloads(payloads);
      final int lifecycle;
      try { lifecycle = LibreGen1Activation.validatedLifecycle(expectedUid, patch, fram); }
      catch (IllegalArgumentException invalid) { throw new ReadException(Failure.invalidFram); }
      requireCurrent(transport, guard);
      // Do not retry close after an uncertain close result.
      closeRequired = false;
      close(transport);
      requireAuthorized(guard);
      return new VerifiedRead(expectedUid, patch, fram, lifecycle);
    } catch (ReadException closedFailure) {
      throw closedFailure;
    } catch (Exception failure) {
      // Native exception text can include target bytes. Never retain its cause.
      throw new ReadException(Failure.transportFailed);
    } finally {
      wipe(patch);
      wipe(fram);
      for (byte[] payload : payloads) wipe(payload);
      wipe(expectedUid);
      wipe(expectedPatch);
      if (closeRequired) close(transport);
    }
  }

  private byte[] exchange(Transport transport, Guard guard, byte[] request) throws Exception {
    byte[] response = null;
    try {
      requireCurrent(transport, guard);
      response = transport.transceive(request);
      requireCurrent(transport, guard);
      return response;
    } catch (Exception failure) {
      wipe(response);
      throw failure;
    } finally { wipe(request); }
  }

  private void requireCurrent(Transport transport, Guard guard) throws Exception {
    requireAuthorized(guard);
    if (!Arrays.equals(expectedUid, transport.uid())) throw new ReadException(Failure.targetChanged);
  }

  private static void requireAuthorized(Guard guard) throws ReadException {
    try { guard.requireCurrent(); }
    catch (Exception failure) { throw new ReadException(Failure.authorizationChanged); }
  }

  private static void close(Transport transport) throws ReadException {
    try { transport.close(); }
    catch (Exception failure) { throw new ReadException(Failure.closeUnconfirmed); }
  }

  private static void wipe(byte[] value) { if (value != null) Arrays.fill(value, (byte) 0); }
}
