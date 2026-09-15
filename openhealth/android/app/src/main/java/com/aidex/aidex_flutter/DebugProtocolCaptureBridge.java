package com.aidex.aidex_flutter;

import android.app.Activity;
import android.Manifest;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.TagLostException;
import android.nfc.tech.NfcV;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicLong;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Debug-only, app-private protocol capture support.
 *
 * <p>The class is present in all build variants so the main activity can stay
 * shared, but MainActivity registers it only when the debug manifest opt-in is
 * present.
 * The release manifest does not request NFC access. Raw identifiers and bytes
 * are restricted data and are never written to logcat.
 */
final class DebugProtocolCaptureBridge {
  static final String CHANNEL_NAME = "com.openglucose/protocol_capture";
  static final String EVENT_CHANNEL_NAME =
      "com.openglucose/protocol_capture_events";
  static final String CAPTURE_DIRECTORY = "protocol-captures";
  static final String GRANT_CONTEXT_FILE = "nfc-grant-context.json";
  static final String TARGET_CONTEXT_FILE = "nfc-target-context.json";
  static final String CAPTURE_STATUS_FILE = "capture-status.json";
  static final String TARGET_UNVERIFIED_PROBE_GRANT_FILE =
      "target-unverified-nfc-grant.json";
  static final String TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE =
      "target-unverified-gen1-fram-read-grant.json";
  static final String TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE =
      "target-unverified-gen1-activation-grant.json";
  static final String NFC_PATCH_INFO_CONTEXT_FILE =
      "nfc-patch-info-context.json";
  static final String NFC_GEN1_FRAM_CAPTURE_FILE =
      "nfc-gen1-fram-capture.json";
  static final String NFC_GEN1_ACTIVATION_JOURNAL_FILE =
      "nfc-gen1-activation-journal.json";

  private static final String TARGET_UNVERIFIED_PROBE_OPERATION =
      "target_unverified_patch_info_probe";
  private static final String TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION =
      "target_unverified_gen1_fram_read";
  private static final String TARGET_UNVERIFIED_GEN1_ACTIVATION_OPERATION =
      "target_unverified_gen1_activation";
  private static final String EXPLICIT_LIBRE2_SETUP_OPERATION =
      "explicit_libre2_lifecycle_read";
  // This prefix is target-family evidence from the audited reference only. It
  // is not cryptographic model or vendor authentication.
  private static final String EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX = "e007";
  private static final String LIBRE2_REFERENCE_SERVICE_UUID =
      "0000fde3-0000-1000-8000-00805f9b34fb";
  private static final String AIDEX_CGM_SERVICE_UUID =
      "0000181f-0000-1000-8000-00805f9b34fb";
  private static final int GRANT_SCHEMA_VERSION = 1;
  // Patch probes and activation keep their existing short authorization
  // window. The read-only Gen1 FRAM sweep gets a longer window so the user
  // can position the phone without extending any state-changing grant.
  private static final long MAX_STANDARD_GRANT_LIFETIME_MILLIS = 120_000L;
  private static final long MAX_GEN1_FRAM_READ_GRANT_LIFETIME_MILLIS =
      300_000L;
  private static final long MAX_CLOCK_SKEW_MILLIS = 5_000L;
  private static final long MAX_BLE_RF_STATUS_AGE_NANOS = 6_000_000_000L;
  private static final int MAX_GRANT_FILE_BYTES = 4_096;
  private static final long MAX_NFC_TRACE_BYTES = 16L * 1024L * 1024L;
  private static final int MAX_NFC_TRACE_FILES = 8;
  private static final long NFC_TRANSACTION_FIXED_RESERVE_BYTES = 128L * 1024L;
  // Covers the patch-info request/response, all 15 fixed read-multiple
  // request/response pairs, the assembled 344-byte FRAM record, and terminal
  // audit records. Reservation happens before the one-shot grant is consumed.
  private static final long NFC_GEN1_FRAM_TRANSACTION_RESERVE_BYTES =
      512L * 1024L;
  // Covers two fixed FRAM sweeps, two patch rechecks, the single activation
  // request/response, and durable terminal audit records.
  private static final long NFC_GEN1_ACTIVATION_TRANSACTION_RESERVE_BYTES =
      1024L * 1024L;
  private static final long NFC_STATUS_HEADROOM_BYTES = 64L * 1024L;
  private static final long PASSIVE_DETECTION_VISIBLE_MILLIS = 900L;
  private static final long EXPLICIT_NFC_SETUP_LIFETIME_NANOS =
      180_000_000_000L;

  // Observed as Abbott SAS GET_PATCH_INFO in a Libre 2-family reference.
  // Its effect is not verified on the target. Treat transmission as R3 and
  // require the separate one-shot authorization marker before sending it.
  private static final byte LIBRE_PATCH_INFO_FLAGS = (byte) 0x02;
  private static final byte LIBRE_PATCH_INFO_CODE = (byte) 0xA1;
  private static final byte LIBRE_REFERENCE_MANUFACTURER_CODE = (byte) 0x07;

  private final Activity activity;
  private final NfcAdapter nfcAdapter;
  private final AtomicLong sequence = new AtomicLong();
  private final Object fileLock = new Object();
  private final Object rfAuthorizationLock = new Object();
  private final Object captureEpochLock = new Object();
  private final Object uiEventLock = new Object();
  private final Object explicitNfcTerminalLock = new Object();
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  // Keep capture-health and explicit-attempt expiry on separate handlers so
  // UI delivery never cancels either fail-closed timeout.
  private final Handler rfEligibilityHandler =
      new Handler(Looper.getMainLooper());
  private final Handler explicitNfcSetupHandler =
      new Handler(Looper.getMainLooper());
  private final ExecutorService statusExecutor =
      Executors.newSingleThreadExecutor(
          runnable -> {
            final Thread thread =
                new Thread(runnable, "openglucose-capture-status");
            thread.setDaemon(true);
            return thread;
          });
  private volatile String sessionToken = newNativeSessionToken();
  private volatile String grantNonce = newGrantNonce();

  private volatile boolean captureRequested;
  private volatile boolean captureReady;
  private volatile boolean captureWritable;
  private volatile boolean resumed;
  private long rfAuthorizationGeneration;
  private NfcV inFlightNfcV;
  private Libre2NfcSetupAttempt explicitNfcSetupAttempt;
  private String inFlightExplicitNfcSetupAttemptId;
  private final NfcRfTransactionLeaseBinding rfTransactionLeaseBinding =
      new NfcRfTransactionLeaseBinding();
  private NfcRfTransactionLease activeHostRfTransactionLease;
  private boolean nfcCallbackActive;
  private boolean bleCaptureRfEligible;
  private long lastBleEligibleStatusElapsedRealtimeNanos;
  private volatile File captureDirectory;
  private volatile File traceFile;
  private long traceBytes;
  private long reservedNfcTraceBytes;
  private long installedVersionCode;
  private long installedLastUpdateTime;
  private String dartProcessSessionId;
  private String expectedDartProcessSessionId;
  private long lastDartHeartbeatMonotonicMicroseconds;
  private long lastPublishedBleSequence;
  private volatile long captureEpoch;
  private EventChannel.EventSink uiEventSink;
  private long uiListenerGeneration;
  private Runnable pendingPassiveUiReset;
  private final Libre2NfcSetupExpiryBinding explicitNfcSetupExpiryBinding =
      new Libre2NfcSetupExpiryBinding();
  private StreamingAttempt streamingAttempt;
  private NfcRfTransactionLease quarantinedStreamingLease;
  private Map<String, Object> lastStreamingStatus;

  DebugProtocolCaptureBridge(Activity activity) {
    this.activity = activity;
    this.nfcAdapter = NfcAdapter.getDefaultAdapter(activity);
  }

  void register(BinaryMessenger messenger) {
    new EventChannel(messenger, EVENT_CHANNEL_NAME)
        .setStreamHandler(
            new EventChannel.StreamHandler() {
              @Override
              public void onListen(Object arguments, EventChannel.EventSink events) {
                synchronized (uiEventLock) {
                  uiListenerGeneration += 1L;
                  uiEventSink = events;
                }
                publishReaderStatusForEpoch(captureEpoch);
              }

              @Override
              public void onCancel(Object arguments) {
                synchronized (uiEventLock) {
                  uiListenerGeneration += 1L;
                  uiEventSink = null;
                }
              }
            });
    new MethodChannel(messenger, CHANNEL_NAME)
        .setMethodCallHandler(
            (call, result) -> {
              if (handleLibreFreshHistoryEvidenceMethod(call.method, call.arguments, result)) {
                return;
              }
              if (handleLibreReceiverReuseProofMethod(call.method, call.arguments, result)) {
                return;
              }
              if (handleLibreActivationUiMethod(call.method, call.arguments, result)) {
                return;
              }
              if (handleLibreStreamingMethod(call.method, call.arguments, result)) {
                return;
              }
              if ("setBleCaptureStatus".equals(call.method)) {
                try {
                  final Object arguments = call.arguments;
                  final long statusCaptureEpoch = captureEpoch;
                  statusExecutor.execute(
                      () -> {
                        try {
                          writeBleCaptureStatus(statusCaptureEpoch, arguments);
                          postResult(() -> result.success(null));
                        } catch (IllegalArgumentException error) {
                          revokeRfEligibilityForEpoch(
                              statusCaptureEpoch, true);
                          postResult(
                              () ->
                                  result.error(
                                      "bad_args",
                                      "Invalid private BLE capture status.",
                                      null));
                        } catch (IOException error) {
                          revokeRfEligibilityForEpoch(
                              statusCaptureEpoch, true);
                          postResult(
                              () ->
                                  result.error(
                                      "restricted_storage_failed",
                                      "Could not persist private BLE capture status.",
                                      null));
                        } catch (RuntimeException error) {
                          revokeRfEligibilityForEpoch(
                              statusCaptureEpoch, true);
                          postResult(
                              () ->
                                  result.error(
                                      "capture_status_failed",
                                      "Private BLE capture status failed safely.",
                                      null));
                        }
                      });
                } catch (RejectedExecutionException error) {
                  revokeRfEligibility(true);
                  result.error(
                      "capture_closed",
                      "Private BLE capture status worker is closed.",
                      null);
                }
                return;
              }
              if ("stopProtocolCapture".equals(call.method)) {
                stopNfcCapture();
                result.success(null);
                return;
              }
              if ("startLibre2NfcSetup".equals(call.method)) {
                final String scanAttemptId;
                try {
                  scanAttemptId = explicitNfcSetupAttemptId(call.arguments);
                } catch (IllegalArgumentException error) {
                  result.error("bad_args", "Invalid NFC setup attempt.", null);
                  return;
                }
                if (nfcAdapter == null) {
                  result.error("nfc_unavailable", "This device has no NFC adapter.", null);
                  return;
                }
                if (!hasNfcPermission()) {
                  result.error("nfc_permission_missing", "NFC permission is absent.", null);
                  return;
                }
                if (!nfcAdapter.isEnabled()) {
                  result.error("nfc_disabled", "NFC is disabled.", null);
                  return;
                }
                if (!startExplicitNfcSetup(scanAttemptId)) {
                  result.error(
                      "capture_not_ready",
                      "NFC setup is not ready for a new attempt.",
                      null);
                  return;
                }
                result.success(null);
                return;
              }
              if ("stopLibre2NfcSetup".equals(call.method)) {
                final String scanAttemptId;
                try {
                  scanAttemptId = explicitNfcSetupAttemptId(call.arguments);
                } catch (IllegalArgumentException error) {
                  result.error("bad_args", "Invalid NFC setup attempt.", null);
                  return;
                }
                stopExplicitNfcSetup(scanAttemptId);
                result.success(null);
                return;
              }
              if (!"startNfcCapture".equals(call.method)) {
                result.notImplemented();
                return;
              }
              if (!(call.arguments instanceof Map<?, ?>)
                  || ((Map<?, ?>) call.arguments).size() != 1) {
                result.error("bad_args", "Expected one process session identifier.", null);
                return;
              }
              final String requestedProcessSessionId;
              try {
                requestedProcessSessionId =
                    requiredSafeToken(
                        (Map<?, ?>) call.arguments, "processSessionId");
              } catch (IllegalArgumentException error) {
                result.error("bad_args", "Invalid process session identifier.", null);
                return;
              }
              if (nfcAdapter == null) {
                result.error("nfc_unavailable", "This device has no NFC adapter.", null);
                return;
              }
              if (!hasNfcPermission()) {
                result.error("nfc_permission_missing", "NFC capture permission is absent.", null);
                return;
              }
              if (!nfcAdapter.isEnabled()) {
                result.error("nfc_disabled", "NFC is disabled.", null);
                return;
              }
              try {
                prepareCaptureDirectory(requestedProcessSessionId);
                synchronized (rfAuthorizationLock) {
                  captureRequested = true;
                  rfAuthorizationGeneration += 1L;
                }
                updateReaderMode();
                publishReaderStatusForEpoch(captureEpoch);
                result.success(null);
              } catch (IOException | RuntimeException error) {
                stopNfcCapture();
                result.error(
                    "restricted_storage_failed",
                    "Could not prepare private protocol capture storage.",
                    null);
              }
            });
  }

  void onResume() {
    synchronized (rfAuthorizationLock) {
      resumed = true;
    }
    try {
      updateReaderMode();
      publishReaderStatusForEpoch(captureEpoch);
    } catch (RuntimeException ignored) {
      stopNfcCapture();
    }
  }

  void onPause() {
    final NfcV cancelled;
    final Libre2NfcSetupAttempt cancelledAttempt;
    NfcRfTransactionLease maintenanceLease;
    final long expectedCaptureEpoch = captureEpoch;
    synchronized (rfAuthorizationLock) {
      resumed = false;
      bleCaptureRfEligible = false;
      lastBleEligibleStatusElapsedRealtimeNanos = 0L;
      rfAuthorizationGeneration += 1L;
      cancelledAttempt = explicitNfcSetupAttempt;
      if (cancelledAttempt != null) {
        maintenanceLease =
            terminalizeExplicitNfcSetupAttempt(
                cancelledAttempt,
                inFlightNfcV,
                "nfc.explicit_setup.connection.cancelled",
                "paused");
        cancelled = null;
      } else {
        cancelled = inFlightNfcV;
        inFlightNfcV = null;
        inFlightExplicitNfcSetupAttemptId = null;
        maintenanceLease =
            claimActiveRfTransactionLeaseForMaintenanceLocked(null);
      }
    }
    cancelExplicitNfcSetupExpiry(cancelledAttempt);
    closeNfcVQuietly(cancelled);
    finishRfEligibilityRevocation(
        expectedCaptureEpoch, maintenanceLease, false, true);
    publishCancelledExplicitAttempt(cancelledAttempt);
    if (captureRequested && nfcAdapter != null && hasNfcPermission()) {
      try {
        nfcAdapter.disableReaderMode(activity);
      } catch (RuntimeException ignored) {
        // State is already fail-closed and no callback can pass its guards.
      }
    }
  }

  void close() {
    stopNfcCapture();
  }

  void destroy() {
    stopNfcCapture();
    cancelPendingPassiveUiReset();
    explicitNfcSetupHandler.removeCallbacksAndMessages(null);
    synchronized (uiEventLock) {
      uiListenerGeneration += 1L;
      uiEventSink = null;
    }
    statusExecutor.shutdownNow();
  }

  private synchronized void stopNfcCapture() {
    final boolean wasRequested;
    final NfcV cancelled;
    final Libre2NfcSetupAttempt cancelledAttempt;
    NfcRfTransactionLease maintenanceLease;
    final long expectedCaptureEpoch = captureEpoch;
    synchronized (rfAuthorizationLock) {
      wasRequested = captureRequested;
      captureRequested = false;
      rfAuthorizationGeneration += 1L;
      cancelledAttempt = explicitNfcSetupAttempt;
      if (cancelledAttempt != null) {
        maintenanceLease =
            terminalizeExplicitNfcSetupAttempt(
                cancelledAttempt,
                inFlightNfcV,
                "nfc.explicit_setup.connection.cancelled",
                "captureStopped");
        cancelled = null;
      } else {
        cancelled = inFlightNfcV;
        inFlightNfcV = null;
        inFlightExplicitNfcSetupAttemptId = null;
        maintenanceLease =
            claimActiveRfTransactionLeaseForMaintenanceLocked(null);
      }
    }
    cancelExplicitNfcSetupExpiry(cancelledAttempt);
    closeNfcVQuietly(cancelled);
    finishRfEligibilityRevocation(
        expectedCaptureEpoch, maintenanceLease, false, true);
    publishCancelledExplicitAttempt(cancelledAttempt);
    if (wasRequested && captureReady) {
      appendEvent("nfc.capture.stopped", new JSONObject());
    }
    captureReady = false;
    invalidateCaptureStatus();
    if (nfcAdapter != null && hasNfcPermission()) {
      try {
        nfcAdapter.disableReaderMode(activity);
      } catch (RuntimeException ignored) {
        // State is already fail-closed and no callback can pass its guards.
      }
    }
  }

  private void updateReaderMode() {
    if (!captureRequested
        || !resumed
        || nfcAdapter == null
        || !hasNfcPermission()
        || !nfcAdapter.isEnabled()) {
      return;
    }
    final Bundle extras = new Bundle();
    extras.putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250);
    nfcAdapter.enableReaderMode(
        activity,
        this::captureTag,
        NfcAdapter.FLAG_READER_NFC_V | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
        extras);
  }

  private static String explicitNfcSetupAttemptId(Object arguments) {
    if (!(arguments instanceof Map<?, ?>)
        || ((Map<?, ?>) arguments).size() != 1) {
      throw new IllegalArgumentException("Expected one NFC setup field.");
    }
    final Map<?, ?> values = (Map<?, ?>) arguments;
    if (!values.containsKey("attemptId")) {
      throw new IllegalArgumentException("Missing NFC setup attempt identifier.");
    }
    return requiredSafeToken(values, "attemptId");
  }

  private boolean startExplicitNfcSetup(String scanAttemptId) {
    final long preflightCaptureEpoch = captureEpoch;
    if (!reconcilePublishedHostGrantForExplicitSetup(
        preflightCaptureEpoch)) {
      return false;
    }
    final long expectedCaptureEpoch;
    final long expectedGeneration;
    final String expectedProcessSession;
    final long expiresAtElapsedRealtimeNanos;
    final Libre2NfcSetupAttempt attempt;
    NfcRfTransactionLease acquiredLease = null;
    boolean accepted = false;
    synchronized (captureEpochLock) {
      if (grantKindForEpoch(captureEpoch) != GrantKind.NONE) {
        return false;
      }
      synchronized (rfAuthorizationLock) {
        if (!captureRequested
            || !resumed
            || !captureReady
            || !captureWritable
            || captureEpoch < 1L
            || expectedDartProcessSessionId == null
            || dartProcessSessionId == null
            || !expectedDartProcessSessionId.equals(dartProcessSessionId)
            || streamingAttempt != null
            || explicitNfcSetupAttempt != null
            || nfcCallbackActive
            || inFlightNfcV != null
            || activeHostRfTransactionLease != null
            || !explicitNfcSetupExpiryBinding.isEmpty()
            || !rfTransactionLeaseBinding.isEmpty()) {
          return false;
        }
        try {
          acquiredLease =
              NfcRfTransactionLease.tryAcquire(
                  captureDirectory, newNativeRfLeaseOwnerToken());
        } catch (IOException | RuntimeException error) {
          return false;
        }
        if (acquiredLease == null) {
          return false;
        }
        if (grantKindForEpoch(captureEpoch) != GrantKind.NONE) {
          releaseRfTransactionLease(acquiredLease);
          return false;
        }
        expectedCaptureEpoch = captureEpoch;
        expectedGeneration = rfAuthorizationGeneration;
        expectedProcessSession = expectedDartProcessSessionId;
        final long now = SystemClock.elapsedRealtimeNanos();
        expiresAtElapsedRealtimeNanos =
            now + EXPLICIT_NFC_SETUP_LIFETIME_NANOS;
        attempt =
            new Libre2NfcSetupAttempt(
                scanAttemptId,
                expectedCaptureEpoch,
                expectedProcessSession,
                expectedGeneration,
                expiresAtElapsedRealtimeNanos);
        if (!rfTransactionLeaseBinding.bindExplicit(attempt, acquiredLease)) {
          releaseRfTransactionLease(acquiredLease);
          return false;
        }
        explicitNfcSetupAttempt = attempt;
        accepted = true;
      }
    }
    if (!accepted) {
      releaseRfTransactionLease(acquiredLease);
      return false;
    }
    // Clear stale host artifacts while no sensor contact is in progress. The
    // tag callback must reach NfcV.connect without filesystem latency.
    if (!deleteExplicitLifecycleArtifactsForEpoch(
        expectedCaptureEpoch, attempt)) {
      failExplicitNfcSetupForEpoch(
          expectedCaptureEpoch, attempt, "readFailed");
      return false;
    }
    final Runnable expiry =
        () ->
            expireExplicitNfcSetup(
                scanAttemptId,
                expectedCaptureEpoch,
                expectedGeneration,
                expiresAtElapsedRealtimeNanos);
    final boolean expiryScheduled;
    synchronized (rfAuthorizationLock) {
      expiryScheduled =
          explicitNfcSetupAttempt == attempt
              && explicitNfcSetupExpiryBinding.bind(attempt, expiry)
              && explicitNfcSetupHandler.postDelayed(
                  expiry,
                  EXPLICIT_NFC_SETUP_LIFETIME_NANOS / 1_000_000L);
      if (!expiryScheduled) {
        cancelExplicitNfcSetupExpiry(attempt);
      }
    }
    if (!expiryScheduled) {
      failExplicitNfcSetupForEpoch(
          expectedCaptureEpoch, attempt, "readFailed");
      return false;
    }
    publishExplicitUiEventForEpoch(
        expectedCaptureEpoch, attempt, "listening", null, null, null);
    return true;
  }

  /**
   * Removes only a definitively stale or malformed published host grant.
   *
   * <p>A current grant, a staged publication, or a conflicting set remains
   * untouched. The process-safe maintenance lease closes the check/delete
   * race with the host before an explicit setup lease can be acquired.
   */
  private boolean reconcilePublishedHostGrantForExplicitSetup(
      long expectedCaptureEpoch) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || !captureRequested
            || !resumed
            || !captureReady
            || !captureWritable
            || expectedDartProcessSessionId == null
            || dartProcessSessionId == null
            || !expectedDartProcessSessionId.equals(dartProcessSessionId)
            || explicitNfcSetupAttempt != null
            || nfcCallbackActive
            || inFlightNfcV != null
            || activeHostRfTransactionLease != null
            || !explicitNfcSetupExpiryBinding.isEmpty()
            || !rfTransactionLeaseBinding.isEmpty()) {
          return false;
        }
      }
    }
    final GrantKind initialKind = grantKindForEpoch(expectedCaptureEpoch);
    if (initialKind == GrantKind.NONE) {
      return true;
    }
    if (initialKind == GrantKind.CONFLICT) {
      return false;
    }
    final NfcRfTransactionLease maintenanceLease =
        beginAuthorizationMutationLease(expectedCaptureEpoch);
    if (maintenanceLease == null) {
      return false;
    }
    boolean reconciled = false;
    try {
      synchronized (captureEpochLock) {
        synchronized (rfAuthorizationLock) {
          final GrantKind currentKind =
              grantKindForEpoch(expectedCaptureEpoch);
          if (currentKind == GrantKind.NONE) {
            return true;
          }
          if (currentKind == GrantKind.CONFLICT
              || isCurrentPublishedGrantEnvelope(
                  expectedCaptureEpoch, currentKind)) {
            return false;
          }
          if (!deleteAuthorizationArtifacts(
              captureDirectory,
              false,
              RfMutationOwner.MAINTENANCE,
              null,
              maintenanceLease)) {
            captureWritable = false;
            captureReady = false;
            return false;
          }
          reconciled = true;
        }
      }
    } finally {
      finishAuthorizationMutationLease(maintenanceLease);
    }
    if (reconciled) {
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.authorization.stale.reconciled",
          new JSONObject());
    }
    return reconciled;
  }

  private boolean isCurrentPublishedGrantEnvelope(
      long expectedCaptureEpoch, GrantKind kind) {
    if (expectedCaptureEpoch != captureEpoch
        || captureDirectory == null
        || kind == GrantKind.NONE
        || kind == GrantKind.CONFLICT) {
      return false;
    }
    final String fileName;
    final String operation;
    final NfcPublishedGrantEnvelope.Kind envelopeKind;
    switch (kind) {
      case PATCH_INFO:
        fileName = TARGET_UNVERIFIED_PROBE_GRANT_FILE;
        operation = TARGET_UNVERIFIED_PROBE_OPERATION;
        envelopeKind = NfcPublishedGrantEnvelope.Kind.PATCH_INFO;
        break;
      case GEN1_FRAM_READ:
        fileName = TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE;
        operation = TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION;
        envelopeKind = NfcPublishedGrantEnvelope.Kind.GEN1_FRAM_READ;
        break;
      case GEN1_ACTIVATION:
        fileName = TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE;
        operation = TARGET_UNVERIFIED_GEN1_ACTIVATION_OPERATION;
        envelopeKind = NfcPublishedGrantEnvelope.Kind.GEN1_ACTIVATION;
        break;
      default:
        return false;
    }
    try {
      final byte[] encoded =
          readSmallFile(new File(captureDirectory, fileName));
      final JSONObject grant =
          new JSONObject(new String(encoded, StandardCharsets.UTF_8));
      final Map<String, Object> fields = new HashMap<>();
      final Iterator<String> keys = grant.keys();
      while (keys.hasNext()) {
        final String key = keys.next();
        fields.put(key, grant.opt(key));
      }
      return NfcPublishedGrantEnvelope.isCurrentAndUnexpired(
          envelopeKind,
          fields,
          GRANT_SCHEMA_VERSION,
          operation,
          grantNonce,
          sessionToken,
          expectedDartProcessSessionId,
          installedVersionCode,
          installedLastUpdateTime,
          EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX,
          System.currentTimeMillis(),
          MAX_CLOCK_SKEW_MILLIS,
          MAX_STANDARD_GRANT_LIFETIME_MILLIS,
          MAX_GEN1_FRAM_READ_GRANT_LIFETIME_MILLIS);
    } catch (IOException | JSONException | RuntimeException error) {
      return false;
    }
  }

  private void stopExplicitNfcSetup(String scanAttemptId) {
    final Libre2NfcSetupAttempt stoppedAttempt;
    final NfcRfTransactionLease releasedLease;
    synchronized (rfAuthorizationLock) {
      final Libre2NfcSetupAttempt attempt = explicitNfcSetupAttempt;
      if (attempt == null || !attempt.scanAttemptId().equals(scanAttemptId)) {
        return;
      }
      stoppedAttempt = attempt;
      releasedLease =
          terminalizeExplicitNfcSetupAttempt(
              stoppedAttempt,
              inFlightNfcV,
              "nfc.explicit_setup.connection.cancelled",
              "stopped");
      cancelExplicitNfcSetupExpiry(stoppedAttempt);
      if (releasedLease != null) {
        finishAuthorizationMutationLease(releasedLease);
      }
    }
  }

  private void expireExplicitNfcSetup(
      String scanAttemptId,
      long expectedCaptureEpoch,
      long expectedGeneration,
      long expectedExpiryElapsedRealtimeNanos) {
    final Libre2NfcSetupAttempt expiredAttempt;
    final NfcRfTransactionLease releasedLease;
    synchronized (rfAuthorizationLock) {
      final Libre2NfcSetupAttempt attempt = explicitNfcSetupAttempt;
      final long now = SystemClock.elapsedRealtimeNanos();
      if (attempt == null
          || !attempt.scanAttemptId().equals(scanAttemptId)
          || attempt.captureEpoch() != expectedCaptureEpoch
          || attempt.rfAuthorizationGeneration() != expectedGeneration
          || attempt.expiresAtElapsedRealtimeNanos()
              != expectedExpiryElapsedRealtimeNanos
          || now < expectedExpiryElapsedRealtimeNanos) {
        return;
      }
      expiredAttempt = attempt;
      cancelExplicitNfcSetupExpiry(expiredAttempt);
      releasedLease =
          terminalizeExplicitNfcSetupAttempt(
              expiredAttempt,
              inFlightNfcV,
              "nfc.explicit_setup.connection.cancelled",
              "expired");
      if (releasedLease != null) {
        finishAuthorizationMutationLease(releasedLease);
      }
    }
    if (releasedLease != null) {
      publishExplicitUiEventForEpoch(
          expectedCaptureEpoch,
          expiredAttempt,
          "failed",
          null,
          null,
          "readFailed");
    }
  }

  private void publishReaderStatusForEpoch(long expectedCaptureEpoch) {
    final String event;
    final String reason;
    final Libre2NfcSetupAttempt attempt;
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasUnreservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        attempt = explicitNfcSetupAttempt;
        if (expectedCaptureEpoch != captureEpoch
            || !captureRequested
            || !resumed
            || attempt == null) {
          return;
        }
        if (attempt.isClaimed()
            || attempt.scanAttemptId().equals(
                inFlightExplicitNfcSetupAttemptId)) {
          // Reader status describes only an unclaimed listening attempt.
          // A BLE status change must not regress tag-detected or in-flight UI.
          return;
        }
        if (nfcAdapter == null || !hasNfcPermission()) {
          event = "failed";
          reason = "unavailable";
        } else if (!nfcAdapter.isEnabled()) {
          event = "failed";
          reason = "disabled";
        } else if (!isExplicitNfcSetupUnclaimedReadyLocked(
            expectedCaptureEpoch,
            attempt.rfAuthorizationGeneration(),
            SystemClock.elapsedRealtimeNanos(),
            attempt,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts)) {
          event = "failed";
          reason = "readFailed";
        } else {
          event = "listening";
          reason = null;
        }
      }
    }
    publishExplicitUiEventForEpoch(
        expectedCaptureEpoch, attempt, event, null, null, reason);
  }

  private boolean hasNfcPermission() {
    return activity.checkSelfPermission(Manifest.permission.NFC)
        == PackageManager.PERMISSION_GRANTED;
  }

  private void captureTag(Tag tag) {
    final NfcRfReadiness.CallbackCompletion completion =
        new NfcRfReadiness.CallbackCompletion();
    synchronized (rfAuthorizationLock) {
      if (nfcCallbackActive || inFlightNfcV != null) {
        return;
      }
      nfcCallbackActive = true;
    }
    try {
      captureTagOnce(tag, completion);
    } finally {
      completion.finish(() -> {
        synchronized (rfAuthorizationLock) {
          nfcCallbackActive = false;
        }
      });
    }
  }

  private void captureTagOnce(Tag tag, NfcRfReadiness.CallbackCompletion completion) {
    final StreamingAttempt streaming;
    synchronized (rfAuthorizationLock) { streaming = streamingAttempt; }
    if (streaming != null) {
      captureStreamingTag(tag, streaming);
      return;
    }
    final long expectedCaptureEpoch = captureEpoch;
    final long authorizationGeneration;
    final long observedStatusElapsedRealtimeNanos;
    final boolean captureReadyForRf;
    final Libre2NfcSetupAttempt explicitSetupCandidate;
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasUnreservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        authorizationGeneration = rfAuthorizationGeneration;
        observedStatusElapsedRealtimeNanos =
            lastBleEligibleStatusElapsedRealtimeNanos;
        explicitSetupCandidate = explicitNfcSetupAttempt;
        captureReadyForRf =
            explicitSetupCandidate == null
                ? isCaptureReadyForRfLocked()
                    && expectedCaptureEpoch == captureEpoch
                : isExplicitNfcSetupUnclaimedReadyLocked(
                    expectedCaptureEpoch,
                    authorizationGeneration,
                    SystemClock.elapsedRealtimeNanos(),
                    explicitSetupCandidate,
                    traceCapacityAvailable,
                    noHostAuthorizationArtifacts);
      }
    }
    if (!captureReadyForRf) {
      if (explicitSetupCandidate == null) {
        expireRfEligibilityIfStale(
            expectedCaptureEpoch, observedStatusElapsedRealtimeNanos);
      }
      publishReaderStatusForEpoch(expectedCaptureEpoch);
      return;
    }
    if (explicitSetupCandidate == null
        && !isCaptureReadyForRf(expectedCaptureEpoch)) {
      expireRfEligibilityIfStale(
          expectedCaptureEpoch, observedStatusElapsedRealtimeNanos);
      publishReaderStatusForEpoch(expectedCaptureEpoch);
      return;
    }
    final JSONArray techList = new JSONArray();
    for (String technology : tag.getTechList()) {
      techList.put(technology);
    }

    final NfcV nfcV = NfcV.get(tag);
    if (nfcV == null) {
      if (explicitSetupCandidate != null) {
        failExplicitNfcSetupForEpoch(
            expectedCaptureEpoch, explicitSetupCandidate, "readFailed");
      } else {
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.probe.skipped.not_nfc_v",
            new JSONObject());
      }
      return;
    }

    final String targetUidSha256 = sha256Hex(tag.getId());
    final String manufacturerPrefix = iso15693ManufacturerPrefix(tag.getId());
    if (!EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX.equals(manufacturerPrefix)) {
      if (explicitSetupCandidate != null) {
        failExplicitNfcSetupForEpoch(
            expectedCaptureEpoch, explicitSetupCandidate, "readFailed");
      } else {
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.probe.skipped.unexpected_manufacturer",
            new JSONObject());
      }
      return;
    }
    final byte[] patchInfoCommand = librePatchInfoCommand(tag.getId());
    if (patchInfoCommand == null) {
      if (explicitSetupCandidate != null) {
        failExplicitNfcSetupForEpoch(
            expectedCaptureEpoch, explicitSetupCandidate, "readFailed");
      } else {
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.probe.skipped.invalid_uid_length",
            new JSONObject());
      }
      return;
    }

    if (explicitSetupCandidate != null) {
      if (!reserveExplicitNfcLifecycleTransactionTrace(
          expectedCaptureEpoch, nfcV, explicitSetupCandidate)) {
        failExplicitNfcSetupForEpoch(
            expectedCaptureEpoch,
            explicitSetupCandidate,
            "readFailed");
        return;
      }
      final Libre2NfcSetupAttempt explicitAttempt =
          claimExplicitNfcSetupAttempt(
              expectedCaptureEpoch,
              authorizationGeneration,
              targetUidSha256,
              explicitSetupCandidate);
      if (explicitAttempt == null) {
        failExplicitNfcSetupForEpoch(
            expectedCaptureEpoch,
            explicitSetupCandidate,
            "readFailed");
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.explicit_setup.skipped.authorization_conflict",
            new JSONObject());
        return;
      }
      publishExplicitUiEventForEpoch(
          expectedCaptureEpoch,
          explicitAttempt,
          "tagDetected",
          null,
          null,
          null);
      captureExplicitLifecycleOnce(
          expectedCaptureEpoch,
          authorizationGeneration,
          tag.getId().clone(),
          targetUidSha256,
          manufacturerPrefix,
          techList,
          patchInfoCommand,
          nfcV,
          explicitAttempt,
          completion);
      return;
    }

    final JSONObject discovered = new JSONObject();
    put(discovered, "uidHex", hex(tag.getId()));
    put(discovered, "techList", techList);
    if (!appendEventForEpoch(
        expectedCaptureEpoch, "nfc.tag.discovered", discovered)) {
      return;
    }
    if (!recordTargetContextWithLease(
        expectedCaptureEpoch,
        targetUidSha256,
        manufacturerPrefix,
        null)) {
      return;
    }

    final GrantKind grantKind = grantKindForEpoch(expectedCaptureEpoch);
    if (grantKind == GrantKind.CONFLICT) {
      if (!deleteConflictingAuthorizationArtifactsForEpoch(
          expectedCaptureEpoch)) {
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.probe.skipped.conflict_changed_or_busy",
            new JSONObject());
        return;
      }
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.probe.skipped.conflicting_grants",
          new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }
    if (grantKind == GrantKind.GEN1_FRAM_READ) {
      final NfcRfTransactionLease lease =
          beginHostRfTransactionLease(
              expectedCaptureEpoch, GrantKind.GEN1_FRAM_READ);
      if (lease == null) {
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.gen1_fram.skipped.rf_lease_conflict",
            new JSONObject());
        return;
      }
      try {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "tagDetected", null, null, null);
        captureGen1FramOnce(
            expectedCaptureEpoch,
            authorizationGeneration,
            tag.getId(),
            targetUidSha256,
            manufacturerPrefix,
            patchInfoCommand,
            nfcV,
            lease);
      } finally {
        finishRfTransactionLease(lease);
      }
      return;
    }
    if (grantKind == GrantKind.GEN1_ACTIVATION) {
      final NfcRfTransactionLease lease =
          beginHostRfTransactionLease(
              expectedCaptureEpoch, GrantKind.GEN1_ACTIVATION);
      if (lease == null) {
        appendEventForEpoch(
            expectedCaptureEpoch,
            "nfc.gen1_activation.skipped.rf_lease_conflict",
            new JSONObject());
        return;
      }
      try {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "tagDetected", null, null, null);
        activateGen1Once(
            expectedCaptureEpoch,
            authorizationGeneration,
            tag.getId(),
            targetUidSha256,
            manufacturerPrefix,
            patchInfoCommand,
            nfcV,
            lease);
      } finally {
        finishRfTransactionLease(lease);
      }
      return;
    }
    if (grantKind == GrantKind.NONE) {
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.probe.skipped.no_valid_grant",
          new JSONObject());
      return;
    }
    final NfcRfTransactionLease lease =
        beginHostRfTransactionLease(
            expectedCaptureEpoch, GrantKind.PATCH_INFO);
    if (lease == null) {
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.probe.skipped.rf_lease_conflict",
          new JSONObject());
      return;
    }
    try {
      captureHostPatchInfoOnce(
          expectedCaptureEpoch,
          authorizationGeneration,
          targetUidSha256,
          manufacturerPrefix,
          patchInfoCommand,
          nfcV,
          lease);
    } finally {
      finishRfTransactionLease(lease);
    }
  }

  private void captureHostPatchInfoOnce(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      String targetUidSha256,
      String manufacturerPrefix,
      byte[] patchInfoCommand,
      NfcV nfcV,
      NfcRfTransactionLease hostLease) {
    publishUiEventForEpoch(
        expectedCaptureEpoch, "tagDetected", null, null, null);
    if (!reserveNfcTransactionTrace(expectedCaptureEpoch, nfcV)) {
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.probe.skipped.insufficient_trace_capacity",
          new JSONObject());
      invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    final ProbeGrant grant =
        consumeValidatedGrant(
            expectedCaptureEpoch,
            targetUidSha256,
            manufacturerPrefix,
            hostLease);
    if (grant == null) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.probe.skipped.no_valid_grant",
          new JSONObject());
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventDelayedForEpoch(
          expectedCaptureEpoch,
          PASSIVE_DETECTION_VISIBLE_MILLIS,
          "listening",
          null,
          null,
          null);
      return;
    }
    if (!deletePatchInfoContextForEpoch(
        expectedCaptureEpoch, hostLease, null)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    final JSONObject authorization = new JSONObject();
    put(authorization, "operation", TARGET_UNVERIFIED_PROBE_OPERATION);
    put(authorization, "captureSessionId", grant.captureSessionId);
    put(authorization, "expiresAtEpochMillis", grant.expiresAtEpochMillis);
    if (!appendReservedEventForEpoch(
        expectedCaptureEpoch,
        "nfc.probe.authorization.consumed",
        authorization)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    if (!beginRfOperation(
        expectedCaptureEpoch,
        authorizationGeneration,
        grant,
        nfcV,
        hostLease)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }
    if (!appendReservedEventForEpoch(
        expectedCaptureEpoch, "nfc.connection.start", new JSONObject())) {
      endRfOperation(nfcV);
      closeNfcVQuietly(nfcV);
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }
    publishUiEventForEpoch(
        expectedCaptureEpoch, "readingMetadata", null, null, null);
    try {
      if (!isRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      nfcV.connect();
      final JSONObject connected = new JSONObject();
      put(connected, "maxTransceiveLength", nfcV.getMaxTransceiveLength());
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.connection.ready", connected)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }

      final JSONObject request = new JSONObject();
      put(request, "operation", TARGET_UNVERIFIED_PROBE_OPERATION);
      put(request, "captureSessionId", grant.captureSessionId);
      put(request, "valueHex", hex(patchInfoCommand));
      put(request, "length", patchInfoCommand.length);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.transceive.request", request)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      final byte[] response =
          transceiveProbeAuthorized(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              nfcV,
              hostLease,
              patchInfoCommand);
      final JSONObject received = new JSONObject();
      put(received, "operation", TARGET_UNVERIFIED_PROBE_OPERATION);
      put(received, "captureSessionId", grant.captureSessionId);
      put(received, "valueHex", hex(response));
      put(received, "length", response.length);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.transceive.response", received)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      if (!isRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      publishMetadataRead(
          expectedCaptureEpoch,
          response,
          targetUidSha256,
          manufacturerPrefix,
          hostLease);
    } catch (TagLostException error) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.failure.tag_lost", new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "tagMoved");
    } catch (IOException error) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.failure.io", new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    } catch (RuntimeException error) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.failure.runtime", new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    } finally {
      endRfOperation(nfcV);
      try {
        nfcV.close();
      } catch (IOException | RuntimeException ignored) {
        appendReservedEventForEpoch(
            expectedCaptureEpoch,
            "nfc.connection.close_failure",
            new JSONObject());
      }
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.connection.closed", new JSONObject());
      releaseNfcTransactionTrace(expectedCaptureEpoch);
    }
  }

  private Libre2NfcSetupAttempt claimExplicitNfcSetupAttempt(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt expectedAttempt) {
    synchronized (captureEpochLock) {
      // Host-authored patch, FRAM, activation, and staged grants always win
      // the safety check. An explicit UI attempt can never share their lane.
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasReservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      if (!noHostAuthorizationArtifacts) {
        return null;
      }
      synchronized (rfAuthorizationLock) {
        final Libre2NfcSetupAttempt attempt = explicitNfcSetupAttempt;
        final long nowElapsedRealtimeNanos =
            SystemClock.elapsedRealtimeNanos();
        if (attempt == null
            || attempt != expectedAttempt
            || !isExplicitNfcSetupUnclaimedReadyLocked(
                expectedCaptureEpoch,
                expectedGeneration,
                nowElapsedRealtimeNanos,
                expectedAttempt,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)
            || !attempt.claim(
                expectedCaptureEpoch,
                expectedDartProcessSessionId,
                expectedGeneration,
                nowElapsedRealtimeNanos,
                targetUidSha256)) {
          return null;
        }
        return attempt;
      }
    }
  }

  private boolean beginExplicitNfcSetupRfOperation(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt attempt,
      NfcV nfcV) {
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasReservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      if (!noHostAuthorizationArtifacts) {
        return false;
      }
      synchronized (rfAuthorizationLock) {
        if (explicitNfcSetupAttempt != attempt
            || !isExplicitNfcSetupClaimedReadyLocked(
                expectedCaptureEpoch,
                expectedGeneration,
                SystemClock.elapsedRealtimeNanos(),
                targetUidSha256,
                attempt,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)
            || inFlightNfcV != null
            || inFlightExplicitNfcSetupAttemptId != null
            || !attempt.bindRfOperationOnce()) {
          return false;
        }
        inFlightNfcV = nfcV;
        inFlightExplicitNfcSetupAttemptId = attempt.scanAttemptId();
        return true;
      }
    }
  }

  private boolean isExplicitNfcSetupRfAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt attempt) {
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasReservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      if (!noHostAuthorizationArtifacts) {
        return false;
      }
      synchronized (rfAuthorizationLock) {
        return isExplicitNfcSetupRfAuthorizedLocked(
            expectedCaptureEpoch,
            expectedGeneration,
            targetUidSha256,
            attempt,
            inFlightNfcV,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts);
      }
    }
  }

  private boolean isExplicitNfcSetupRfAuthorizedLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt attempt,
      NfcV expectedNfcV,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return explicitNfcSetupAttempt == attempt
        && isExplicitNfcSetupClaimedReadyLocked(
            expectedCaptureEpoch,
            expectedGeneration,
            SystemClock.elapsedRealtimeNanos(),
            targetUidSha256,
            attempt,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts)
        && expectedNfcV != null
        && inFlightNfcV == expectedNfcV
        && attempt.scanAttemptId().equals(
            inFlightExplicitNfcSetupAttemptId);
  }

  private boolean failExplicitNfcSetupForEpoch(
      long expectedCaptureEpoch,
      Libre2NfcSetupAttempt failedAttempt,
      String reason) {
    final NfcRfTransactionLease releasedLease;
    synchronized (rfAuthorizationLock) {
      final Libre2NfcSetupAttempt attempt = explicitNfcSetupAttempt;
      if (attempt == null
          || attempt != failedAttempt
          || attempt.captureEpoch() != expectedCaptureEpoch) {
        return false;
      }
      releasedLease =
          terminalizeExplicitNfcSetupAttempt(
              failedAttempt,
              inFlightNfcV,
              "nfc.explicit_setup.connection.cancelled",
              "failed");
      cancelExplicitNfcSetupExpiry(failedAttempt);
      if (releasedLease != null) {
        finishAuthorizationMutationLease(releasedLease);
      }
    }
    if (releasedLease == null) {
      return false;
    }
    publishExplicitUiEventForEpoch(
        expectedCaptureEpoch,
        failedAttempt,
        "failed",
        null,
        null,
        reason);
    return true;
  }

  private NfcRfTransactionLease terminalizeExplicitNfcSetupAttempt(
      Libre2NfcSetupAttempt attempt,
      NfcV requestedNfcV,
      String terminalEvent,
      String lifecycle) {
    if (attempt == null) {
      closeNfcVQuietly(requestedNfcV);
      return null;
    }
    final long expectedCaptureEpoch = attempt.captureEpoch();
    synchronized (rfAuthorizationLock) {
      if (!attempt.claimTerminalization()) {
        closeNfcVQuietly(requestedNfcV);
        return null;
      }
      final NfcV boundNfcV;
      if (explicitNfcSetupAttempt == attempt) {
        explicitNfcSetupAttempt = null;
      }
      if (attempt.scanAttemptId().equals(
          inFlightExplicitNfcSetupAttemptId)) {
        boundNfcV = inFlightNfcV;
        inFlightNfcV = null;
        inFlightExplicitNfcSetupAttemptId = null;
      } else {
        boundNfcV = null;
      }
      final NfcRfTransactionLease maintenanceLease =
          rfTransactionLeaseBinding.claimExplicitForMaintenance(attempt);
      if (maintenanceLease == null) {
        captureWritable = false;
        captureReady = false;
        closeNfcVQuietly(boundNfcV);
        if (requestedNfcV != boundNfcV) {
          closeNfcVQuietly(requestedNfcV);
        }
        return null;
      }
      synchronized (explicitNfcTerminalLock) {
        closeNfcVQuietly(boundNfcV);
        if (requestedNfcV != boundNfcV) {
          closeNfcVQuietly(requestedNfcV);
        }
        final JSONObject terminal = new JSONObject();
        put(terminal, "operation", EXPLICIT_LIBRE2_SETUP_OPERATION);
        if (lifecycle != null) {
          put(terminal, "lifecycle", lifecycle);
        }
        final boolean hasReservation =
            attempt.hasTraceReservationForTerminalization();
        final boolean audited =
            hasReservation
                ? appendReservedEventForEpoch(
                    expectedCaptureEpoch, terminalEvent, terminal)
                : appendEventForEpoch(
                    expectedCaptureEpoch, terminalEvent, terminal);
        if (!audited) {
          // The maintenance-bound filesystem lease and any exact trace
          // reservation are deliberately retained as a quarantine. No later
          // host or explicit transaction can overlap an unaudited terminal
          // outcome.
          captureWritable = false;
          captureReady = false;
          return null;
        }
        if (attempt.takeTraceReservationForTerminalization()) {
          releaseNfcTransactionTrace(expectedCaptureEpoch);
        }
      }
      return maintenanceLease;
    }
  }

  private void publishCancelledExplicitAttempt(
      Libre2NfcSetupAttempt cancelledAttempt) {
    if (cancelledAttempt == null) {
      return;
    }
    publishExplicitUiEventForEpoch(
        cancelledAttempt.captureEpoch(),
        cancelledAttempt,
        "failed",
        null,
        null,
        "readFailed");
  }

  private void captureExplicitLifecycleOnce(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      byte[] targetUid,
      String targetUidSha256,
      String manufacturerPrefix,
      JSONArray techList,
      byte[] patchInfoCommand,
      NfcV nfcV,
      Libre2NfcSetupAttempt attempt,
      NfcRfReadiness.CallbackCompletion completion) {
    if (!beginExplicitNfcSetupRfOperation(
        expectedCaptureEpoch,
        authorizationGeneration,
        targetUidSha256,
        attempt,
        nfcV)) {
      failExplicitNfcSetupForEpoch(
          expectedCaptureEpoch, attempt, "readFailed");
      return;
    }
    publishExplicitUiEventForEpoch(
        expectedCaptureEpoch,
        attempt,
        "readingMetadata",
        null,
        null,
        null);
    PatchInfoClassification classified = null;
    String lifecycle = null;
    String terminalFailureReason = null;
    final JSONArray exchanges = new JSONArray();
    final List<byte[]> payloads = new ArrayList<>();
    byte[] patchInfoResponse = null;
    byte[] encryptedFram = null;
    try {
      if (!isExplicitNfcSetupRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          targetUidSha256,
          attempt)) {
        throw new IOException("NFC setup authorization changed.");
      }
      nfcV.connect();
      if (nfcV.getMaxTransceiveLength()
              < LibreGen1NfcFrames.MAX_RESPONSE_BYTES
          || !advanceExplicitNfcSetupState(
              expectedCaptureEpoch,
              authorizationGeneration,
              targetUidSha256,
              attempt,
              ExplicitStateAdvance.CONNECTED)) {
        throw new IOException("NFC setup transport is unavailable.");
      }

      final JSONObject patchExchange = new JSONObject();
      put(patchExchange, "step", "patchInfo");
      put(patchExchange, "requestHex", hex(patchInfoCommand));
      put(patchExchange, "requestLength", patchInfoCommand.length);
      exchanges.put(patchExchange);
      // Slot zero is consumed before transceive. An unknown outcome can never
      // be retried by this attempt.
      patchInfoResponse =
          transceiveExplicitNfcSetupAuthorized(
              expectedCaptureEpoch,
              authorizationGeneration,
              targetUidSha256,
              attempt,
              nfcV,
              patchInfoCommand);
      put(patchExchange, "responseHex", hex(patchInfoResponse));
      put(patchExchange, "responseLength", patchInfoResponse.length);
      if (!isExplicitNfcSetupRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          targetUidSha256,
          attempt)) {
        throw new IOException("NFC setup authorization changed.");
      }
      classified = classifyPatchInfo(patchInfoResponse);
      if (classified == null
          || !"libre2".equals(classified.model)
          || !"gen1".equals(classified.securityGeneration)
          || !advanceExplicitNfcSetupState(
              expectedCaptureEpoch,
              authorizationGeneration,
              targetUidSha256,
              attempt,
              ExplicitStateAdvance.PATCH_INFO_ACCEPTED)) {
        throw new IOException("Unsupported NFC setup target.");
      }

      int frameIndex = 0;
      for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
        final byte[] requestBytes = frame.request();
        final JSONObject exchange = new JSONObject();
        put(exchange, "step", "fram");
        put(exchange, "frameIndex", frameIndex);
        put(exchange, "startBlock", frame.startBlock());
        put(exchange, "blockCount", frame.blockCount());
        put(exchange, "requestHex", hex(requestBytes));
        put(exchange, "requestLength", requestBytes.length);
        exchanges.put(exchange);
        final byte[] responseBytes =
            transceiveExplicitNfcFramAuthorized(
                expectedCaptureEpoch,
                authorizationGeneration,
                targetUidSha256,
                attempt,
                nfcV,
                frameIndex,
                requestBytes);
        try {
          put(exchange, "responseHex", hex(responseBytes));
          put(exchange, "responseLength", responseBytes.length);
          payloads.add(frame.payloadFromResponse(responseBytes));
        } finally {
          Arrays.fill(responseBytes, (byte) 0);
        }
        frameIndex += 1;
      }
      if (!advanceExplicitNfcSetupState(
          expectedCaptureEpoch,
          authorizationGeneration,
          targetUidSha256,
          attempt,
          ExplicitStateAdvance.FRAM_COMPLETE)) {
        throw new IOException("NFC setup sequence was incomplete.");
      }
      encryptedFram = LibreGen1NfcFrames.concatenatePayloads(payloads);
      final byte[] patchInfoPayload =
          Arrays.copyOfRange(
              patchInfoResponse, 1, patchInfoResponse.length);
      final int lifecycleCode;
      try {
        lifecycleCode =
            LibreGen1Activation.validatedLifecycle(
                targetUid,
                patchInfoPayload,
                encryptedFram);
      } finally {
        Arrays.fill(patchInfoPayload, (byte) 0);
      }
      lifecycle = LibreGen1Activation.closedLifecycleName(lifecycleCode);
      if (!advanceExplicitNfcSetupState(
          expectedCaptureEpoch,
          authorizationGeneration,
          targetUidSha256,
          attempt,
          ExplicitStateAdvance.LIFECYCLE_VALIDATED)) {
        throw new IOException("NFC setup lifecycle became stale.");
      }
    } catch (TagLostException error) {
      terminalFailureReason = "tagMoved";
    } catch (IOException | RuntimeException error) {
      terminalFailureReason = "readFailed";
    } finally {
      closeNfcVQuietly(nfcV);
      final JSONObject sequenceRecord = new JSONObject();
      put(sequenceRecord, "operation", EXPLICIT_LIBRE2_SETUP_OPERATION);
      put(sequenceRecord, "fixedSendCount", 1 + LibreGen1NfcFrames.REQUEST_COUNT);
      put(sequenceRecord, "framBytes", LibreGen1NfcFrames.FRAM_BYTES);
      put(sequenceRecord, "uidHex", hex(targetUid));
      put(sequenceRecord, "iso15693ManufacturerPrefix", manufacturerPrefix);
      put(sequenceRecord, "techList", techList);
      put(sequenceRecord, "exchanges", exchanges);
      if (classified != null) {
        put(sequenceRecord, "model", classified.model);
        put(sequenceRecord, "securityGeneration", classified.securityGeneration);
      }
      if (lifecycle != null) {
        put(sequenceRecord, "lifecycle", lifecycle);
      }
      put(
          sequenceRecord,
          "outcome",
          terminalFailureReason == null && lifecycle != null
              ? "validated"
              : "failed");
      boolean terminalized = false;
      synchronized (captureEpochLock) {
        synchronized (rfAuthorizationLock) {
          final boolean exactAttemptStillOwnsPostProcessing =
              isExplicitNfcSetupRfAuthorizedLocked(
                  expectedCaptureEpoch,
                  authorizationGeneration,
                  targetUidSha256,
                  attempt,
                  nfcV,
                  hasReservedExplicitNfcSetupTraceCapacity(
                      expectedCaptureEpoch),
                  grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE);
          if (exactAttemptStillOwnsPostProcessing) {
            boolean artifactsPersisted = terminalFailureReason != null;
            if (terminalFailureReason == null
                && lifecycle != null
                && classified != null) {
              final String patchInfoSha256 =
                  sha256PatchInfoPayload(patchInfoResponse);
              artifactsPersisted =
                  recordTargetContextWithLease(
                      expectedCaptureEpoch,
                      targetUidSha256,
                      manufacturerPrefix,
                      attempt)
                  && persistPatchInfoContext(
                      expectedCaptureEpoch,
                      targetUidSha256,
                      manufacturerPrefix,
                      classified,
                      patchInfoResponse,
                      null,
                      attempt)
                  && persistGen1FramCapture(
                      expectedCaptureEpoch,
                      targetUid,
                      targetUidSha256,
                      manufacturerPrefix,
                      null,
                      classified,
                      patchInfoResponse,
                      patchInfoSha256,
                      encryptedFram,
                      null,
                      attempt);
              if (!artifactsPersisted) {
                terminalFailureReason = "readFailed";
                lifecycle = null;
                sequenceRecord.remove("lifecycle");
                put(sequenceRecord, "outcome", "failed");
              }
            }
            final boolean sequenceAudited =
                appendExplicitReservedEventForEpoch(
                    expectedCaptureEpoch,
                    attempt,
                    "nfc.explicit_setup.read_sequence",
                    sequenceRecord);
            if (!sequenceAudited) {
              terminalFailureReason = "readFailed";
              lifecycle = null;
            }
            if ((!artifactsPersisted || !sequenceAudited)
                && !deleteExplicitLifecycleArtifactsForEpoch(
                    expectedCaptureEpoch, attempt)) {
              captureWritable = false;
              captureReady = false;
            }
            final NfcRfTransactionLease terminalLease =
                terminalizeExplicitNfcSetupAttempt(
                    attempt,
                    nfcV,
                    "nfc.explicit_setup.connection.closed",
                    lifecycle);
            terminalized = terminalLease != null;
            cancelExplicitNfcSetupExpiry(attempt);
            if (terminalLease != null) {
              finishAuthorizationMutationLease(terminalLease);
            }
          }
        }
      }
      if (terminalized) {
        if (terminalFailureReason != null
            || classified == null
            || lifecycle == null) {
          publishExplicitUiEventForEpoch(
              expectedCaptureEpoch,
              attempt,
              "failed",
              null,
              null,
              terminalFailureReason == null
                  ? "readFailed"
                  : terminalFailureReason);
        } else {
          // Retain factory evidence only after this read has been validated,
          // audited, terminalized, and released. This is not an RF operation.
          final LibreGen1CalibrationPersistence.Result cacheResult =
              preserveMatchedCalibrationEvidence(
                  expectedCaptureEpoch, targetUid, patchInfoResponse, encryptedFram);
          final String completedModel = classified.model;
          final String completedLifecycle = lifecycle;
          // Dart can immediately query fresh evidence on metadataRead. Deliver
          // only after the outer tag callback clears its active guard and this
          // method wipes its buffers; stop alone cannot prove callback drain.
          completion.defer(() -> {
            publishExplicitUiEventForEpoch(
                expectedCaptureEpoch,
                attempt,
                "metadataRead",
                completedModel,
                completedLifecycle,
                null);
            recordCalibrationCacheResultAfterUi(expectedCaptureEpoch, cacheResult);
          });
        }
      }
      if (patchInfoResponse != null) {
        Arrays.fill(patchInfoResponse, (byte) 0);
      }
      if (encryptedFram != null) {
        Arrays.fill(encryptedFram, (byte) 0);
      }
      for (byte[] payload : payloads) {
        Arrays.fill(payload, (byte) 0);
      }
      Arrays.fill(targetUid, (byte) 0);
    }
  }

  private void captureGen1FramOnce(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      byte[] targetUid,
      String targetUidSha256,
      String manufacturerPrefix,
      byte[] patchInfoCommand,
      NfcV nfcV,
      NfcRfTransactionLease hostLease) {
    if (!reserveGen1FramTransactionTrace(expectedCaptureEpoch, nfcV)) {
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_fram.skipped.insufficient_trace_capacity",
          new JSONObject());
      invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    final FramReadGrant grant =
        consumeValidatedFramReadGrant(
            expectedCaptureEpoch,
            targetUidSha256,
            manufacturerPrefix,
            hostLease);
    if (grant == null) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_fram.skipped.no_valid_grant",
          new JSONObject());
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    final JSONObject authorization = new JSONObject();
    put(authorization, "operation", TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION);
    put(authorization, "captureSessionId", grant.captureSessionId);
    put(authorization, "expiresAtEpochMillis", grant.expiresAtEpochMillis);
    put(authorization, "patchInfoSha256", grant.patchInfoSha256);
    if (!appendReservedEventForEpoch(
        expectedCaptureEpoch,
        "nfc.gen1_fram.authorization.consumed",
        authorization)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    if (!beginFramRfOperation(
        expectedCaptureEpoch,
        authorizationGeneration,
        grant,
        nfcV,
        hostLease)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }
    if (!appendReservedEventForEpoch(
        expectedCaptureEpoch, "nfc.connection.start", new JSONObject())) {
      endRfOperation(nfcV);
      closeNfcVQuietly(nfcV);
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    publishUiEventForEpoch(
        expectedCaptureEpoch, "readingMetadata", null, null, null);
    try {
      if (!isFramRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      nfcV.connect();
      final int maxTransceiveLength = nfcV.getMaxTransceiveLength();
      if (maxTransceiveLength < LibreGen1NfcFrames.MAX_RESPONSE_BYTES) {
        appendReservedEventForEpoch(
            expectedCaptureEpoch,
            "nfc.gen1_fram.failure.transceive_limit",
            new JSONObject());
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      final JSONObject connected = new JSONObject();
      put(connected, "maxTransceiveLength", maxTransceiveLength);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.connection.ready", connected)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }

      final JSONObject patchRequest = new JSONObject();
      put(patchRequest, "operation", TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION);
      put(patchRequest, "step", "patch_info_recheck");
      put(patchRequest, "captureSessionId", grant.captureSessionId);
      put(patchRequest, "valueHex", hex(patchInfoCommand));
      put(patchRequest, "length", patchInfoCommand.length);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.transceive.request", patchRequest)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      if (!isFramRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      final byte[] patchInfoResponse =
          transceiveFramAuthorized(
              expectedCaptureEpoch,
                authorizationGeneration,
                grant,
                nfcV,
                hostLease,
                patchInfoCommand);
      final JSONObject patchReceived = new JSONObject();
      put(patchReceived, "operation", TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION);
      put(patchReceived, "step", "patch_info_recheck");
      put(patchReceived, "captureSessionId", grant.captureSessionId);
      put(patchReceived, "valueHex", hex(patchInfoResponse));
      put(patchReceived, "length", patchInfoResponse.length);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.transceive.response", patchReceived)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      if (!isFramRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      final PatchInfoClassification classification =
          classifyPatchInfo(patchInfoResponse);
      if (classification == null
          || !"gen1".equals(classification.securityGeneration)
          || !classification.model.equals(grant.model)
          || !sha256PatchInfoPayload(patchInfoResponse)
              .equals(grant.patchInfoSha256)) {
        appendReservedEventForEpoch(
            expectedCaptureEpoch,
            "nfc.gen1_fram.failure.patch_info_mismatch",
            new JSONObject());
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }

      final JSONObject revalidated = new JSONObject();
      put(revalidated, "model", classification.model);
      put(revalidated, "securityGeneration", classification.securityGeneration);
      put(revalidated, "patchInfoSha256", grant.patchInfoSha256);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.patch_info.revalidated",
          revalidated)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }

      final List<byte[]> payloads = new ArrayList<>();
      int frameIndex = 0;
      for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
        final byte[] requestBytes = frame.request();
        final JSONObject request = new JSONObject();
        put(request, "operation", TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION);
        put(request, "captureSessionId", grant.captureSessionId);
        put(request, "frameIndex", frameIndex);
        put(request, "startBlock", frame.startBlock());
        put(request, "blockCount", frame.blockCount());
        put(request, "valueHex", hex(requestBytes));
        put(request, "length", requestBytes.length);
        if (!appendReservedEventForEpoch(
            expectedCaptureEpoch, "nfc.transceive.request", request)) {
          publishUiEventForEpoch(
              expectedCaptureEpoch, "failed", null, null, "readFailed");
          return;
        }
        if (!isFramRfAuthorized(
            expectedCaptureEpoch,
            authorizationGeneration,
            grant,
            hostLease)) {
          publishUiEventForEpoch(
              expectedCaptureEpoch, "failed", null, null, "readFailed");
          return;
        }
        final byte[] responseBytes =
            transceiveFramAuthorized(
                expectedCaptureEpoch,
                authorizationGeneration,
                grant,
                nfcV,
                hostLease,
                requestBytes);
        final JSONObject received = new JSONObject();
        put(received, "operation", TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION);
        put(received, "captureSessionId", grant.captureSessionId);
        put(received, "frameIndex", frameIndex);
        put(received, "startBlock", frame.startBlock());
        put(received, "blockCount", frame.blockCount());
        put(received, "valueHex", hex(responseBytes));
        put(received, "length", responseBytes.length);
        if (!appendReservedEventForEpoch(
            expectedCaptureEpoch, "nfc.transceive.response", received)) {
          publishUiEventForEpoch(
              expectedCaptureEpoch, "failed", null, null, "readFailed");
          return;
        }
        if (!isFramRfAuthorized(
            expectedCaptureEpoch,
            authorizationGeneration,
            grant,
            hostLease)) {
          publishUiEventForEpoch(
              expectedCaptureEpoch, "failed", null, null, "readFailed");
          return;
        }
        payloads.add(frame.payloadFromResponse(responseBytes));
        frameIndex += 1;
      }

      final byte[] encryptedFram =
          LibreGen1NfcFrames.concatenatePayloads(payloads);
      if (encryptedFram.length != LibreGen1NfcFrames.FRAM_BYTES) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      if (!isFramRfAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      // The FRAM grant consumes the prior patch context before RF work. After
      // every fixed frame succeeds, publish a fresh context from the exact
      // patch-info response revalidated in this same operation. The private
      // collector can then bind the atomic FRAM artifact to current evidence.
      if (!persistPatchInfoContext(
          expectedCaptureEpoch,
          targetUidSha256,
          manufacturerPrefix,
          classification,
          patchInfoResponse,
          hostLease,
          null)) {
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      if (!persistGen1FramCapture(
          expectedCaptureEpoch,
          targetUid,
          targetUidSha256,
          manufacturerPrefix,
          grant.captureSessionId,
          classification,
          patchInfoResponse,
          grant.patchInfoSha256,
          encryptedFram,
          hostLease,
          null)) {
        deletePatchInfoContextForEpoch(
            expectedCaptureEpoch, hostLease, null);
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      final JSONObject captured = new JSONObject();
      put(captured, "operation", TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION);
      put(captured, "captureSessionId", grant.captureSessionId);
      put(captured, "model", classification.model);
      put(captured, "securityGeneration", classification.securityGeneration);
      put(captured, "valueHex", hex(encryptedFram));
      put(captured, "length", encryptedFram.length);
      if (!appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.gen1_fram.captured", captured)) {
        deleteGen1FramCaptureForEpoch(expectedCaptureEpoch, hostLease);
        deletePatchInfoContextForEpoch(
            expectedCaptureEpoch, hostLease, null);
        publishUiEventForEpoch(
            expectedCaptureEpoch, "failed", null, null, "readFailed");
        return;
      }
      publishUiEventForEpoch(
          expectedCaptureEpoch,
          "metadataRead",
          classification.model,
          null,
          null);
    } catch (TagLostException error) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.failure.tag_lost", new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "tagMoved");
    } catch (IOException error) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.failure.io", new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    } catch (RuntimeException error) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.failure.runtime", new JSONObject());
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    } finally {
      endRfOperation(nfcV);
      try {
        nfcV.close();
      } catch (IOException | RuntimeException ignored) {
        appendReservedEventForEpoch(
            expectedCaptureEpoch,
            "nfc.connection.close_failure",
            new JSONObject());
      }
      appendReservedEventForEpoch(
          expectedCaptureEpoch, "nfc.connection.closed", new JSONObject());
      releaseNfcTransactionTrace(expectedCaptureEpoch);
    }
  }

  private boolean handleLibreFreshHistoryEvidenceMethod(
      String method, Object arguments, MethodChannel.Result result) {
    if (!"readLibreGen1FreshHistoryEvidence".equals(method)) return false;
    try {
      final Map<?, ?> args = exactStreamingArguments(arguments, 2);
      final String attemptId = requiredSafeToken(args, "attemptId");
      final String bootstrapId = requiredSafeToken(args, "bootstrapId");
      final long expectedEpoch = captureEpoch;
      final long expectedGeneration;
      synchronized (rfAuthorizationLock) { expectedGeneration = rfAuthorizationGeneration; }
      statusExecutor.execute(() -> {
        LibreGen1ReceiverReuseProof.FreshHistoryEvidence pending = null;
        try {
          pending = readLibreGen1FreshHistoryEvidence(
              attemptId, bootstrapId, expectedEpoch, expectedGeneration);
          final LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence = pending;
          if (!mainHandler.post(() -> {
            try {
              deliverLibreGen1FreshHistoryEvidence(evidence, expectedEpoch, expectedGeneration, result);
            } catch (Exception unavailable) {
              result.error("libre_history_evidence_unavailable",
                  "Fresh Libre history evidence is unavailable.", null);
            } finally {
              evidence.close();
            }
          })) throw new IOException("Fresh Libre history evidence is unavailable.");
          pending = null; // The posted callback now owns cleanup, including revocation.
        } catch (Exception unavailable) {
          if (pending != null) pending.close();
          postResult(() -> result.error("libre_history_evidence_unavailable",
              "Fresh Libre history evidence is unavailable.", null));
        }
      });
    } catch (IllegalArgumentException invalid) {
      result.error("bad_args", "Invalid fresh Libre history request.", null);
    } catch (RejectedExecutionException closed) {
      result.error("capture_closed", "Protocol capture worker is closed.", null);
    }
    return true;
  }

  /** Fixed fresh explicit-read source only. No cache fallback, file mutation or RF. */
  private LibreGen1ReceiverReuseProof.FreshHistoryEvidence readLibreGen1FreshHistoryEvidence(
      String attemptId, String bootstrapId, long expectedEpoch, long expectedGeneration)
      throws Exception {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
        byte[] sourceBytes = null;
        LibreGen1StreamingJournal.Record receiver = null;
        LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence = null;
        try {
          sourceBytes = readActivationUiProofFile(new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE));
          // Use this one immutable string for strict proof and byte extraction.
          // There is no second file read which could replace the verified source.
          final String sourceJson = new String(sourceBytes, StandardCharsets.UTF_8);
          final LibreGen1StreamingJournal journal = LibreGen1StreamingStore.journal(activity);
          synchronized (journal) {
            if (!receiverReuseRecordPresent()) throw new IOException("Saved receiver is absent.");
            receiver = journal.read();
            if (receiver == null || !receiverReuseRecordPresent()) {
              throw new IOException("Saved receiver is unavailable.");
            }
            evidence = LibreGen1ReceiverReuseProof.readFreshHistory(sourceJson, receiver,
                attemptId, bootstrapId, sessionToken, expectedDartProcessSessionId,
                installedVersionCode, installedLastUpdateTime,
                System.currentTimeMillis(), SystemClock.elapsedRealtimeNanos());
            requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
            final LibreGen1ReceiverReuseProof.FreshHistoryEvidence result = evidence;
            evidence = null;
            return result;
          }
        } finally {
          if (evidence != null) evidence.close();
          if (sourceBytes != null) Arrays.fill(sourceBytes, (byte) 0);
          if (receiver != null) {
            Arrays.fill(receiver.uid, (byte) 0);
            Arrays.fill(receiver.initialPatchInfo, (byte) 0);
          }
        }
      }
    }
  }

  /** Main-thread point-of-use checks; the result is never sent to a UI event/log. */
  private void deliverLibreGen1FreshHistoryEvidence(
      LibreGen1ReceiverReuseProof.FreshHistoryEvidence evidence,
      long expectedEpoch, long expectedGeneration, MethodChannel.Result result) throws Exception {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
        final LibreGen1StreamingJournal journal = LibreGen1StreamingStore.journal(activity);
        synchronized (journal) {
          LibreGen1StreamingJournal.Record receiver = null;
          try {
            if (!receiverReuseRecordPresent()) throw new IOException("Saved receiver is absent.");
            receiver = journal.read();
            if (receiver == null || !receiverReuseRecordPresent()) {
              throw new IOException("Saved receiver is unavailable.");
            }
            requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
            evidence.deliver(receiver, System.currentTimeMillis(), SystemClock.elapsedRealtimeNanos(),
                value -> result.success(value));
          } finally {
            if (receiver != null) {
              Arrays.fill(receiver.uid, (byte) 0);
              Arrays.fill(receiver.initialPatchInfo, (byte) 0);
            }
          }
        }
      }
    }
  }

  private boolean handleLibreReceiverReuseProofMethod(
      String method, Object arguments, MethodChannel.Result result) {
    if (!"readLibreGen1ReceiverReuseProof".equals(method)) return false;
    try {
      final String attemptId = requiredSafeToken(exactStreamingArguments(arguments, 1), "attemptId");
      final long expectedEpoch = captureEpoch;
      final long expectedGeneration;
      synchronized (rfAuthorizationLock) { expectedGeneration = rfAuthorizationGeneration; }
      statusExecutor.execute(() -> {
        try {
          final Map<String, Object> proof = readLibreGen1ReceiverReuseProof(
              attemptId, expectedEpoch, expectedGeneration);
          postResult(() -> {
            try {
              synchronized (captureEpochLock) {
                synchronized (rfAuthorizationLock) {
                  requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
                  result.success(proof);
                }
              }
            } catch (Exception revoked) {
              result.error("libre_receiver_reuse_unavailable", "Saved receiver verification is unavailable.", null);
            }
          });
        } catch (Exception unavailable) {
          postResult(() -> result.error("libre_receiver_reuse_unavailable",
              "Saved receiver verification is unavailable.", null));
        }
      });
    } catch (IllegalArgumentException invalid) {
      result.error("bad_args", "Invalid saved receiver verification request.", null);
    } catch (RejectedExecutionException closed) {
      result.error("capture_closed", "Protocol capture worker is closed.", null);
    }
    return true;
  }

  /** Read-only point proof, not an RF lease or permission to replay streaming enablement. */
  private Map<String, Object> readLibreGen1ReceiverReuseProof(
      String attemptId, long expectedEpoch, long expectedGeneration) throws Exception {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
        byte[] sourceBytes = null;
        LibreGen1StreamingJournal.Record receiver = null;
        try {
          sourceBytes = readActivationUiProofFile(new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE));
          final LibreGen1StreamingJournal journal = LibreGen1StreamingStore.journal(activity);
          synchronized (journal) {
            // Null is returned only for a positively absent receiver. Unknown,
            // corrupt, or unreadable journals must not permit fresh enablement.
            final boolean receiverPresent = receiverReuseRecordPresent();
            receiver = journal.read();
            if (receiverPresent != (receiver != null)
                || receiverPresent != receiverReuseRecordPresent()) {
              throw new IOException("Saved receiver verification is unavailable.");
            }
            final Map<String, Object> proof = LibreGen1ReceiverReuseProof.read(
                new String(sourceBytes, StandardCharsets.UTF_8), receiver, attemptId,
                sessionToken, expectedDartProcessSessionId, installedVersionCode,
                installedLastUpdateTime, System.currentTimeMillis(), SystemClock.elapsedRealtimeNanos());
            requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration);
            return proof;
          }
        } finally {
          if (sourceBytes != null) Arrays.fill(sourceBytes, (byte) 0);
          if (receiver != null) {
            Arrays.fill(receiver.uid, (byte) 0);
            Arrays.fill(receiver.initialPatchInfo, (byte) 0);
          }
        }
      }
    }
  }

  /** Positive ENOENT only; File.exists() alone cannot distinguish a denied path. */
  private boolean receiverReuseRecordPresent() throws Exception {
    final File directory = activity.getNoBackupFilesDir();
    final android.system.StructStat parent = Os.lstat(directory.getAbsolutePath());
    if (!OsConstants.S_ISDIR(parent.st_mode) || parent.st_uid != android.os.Process.myUid()) {
      throw new IOException("Saved receiver storage is unavailable.");
    }
    final android.system.StructStat record;
    try {
      record = Os.lstat(new File(directory, "libre-gen1-streaming-v1.bin").getAbsolutePath());
    } catch (ErrnoException absent) {
      if (absent.errno == OsConstants.ENOENT) return false;
      throw absent;
    }
    if (!OsConstants.S_ISREG(record.st_mode) || record.st_uid != android.os.Process.myUid()
        || (record.st_mode & 0777) != 0600 || record.st_size < 30 || record.st_size > 2048) {
      throw new IOException("Saved receiver storage is unavailable.");
    }
    return true;
  }

  /** Caller holds captureEpochLock then rfAuthorizationLock. No filesystem mutation. */
  private void requireReceiverReuseQueryReadyLocked(long expectedEpoch, long expectedGeneration)
      throws Exception {
    if (expectedEpoch < 1 || expectedEpoch != captureEpoch
        || expectedGeneration != rfAuthorizationGeneration
        || !captureRequested || !resumed || !captureReady || !captureWritable
        || captureDirectory == null || expectedDartProcessSessionId == null
        || explicitNfcSetupAttempt != null || streamingAttempt != null
        || nfcCallbackActive || inFlightNfcV != null || inFlightExplicitNfcSetupAttemptId != null
        || !rfTransactionLeaseBinding.isEmpty() || grantKindForEpoch(expectedEpoch) != GrantKind.NONE) {
      throw new IOException("Saved receiver verification is unavailable.");
    }
    final android.system.StructStat directory = Os.lstat(captureDirectory.getAbsolutePath());
    if (!OsConstants.S_ISDIR(directory.st_mode) || directory.st_uid != android.os.Process.myUid()
        || (directory.st_mode & 0777) != 0700) throw new IOException("Private capture is unavailable.");
    try {
      Os.lstat(new File(captureDirectory, NfcRfTransactionLease.DIRECTORY_NAME).getAbsolutePath());
    } catch (ErrnoException absent) {
      if (absent.errno == OsConstants.ENOENT) return;
      throw absent;
    }
    throw new IOException("NFC owner is busy.");
  }

  private boolean handleLibreActivationUiMethod(
      String method, Object arguments, MethodChannel.Result result) {
    if (!method.equals("readLibre2VerifiedActivation")
        && !method.equals("readLastLibre2ActivationResult")) return false;
    final String attemptId;
    try {
      if (method.equals("readLastLibre2ActivationResult")) {
        if (arguments != null
            && (!(arguments instanceof Map<?, ?>) || !((Map<?, ?>) arguments).isEmpty())) {
          throw new IllegalArgumentException();
        }
        attemptId = null;
      } else {
        attemptId = requiredSafeToken(exactStreamingArguments(arguments, 1), "attemptId");
      }
      statusExecutor.execute(() -> {
        final Map<String, Object> proof = attemptId == null
            ? readLastLibre2ActivationResult() : readLibre2VerifiedActivation(attemptId);
        postResult(() -> result.success(proof));
      });
    } catch (IllegalArgumentException failure) {
      result.error("bad_args", "Invalid activation status request.", null);
    } catch (RejectedExecutionException failure) {
      result.error("capture_closed", "Protocol capture worker is closed.", null);
    }
    return true;
  }

  private Map<String, Object> readLastLibre2ActivationResult() {
    synchronized (captureEpochLock) {
      try {
        final File directory = new File(activity.getFilesDir(), CAPTURE_DIRECTORY);
        final Map<String, Object> journal = Libre2ActivationUiProof.parse(new String(
            readActivationUiProofFile(new File(directory, NFC_GEN1_ACTIVATION_JOURNAL_FILE)),
            StandardCharsets.UTF_8));
        if (!Libre2ActivationUiProof.verified(journal, System.currentTimeMillis())) return null;
        final Map<String, Object> result = new HashMap<>();
        result.put("activation", "verified");
        result.put("lifecycleAtActivation", "warmingUp");
        return result;
      } catch (Exception malformedOrAbsent) { return null; }
    }
  }

  private Map<String, Object> readLibre2VerifiedActivation(String attemptId) {
    synchronized (captureEpochLock) {
      byte[] uid = null;
      byte[] patch = null;
      byte[] fram = null;
      try {
        if (captureDirectory == null || expectedDartProcessSessionId == null) return null;
        final Map<String, Object> journal = Libre2ActivationUiProof.parse(new String(
            readActivationUiProofFile(new File(captureDirectory, NFC_GEN1_ACTIVATION_JOURNAL_FILE)),
            StandardCharsets.UTF_8));
        if (!Libre2ActivationUiProof.verified(journal, System.currentTimeMillis())) return null;
        final byte[] sourceBytes = readActivationUiProofFile(
            new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE));
        final Map<String, Object> source = Libre2ActivationUiProof.parse(
            new String(sourceBytes, StandardCharsets.UTF_8));
        if (!Libre2ActivationUiProof.currentBindings(journal, source, attemptId,
            sessionToken, expectedDartProcessSessionId, installedVersionCode,
            installedLastUpdateTime, sha256Hex(sourceBytes))) return null;
        uid = decodeLowerHex((String) source.get("algorithmOrderUidHex"), 8);
        patch = decodeLowerHex((String) source.get("patchInfoHex"), 6);
        fram = decodeLowerHex((String) source.get("encryptedFramHex"), 344);
        if (uid == null || patch == null || fram == null
            || !"e007".equals(iso15693ManufacturerPrefix(uid))
            || !sha256Hex(uid).equals(source.get("targetUidSha256"))
            || !sha256Hex(patch).equals(journal.get("patchInfoSha256"))
            || !sha256Hex(fram).equals(journal.get("sourceEncryptedFramSha256"))
            || !sha256Hex(LibreGen1Activation.activationRequest(uid)).equals(journal.get("plannedRequestSha256"))
            || LibreGen1Activation.validatedLifecycle(uid, patch, fram)
                != LibreGen1Activation.LIFECYCLE_NOT_ACTIVATED) return null;
        final Map<String, Object> result = new HashMap<>();
        result.put("attemptId", attemptId);
        result.put("event", "activationVerified");
        result.put("model", "libre2");
        result.put("status", "warmingUp");
        return result;
      } catch (Exception malformedOrAbsent) { return null; }
      finally {
        if (uid != null) Arrays.fill(uid, (byte) 0);
        if (patch != null) Arrays.fill(patch, (byte) 0);
        if (fram != null) Arrays.fill(fram, (byte) 0);
      }
    }
  }

  private void publishVerifiedActivationUiForEpoch(long expectedCaptureEpoch) {
    final Map<String, Object> proof;
    synchronized (captureEpochLock) {
      try {
        if (expectedCaptureEpoch != captureEpoch || captureDirectory == null) return;
        final Map<String, Object> source = Libre2ActivationUiProof.parse(new String(
            readActivationUiProofFile(new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE)),
            StandardCharsets.UTF_8));
        final Object attemptId = source.get("explicitAttemptId");
        if (!(attemptId instanceof String)) return;
        proof = readLibre2VerifiedActivation((String) attemptId);
        if (proof == null) return;
      } catch (Exception malformedOrAbsent) { return; }
    }
    mainHandler.post(() -> {
      synchronized (uiEventLock) {
        if (captureEpoch == expectedCaptureEpoch && uiEventSink != null) uiEventSink.success(proof);
      }
    });
  }

  /** Fixed private path, owner-only regular file, no symlinks, bounded descriptor read. */
  private static byte[] readActivationUiProofFile(File file) throws Exception {
    final FileDescriptor descriptor = Os.open(file.getAbsolutePath(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
    try (FileInputStream input = new FileInputStream(descriptor);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
      final android.system.StructStat stat = Os.fstat(descriptor);
      if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != android.os.Process.myUid()
          || (stat.st_mode & 0777) != 0600 || stat.st_size < 1 || stat.st_size > MAX_GRANT_FILE_BYTES) {
        throw new IOException("Invalid private activation proof.");
      }
      final byte[] buffer = new byte[512];
      int count;
      while ((count = input.read(buffer)) != -1) {
        if (bytes.size() + count > MAX_GRANT_FILE_BYTES) throw new IOException("Activation proof size changed.");
        bytes.write(buffer, 0, count);
      }
      return bytes.toByteArray();
    }
  }

  private boolean handleLibreStreamingMethod(
      String method, Object arguments, MethodChannel.Result result) {
    final Set<String> methods = new HashSet<>(Arrays.asList(
        "startLibreGen1Streaming", "stopLibreGen1Streaming", "readLibreGen1StreamingStatus",
        "readLibreGen1StreamingBootstrap", "readLibreGen1CalibrationEvidence",
        "reserveLibreGen1UnlockCount", "markLibreGen1LoginOutcome"));
    if (!methods.contains(method)) return false;
    try {
      statusExecutor.execute(() -> {
        try {
          final LibreGen1StreamingJournal journal = LibreGen1StreamingStore.journal(activity);
          final Object value;
          if (method.equals("readLibreGen1StreamingBootstrap")) {
            requireStreamingReceiverUsable();
            if (arguments != null) throw new IllegalArgumentException();
            final LibreGen1StreamingJournal.Record record = journal.read();
            value = record == null || !record.state.equals("confirmed") ? null : streamingBootstrap(record);
          } else if (method.equals("readLibreGen1CalibrationEvidence")) {
            requireStreamingReceiverUsable();
            final Map<?, ?> args = exactStreamingArguments(arguments, 1);
            final String bootstrapId = requiredSafeToken(args, "bootstrapId");
            value = readMatchedCalibrationEvidence(journal, bootstrapId);
          } else if (method.equals("reserveLibreGen1UnlockCount")) {
            requireStreamingReceiverUsable();
            final Map<?, ?> args = exactStreamingArguments(arguments, 1);
            value = journal.reserve(requiredSafeToken(args, "bootstrapId"));
          } else if (method.equals("markLibreGen1LoginOutcome")) {
            final Map<?, ?> args = exactStreamingArguments(arguments, 3);
            final Object count = args.get("unlockCount");
            if (!(count instanceof Integer) && !(count instanceof Long)) throw new IllegalArgumentException();
            final long numericCount = ((Number) count).longValue();
            if (numericCount < 1 || numericCount > 0xffff) throw new IllegalArgumentException();
            final Object outcome = args.get("outcome");
            if (!(outcome instanceof String)) throw new IllegalArgumentException();
            journal.mark(requiredSafeToken(args, "bootstrapId"), (int) numericCount,
                (String) outcome);
            value = null;
          } else {
            final Map<?, ?> args = exactStreamingArguments(arguments, 1);
            final String attemptId = requiredSafeToken(args, "attemptId");
            if (method.equals("startLibreGen1Streaming")) {
              startStreamingAttempt(attemptId, journal);
              value = null;
            } else if (method.equals("stopLibreGen1Streaming")) {
              stopStreamingAttempt(attemptId, "cancelled");
              value = null;
            } else {
              synchronized (rfAuthorizationLock) {
                value = lastStreamingStatus != null && attemptId.equals(lastStreamingStatus.get("attemptId"))
                    ? new HashMap<>(lastStreamingStatus) : null;
              }
            }
          }
          postResult(() -> result.success(value));
        } catch (Exception failure) {
          postResult(() -> result.error("libre_streaming_unavailable",
              "Libre streaming setup could not complete.", null));
        }
      });
    } catch (RejectedExecutionException failure) {
      result.error("capture_closed", "Protocol capture worker is closed.", null);
    }
    return true;
  }

  private static Map<?, ?> exactStreamingArguments(Object arguments, int length) {
    if (!(arguments instanceof Map<?, ?>) || ((Map<?, ?>) arguments).size() != length) {
      throw new IllegalArgumentException("Invalid streaming arguments.");
    }
    return (Map<?, ?>) arguments;
  }

  private void requireStreamingReceiverUsable() throws IOException {
    synchronized (rfAuthorizationLock) {
      if (!captureReady || !captureWritable || streamingAttempt != null
          || !rfTransactionLeaseBinding.isEmpty()
          || (captureDirectory != null && new File(captureDirectory,
              NfcRfTransactionLease.DIRECTORY_NAME).exists())) {
        throw new IOException("Streaming receiver is not available.");
      }
    }
  }

  private static Map<String, Object> streamingBootstrap(LibreGen1StreamingJournal.Record record) {
    final Map<String, Object> value = new HashMap<>();
    value.put("bootstrapId", record.bootstrapId);
    value.put("deviceId", record.deviceId);
    value.put("uid", record.uid.clone());
    value.put("initialPatchInfo", record.initialPatchInfo.clone());
    value.put("streamingBase", record.streamingBase);
    value.put("lifecycle", LibreGen1Activation.closedLifecycleName(record.lifecycle));
    return value;
  }

  /** No RF, receiver mutation, counter reservation, event publication, or query-time cache write. */
  private Map<String, Object> readMatchedCalibrationEvidence(
      LibreGen1StreamingJournal journal, String bootstrapId) {
    synchronized (journal) {
      LibreGen1StreamingJournal.Record record = null;
      byte[] encoded = null;
      LibreGen1CalibrationEvidence evidence = null;
      try {
        record = journal.read();
        if (record == null || !record.state.equals("confirmed")
            || !record.bootstrapId.equals(bootstrapId)) return null;
        encoded = new LibreGen1CalibrationStore(activity).read();
        if (encoded != null) {
          evidence = LibreGen1CalibrationEvidence.decode(
              encoded, bootstrapId, record.uid, record.initialPatchInfo);
        } else {
          // This fixed source is optional and may be deleted by recorder
          // restarts. Never search traces or import host files to replace it.
          encoded = readActivationUiProofFile(new File(
              new File(activity.getFilesDir(), CAPTURE_DIRECTORY), NFC_GEN1_FRAM_CAPTURE_FILE));
          evidence = LibreGen1CalibrationEvidence.fromCapture(
              new String(encoded, StandardCharsets.UTF_8), bootstrapId, record.uid, record.initialPatchInfo);
        }
        final Map<String, Object> value = new HashMap<>();
        value.put("bootstrapId", evidence.bootstrapId);
        value.put("uid", evidence.uid());
        value.put("receiverInitialPatchInfo", evidence.receiverInitialPatchInfo());
        value.put("calibrationPatchInfo", evidence.calibrationPatchInfo());
        value.put("encryptedFram", evidence.encryptedFram());
        return value;
      } catch (Exception unavailable) {
        return null;
      } finally {
        if (encoded != null) Arrays.fill(encoded, (byte) 0);
        if (evidence != null) evidence.close();
        if (record != null) {
          Arrays.fill(record.uid, (byte) 0);
          Arrays.fill(record.initialPatchInfo, (byte) 0);
        }
      }
    }
  }

  /** Saves only a successful explicit read of the already confirmed receiver. */
  private LibreGen1CalibrationPersistence.Result preserveMatchedCalibrationEvidence(long expectedEpoch, byte[] uid,
      byte[] patchResponse, byte[] fram) {
    if (patchResponse == null || patchResponse.length != 7) {
      return LibreGen1CalibrationPersistence.Result.INVALID_EVIDENCE;
    }
    final byte[] patch = Arrays.copyOfRange(patchResponse, 1, 7);
    try {
      synchronized (captureEpochLock) {
        synchronized (rfAuthorizationLock) {
          if (expectedEpoch != captureEpoch || !captureReady || !captureWritable
              || !rfTransactionLeaseBinding.isEmpty() || streamingAttempt != null) {
            return LibreGen1CalibrationPersistence.Result.CAPTURE_UNAVAILABLE;
          }
          final LibreGen1StreamingJournal journal = LibreGen1StreamingStore.journal(activity);
          synchronized (journal) {
            final LibreGen1StreamingJournal.Record record = journal.read();
            try {
              return LibreGen1CalibrationPersistence.preserve(
                  record, uid, patch, fram,
                  evidence -> new LibreGen1CalibrationStore(activity).writeVerified(evidence));
            } finally {
              if (record != null) {
                Arrays.fill(record.uid, (byte) 0);
                Arrays.fill(record.initialPatchInfo, (byte) 0);
              }
            }
          }
        }
      }
    } catch (Exception unavailable) {
      return LibreGen1CalibrationPersistence.Result.RECEIVER_READ_FAILED;
    } finally { Arrays.fill(patch, (byte) 0); }
  }

  private void recordCalibrationCacheResultAfterUi(
      long expectedEpoch, LibreGen1CalibrationPersistence.Result result) {
    // publishExplicitUiEventForEpoch already queued the original NFC result.
    // Queue behind that delivery before dispatching file I/O: a diagnostic
    // trace failure must not suppress the successfully completed read UI.
    mainHandler.post(() -> {
      try {
        statusExecutor.execute(() -> {
          final JSONObject data = new JSONObject();
          put(data, "outcome", result.outcome);
          put(data, "reason", result.reason);
          appendEventForEpoch(expectedEpoch, "nfc.calibration.cache", data);
        });
      } catch (RejectedExecutionException closed) {
        // Recorder closed. Never retry or change the completed sensor result.
      }
    });
  }

  private void startStreamingAttempt(String attemptId, LibreGen1StreamingJournal journal) throws Exception {
    final long epoch = captureEpoch;
    final NfcRfTransactionLease maintenance = beginAuthorizationMutationLease(epoch);
    if (maintenance == null) throw new IOException("NFC owner is busy.");
    try {
      synchronized (captureEpochLock) {
        synchronized (rfAuthorizationLock) {
          if (!isCaptureReadyForRfLocked() || epoch != captureEpoch || streamingAttempt != null
              || explicitNfcSetupAttempt != null || nfcCallbackActive || inFlightNfcV != null
              || grantKindForEpoch(epoch) != GrantKind.NONE) throw new IOException("NFC is not ready.");
          final JSONObject source = new JSONObject(new String(readSmallFile(
              new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE)), StandardCharsets.UTF_8));
          final Long schema = strictJsonInteger(source, "schemaVersion");
          final Long observed = strictJsonInteger(source, "observedAtMonotonicElapsedNanos");
          final Long version = strictJsonInteger(source, "versionCode");
          final Long updated = strictJsonInteger(source, "lastUpdateTime");
          final long now = SystemClock.elapsedRealtimeNanos();
          final String observedUtc = strictJsonString(source, "observedAtUtc");
          final long observedWall = observedUtc == null ? -1 : Instant.parse(observedUtc).toEpochMilli();
          final long wallAge = System.currentTimeMillis() - observedWall;
          if (schema == null || !((schema == 1 && source.length() == 16)
                  || (schema == 2 && source.length() == 18
                      && "explicitLibre2Lifecycle".equals(strictJsonString(source, "sourceKind"))
                      && strictJsonString(source, "explicitAttemptId") != null))
              || !sessionToken.equals(strictJsonString(source, "nativeCaptureSessionId"))
              || !expectedDartProcessSessionId.equals(strictJsonString(source, "processSessionId"))
              || version == null || version != installedVersionCode || updated == null || updated != installedLastUpdateTime
              || !"libre2".equals(strictJsonString(source, "model"))
              || !"gen1".equals(strictJsonString(source, "securityGeneration"))
              || !"e007".equals(strictJsonString(source, "iso15693ManufacturerPrefix"))
              || observed == null || now < observed || now - observed > 120_000_000_000L
              || wallAge < -MAX_CLOCK_SKEW_MILLIS || wallAge > MAX_STANDARD_GRANT_LIFETIME_MILLIS) {
            throw new IOException("Fresh verified sensor evidence is required.");
          }
          final byte[] uid = decodeLowerHex(strictJsonString(source, "algorithmOrderUidHex"), 8);
          final byte[] patch = decodeLowerHex(strictJsonString(source, "patchInfoHex"), 6);
          final byte[] fram = decodeLowerHex(strictJsonString(source, "encryptedFramHex"), 344);
          try {
            if (uid == null || patch == null || fram == null
                || !"e007".equals(iso15693ManufacturerPrefix(uid))
                || !sha256Hex(uid).equals(strictJsonString(source, "targetUidSha256"))
                || !sha256Hex(patch).equals(strictJsonString(source, "patchInfoSha256"))) {
              throw new IOException("Sensor evidence binding failed.");
            }
            final int lifecycle = LibreGen1Activation.validatedLifecycle(uid, patch, fram);
            LibreGen1Streaming.requireLifecycle(lifecycle);
            // Leave room for the full uint16 login counter without uint32 overflow.
            final long base = new java.security.SecureRandom().nextInt() & 0x7fffffffL;
            final LibreGen1StreamingJournal.Record record = journal.prepare(uid, patch, base, lifecycle);
            streamingAttempt = new StreamingAttempt(attemptId, epoch, rfAuthorizationGeneration,
                expectedDartProcessSessionId, now + 90_000_000_000L, record);
            publishStreamingStatus(streamingAttempt, "listening", null, null);
          } finally {
            if (uid != null) Arrays.fill(uid, (byte) 0);
            if (patch != null) Arrays.fill(patch, (byte) 0);
            if (fram != null) Arrays.fill(fram, (byte) 0);
          }
        }
      }
    } finally { finishAuthorizationMutationLease(maintenance); }
    final StreamingAttempt scheduled;
    synchronized (rfAuthorizationLock) { scheduled = streamingAttempt; }
    mainHandler.postDelayed(() -> {
      try { statusExecutor.execute(() -> {
        synchronized (rfAuthorizationLock) {
          if (streamingAttempt != scheduled) return;
          try { stopStreamingAttempt(attemptId, "expired"); }
          catch (IOException ignored) { /* In-flight cleanup publishes the terminal result. */ }
        }
      }); }
      catch (RejectedExecutionException ignored) { /* Process closure revokes RF. */ }
    }, 90_000L);
  }

  private void stopStreamingAttempt(String attemptId, String reason) throws IOException {
    synchronized (rfAuthorizationLock) {
      final StreamingAttempt attempt = streamingAttempt;
      if (attempt == null || !attempt.attemptId.equals(attemptId)) return;
      attempt.cancelled = true;
      if (attempt.claimed) {
        closeNfcVQuietly(inFlightNfcV);
        throw new IOException("Streaming contact cleanup is still pending.");
      }
      try { LibreGen1StreamingStore.journal(activity).abortPrepared(attempt.record.bootstrapId); }
      catch (Exception failure) { throw new IOException("Streaming cancellation could not be confirmed."); }
      streamingAttempt = null;
      publishStreamingStatus(attempt, "failed", reason, null);
    }
  }

  private void publishStreamingStatus(StreamingAttempt attempt, String event, String reason, String lifecycle) {
    final Map<String, Object> value = new HashMap<>();
    value.put("operation", "libreGen1Streaming");
    value.put("attemptId", attempt.attemptId);
    value.put("event", event);
    if (reason != null) value.put("reason", reason);
    if (lifecycle != null) value.put("lifecycle", lifecycle);
    synchronized (rfAuthorizationLock) { lastStreamingStatus = value; }
    mainHandler.post(() -> {
      synchronized (uiEventLock) {
        if (uiEventSink != null) uiEventSink.success(value);
      }
    });
  }

  private void captureStreamingTag(Tag tag, StreamingAttempt attempt) {
    final NfcV nfcV = NfcV.get(tag);
    final NfcRfTransactionLease lease = beginHostRfTransactionLease(attempt.epoch, GrantKind.NONE);
    if (lease == null) return;
    boolean intent = false;
    boolean confirmed = false;
    LibreGen1StreamingCalibration calibration = null;
    byte[] enableResponse = null;
    int observedLifecycle = -1;
    boolean reserved = false;
    String failureReason = "readFailed";
    final List<JSONObject> exchanges = new ArrayList<>();
    try {
      synchronized (rfAuthorizationLock) {
        if (nfcV == null || streamingAttempt != attempt || attempt.claimed
            || !Arrays.equals(tag.getId(), attempt.record.uid)) throw new IOException("Streaming target changed.");
        attempt.claimed = true;
        attempt.transport = nfcV;
        attempt.lease = lease;
        inFlightNfcV = nfcV;
      }
      reserved = reserveGen1FramTransactionTrace(attempt.epoch, nfcV);
      if (!reserved) throw new IOException("Streaming trace unavailable.");
      requireStreamingAuthorized(attempt, nfcV, lease);
      publishStreamingStatus(attempt, "tagDetected", null, null);
      nfcV.connect();
      publishStreamingStatus(attempt, "readingMetadata", null, null);
      final byte[] patchResponse = transceiveStreamingAuthorized(attempt, nfcV, lease,
          new byte[] {0x02, (byte) 0xa1, 0x07}, exchanges);
      final PatchInfoClassification classification = classifyPatchInfo(patchResponse);
      if (classification == null || !"libre2".equals(classification.model)
          || !"gen1".equals(classification.securityGeneration)
          || !Arrays.equals(Arrays.copyOfRange(patchResponse, 1, patchResponse.length), attempt.record.initialPatchInfo)) {
        throw new IOException("Streaming patch changed.");
      }
      final List<byte[]> payloads = new ArrayList<>();
      for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
        payloads.add(frame.payloadFromResponse(transceiveStreamingAuthorized(
            attempt, nfcV, lease, frame.request(), exchanges)));
      }
      final byte[] fram = LibreGen1NfcFrames.concatenatePayloads(payloads);
      final byte[] currentPatch = Arrays.copyOfRange(patchResponse, 1, patchResponse.length);
      final int lifecycle;
      try {
        calibration = LibreGen1StreamingCalibration.fromRead(attempt.record, currentPatch, fram);
        lifecycle = calibration.lifecycle();
      }
      finally {
        Arrays.fill(currentPatch, (byte) 0);
        Arrays.fill(fram, (byte) 0);
        for (byte[] payload : payloads) Arrays.fill(payload, (byte) 0);
      }
      attempt.sequence.verifyLifecycle(lifecycle);
      observedLifecycle = lifecycle;
      requireStreamingAuthorized(attempt, nfcV, lease);
      intent = true;
      LibreGen1StreamingStore.journal(activity).commitIntent(attempt.record.bootstrapId);
      publishStreamingStatus(attempt, "enablingStreaming", null, null);
      enableResponse = transceiveStreamingAuthorized(attempt, nfcV, lease,
          LibreGen1Streaming.request(attempt.record.uid, attempt.record.initialPatchInfo,
              attempt.record.streamingBase), exchanges);
      requireStreamingAuthorized(attempt, nfcV, lease);
      LibreGen1Streaming.deviceId(enableResponse);
    } catch (TagLostException failure) {
      failureReason = intent ? "outcomeUnknown" : "tagMoved";
    } catch (Exception failure) {
      failureReason = intent ? "outcomeUnknown" : "readFailed";
    } finally {
      try {
      final boolean closed = closeNfcVQuietly(nfcV) && !attempt.closeUncertain;
      if (closed) endRfOperation(nfcV);
      boolean audited = reserved;
      for (JSONObject exchange : exchanges) {
        audited &= appendReservedEventForEpoch(attempt.epoch, "nfc.gen1_streaming.exchange", exchange);
      }
      final JSONObject terminal = new JSONObject();
      put(terminal, "attemptId", attempt.attemptId);
      put(terminal, "transportClosed", closed);
      put(terminal, "outcome", enableResponse != null ? "response_received" : intent ? "unknown_outcome" : "not_sent");
      audited &= appendReservedEventForEpoch(attempt.epoch, "nfc.gen1_streaming.closed", terminal);
      final boolean terminalReady = LibreGen1Streaming.completeTransport(
          closed, audited, () -> finishStreamingRfLease(lease));
      if (!terminalReady) {
        synchronized (rfAuthorizationLock) { quarantinedStreamingLease = lease; }
        captureWritable = false;
        captureReady = false;
      }
      if (terminalReady && enableResponse != null && !attempt.cancelled) {
        try {
          synchronized (captureEpochLock) {
            synchronized (rfAuthorizationLock) {
              if (streamingAttempt != attempt || attempt.cancelled || attempt.closeUncertain
                  || SystemClock.elapsedRealtimeNanos() >= attempt.expiresAtNanos
                  || captureEpoch != attempt.epoch
                  || rfAuthorizationGeneration != attempt.generation
                  || !isCaptureReadyForRfLocked() || !rfTransactionLeaseBinding.isEmpty()) {
                throw new IOException("Streaming completion authorization changed.");
              }
              LibreGen1StreamingStore.journal(activity).confirm(
                  attempt.record.bootstrapId, enableResponse, observedLifecycle, terminalReady);
              confirmed = true;
            }
          }
        } catch (Exception failure) { failureReason = "outcomeUnknown"; }
      }
      if (!intent && terminalReady) {
        try { LibreGen1StreamingStore.journal(activity).abortPrepared(attempt.record.bootstrapId); }
        catch (Exception ignored) { audited = false; }
      }
      if (!audited) invalidateCaptureStatusForEpoch(attempt.epoch);
      if (terminalReady) releaseNfcTransactionTrace(attempt.epoch);
      synchronized (rfAuthorizationLock) { if (streamingAttempt == attempt) streamingAttempt = null; }
      if (confirmed && audited && captureWritable && captureReady) {
        final LibreGen1CalibrationPersistence.Result cacheResult =
            preserveStreamingCalibration(attempt, calibration, terminalReady);
        publishStreamingStatus(attempt, "streamingEnabled", null,
            LibreGen1Activation.closedLifecycleName(observedLifecycle));
        recordCalibrationCacheResultAfterUi(attempt.epoch, cacheResult);
      } else {
        publishStreamingStatus(attempt, "failed", intent ? "outcomeUnknown" : failureReason, null);
      }
      } finally {
        if (calibration != null) calibration.close();
        if (enableResponse != null) Arrays.fill(enableResponse, (byte) 0);
      }
    }
  }

  /** No sensor command, journal mutation, counter reservation, or volatile-file fallback. */
  private LibreGen1CalibrationPersistence.Result preserveStreamingCalibration(
      StreamingAttempt attempt, LibreGen1StreamingCalibration calibration, boolean terminalReady) {
    if (calibration == null) return LibreGen1CalibrationPersistence.Result.INVALID_EVIDENCE;
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (!terminalReady || attempt.cancelled || attempt.closeUncertain
            || captureEpoch != attempt.epoch || rfAuthorizationGeneration != attempt.generation
            || !attempt.processSessionId.equals(expectedDartProcessSessionId)
            || !isCaptureReadyForRfLocked() || streamingAttempt != null
            || !rfTransactionLeaseBinding.isEmpty() || quarantinedStreamingLease != null) {
          return LibreGen1CalibrationPersistence.Result.CAPTURE_UNAVAILABLE;
        }
        final LibreGen1StreamingJournal journal = LibreGen1StreamingStore.journal(activity);
        synchronized (journal) {
          LibreGen1StreamingJournal.Record confirmed = null;
          try {
            confirmed = journal.read();
            return calibration.preserveAfterConfirmation(confirmed, terminalReady,
                evidence -> new LibreGen1CalibrationStore(activity).writeVerified(evidence));
          } catch (Exception unavailable) {
            return LibreGen1CalibrationPersistence.Result.RECEIVER_READ_FAILED;
          } finally {
            if (confirmed != null) {
              Arrays.fill(confirmed.uid, (byte) 0);
              Arrays.fill(confirmed.initialPatchInfo, (byte) 0);
            }
          }
        }
      }
    }
  }

  private boolean finishStreamingRfLease(NfcRfTransactionLease lease) {
    synchronized (rfAuthorizationLock) {
      if (streamingAttempt == null || streamingAttempt.lease != lease
          || streamingAttempt.closeUncertain || streamingAttempt.cancelled
          || quarantinedStreamingLease == lease
          || !rfTransactionLeaseBinding.isHeldByHost(lease) || activeHostRfTransactionLease != lease
          || !lease.release()) return false;
      final NfcRfTransactionLease released = rfTransactionLeaseBinding.takeHost(lease);
      if (released != lease) return false;
      activeHostRfTransactionLease = null;
      return true;
    }
  }

  private void requireStreamingAuthorized(StreamingAttempt attempt, NfcV nfcV, NfcRfTransactionLease lease)
      throws IOException {
    synchronized (captureEpochLock) {
    synchronized (rfAuthorizationLock) {
      if (streamingAttempt != attempt || attempt.cancelled || !attempt.claimed
          || attempt.epoch != captureEpoch || attempt.generation != rfAuthorizationGeneration
          || !attempt.processSessionId.equals(expectedDartProcessSessionId)
          || !isCaptureReadyForRfLocked() || !rfTransactionLeaseBinding.isHeldByHost(lease)
          || inFlightNfcV != nfcV || !Arrays.equals(nfcV.getTag().getId(), attempt.record.uid)
          || SystemClock.elapsedRealtimeNanos() >= attempt.expiresAtNanos
          || grantKindForEpoch(attempt.epoch) != GrantKind.NONE) {
        throw new IOException("Streaming authorization changed.");
      }
    }
    }
  }

  private byte[] transceiveStreamingAuthorized(StreamingAttempt attempt, NfcV nfcV,
      NfcRfTransactionLease lease, byte[] request, List<JSONObject> exchanges) throws IOException {
    synchronized (captureEpochLock) {
    synchronized (rfAuthorizationLock) {
      requireStreamingAuthorized(attempt, nfcV, lease);
      if (!attempt.sequence.consume(request)) throw new IOException("Streaming send sequence changed.");
      final JSONObject exchange = new JSONObject();
      put(exchange, "frameIndex", exchanges.size());
      put(exchange, "requestHex", hex(request));
      exchanges.add(exchange);
      final byte[] response = nfcV.transceive(request);
      put(exchange, "responseHex", hex(response));
      return response;
    }
    }
  }

  private static final class StreamingAttempt {
    final String attemptId;
    final long epoch;
    final long generation;
    final String processSessionId;
    final long expiresAtNanos;
    final LibreGen1StreamingJournal.Record record;
    final LibreGen1Streaming.Sequence sequence;
    boolean claimed;
    boolean cancelled;
    volatile boolean closeUncertain;
    NfcV transport;
    NfcRfTransactionLease lease;

    StreamingAttempt(String id, long epoch, long generation, String processSessionId,
        long expiresAtNanos, LibreGen1StreamingJournal.Record record) {
      this.attemptId = id;
      this.epoch = epoch;
      this.generation = generation;
      this.processSessionId = processSessionId;
      this.expiresAtNanos = expiresAtNanos;
      this.record = record;
      sequence = new LibreGen1Streaming.Sequence(LibreGen1Streaming.request(
          record.uid, record.initialPatchInfo, record.streamingBase));
    }
  }

  private void activateGen1Once(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      byte[] targetUid,
      String targetUidSha256,
      String manufacturerPrefix,
      byte[] patchInfoCommand,
      NfcV nfcV,
      NfcRfTransactionLease hostLease) {
    if (!reserveGen1ActivationTransactionTrace(expectedCaptureEpoch, nfcV)) {
      appendEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_activation.skipped.insufficient_trace_capacity",
          new JSONObject());
      invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    final ActivationGrant grant =
        consumeValidatedActivationGrant(
            expectedCaptureEpoch,
            targetUid,
            targetUidSha256,
            manufacturerPrefix,
            hostLease);
    if (grant == null) {
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_activation.skipped.no_valid_grant",
          new JSONObject());
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    final JSONObject authorization = new JSONObject();
    put(authorization, "operation", TARGET_UNVERIFIED_GEN1_ACTIVATION_OPERATION);
    put(authorization, "captureSessionId", grant.captureSessionId);
    put(authorization, "attemptId", grant.attemptId);
    put(authorization, "expiresAtEpochMillis", grant.expiresAtEpochMillis);
    if (!appendReservedEventForEpoch(
        expectedCaptureEpoch,
        "nfc.gen1_activation.authorization.consumed",
        authorization)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }
    if (!beginActivationRfOperation(
        expectedCaptureEpoch,
        authorizationGeneration,
        grant,
        nfcV,
        hostLease)) {
      releaseNfcTransactionTrace(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
      return;
    }

    boolean transmitIntentCommitted = false;
    boolean postStateVerified = false;
    try {
      requireActivationAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease);
      nfcV.connect();
      if (nfcV.getMaxTransceiveLength()
          < LibreGen1NfcFrames.MAX_RESPONSE_BYTES) {
        throw new IOException("NFC transport capacity changed.");
      }
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.connection.ready",
          closedActivationEvent(grant, "connected", null));
      publishUiEventForEpoch(
          expectedCaptureEpoch, "readingMetadata", "libre2", null, null);

      final byte[] patchInfoResponse =
          transceiveActivationPatchInfo(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              patchInfoCommand,
              nfcV,
              hostLease,
              "pre_activation");
      final PatchInfoClassification classification =
          classifyPatchInfo(patchInfoResponse);
      if (classification == null
          || !"libre2".equals(classification.model)
          || !"gen1".equals(classification.securityGeneration)
          || !sha256PatchInfoPayload(patchInfoResponse)
              .equals(grant.patchInfoSha256)) {
        throw new IOException("Patch evidence changed before activation.");
      }
      final byte[] patchInfoPayload =
          Arrays.copyOfRange(patchInfoResponse, 1, patchInfoResponse.length);
      final byte[] preActivationFram =
          readGen1ActivationFram(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              nfcV,
              hostLease,
              "pre_activation");
      final int preLifecycle =
          LibreGen1Activation.validatedLifecycle(
              targetUid, patchInfoPayload, preActivationFram);
      if (preLifecycle != LibreGen1Activation.LIFECYCLE_NOT_ACTIVATED) {
        throw new IOException("Current lifecycle does not authorize activation.");
      }
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.pre_state_verified",
          closedActivationEvent(grant, "pre_state_verified", "notActivated"));

      final byte[] activationRequest =
          LibreGen1Activation.activationRequest(targetUid);
      if (!grant.plannedRequestSha256.equals(sha256Hex(activationRequest))) {
        throw new IOException("Activation plan changed at point of use.");
      }
      requireActivationAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease);
      if (!persistActivationJournalForEpoch(
          expectedCaptureEpoch,
          grant,
          "transmit_intent_committed",
          "unknown_outcome",
          "notActivated",
          hostLease)) {
        throw new IOException("Could not commit activation intent.");
      }
      transmitIntentCommitted = true;
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.transmit_intent_committed",
          closedActivationEvent(grant, "transmit_intent_committed", null));
      requireActivationAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease);

      // Exactly one state-changing frame. There is deliberately no retry,
      // fallback, addressed variant, or second write.
      final byte[] activationResponse =
          transceiveActivationAuthorized(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              nfcV,
              hostLease,
              activationRequest);
      LibreGen1Activation.requireActivationResponseShape(activationResponse);
      if (!persistActivationJournalForEpoch(
          expectedCaptureEpoch,
          grant,
          "response_received",
          "unknown_outcome",
          null,
          hostLease)) {
        throw new IOException("Could not journal activation response.");
      }
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.response_received",
          closedActivationEvent(grant, "response_received", null));

      final byte[] postPatchInfoResponse =
          transceiveActivationPatchInfo(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              patchInfoCommand,
              nfcV,
              hostLease,
              "post_activation");
      final PatchInfoClassification postClassification =
          classifyPatchInfo(postPatchInfoResponse);
      if (postClassification == null
          || !"libre2".equals(postClassification.model)
          || !"gen1".equals(postClassification.securityGeneration)
          || !sha256PatchInfoPayload(postPatchInfoResponse)
              .equals(grant.patchInfoSha256)) {
        throw new IOException("Patch evidence changed after activation.");
      }
      final byte[] postPatchInfoPayload =
          Arrays.copyOfRange(
              postPatchInfoResponse, 1, postPatchInfoResponse.length);
      final byte[] postActivationFram =
          readGen1ActivationFram(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              nfcV,
              hostLease,
              "post_activation");
      final int postLifecycle =
          LibreGen1Activation.validatedLifecycle(
              targetUid, postPatchInfoPayload, postActivationFram);
      if (postLifecycle != LibreGen1Activation.LIFECYCLE_WARMING_UP) {
        throw new IOException("Activation did not prove warming-up state.");
      }
      if (!persistActivationJournalForEpoch(
          expectedCaptureEpoch,
          grant,
          "post_state_verified",
          "verified",
          "warmingUp",
          hostLease)) {
        throw new IOException("Could not commit activation proof.");
      }
      postStateVerified = true;
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.post_state_verified",
          closedActivationEvent(grant, "post_state_verified", "warmingUp"));
      publishVerifiedActivationUiForEpoch(expectedCaptureEpoch);
      publishUiEventForEpoch(
          expectedCaptureEpoch,
          "metadataRead",
          "libre2",
          "warmingUp",
          null);
    } catch (TagLostException error) {
      if (transmitIntentCommitted && !postStateVerified) {
        persistActivationJournalForEpoch(
            expectedCaptureEpoch,
            grant,
            "unknown_outcome",
            "unknown_outcome",
            null,
            hostLease);
      }
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_activation.failure.tag_lost",
          closedActivationEvent(grant, "failed", null));
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "tagMoved");
    } catch (IOException | IllegalArgumentException error) {
      if (transmitIntentCommitted && !postStateVerified) {
        persistActivationJournalForEpoch(
            expectedCaptureEpoch,
            grant,
            "unknown_outcome",
            "unknown_outcome",
            null,
            hostLease);
      }
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_activation.failure.closed",
          closedActivationEvent(grant, "failed", null));
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    } catch (RuntimeException error) {
      if (transmitIntentCommitted && !postStateVerified) {
        persistActivationJournalForEpoch(
            expectedCaptureEpoch,
            grant,
            "unknown_outcome",
            "unknown_outcome",
            null,
            hostLease);
      }
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_activation.failure.closed",
          closedActivationEvent(grant, "failed", null));
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    } finally {
      endRfOperation(nfcV);
      closeNfcVQuietly(nfcV);
      appendReservedEventForEpoch(
          expectedCaptureEpoch,
          "nfc.gen1_activation.connection.closed",
          closedActivationEvent(grant, "closed", null));
      releaseNfcTransactionTrace(expectedCaptureEpoch);
    }
  }

  private byte[] transceiveActivationPatchInfo(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      ActivationGrant grant,
      byte[] patchInfoCommand,
      NfcV nfcV,
      NfcRfTransactionLease hostLease,
      String phase)
      throws IOException {
    requireActivationAuthorized(
        expectedCaptureEpoch,
        authorizationGeneration,
        grant,
        hostLease);
    requireActivationTrace(
        expectedCaptureEpoch,
        "nfc.gen1_activation.patch_info.request",
        closedActivationEvent(grant, phase, null));
    final byte[] response =
        transceiveActivationAuthorized(
            expectedCaptureEpoch,
            authorizationGeneration,
            grant,
            nfcV,
            hostLease,
            patchInfoCommand);
    requireActivationAuthorized(
        expectedCaptureEpoch,
        authorizationGeneration,
        grant,
        hostLease);
    requireActivationTrace(
        expectedCaptureEpoch,
        "nfc.gen1_activation.patch_info.response",
        closedActivationEvent(grant, phase, null));
    return response;
  }

  private byte[] readGen1ActivationFram(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      ActivationGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease,
      String phase)
      throws IOException {
    final List<byte[]> payloads = new ArrayList<>();
    int frameIndex = 0;
    for (LibreGen1NfcFrames.Frame frame : LibreGen1NfcFrames.frames()) {
      requireActivationAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease);
      final JSONObject request = closedActivationEvent(grant, phase, null);
      put(request, "frameIndex", frameIndex);
      put(request, "startBlock", frame.startBlock());
      put(request, "blockCount", frame.blockCount());
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.fram.request",
          request);
      final byte[] response =
          transceiveActivationAuthorized(
              expectedCaptureEpoch,
              authorizationGeneration,
              grant,
              nfcV,
              hostLease,
              frame.request());
      requireActivationAuthorized(
          expectedCaptureEpoch,
          authorizationGeneration,
          grant,
          hostLease);
      payloads.add(frame.payloadFromResponse(response));
      final JSONObject received = closedActivationEvent(grant, phase, null);
      put(received, "frameIndex", frameIndex);
      put(received, "responseLength", response.length);
      requireActivationTrace(
          expectedCaptureEpoch,
          "nfc.gen1_activation.fram.response",
          received);
      frameIndex += 1;
    }
    return LibreGen1NfcFrames.concatenatePayloads(payloads);
  }

  private void requireActivationAuthorized(
      long expectedCaptureEpoch,
      long authorizationGeneration,
      ActivationGrant grant,
      NfcRfTransactionLease hostLease)
      throws IOException {
    if (!isActivationRfAuthorized(
        expectedCaptureEpoch,
        authorizationGeneration,
        grant,
        hostLease)) {
      throw new IOException("Activation authorization expired.");
    }
  }

  private void requireActivationTrace(
      long expectedCaptureEpoch, String type, JSONObject value)
      throws IOException {
    if (!appendReservedEventForEpoch(expectedCaptureEpoch, type, value)) {
      throw new IOException("Activation trace became unavailable.");
    }
  }

  private static JSONObject closedActivationEvent(
      ActivationGrant grant, String step, String lifecycle) {
    final JSONObject value = new JSONObject();
    put(value, "operation", TARGET_UNVERIFIED_GEN1_ACTIVATION_OPERATION);
    put(value, "captureSessionId", grant.captureSessionId);
    put(value, "attemptId", grant.attemptId);
    put(value, "step", step);
    if (lifecycle != null) {
      put(value, "lifecycle", lifecycle);
    }
    return value;
  }

  private void publishMetadataRead(
      long expectedCaptureEpoch,
      byte[] response,
      String targetUidSha256,
      String manufacturerPrefix,
      NfcRfTransactionLease hostLease) {
    publishMetadataRead(
        expectedCaptureEpoch,
        response,
        targetUidSha256,
        manufacturerPrefix,
        hostLease,
        null);
  }

  private void publishMetadataRead(
      long expectedCaptureEpoch,
      byte[] response,
      String targetUidSha256,
      String manufacturerPrefix,
      NfcRfTransactionLease hostLease,
      Libre2NfcSetupAttempt explicitAttempt) {
    final PatchInfoClassification classified =
        recordMetadataRead(
            expectedCaptureEpoch,
            response,
            targetUidSha256,
            manufacturerPrefix,
            hostLease,
            explicitAttempt);
    if (classified == null) {
      publishUiEventForAttemptOrGlobal(
          expectedCaptureEpoch,
          explicitAttempt,
          "failed",
          null,
          null,
          "readFailed");
      return;
    }
    publishUiEventForAttemptOrGlobal(
        expectedCaptureEpoch,
        explicitAttempt,
        "metadataRead",
        classified.model,
        null,
        null);
  }

  private PatchInfoClassification recordMetadataRead(
      long expectedCaptureEpoch,
      byte[] response,
      String targetUidSha256,
      String manufacturerPrefix,
      NfcRfTransactionLease hostLease,
      Libre2NfcSetupAttempt explicitAttempt) {
    // ISO 15693 custom-command responses start with a flags byte. Bit zero
    // reports an error. The known Libre 2-family patch-info payload is six
    // bytes after that flag. Lifecycle state is not encoded here, so this UI
    // event deliberately makes no warmup or active-state claim.
    final PatchInfoClassification classified = classifyPatchInfo(response);
    if (classified == null) {
      return null;
    }
    if ("gen1".equals(classified.securityGeneration)
        && !persistPatchInfoContext(
            expectedCaptureEpoch,
            targetUidSha256,
            manufacturerPrefix,
            classified,
            response,
            hostLease,
            explicitAttempt)) {
      return null;
    }
    final JSONObject classification = new JSONObject();
    put(classification, "model", classified.model);
    put(classification, "securityGeneration", classified.securityGeneration);
    final boolean classificationRecorded =
        explicitAttempt == null
            ? appendReservedEventForEpoch(
                expectedCaptureEpoch,
                "nfc.patch_info.classified",
                classification)
            : appendExplicitReservedEventForEpoch(
                expectedCaptureEpoch,
                explicitAttempt,
                "nfc.patch_info.classified",
                classification);
    if (!classificationRecorded) {
      return null;
    }
    return classified;
  }

  private static PatchInfoClassification classifyPatchInfo(byte[] response) {
    if (response == null || response.length != 7 || (response[0] & 0x01) != 0) {
      return null;
    }
    final int signature =
        ((response[1] & 0xff) << 16)
            | ((response[2] & 0xff) << 8)
            | (response[3] & 0xff);
    final String model;
    switch (signature) {
      case 0x9d0830:
      case 0xc50930:
      case 0x7f0e30:
        model = "libre2";
        break;
      case 0xc60931:
      case 0x7f0e31:
        model = "libre2Plus";
        break;
      default:
        return null;
    }
    final int securityMarker = response[3] & 0xff;
    final int securityFamily = securityMarker >>> 4;
    final int securityVariant = securityMarker & 0x0f;
    final String securityGeneration;
    if (securityFamily == 3) {
      securityGeneration = securityVariant < 9 ? "gen1" : "gen2";
    } else if (securityFamily == 7) {
      securityGeneration = securityVariant < 4 ? "gen1" : "gen2";
    } else {
      return null;
    }
    return new PatchInfoClassification(model, securityGeneration);
  }

  private void publishUiEventForEpoch(
      long expectedCaptureEpoch,
      String event,
      String model,
      String status,
      String reason) {
    publishUiEventForAttemptOrGlobal(
        expectedCaptureEpoch, null, event, model, status, reason);
  }

  private void publishExplicitUiEventForEpoch(
      long expectedCaptureEpoch,
      Libre2NfcSetupAttempt attempt,
      String event,
      String model,
      String status,
      String reason) {
    if (attempt == null) {
      return;
    }
    publishUiEventForAttemptOrGlobal(
        expectedCaptureEpoch, attempt, event, model, status, reason);
  }

  private void publishUiEventForAttemptOrGlobal(
      long expectedCaptureEpoch,
      Libre2NfcSetupAttempt explicitAttempt,
      String event,
      String model,
      String status,
      String reason) {
    cancelPendingPassiveUiReset();
    final long expectedListenerGeneration;
    synchronized (uiEventLock) {
      expectedListenerGeneration = uiListenerGeneration;
    }
    final String attemptId =
        explicitAttempt == null ? null : explicitAttempt.scanAttemptId();
    final boolean allowInactiveExplicitTerminal =
        attemptId != null && "failed".equals(event);
    mainHandler.post(
        () ->
            deliverUiEventForEpoch(
                expectedCaptureEpoch,
                expectedListenerGeneration,
                !"failed".equals(event),
                allowInactiveExplicitTerminal,
                attemptId,
                event,
                model,
                status,
                reason));
  }

  private void publishUiEventDelayedForEpoch(
      long expectedCaptureEpoch,
      long delayMillis,
      String event,
      String model,
      String status,
      String reason) {
    final long expectedListenerGeneration;
    synchronized (uiEventLock) {
      expectedListenerGeneration = uiListenerGeneration;
    }
    final class PassiveUiReset implements Runnable {
      @Override
      public void run() {
        synchronized (uiEventLock) {
          if (pendingPassiveUiReset != this) {
            return;
          }
          pendingPassiveUiReset = null;
        }
        deliverUiEventForEpoch(
            expectedCaptureEpoch,
            expectedListenerGeneration,
            true,
            false,
            null,
            event,
            model,
            status,
            reason);
      }
    }
    final Runnable reset = new PassiveUiReset();
    synchronized (uiEventLock) {
      pendingPassiveUiReset = reset;
    }
    mainHandler.postDelayed(reset, delayMillis);
  }

  private void deliverUiEventForEpoch(
      long expectedCaptureEpoch,
      long expectedListenerGeneration,
      boolean requireHealthyCapture,
      boolean allowInactiveExplicitTerminal,
      String attemptId,
      String event,
      String model,
      String status,
      String reason) {
    final Map<String, Object> value = new HashMap<>();
    value.put("event", event);
    if (attemptId != null) {
      value.put("attemptId", attemptId);
    }
    if (model != null) {
      value.put("model", model);
    }
    if (status != null) {
      value.put("status", status);
    }
    if (reason != null) {
      value.put("reason", reason);
    }
    if (!isUiCaptureCurrent(
        expectedCaptureEpoch,
        requireHealthyCapture,
        allowInactiveExplicitTerminal)) {
      return;
    }
    synchronized (uiEventLock) {
      if (uiListenerGeneration != expectedListenerGeneration
          || uiEventSink == null) {
        return;
      }
      uiEventSink.success(value);
    }
  }

  private void cancelPendingPassiveUiReset() {
    final Runnable reset;
    synchronized (uiEventLock) {
      reset = pendingPassiveUiReset;
      pendingPassiveUiReset = null;
    }
    if (reset != null) {
      mainHandler.removeCallbacks(reset);
    }
  }

  private boolean isUiCaptureCurrent(
      long expectedCaptureEpoch,
      boolean requireHealthyCapture,
      boolean allowInactiveExplicitTerminal) {
    synchronized (rfAuthorizationLock) {
      return expectedCaptureEpoch == captureEpoch
          && (allowInactiveExplicitTerminal
              || (captureRequested
                  && resumed
                  && (!requireHealthyCapture
                      || (captureReady && captureWritable))));
    }
  }

  private boolean reserveNfcTransactionTrace(
      long expectedCaptureEpoch, NfcV nfcV) {
    final int maxTransceiveLength;
    try {
      maxTransceiveLength = nfcV.getMaxTransceiveLength();
    } catch (RuntimeException error) {
      return false;
    }
    final long responseHexBytes = Math.max(0L, (long) maxTransceiveLength) * 2L;
    final long required = responseHexBytes + NFC_TRANSACTION_FIXED_RESERVE_BYTES;
    synchronized (fileLock) {
      if (expectedCaptureEpoch != captureEpoch
          || !captureWritable
          || reservedNfcTraceBytes != 0L
          || required > MAX_NFC_TRACE_BYTES
          || traceBytes + required + NFC_STATUS_HEADROOM_BYTES
              > MAX_NFC_TRACE_BYTES) {
        return false;
      }
      reservedNfcTraceBytes = required;
      return true;
    }
  }

  private boolean reserveExplicitNfcLifecycleTransactionTrace(
      long expectedCaptureEpoch,
      NfcV nfcV,
      Libre2NfcSetupAttempt attempt) {
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasUnreservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        if (attempt == null
            || explicitNfcSetupAttempt != attempt
            || !isExplicitNfcSetupUnclaimedReadyLocked(
                expectedCaptureEpoch,
                attempt.rfAuthorizationGeneration(),
                SystemClock.elapsedRealtimeNanos(),
                attempt,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)) {
          return false;
        }
        synchronized (explicitNfcTerminalLock) {
          if (!reserveGen1FramTransactionTrace(expectedCaptureEpoch, nfcV)) {
            return false;
          }
          if (!attempt.registerTraceReservation()) {
            releaseNfcTransactionTrace(expectedCaptureEpoch);
            return false;
          }
          return true;
        }
      }
    }
  }

  private boolean appendExplicitReservedEventForEpoch(
      long expectedCaptureEpoch,
      Libre2NfcSetupAttempt attempt,
      String type,
      JSONObject data) {
    synchronized (rfAuthorizationLock) {
      synchronized (explicitNfcTerminalLock) {
        if (attempt == null
            || attempt.captureEpoch() != expectedCaptureEpoch
            || explicitNfcSetupAttempt != attempt
            || !attempt.hasActiveTraceReservation()) {
          // Cancellation owns terminalization and may already have released
          // this attempt's reservation. A stale callback must stop benignly;
          // it must never consume another transaction's reservation or poison
          // capture health by calling the generic reserved append path.
          return false;
        }
        return appendReservedEventForEpoch(expectedCaptureEpoch, type, data);
      }
    }
  }

  private boolean hasUnreservedExplicitNfcSetupTraceCapacity(
      long expectedCaptureEpoch) {
    synchronized (fileLock) {
      return expectedCaptureEpoch == captureEpoch
          && captureWritable
          && traceFile != null
          && reservedNfcTraceBytes == 0L
          && traceBytes
                  + NFC_TRANSACTION_FIXED_RESERVE_BYTES
                  + NFC_STATUS_HEADROOM_BYTES
              <= MAX_NFC_TRACE_BYTES;
    }
  }

  private boolean hasReservedExplicitNfcSetupTraceCapacity(
      long expectedCaptureEpoch) {
    synchronized (fileLock) {
      return expectedCaptureEpoch == captureEpoch
          && captureWritable
          && traceFile != null
          && reservedNfcTraceBytes > 0L
          && traceBytes + reservedNfcTraceBytes + NFC_STATUS_HEADROOM_BYTES
              <= MAX_NFC_TRACE_BYTES;
    }
  }

  private boolean reserveGen1FramTransactionTrace(
      long expectedCaptureEpoch, NfcV nfcV) {
    final int maxTransceiveLength;
    try {
      maxTransceiveLength = nfcV.getMaxTransceiveLength();
    } catch (RuntimeException error) {
      return false;
    }
    if (maxTransceiveLength < LibreGen1NfcFrames.MAX_RESPONSE_BYTES) {
      return false;
    }
    synchronized (fileLock) {
      if (expectedCaptureEpoch != captureEpoch
          || !captureWritable
          || reservedNfcTraceBytes != 0L
          || traceBytes
                  + NFC_GEN1_FRAM_TRANSACTION_RESERVE_BYTES
                  + NFC_STATUS_HEADROOM_BYTES
              > MAX_NFC_TRACE_BYTES) {
        return false;
      }
      reservedNfcTraceBytes = NFC_GEN1_FRAM_TRANSACTION_RESERVE_BYTES;
      return true;
    }
  }

  private boolean reserveGen1ActivationTransactionTrace(
      long expectedCaptureEpoch, NfcV nfcV) {
    final int maxTransceiveLength;
    try {
      maxTransceiveLength = nfcV.getMaxTransceiveLength();
    } catch (RuntimeException error) {
      return false;
    }
    if (maxTransceiveLength < LibreGen1NfcFrames.MAX_RESPONSE_BYTES) {
      return false;
    }
    synchronized (fileLock) {
      if (expectedCaptureEpoch != captureEpoch
          || !captureWritable
          || reservedNfcTraceBytes != 0L
          || traceBytes
                  + NFC_GEN1_ACTIVATION_TRANSACTION_RESERVE_BYTES
                  + NFC_STATUS_HEADROOM_BYTES
              > MAX_NFC_TRACE_BYTES) {
        return false;
      }
      reservedNfcTraceBytes = NFC_GEN1_ACTIVATION_TRANSACTION_RESERVE_BYTES;
      return true;
    }
  }

  private void releaseNfcTransactionTrace(long expectedCaptureEpoch) {
    synchronized (fileLock) {
      if (expectedCaptureEpoch == captureEpoch) {
        reservedNfcTraceBytes = 0L;
      }
    }
  }

  private NfcRfTransactionLease beginHostRfTransactionLease(
      long expectedCaptureEpoch, GrantKind expectedGrantKind) {
    NfcRfTransactionLease acquired;
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || !nfcCallbackActive
            || !isCaptureReadyForRfLocked()
            || explicitNfcSetupAttempt != null
            || inFlightNfcV != null
            || activeHostRfTransactionLease != null
            || !rfTransactionLeaseBinding.isEmpty()
            || grantKindForEpoch(expectedCaptureEpoch) != expectedGrantKind) {
          return null;
        }
        try {
          acquired =
              NfcRfTransactionLease.tryAcquire(
                  captureDirectory, newNativeRfLeaseOwnerToken());
        } catch (IOException | RuntimeException error) {
          return null;
        }
        if (acquired == null) {
          return null;
        }
        if (expectedCaptureEpoch != captureEpoch
            || !nfcCallbackActive
            || !isCaptureReadyForRfLocked()
            || explicitNfcSetupAttempt != null
            || inFlightNfcV != null
            || activeHostRfTransactionLease != null
            || !rfTransactionLeaseBinding.isEmpty()
            || grantKindForEpoch(expectedCaptureEpoch) != expectedGrantKind) {
          releaseRfTransactionLease(acquired);
          return null;
        }
        if (!rfTransactionLeaseBinding.bindHost(acquired)) {
          releaseRfTransactionLease(acquired);
          return null;
        }
        activeHostRfTransactionLease = acquired;
        return acquired;
      }
    }
  }

  private NfcRfTransactionLease beginAuthorizationMutationLease(
      long expectedCaptureEpoch) {
    NfcRfTransactionLease acquired;
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || activeHostRfTransactionLease != null
            || !rfTransactionLeaseBinding.isEmpty()) {
          return null;
        }
        try {
          acquired =
              NfcRfTransactionLease.tryAcquire(
                  captureDirectory, newNativeRfLeaseOwnerToken());
        } catch (IOException | RuntimeException error) {
          return null;
        }
        if (acquired == null) {
          return null;
        }
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || activeHostRfTransactionLease != null
            || !rfTransactionLeaseBinding.isEmpty()
            || !rfTransactionLeaseBinding.bindMaintenance(acquired)) {
          releaseRfTransactionLease(acquired);
          return null;
        }
        return acquired;
      }
    }
  }

  private void finishAuthorizationMutationLease(
      NfcRfTransactionLease lease) {
    final NfcRfTransactionLease releasedLease;
    synchronized (rfAuthorizationLock) {
      releasedLease = rfTransactionLeaseBinding.takeMaintenance(lease);
    }
    releaseRfTransactionLease(releasedLease);
  }

  private NfcRfTransactionLease claimActiveRfTransactionLeaseForMaintenanceLocked(
      Libre2NfcSetupAttempt cancelledAttempt) {
    if (quarantinedStreamingLease != null
        && quarantinedStreamingLease == activeHostRfTransactionLease) return null;
    if (streamingAttempt != null && streamingAttempt.claimed
        && streamingAttempt.lease == activeHostRfTransactionLease) {
      streamingAttempt.cancelled = true;
      // The streaming callback owns close, terminal evidence, and lease release.
      return null;
    }
    if (cancelledAttempt != null) {
      return rfTransactionLeaseBinding.claimExplicitForMaintenance(
          cancelledAttempt);
    }
    final NfcRfTransactionLease hostLease = activeHostRfTransactionLease;
    final NfcRfTransactionLease claimed =
        rfTransactionLeaseBinding.claimHostForMaintenance(hostLease);
    if (claimed != null) {
      activeHostRfTransactionLease = null;
    }
    return claimed;
  }

  private void finishRfTransactionLease(NfcRfTransactionLease lease) {
    final NfcRfTransactionLease releasedLease;
    synchronized (rfAuthorizationLock) {
      releasedLease = rfTransactionLeaseBinding.takeHost(lease);
      if (releasedLease != null && activeHostRfTransactionLease == lease) {
        activeHostRfTransactionLease = null;
      }
    }
    releaseRfTransactionLease(releasedLease);
  }

  private void releaseRfTransactionLease(NfcRfTransactionLease lease) {
    if (lease != null && lease == quarantinedStreamingLease) {
      captureWritable = false;
      captureReady = false;
      return;
    }
    if (lease != null && !lease.release()) {
      // Never remove an unknown owner's files. A conflicting lease is a hard
      // capture-health failure until app-private state is reviewed.
      captureWritable = false;
      captureReady = false;
    }
  }

  private boolean isRfMutationLeaseHeld(
      RfMutationOwner owner,
      Libre2NfcSetupAttempt explicitAttempt,
      NfcRfTransactionLease maintenanceLease) {
    switch (owner) {
      case HOST:
        return rfTransactionLeaseBinding.isHeldByHost(
            maintenanceLease);
      case MAINTENANCE:
        return rfTransactionLeaseBinding.isHeldByMaintenance(
            maintenanceLease);
      case EXPLICIT:
        return explicitAttempt != null
            && rfTransactionLeaseBinding.isHeldByExplicitAttempt(
                explicitAttempt);
      default:
        return false;
    }
  }

  private void cancelExplicitNfcSetupExpiry(
      Libre2NfcSetupAttempt expectedAttempt) {
    final Runnable expiry;
    synchronized (rfAuthorizationLock) {
      expiry = explicitNfcSetupExpiryBinding.take(expectedAttempt);
    }
    if (expiry != null) {
      explicitNfcSetupHandler.removeCallbacks(expiry);
    }
  }

  private static String newNativeRfLeaseOwnerToken() {
    return "native_" + UUID.randomUUID().toString().replace("-", "");
  }

  private boolean isCaptureReadyForRf(long expectedCaptureEpoch) {
    synchronized (rfAuthorizationLock) {
      return expectedCaptureEpoch == captureEpoch
          && isCaptureReadyForRfLocked();
    }
  }

  private boolean isCaptureReadyForRfLocked() {
    final long now = SystemClock.elapsedRealtimeNanos();
    return NfcRfReadiness.isHostReady(
        captureRequested,
        resumed,
        captureReady,
        captureWritable,
        bleCaptureRfEligible,
        lastBleEligibleStatusElapsedRealtimeNanos,
        now,
        MAX_BLE_RF_STATUS_AGE_NANOS);
  }

  private boolean isExplicitNfcSetupUnclaimedReadyLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      long nowElapsedRealtimeNanos,
      Libre2NfcSetupAttempt expectedAttempt,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return NfcRfReadiness.isExplicitUnclaimedReady(
        captureRequested,
        resumed,
        captureReady,
        captureWritable,
        expectedCaptureEpoch,
        captureEpoch,
        expectedDartProcessSessionId,
        dartProcessSessionId,
        expectedGeneration,
        nowElapsedRealtimeNanos,
        explicitNfcSetupAttempt,
        expectedAttempt,
        rfTransactionLeaseBinding,
        traceCapacityAvailable,
        noHostAuthorizationArtifacts);
  }

  private boolean isExplicitNfcSetupClaimedReadyLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      long nowElapsedRealtimeNanos,
      String targetUidSha256,
      Libre2NfcSetupAttempt expectedAttempt,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return NfcRfReadiness.isExplicitClaimedReady(
        captureRequested,
        resumed,
        captureReady,
        captureWritable,
        expectedCaptureEpoch,
        captureEpoch,
        expectedDartProcessSessionId,
        dartProcessSessionId,
        expectedGeneration,
        nowElapsedRealtimeNanos,
        targetUidSha256,
        explicitNfcSetupAttempt,
        expectedAttempt,
        rfTransactionLeaseBinding,
        traceCapacityAvailable,
        noHostAuthorizationArtifacts);
  }

  private boolean isExplicitNfcSetupBindingReadyLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      long nowElapsedRealtimeNanos,
      Libre2NfcSetupAttempt expectedAttempt,
      boolean traceCapacityAvailable,
      boolean noHostAuthorizationArtifacts) {
    return NfcRfReadiness.isExplicitBindingReady(
        captureRequested,
        resumed,
        captureReady,
        captureWritable,
        expectedCaptureEpoch,
        captureEpoch,
        expectedDartProcessSessionId,
        dartProcessSessionId,
        expectedGeneration,
        nowElapsedRealtimeNanos,
        explicitNfcSetupAttempt,
        expectedAttempt,
        rfTransactionLeaseBinding,
        traceCapacityAvailable,
        noHostAuthorizationArtifacts);
  }

  private boolean isRfAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ProbeGrant grant,
      NfcRfTransactionLease hostLease) {
    synchronized (rfAuthorizationLock) {
      return isRfAuthorizedLocked(
          expectedCaptureEpoch, expectedGeneration, grant, hostLease);
    }
  }

  private boolean isRfAuthorizedLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ProbeGrant grant,
      NfcRfTransactionLease hostLease) {
    return isCaptureReadyForRfLocked()
        && rfTransactionLeaseBinding.isHeldByHost(hostLease)
        && expectedCaptureEpoch == captureEpoch
        && grant.captureEpoch == expectedCaptureEpoch
        && System.currentTimeMillis() < grant.expiresAtEpochMillis
        && SystemClock.elapsedRealtimeNanos()
            < grant.expiresAtElapsedRealtimeNanos
        && rfAuthorizationGeneration == expectedGeneration;
  }

  private boolean beginRfOperation(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ProbeGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease) {
    synchronized (rfAuthorizationLock) {
      if (!isRfAuthorizedLocked(
              expectedCaptureEpoch, expectedGeneration, grant, hostLease)
          || inFlightNfcV != null) {
        return false;
      }
      inFlightNfcV = nfcV;
      return true;
    }
  }

  private boolean isFramRfAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      FramReadGrant grant,
      NfcRfTransactionLease hostLease) {
    synchronized (rfAuthorizationLock) {
      return isFramRfAuthorizedLocked(
          expectedCaptureEpoch, expectedGeneration, grant, hostLease);
    }
  }

  private boolean isFramRfAuthorizedLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      FramReadGrant grant,
      NfcRfTransactionLease hostLease) {
    return isCaptureReadyForRfLocked()
        && rfTransactionLeaseBinding.isHeldByHost(hostLease)
        && expectedCaptureEpoch == captureEpoch
        && grant.captureEpoch == expectedCaptureEpoch
        && System.currentTimeMillis() < grant.expiresAtEpochMillis
        && SystemClock.elapsedRealtimeNanos()
            < grant.expiresAtElapsedRealtimeNanos
        && rfAuthorizationGeneration == expectedGeneration;
  }

  private boolean beginFramRfOperation(
      long expectedCaptureEpoch,
      long expectedGeneration,
      FramReadGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease) {
    synchronized (rfAuthorizationLock) {
      if (!isCaptureReadyForRfLocked()
          || !rfTransactionLeaseBinding.isHeldByHost(hostLease)
          || expectedCaptureEpoch != captureEpoch
          || grant.captureEpoch != expectedCaptureEpoch
          || System.currentTimeMillis() >= grant.expiresAtEpochMillis
          || SystemClock.elapsedRealtimeNanos()
              >= grant.expiresAtElapsedRealtimeNanos
          || rfAuthorizationGeneration != expectedGeneration
          || inFlightNfcV != null) {
        return false;
      }
      inFlightNfcV = nfcV;
      return true;
    }
  }

  private boolean isActivationRfAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ActivationGrant grant,
      NfcRfTransactionLease hostLease) {
    synchronized (rfAuthorizationLock) {
      return isActivationRfAuthorizedLocked(
          expectedCaptureEpoch, expectedGeneration, grant, hostLease);
    }
  }

  private boolean isActivationRfAuthorizedLocked(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ActivationGrant grant,
      NfcRfTransactionLease hostLease) {
    return isCaptureReadyForRfLocked()
        && rfTransactionLeaseBinding.isHeldByHost(hostLease)
        && expectedCaptureEpoch == captureEpoch
        && grant.captureEpoch == expectedCaptureEpoch
        && System.currentTimeMillis() < grant.expiresAtEpochMillis
        && SystemClock.elapsedRealtimeNanos()
            < grant.expiresAtElapsedRealtimeNanos
        && rfAuthorizationGeneration == expectedGeneration;
  }

  private boolean beginActivationRfOperation(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ActivationGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease) {
    synchronized (rfAuthorizationLock) {
      if (!isCaptureReadyForRfLocked()
          || !rfTransactionLeaseBinding.isHeldByHost(hostLease)
          || expectedCaptureEpoch != captureEpoch
          || grant.captureEpoch != expectedCaptureEpoch
          || System.currentTimeMillis() >= grant.expiresAtEpochMillis
          || SystemClock.elapsedRealtimeNanos()
              >= grant.expiresAtElapsedRealtimeNanos
          || rfAuthorizationGeneration != expectedGeneration
          || inFlightNfcV != null) {
        return false;
      }
      inFlightNfcV = nfcV;
      return true;
    }
  }

  private void endRfOperation(NfcV nfcV) {
    synchronized (rfAuthorizationLock) {
      if (inFlightNfcV == nfcV) {
        inFlightNfcV = null;
      }
    }
  }

  private byte[] transceiveProbeAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ProbeGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease,
      byte[] request)
      throws IOException {
    synchronized (rfAuthorizationLock) {
      if (!isRfAuthorizedLocked(
              expectedCaptureEpoch,
              expectedGeneration,
              grant,
              hostLease)
          || inFlightNfcV != nfcV) {
        throw new IOException("NFC authorization changed.");
      }
      return nfcV.transceive(request);
    }
  }

  private byte[] transceiveFramAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      FramReadGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease,
      byte[] request)
      throws IOException {
    synchronized (rfAuthorizationLock) {
      if (!isFramRfAuthorizedLocked(
              expectedCaptureEpoch, expectedGeneration, grant, hostLease)
          || inFlightNfcV != nfcV) {
        throw new IOException("NFC authorization changed.");
      }
      return nfcV.transceive(request);
    }
  }

  private byte[] transceiveActivationAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      ActivationGrant grant,
      NfcV nfcV,
      NfcRfTransactionLease hostLease,
      byte[] request)
      throws IOException {
    synchronized (rfAuthorizationLock) {
      if (!isActivationRfAuthorizedLocked(
              expectedCaptureEpoch, expectedGeneration, grant, hostLease)
          || inFlightNfcV != nfcV) {
        throw new IOException("NFC authorization changed.");
      }
      return nfcV.transceive(request);
    }
  }

  private byte[] transceiveExplicitNfcSetupAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt attempt,
      NfcV nfcV,
      byte[] request)
      throws IOException {
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasReservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        if (!isExplicitNfcSetupRfAuthorizedLocked(
                expectedCaptureEpoch,
                expectedGeneration,
                targetUidSha256,
                attempt,
                nfcV,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)
            || request == null
            || request.length != 3
            || request[0] != LIBRE_PATCH_INFO_FLAGS
            || request[1] != LIBRE_PATCH_INFO_CODE
            || request[2] != LIBRE_REFERENCE_MANUFACTURER_CODE
            || !attempt.consumePatchInfoTransceiveOnce(request)) {
          throw new IOException("NFC setup authorization changed.");
        }
        return nfcV.transceive(request);
      }
    }
  }

  private byte[] transceiveExplicitNfcFramAuthorized(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt attempt,
      NfcV nfcV,
      int frameIndex,
      byte[] request)
      throws IOException {
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasReservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        if (!isExplicitNfcSetupRfAuthorizedLocked(
                expectedCaptureEpoch,
                expectedGeneration,
                targetUidSha256,
                attempt,
                nfcV,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)
            || !attempt.consumeFramTransceive(frameIndex, request)) {
          throw new IOException("NFC setup authorization changed.");
        }
        // The exact frame slot is consumed before platform I/O. A timeout or
        // tag-loss outcome is terminal and can never be retried.
        return nfcV.transceive(request);
      }
    }
  }

  private boolean advanceExplicitNfcSetupState(
      long expectedCaptureEpoch,
      long expectedGeneration,
      String targetUidSha256,
      Libre2NfcSetupAttempt attempt,
      ExplicitStateAdvance advance) {
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasReservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        if (!isExplicitNfcSetupRfAuthorizedLocked(
            expectedCaptureEpoch,
            expectedGeneration,
            targetUidSha256,
            attempt,
            inFlightNfcV,
            traceCapacityAvailable,
            noHostAuthorizationArtifacts)) {
          return false;
        }
        switch (advance) {
          case CONNECTED:
            return attempt.markConnectedOnce();
          case PATCH_INFO_ACCEPTED:
            return attempt.acceptKnownGen1Libre2PatchInfo();
          case FRAM_COMPLETE:
            return attempt.completeFramSequence();
          case LIFECYCLE_VALIDATED:
            return attempt.recordValidatedLifecycleOnce();
          default:
            return false;
        }
      }
    }
  }

  private boolean closeNfcVQuietly(NfcV nfcV) {
    if (nfcV == null) {
      return true;
    }
    try {
      nfcV.close();
      return true;
    } catch (IOException | RuntimeException ignored) {
      // Cancellation is fail-closed. The trace records the operation outcome,
      // not platform error text that could contain sensitive device details.
      synchronized (rfAuthorizationLock) {
        if (streamingAttempt != null && streamingAttempt.transport == nfcV) {
          streamingAttempt.closeUncertain = true;
        }
      }
      return false;
    }
  }

  private void postResult(Runnable resultAction) {
    activity.runOnUiThread(resultAction);
  }

  private GrantKind grantKindForEpoch(long expectedCaptureEpoch) {
    synchronized (captureEpochLock) {
      final File directory = captureDirectory;
      if (expectedCaptureEpoch != captureEpoch || directory == null) {
        return GrantKind.NONE;
      }
      final boolean patchGrant =
          new File(directory, TARGET_UNVERIFIED_PROBE_GRANT_FILE).isFile();
      final boolean patchPending =
          new File(
                  directory,
                  TARGET_UNVERIFIED_PROBE_GRANT_FILE + ".pending")
              .exists();
      final boolean framGrant =
          new File(
                  directory,
                  TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE)
              .isFile();
      final boolean framPending =
          new File(
                  directory,
                  TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE + ".pending")
              .exists();
      final boolean activationGrant =
          new File(
                  directory,
                  TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE)
              .isFile();
      final boolean activationPending =
          new File(
                  directory,
                  TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE + ".pending")
              .exists();
      final int publishedGrantCount =
          (patchGrant ? 1 : 0)
              + (framGrant ? 1 : 0)
              + (activationGrant ? 1 : 0);
      // A staged grant is never authorization. Treat even a lone .pending
      // file as a conflict so a tag presentation cannot race host publication
      // or silently fall through to the passive read path.
      if (patchPending
          || framPending
          || activationPending
          || publishedGrantCount > 1) {
        return GrantKind.CONFLICT;
      }
      if (activationGrant) {
        return GrantKind.GEN1_ACTIVATION;
      }
      if (framGrant) {
        return GrantKind.GEN1_FRAM_READ;
      }
      return patchGrant ? GrantKind.PATCH_INFO : GrantKind.NONE;
    }
  }

  private boolean deleteConflictingAuthorizationArtifactsForEpoch(
      long expectedCaptureEpoch) {
    final NfcRfTransactionLease temporaryLease =
        beginAuthorizationMutationLease(expectedCaptureEpoch);
    if (temporaryLease == null) {
      return false;
    }
    try {
      synchronized (captureEpochLock) {
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || grantKindForEpoch(expectedCaptureEpoch)
                != GrantKind.CONFLICT) {
          return false;
        }
        if (!deleteAuthorizationArtifacts(
            captureDirectory,
            true,
            RfMutationOwner.MAINTENANCE,
            null,
            temporaryLease)) {
          captureWritable = false;
          captureReady = false;
          invalidateCaptureStatus();
          return false;
        }
        return true;
      }
    } finally {
      finishAuthorizationMutationLease(temporaryLease);
    }
  }

  private ProbeGrant consumeValidatedGrant(
      long expectedCaptureEpoch,
      String targetUidSha256,
      String manufacturerPrefix,
      NfcRfTransactionLease hostLease) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
      if (expectedCaptureEpoch != captureEpoch
          || captureDirectory == null
          || !rfTransactionLeaseBinding.isHeldByHost(hostLease)) {
        return null;
      }
      final File grantFile =
          new File(captureDirectory, TARGET_UNVERIFIED_PROBE_GRANT_FILE);
      final File framGrantFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE);
      final File activationGrantFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE);
      final File patchPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_PROBE_GRANT_FILE + ".pending");
      final File framPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE + ".pending");
      final File activationPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE + ".pending");
      if (!grantFile.isFile()
          || framGrantFile.exists()
          || activationGrantFile.exists()
          || patchPendingFile.exists()
          || framPendingFile.exists()
          || activationPendingFile.exists()) {
        deleteAuthorizationArtifacts(
            captureDirectory, true, RfMutationOwner.HOST, null, hostLease);
        return null;
      }

      byte[] encoded;
      try {
        encoded = readSmallFile(grantFile);
      } catch (IOException error) {
        encoded = null;
      }
      // Consume before validation or RF work. Invalid, stale, or malformed
      // grants cannot remain armed for a later tag.
      if (!grantFile.delete() || encoded == null) {
        captureWritable = false;
        invalidateCaptureStatus();
        return null;
      }
      try {
        syncDirectory(captureDirectory);
      } catch (IOException error) {
        captureWritable = false;
        invalidateCaptureStatus();
        return null;
      }

      try {
        final JSONObject value =
            new JSONObject(new String(encoded, StandardCharsets.UTF_8));
        final long now = System.currentTimeMillis();
        final long nowElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos();
        final Long schemaVersion = strictJsonInteger(value, "schemaVersion");
        final Long versionCode = strictJsonInteger(value, "versionCode");
        final Long lastUpdateTime = strictJsonInteger(value, "lastUpdateTime");
        final Long issuedAt = strictJsonInteger(value, "issuedAtEpochMillis");
        final Long expiresAt = strictJsonInteger(value, "expiresAtEpochMillis");
        final String operation = strictJsonString(value, "operation");
        final String nonce = strictJsonString(value, "nonce");
        final String nativeCaptureSessionId =
            strictJsonString(value, "nativeCaptureSessionId");
        final String processSessionId =
            strictJsonString(value, "processSessionId");
        final String encodedTargetUidSha256 =
            strictJsonString(value, "targetUidSha256");
        final String encodedManufacturerPrefix =
            strictJsonString(value, "iso15693ManufacturerPrefix");
        final String captureSessionId = strictJsonString(value, "sessionId");
        final boolean valid =
            expectedCaptureEpoch == captureEpoch
                && value.length() == 12
                && schemaVersion != null
                && schemaVersion == GRANT_SCHEMA_VERSION
                && TARGET_UNVERIFIED_PROBE_OPERATION.equals(operation)
                && grantNonce.equals(nonce)
                && sessionToken.equals(nativeCaptureSessionId)
                && expectedDartProcessSessionId.equals(processSessionId)
                && versionCode != null
                && versionCode == installedVersionCode
                && lastUpdateTime != null
                && lastUpdateTime == installedLastUpdateTime
                && targetUidSha256.equals(encodedTargetUidSha256)
                && manufacturerPrefix.equals(encodedManufacturerPrefix)
                && EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX.equals(
                    manufacturerPrefix)
                && captureSessionId != null
                && captureSessionId.matches("^session-[A-Za-z0-9-]{10,80}$")
                && issuedAt != null
                && expiresAt != null
                && issuedAt > 0L
                && issuedAt <= now + MAX_CLOCK_SKEW_MILLIS
                && now < expiresAt
                && expiresAt > issuedAt
                && expiresAt - issuedAt
                    <= MAX_STANDARD_GRANT_LIFETIME_MILLIS;
        if (!valid) {
          return null;
        }
        final long remainingMillis = expiresAt - now;
        final long expiresAtElapsedRealtimeNanos =
            nowElapsedRealtimeNanos + (remainingMillis * 1_000_000L);
        return new ProbeGrant(
            captureSessionId,
            expectedCaptureEpoch,
            expiresAt,
            expiresAtElapsedRealtimeNanos);
      } catch (JSONException error) {
        return null;
      }
      }
    }
  }

  private FramReadGrant consumeValidatedFramReadGrant(
      long expectedCaptureEpoch,
      String targetUidSha256,
      String manufacturerPrefix,
      NfcRfTransactionLease hostLease) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
      if (expectedCaptureEpoch != captureEpoch
          || captureDirectory == null
          || !rfTransactionLeaseBinding.isHeldByHost(hostLease)) {
        return null;
      }
      final File grantFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE);
      final File patchGrantFile =
          new File(captureDirectory, TARGET_UNVERIFIED_PROBE_GRANT_FILE);
      final File activationGrantFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE);
      final File patchContextFile =
          new File(captureDirectory, NFC_PATCH_INFO_CONTEXT_FILE);
      final File patchPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_PROBE_GRANT_FILE + ".pending");
      final File framPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE + ".pending");
      final File activationPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE + ".pending");
      if (!grantFile.isFile()
          || patchGrantFile.exists()
          || activationGrantFile.exists()
          || patchPendingFile.exists()
          || framPendingFile.exists()
          || activationPendingFile.exists()
          || !patchContextFile.isFile()) {
        deleteAuthorizationArtifacts(
            captureDirectory, true, RfMutationOwner.HOST, null, hostLease);
        return null;
      }

      byte[] encodedGrant;
      byte[] encodedPatchContext;
      try {
        encodedGrant = readSmallFile(grantFile);
        encodedPatchContext = readSmallFile(patchContextFile);
      } catch (IOException error) {
        encodedGrant = null;
        encodedPatchContext = null;
      }

      // Both the authorization and its exact patch observation are one-shot.
      // Consume them before connecting or transmitting any RF frame.
      final boolean removed =
          deleteAuthorizationArtifacts(
              captureDirectory,
              true,
              RfMutationOwner.HOST,
              null,
              hostLease);
      final File staleFramCapture =
          new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE);
      final boolean staleCaptureRemoved =
          !staleFramCapture.exists() || staleFramCapture.delete();
      try {
        syncDirectory(captureDirectory);
      } catch (IOException error) {
        captureWritable = false;
        invalidateCaptureStatus();
        return null;
      }
      if (!removed
          || !staleCaptureRemoved
          || encodedGrant == null
          || encodedPatchContext == null) {
        captureWritable = false;
        invalidateCaptureStatus();
        return null;
      }

      try {
        final JSONObject grant =
            new JSONObject(
                new String(encodedGrant, StandardCharsets.UTF_8));
        final JSONObject patchContext =
            new JSONObject(
                new String(encodedPatchContext, StandardCharsets.UTF_8));
        final long now = System.currentTimeMillis();
        final long nowElapsedRealtimeNanos =
            SystemClock.elapsedRealtimeNanos();

        final Long schemaVersion = strictJsonInteger(grant, "schemaVersion");
        final Long versionCode = strictJsonInteger(grant, "versionCode");
        final Long lastUpdateTime = strictJsonInteger(grant, "lastUpdateTime");
        final Long issuedAt = strictJsonInteger(grant, "issuedAtEpochMillis");
        final Long expiresAt = strictJsonInteger(grant, "expiresAtEpochMillis");
        final String operation = strictJsonString(grant, "operation");
        final String nonce = strictJsonString(grant, "nonce");
        final String nativeCaptureSessionId =
            strictJsonString(grant, "nativeCaptureSessionId");
        final String processSessionId =
            strictJsonString(grant, "processSessionId");
        final String encodedTargetUidSha256 =
            strictJsonString(grant, "targetUidSha256");
        final String encodedManufacturerPrefix =
            strictJsonString(grant, "iso15693ManufacturerPrefix");
        final String captureSessionId = strictJsonString(grant, "sessionId");
        final String patchInfoSha256 =
            strictJsonString(grant, "patchInfoSha256");

        final Long contextSchemaVersion =
            strictJsonInteger(patchContext, "schemaVersion");
        final Long contextVersionCode =
            strictJsonInteger(patchContext, "versionCode");
        final Long contextLastUpdateTime =
            strictJsonInteger(patchContext, "lastUpdateTime");
        final Long contextObservedMonotonic =
            strictJsonInteger(
                patchContext, "observedAtMonotonicElapsedNanos");
        final String contextNativeSession =
            strictJsonString(patchContext, "nativeCaptureSessionId");
        final String contextProcessSession =
            strictJsonString(patchContext, "processSessionId");
        final String contextTargetUidSha256 =
            strictJsonString(patchContext, "targetUidSha256");
        final String contextManufacturerPrefix =
            strictJsonString(
                patchContext, "iso15693ManufacturerPrefix");
        final String contextModel = strictJsonString(patchContext, "model");
        final String contextGeneration =
            strictJsonString(patchContext, "generation");
        final String contextPatchInfoSha256 =
            strictJsonString(patchContext, "patchInfoSha256");
        final String contextObservedAtUtc =
            strictJsonString(patchContext, "observedAtUtc");
        final boolean contextInstantValid =
            isStrictInstant(contextObservedAtUtc);

        final boolean valid =
            expectedCaptureEpoch == captureEpoch
                && grant.length() == 13
                && schemaVersion != null
                && schemaVersion == GRANT_SCHEMA_VERSION
                && TARGET_UNVERIFIED_GEN1_FRAM_READ_OPERATION.equals(operation)
                && grantNonce.equals(nonce)
                && sessionToken.equals(nativeCaptureSessionId)
                && expectedDartProcessSessionId.equals(processSessionId)
                && versionCode != null
                && versionCode == installedVersionCode
                && lastUpdateTime != null
                && lastUpdateTime == installedLastUpdateTime
                && targetUidSha256.equals(encodedTargetUidSha256)
                && manufacturerPrefix.equals(encodedManufacturerPrefix)
                && EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX.equals(
                    manufacturerPrefix)
                && captureSessionId != null
                && captureSessionId.matches("^session-[A-Za-z0-9-]{10,80}$")
                && patchInfoSha256 != null
                && patchInfoSha256.matches("^[0-9a-f]{64}$")
                && issuedAt != null
                && expiresAt != null
                && issuedAt > 0L
                && issuedAt <= now + MAX_CLOCK_SKEW_MILLIS
                && now < expiresAt
                && expiresAt > issuedAt
                && expiresAt - issuedAt
                    <= MAX_GEN1_FRAM_READ_GRANT_LIFETIME_MILLIS
                && patchContext.length() == 12
                && contextSchemaVersion != null
                && contextSchemaVersion == GRANT_SCHEMA_VERSION
                && contextVersionCode != null
                && contextVersionCode == installedVersionCode
                && contextLastUpdateTime != null
                && contextLastUpdateTime == installedLastUpdateTime
                && sessionToken.equals(contextNativeSession)
                && expectedDartProcessSessionId.equals(contextProcessSession)
                && targetUidSha256.equals(contextTargetUidSha256)
                && manufacturerPrefix.equals(contextManufacturerPrefix)
                && ("libre2".equals(contextModel)
                    || "libre2Plus".equals(contextModel))
                && "gen1".equals(contextGeneration)
                && patchInfoSha256.equals(contextPatchInfoSha256)
                && contextInstantValid
                && contextObservedMonotonic != null
                && contextObservedMonotonic > 0L
                && contextObservedMonotonic <= nowElapsedRealtimeNanos;
        if (!valid) {
          return null;
        }
        final long remainingMillis = expiresAt - now;
        final long expiresAtElapsedRealtimeNanos =
            nowElapsedRealtimeNanos + (remainingMillis * 1_000_000L);
        return new FramReadGrant(
            captureSessionId,
            contextModel,
            patchInfoSha256,
            expectedCaptureEpoch,
            expiresAt,
            expiresAtElapsedRealtimeNanos);
      } catch (JSONException error) {
        return null;
      }
      }
    }
  }

  private ActivationGrant consumeValidatedActivationGrant(
      long expectedCaptureEpoch,
      byte[] targetUid,
      String targetUidSha256,
      String manufacturerPrefix,
      NfcRfTransactionLease hostLease) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
      if (expectedCaptureEpoch != captureEpoch
          || captureDirectory == null
          || !rfTransactionLeaseBinding.isHeldByHost(hostLease)) {
        return null;
      }
      final File grantFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE);
      final File patchGrantFile =
          new File(captureDirectory, TARGET_UNVERIFIED_PROBE_GRANT_FILE);
      final File framGrantFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE);
      final File patchPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_PROBE_GRANT_FILE + ".pending");
      final File framPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE + ".pending");
      final File activationPendingFile =
          new File(
              captureDirectory,
              TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE + ".pending");
      final File sourceCaptureFile =
          new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE);
      final File journalFile =
          new File(captureDirectory, NFC_GEN1_ACTIVATION_JOURNAL_FILE);
      if (!grantFile.isFile()
          || patchGrantFile.exists()
          || framGrantFile.exists()
          || patchPendingFile.exists()
          || framPendingFile.exists()
          || activationPendingFile.exists()
          || !sourceCaptureFile.isFile()
          || journalFile.exists()) {
        deleteAuthorizationArtifacts(
            captureDirectory, true, RfMutationOwner.HOST, null, hostLease);
        return null;
      }

      final byte[] encodedGrant;
      final byte[] encodedSourceCapture;
      try {
        encodedGrant = readSmallFile(grantFile);
        encodedSourceCapture = readSmallFile(sourceCaptureFile);
      } catch (IOException error) {
        deleteAuthorizationArtifacts(
            captureDirectory, true, RfMutationOwner.HOST, null, hostLease);
        return null;
      }

      try {
        final JSONObject grant =
            new JSONObject(new String(encodedGrant, StandardCharsets.UTF_8));
        final JSONObject source =
            new JSONObject(
                new String(encodedSourceCapture, StandardCharsets.UTF_8));
        final long now = System.currentTimeMillis();
        final long nowElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos();

        final Long schemaVersion = strictJsonInteger(grant, "schemaVersion");
        final Long versionCode = strictJsonInteger(grant, "versionCode");
        final Long lastUpdateTime = strictJsonInteger(grant, "lastUpdateTime");
        final Long issuedAt = strictJsonInteger(grant, "issuedAtEpochMillis");
        final Long expiresAt = strictJsonInteger(grant, "expiresAtEpochMillis");
        final String operation = strictJsonString(grant, "operation");
        final String nonce = strictJsonString(grant, "nonce");
        final String nativeCaptureSessionId =
            strictJsonString(grant, "nativeCaptureSessionId");
        final String processSessionId =
            strictJsonString(grant, "processSessionId");
        final String encodedTargetUidSha256 =
            strictJsonString(grant, "targetUidSha256");
        final String encodedManufacturerPrefix =
            strictJsonString(grant, "iso15693ManufacturerPrefix");
        final String patchInfoSha256 =
            strictJsonString(grant, "patchInfoSha256");
        final String model = strictJsonString(grant, "model");
        final String securityGeneration =
            strictJsonString(grant, "securityGeneration");
        final String captureSessionId = strictJsonString(grant, "sessionId");
        final String attemptId = strictJsonString(grant, "attemptId");
        final String sourceCaptureSha256 =
            strictJsonString(grant, "sourceFramCaptureSha256");
        final String sourceEncryptedFramSha256 =
            strictJsonString(grant, "sourceEncryptedFramSha256");
        final String validatedLifecycle =
            strictJsonString(grant, "validatedLifecycle");
        final String plannedRequestSha256 =
            strictJsonString(grant, "plannedRequestSha256");

        final Long sourceSchemaVersion =
            strictJsonInteger(source, "schemaVersion");
        final String sourceNativeSession =
            strictJsonString(source, "nativeCaptureSessionId");
        final String sourceProcessSession =
            strictJsonString(source, "processSessionId");
        final String sourceCaptureSession =
            strictJsonString(source, "captureSessionId");
        final Long sourceVersionCode =
            strictJsonInteger(source, "versionCode");
        final Long sourceLastUpdateTime =
            strictJsonInteger(source, "lastUpdateTime");
        final String sourceTargetUidSha256 =
            strictJsonString(source, "targetUidSha256");
        final String sourceManufacturerPrefix =
            strictJsonString(source, "iso15693ManufacturerPrefix");
        final String sourcePatchInfoSha256 =
            strictJsonString(source, "patchInfoSha256");
        final String sourceModel = strictJsonString(source, "model");
        final String sourceGeneration =
            strictJsonString(source, "securityGeneration");
        final String sourceKind = strictJsonString(source, "sourceKind");
        final String sourceExplicitAttemptId =
            strictJsonString(source, "explicitAttemptId");
        final byte[] sourceUid =
            decodeLowerHex(strictJsonString(source, "algorithmOrderUidHex"), 8);
        final byte[] sourcePatch =
            decodeLowerHex(strictJsonString(source, "patchInfoHex"), 6);
        final byte[] sourceEncryptedFram =
            decodeLowerHex(
                strictJsonString(source, "encryptedFramHex"),
                LibreGen1NfcFrames.FRAM_BYTES);
        final String sourceObservedAtUtc =
            strictJsonString(source, "observedAtUtc");
        final Long sourceObservedMonotonic =
            strictJsonInteger(source, "observedAtMonotonicElapsedNanos");

        final byte[] plannedRequest =
            targetUid == null || targetUid.length != 8
                ? null
                : LibreGen1Activation.activationRequest(targetUid);
        final int sourceLifecycle =
            sourceUid == null || sourcePatch == null || sourceEncryptedFram == null
                ? -1
                : LibreGen1Activation.validatedLifecycle(
                    sourceUid, sourcePatch, sourceEncryptedFram);
        final boolean valid =
            expectedCaptureEpoch == captureEpoch
                && grant.length() == 20
                && schemaVersion != null
                && schemaVersion == GRANT_SCHEMA_VERSION
                && TARGET_UNVERIFIED_GEN1_ACTIVATION_OPERATION.equals(operation)
                && grantNonce.equals(nonce)
                && sessionToken.equals(nativeCaptureSessionId)
                && expectedDartProcessSessionId.equals(processSessionId)
                && versionCode != null
                && versionCode == installedVersionCode
                && lastUpdateTime != null
                && lastUpdateTime == installedLastUpdateTime
                && targetUidSha256.equals(encodedTargetUidSha256)
                && manufacturerPrefix.equals(encodedManufacturerPrefix)
                && EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX.equals(
                    manufacturerPrefix)
                && patchInfoSha256 != null
                && patchInfoSha256.matches("^[0-9a-f]{64}$")
                && "libre2".equals(model)
                && "gen1".equals(securityGeneration)
                && captureSessionId != null
                && captureSessionId.matches("^session-[A-Za-z0-9-]{10,80}$")
                && attemptId != null
                && attemptId.matches("^activation-[0-9a-f]{32}$")
                && sourceCaptureSha256 != null
                && sourceCaptureSha256.matches("^[0-9a-f]{64}$")
                && sourceCaptureSha256.equals(sha256Hex(encodedSourceCapture))
                && sourceEncryptedFramSha256 != null
                && sourceEncryptedFramSha256.matches("^[0-9a-f]{64}$")
                && "notActivated".equals(validatedLifecycle)
                && plannedRequestSha256 != null
                && plannedRequestSha256.matches("^[0-9a-f]{64}$")
                && plannedRequest != null
                && plannedRequest.length
                    == LibreGen1Activation.ACTIVATION_REQUEST_BYTES
                && plannedRequestSha256.equals(sha256Hex(plannedRequest))
                && issuedAt != null
                && expiresAt != null
                && issuedAt > 0L
                && issuedAt <= now + MAX_CLOCK_SKEW_MILLIS
                && now < expiresAt
                && expiresAt > issuedAt
                && expiresAt - issuedAt
                    <= MAX_STANDARD_GRANT_LIFETIME_MILLIS
                && sourceSchemaVersion != null
                && ((sourceSchemaVersion == GRANT_SCHEMA_VERSION
                        && source.length() == 16
                        && sourceKind == null
                        && sourceExplicitAttemptId == null)
                    || (sourceSchemaVersion == 2L
                        && source.length() == 18
                        && "explicitLibre2Lifecycle".equals(sourceKind)
                        && sourceExplicitAttemptId != null
                        && sourceExplicitAttemptId.matches(
                            "^[A-Za-z0-9_-]{8,120}$")))
                && sessionToken.equals(sourceNativeSession)
                && expectedDartProcessSessionId.equals(sourceProcessSession)
                && captureSessionId.equals(sourceCaptureSession)
                && sourceVersionCode != null
                && sourceVersionCode == installedVersionCode
                && sourceLastUpdateTime != null
                && sourceLastUpdateTime == installedLastUpdateTime
                && targetUidSha256.equals(sourceTargetUidSha256)
                && manufacturerPrefix.equals(sourceManufacturerPrefix)
                && patchInfoSha256.equals(sourcePatchInfoSha256)
                && "libre2".equals(sourceModel)
                && "gen1".equals(sourceGeneration)
                && sourceUid != null
                && Arrays.equals(targetUid, sourceUid)
                && sha256Hex(sourceUid).equals(targetUidSha256)
                && sourcePatch != null
                && sha256Hex(sourcePatch).equals(patchInfoSha256)
                && sourceEncryptedFram != null
                && sha256Hex(sourceEncryptedFram)
                    .equals(sourceEncryptedFramSha256)
                && sourceLifecycle
                    == LibreGen1Activation.LIFECYCLE_NOT_ACTIVATED
                && isStrictInstant(sourceObservedAtUtc)
                && sourceObservedMonotonic != null
                && sourceObservedMonotonic > 0L
                && sourceObservedMonotonic <= nowElapsedRealtimeNanos;
        if (!valid) {
          deleteAuthorizationArtifacts(
              captureDirectory,
              true,
              RfMutationOwner.HOST,
              null,
              hostLease);
          return null;
        }

        final long remainingMillis = expiresAt - now;
        final ActivationGrant result =
            new ActivationGrant(
                captureSessionId,
                attemptId,
                patchInfoSha256,
                plannedRequestSha256,
                sourceCaptureSha256,
                sourceEncryptedFramSha256,
                expectedCaptureEpoch,
                expiresAt,
                nowElapsedRealtimeNanos + (remainingMillis * 1_000_000L));
        // The journal must exist durably before the one-shot authorization is
        // consumed. Any journal, including not_sent, blocks automatic retry
        // until a reviewed reconciliation removes it.
        if (!persistActivationJournalForEpoch(
            expectedCaptureEpoch,
            result,
            "prepared",
            "not_sent",
            null,
            hostLease)) {
          deleteAuthorizationArtifacts(
              captureDirectory,
              true,
              RfMutationOwner.HOST,
              null,
              hostLease);
          return null;
        }
        if (!deleteAuthorizationArtifacts(
            captureDirectory,
            true,
            RfMutationOwner.HOST,
            null,
            hostLease)) {
          captureWritable = false;
          invalidateCaptureStatus();
          return null;
        }
        return result;
      } catch (JSONException | IllegalArgumentException error) {
        deleteAuthorizationArtifacts(
            captureDirectory, true, RfMutationOwner.HOST, null, hostLease);
        return null;
      }
      }
    }
  }

  private boolean recordTargetContextWithLease(
      long expectedCaptureEpoch,
      String targetUidSha256,
      String manufacturerPrefix,
      Libre2NfcSetupAttempt explicitAttempt) {
    NfcRfTransactionLease temporaryLease = null;
    final RfMutationOwner mutationOwner;
    if (explicitAttempt == null) {
      mutationOwner = RfMutationOwner.MAINTENANCE;
      temporaryLease = beginAuthorizationMutationLease(expectedCaptureEpoch);
      if (temporaryLease == null) {
        return false;
      }
    } else {
      mutationOwner = RfMutationOwner.EXPLICIT;
    }
    try {
      return recordTargetContext(
          expectedCaptureEpoch,
          targetUidSha256,
          manufacturerPrefix,
          mutationOwner,
          explicitAttempt,
          temporaryLease);
    } finally {
      if (temporaryLease != null) {
        finishAuthorizationMutationLease(temporaryLease);
      }
    }
  }

  private boolean recordTargetContext(
      long expectedCaptureEpoch,
      String targetUidSha256,
      String manufacturerPrefix,
      RfMutationOwner mutationOwner,
      Libre2NfcSetupAttempt explicitAttempt,
      NfcRfTransactionLease maintenanceLease) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || !isRfMutationLeaseHeld(
                mutationOwner, explicitAttempt, maintenanceLease)) {
          return false;
        }
        final JSONObject context = new JSONObject();
        put(context, "schemaVersion", 1);
        put(context, "nativeCaptureSessionId", sessionToken);
        put(context, "processSessionId", expectedDartProcessSessionId);
        put(context, "targetUidSha256", targetUidSha256);
        put(context, "iso15693ManufacturerPrefix", manufacturerPrefix);
        put(context, "observedAtUtc", Instant.now().toString());
        put(
            context,
            "observedAtMonotonicElapsedNanos",
            SystemClock.elapsedRealtimeNanos());
        try {
          writePrivateJson(
              new File(captureDirectory, TARGET_CONTEXT_FILE), context);
        } catch (IOException error) {
          captureWritable = false;
          invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
          return false;
        }
        if (expectedCaptureEpoch != captureEpoch) {
          return false;
        }

        final JSONObject event = new JSONObject();
        put(event, "targetUidSha256", targetUidSha256);
        put(event, "iso15693ManufacturerPrefix", manufacturerPrefix);
        return appendEventForEpoch(
            expectedCaptureEpoch, "nfc.target.observed", event);
      }
    }
  }

  private boolean persistPatchInfoContext(
      long expectedCaptureEpoch,
      String targetUidSha256,
      String manufacturerPrefix,
      PatchInfoClassification classification,
      byte[] patchInfoResponse,
      NfcRfTransactionLease hostLease,
      Libre2NfcSetupAttempt explicitAttempt) {
    if (classification == null
        || !"gen1".equals(classification.securityGeneration)
        || !("libre2".equals(classification.model)
            || "libre2Plus".equals(classification.model))
        || patchInfoResponse == null
        || patchInfoResponse.length != 7
        || !EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX.equals(
            manufacturerPrefix)) {
      return false;
    }
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        final boolean exactOwner =
            explicitAttempt == null
                ? isRfMutationLeaseHeld(
                    RfMutationOwner.HOST, null, hostLease)
                : isRfMutationLeaseHeld(
                    RfMutationOwner.EXPLICIT, explicitAttempt, null);
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || !captureReady
            || !captureWritable
            || !exactOwner) {
          return false;
        }
        final JSONObject context = new JSONObject();
        put(context, "schemaVersion", GRANT_SCHEMA_VERSION);
        put(context, "nativeCaptureSessionId", sessionToken);
        put(context, "processSessionId", expectedDartProcessSessionId);
        put(context, "versionCode", installedVersionCode);
        put(context, "lastUpdateTime", installedLastUpdateTime);
        put(context, "targetUidSha256", targetUidSha256);
        put(context, "iso15693ManufacturerPrefix", manufacturerPrefix);
        put(context, "model", classification.model);
        put(context, "generation", classification.securityGeneration);
        put(context, "patchInfoSha256", sha256PatchInfoPayload(patchInfoResponse));
        put(context, "observedAtUtc", Instant.now().toString());
        put(
            context,
            "observedAtMonotonicElapsedNanos",
            SystemClock.elapsedRealtimeNanos());
        if (context.length() != 12) {
          return false;
        }
        try {
          writePrivateJson(
              new File(captureDirectory, NFC_PATCH_INFO_CONTEXT_FILE), context);
          return expectedCaptureEpoch == captureEpoch;
        } catch (IOException error) {
          captureWritable = false;
          invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
          return false;
        }
      }
    }
  }

  private boolean deletePatchInfoContextForEpoch(
      long expectedCaptureEpoch,
      NfcRfTransactionLease hostLease,
      Libre2NfcSetupAttempt explicitAttempt) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        final boolean exactOwner =
            explicitAttempt == null
                ? isRfMutationLeaseHeld(
                    RfMutationOwner.HOST, null, hostLease)
                : isRfMutationLeaseHeld(
                    RfMutationOwner.EXPLICIT, explicitAttempt, null);
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || !exactOwner) {
          return false;
        }
        final File context =
            new File(captureDirectory, NFC_PATCH_INFO_CONTEXT_FILE);
        if (context.exists() && !context.delete()) {
          captureWritable = false;
          invalidateCaptureStatus();
          return false;
        }
        try {
          syncDirectory(captureDirectory);
          return expectedCaptureEpoch == captureEpoch;
        } catch (IOException error) {
          captureWritable = false;
          invalidateCaptureStatus();
          return false;
        }
      }
    }
  }

  private boolean deleteExplicitLifecycleArtifactsForEpoch(
      long expectedCaptureEpoch,
      Libre2NfcSetupAttempt explicitAttempt) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || !isRfMutationLeaseHeld(
                RfMutationOwner.EXPLICIT, explicitAttempt, null)) {
          return false;
        }
        final File patchContext =
            new File(captureDirectory, NFC_PATCH_INFO_CONTEXT_FILE);
        final File framCapture =
            new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE);
        final File targetContext =
            new File(captureDirectory, TARGET_CONTEXT_FILE);
        if ((targetContext.exists() && !targetContext.delete())
            || (patchContext.exists() && !patchContext.delete())
            || (framCapture.exists() && !framCapture.delete())) {
          captureWritable = false;
          invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
          return false;
        }
        try {
          syncDirectory(captureDirectory);
          return expectedCaptureEpoch == captureEpoch;
        } catch (IOException error) {
          captureWritable = false;
          invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
          return false;
        }
      }
    }
  }

  private boolean persistGen1FramCapture(
      long expectedCaptureEpoch,
      byte[] androidTagId,
      String targetUidSha256,
      String manufacturerPrefix,
      String captureSessionId,
      PatchInfoClassification classification,
      byte[] patchInfoResponse,
      String patchInfoSha256,
      byte[] encryptedFram,
      NfcRfTransactionLease hostLease,
      Libre2NfcSetupAttempt explicitAttempt) {
    if (androidTagId == null
        || androidTagId.length != 8
        || classification == null
        || !"gen1".equals(classification.securityGeneration)
        || !("libre2".equals(classification.model)
            || "libre2Plus".equals(classification.model))
        || patchInfoResponse == null
        || patchInfoResponse.length != 7
        || encryptedFram == null
        || encryptedFram.length != LibreGen1NfcFrames.FRAM_BYTES
        || !EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX.equals(
            manufacturerPrefix)
        || patchInfoSha256 == null
        || !patchInfoSha256.matches("^[0-9a-f]{64}$")
        || !patchInfoSha256.equals(sha256PatchInfoPayload(patchInfoResponse))) {
      return false;
    }
    // Pinned Libre Gen1 implementations feed Android Tag.getId() directly to
    // the algorithm. Do not reverse this order: byte 6 is the 0x07
    // manufacturer byte and the target hash is over these same eight bytes.
    final byte[] algorithmOrderUid = androidTagId.clone();
    final byte[] patchInfoPayload =
        Arrays.copyOfRange(patchInfoResponse, 1, patchInfoResponse.length);
    try {
      synchronized (captureEpochLock) {
        synchronized (rfAuthorizationLock) {
        final boolean exactOwner =
            explicitAttempt == null
                ? isRfMutationLeaseHeld(
                    RfMutationOwner.HOST, null, hostLease)
                : isRfMutationLeaseHeld(
                    RfMutationOwner.EXPLICIT, explicitAttempt, null);
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || !captureReady
            || !captureWritable
            || !exactOwner) {
          return false;
        }
        final JSONObject capture = new JSONObject();
        put(
            capture,
            "schemaVersion",
            explicitAttempt == null ? GRANT_SCHEMA_VERSION : 2);
        put(capture, "nativeCaptureSessionId", sessionToken);
        put(capture, "processSessionId", expectedDartProcessSessionId);
        put(
            capture,
            "captureSessionId",
            explicitAttempt == null ? captureSessionId : JSONObject.NULL);
        if (explicitAttempt != null) {
          put(capture, "sourceKind", "explicitLibre2Lifecycle");
          put(capture, "explicitAttemptId", explicitAttempt.scanAttemptId());
        }
        put(capture, "versionCode", installedVersionCode);
        put(capture, "lastUpdateTime", installedLastUpdateTime);
        put(capture, "targetUidSha256", targetUidSha256);
        put(capture, "iso15693ManufacturerPrefix", manufacturerPrefix);
        put(capture, "patchInfoSha256", patchInfoSha256);
        put(capture, "model", classification.model);
        put(capture, "securityGeneration", classification.securityGeneration);
        put(capture, "algorithmOrderUidHex", hex(algorithmOrderUid));
        put(capture, "patchInfoHex", hex(patchInfoPayload));
        put(capture, "encryptedFramHex", hex(encryptedFram));
        put(capture, "observedAtUtc", Instant.now().toString());
        put(
            capture,
            "observedAtMonotonicElapsedNanos",
            SystemClock.elapsedRealtimeNanos());
        if (capture.length() != (explicitAttempt == null ? 16 : 18)) {
          return false;
        }
        try {
          writePrivateJson(
              new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE), capture);
          return expectedCaptureEpoch == captureEpoch;
        } catch (IOException error) {
          captureWritable = false;
          invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
          return false;
        }
      }
      }
    } finally {
      Arrays.fill(algorithmOrderUid, (byte) 0);
      Arrays.fill(patchInfoPayload, (byte) 0);
    }
  }

  private void deleteGen1FramCaptureForEpoch(
      long expectedCaptureEpoch, NfcRfTransactionLease hostLease) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || captureDirectory == null
            || !rfTransactionLeaseBinding.isHeldByHost(hostLease)) {
          return;
        }
        final File capture =
            new File(captureDirectory, NFC_GEN1_FRAM_CAPTURE_FILE);
        if (capture.exists() && !capture.delete()) {
          captureWritable = false;
          captureReady = false;
          return;
        }
        try {
          syncDirectory(captureDirectory);
        } catch (IOException error) {
          captureWritable = false;
          captureReady = false;
        }
      }
    }
  }

  private boolean persistActivationJournalForEpoch(
      long expectedCaptureEpoch,
      ActivationGrant grant,
      String state,
      String outcome,
      String lifecycle,
      NfcRfTransactionLease hostLease) {
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
      final boolean validTransitionRecord =
          ("prepared".equals(state)
                  && "not_sent".equals(outcome)
                  && lifecycle == null)
              || ("transmit_intent_committed".equals(state)
                  && "unknown_outcome".equals(outcome)
                  && "notActivated".equals(lifecycle))
              || ("response_received".equals(state)
                  && "unknown_outcome".equals(outcome)
                  && lifecycle == null)
              || ("post_state_verified".equals(state)
                  && "verified".equals(outcome)
                  && "warmingUp".equals(lifecycle))
              || ("unknown_outcome".equals(state)
                  && "unknown_outcome".equals(outcome)
                  && lifecycle == null);
      if (expectedCaptureEpoch != captureEpoch
          || captureDirectory == null
          || grant == null
          || grant.captureEpoch != expectedCaptureEpoch
          || !rfTransactionLeaseBinding.isHeldByHost(hostLease)
          || !validTransitionRecord) {
        return false;
      }
      final JSONObject journal = new JSONObject();
      put(journal, "schemaVersion", GRANT_SCHEMA_VERSION);
      put(journal, "operation", TARGET_UNVERIFIED_GEN1_ACTIVATION_OPERATION);
      put(journal, "attemptId", grant.attemptId);
      put(journal, "state", state);
      put(journal, "outcome", outcome);
      put(journal, "nativeCaptureSessionId", sessionToken);
      put(journal, "processSessionId", expectedDartProcessSessionId);
      put(journal, "versionCode", installedVersionCode);
      put(journal, "lastUpdateTime", installedLastUpdateTime);
      put(journal, "captureSessionId", grant.captureSessionId);
      put(journal, "patchInfoSha256", grant.patchInfoSha256);
      put(journal, "plannedRequestSha256", grant.plannedRequestSha256);
      put(journal, "sourceFramCaptureSha256", grant.sourceCaptureSha256);
      put(
          journal,
          "sourceEncryptedFramSha256",
          grant.sourceEncryptedFramSha256);
      put(journal, "lifecycle", lifecycle == null ? JSONObject.NULL : lifecycle);
      put(journal, "updatedAtUtc", Instant.now().toString());
      put(
          journal,
          "updatedAtMonotonicElapsedNanos",
          SystemClock.elapsedRealtimeNanos());
      if (journal.length() != 17) {
        return false;
      }
      try {
        writePrivateJson(
            new File(captureDirectory, NFC_GEN1_ACTIVATION_JOURNAL_FILE),
            journal);
        return expectedCaptureEpoch == captureEpoch;
      } catch (IOException error) {
        captureWritable = false;
        invalidateCaptureStatusForEpoch(expectedCaptureEpoch);
        return false;
      }
      }
    }
  }

  private static byte[] readSmallFile(File file) throws IOException {
    try (FileInputStream input = new FileInputStream(file);
        ByteArrayOutputStream output = new ByteArrayOutputStream()) {
      final byte[] buffer = new byte[512];
      int total = 0;
      int count;
      while ((count = input.read(buffer)) != -1) {
        total += count;
        if (total > MAX_GRANT_FILE_BYTES) {
          throw new IOException("Grant file exceeds its size limit.");
        }
        output.write(buffer, 0, count);
      }
      return output.toByteArray();
    }
  }

  private static Long strictJsonInteger(JSONObject value, String key) {
    final Object encoded = value.opt(key);
    if (!(encoded instanceof Byte)
        && !(encoded instanceof Short)
        && !(encoded instanceof Integer)
        && !(encoded instanceof Long)) {
      return null;
    }
    return ((Number) encoded).longValue();
  }

  private static String strictJsonString(JSONObject value, String key) {
    final Object encoded = value.opt(key);
    return encoded instanceof String ? (String) encoded : null;
  }

  private static byte[] decodeLowerHex(String value, int expectedBytes) {
    if (value == null
        || value.length() != expectedBytes * 2
        || !value.matches("^[0-9a-f]+$")) {
      return null;
    }
    final byte[] result = new byte[expectedBytes];
    try {
      for (int index = 0; index < expectedBytes; index += 1) {
        result[index] =
            (byte)
                Integer.parseInt(
                    value.substring(index * 2, index * 2 + 2), 16);
      }
      return result;
    } catch (NumberFormatException error) {
      return null;
    }
  }

  private static boolean isStrictInstant(String value) {
    if (value == null) {
      return false;
    }
    try {
      return value.equals(Instant.parse(value).toString());
    } catch (RuntimeException error) {
      return false;
    }
  }

  private NfcRfTransactionLease beginCapturePreparationLease(File directory)
      throws IOException {
    Libre2NfcSetupAttempt cancelledAttempt = null;
    NfcRfTransactionLease maintenanceLease = null;
    IOException acquisitionError = null;
    synchronized (captureEpochLock) {
      synchronized (rfAuthorizationLock) {
        captureRequested = false;
        bleCaptureRfEligible = false;
        lastBleEligibleStatusElapsedRealtimeNanos = 0L;
        rfAuthorizationGeneration += 1L;
        cancelledAttempt = explicitNfcSetupAttempt;
        if (cancelledAttempt != null) {
          maintenanceLease =
              terminalizeExplicitNfcSetupAttempt(
                  cancelledAttempt,
                  inFlightNfcV,
                  "nfc.explicit_setup.connection.cancelled",
                  "captureRestarted");
        } else {
          final NfcV cancelled = inFlightNfcV;
          inFlightNfcV = null;
          inFlightExplicitNfcSetupAttemptId = null;
          closeNfcVQuietly(cancelled);
          maintenanceLease =
              claimActiveRfTransactionLeaseForMaintenanceLocked(null);
        }
        if (maintenanceLease == null
            && rfTransactionLeaseBinding.isEmpty()) {
          NfcRfTransactionLease acquired = null;
          try {
            acquired =
                NfcRfTransactionLease.tryAcquire(
                    directory, newNativeRfLeaseOwnerToken());
          } catch (IOException | RuntimeException error) {
            acquisitionError =
                new IOException(
                    "Could not acquire protocol preparation lease.", error);
          }
          if (acquired != null) {
            if (rfTransactionLeaseBinding.bindMaintenance(acquired)) {
              maintenanceLease = acquired;
            } else {
              releaseRfTransactionLease(acquired);
            }
          }
        }
        captureDirectory = directory;
      }
    }
    cancelExplicitNfcSetupExpiry(cancelledAttempt);
    if (maintenanceLease == null) {
      publishCancelledExplicitAttempt(cancelledAttempt);
      if (acquisitionError != null) {
        throw acquisitionError;
      }
      throw new IOException("Protocol authorization storage is busy.");
    }
    if (!deleteAuthorizationArtifacts(
        directory,
        true,
        RfMutationOwner.MAINTENANCE,
        null,
        maintenanceLease)) {
      finishAuthorizationMutationLease(maintenanceLease);
      publishCancelledExplicitAttempt(cancelledAttempt);
      throw new IOException("Could not revoke stale protocol authorization.");
    }
    publishCancelledExplicitAttempt(cancelledAttempt);
    return maintenanceLease;
  }

  private synchronized void prepareCaptureDirectory(
      String requestedProcessSessionId) throws IOException {
    if (captureReady && captureWritable && traceFile != null && traceFile.isFile()) {
      appendEvent("nfc.capture.restarting", new JSONObject());
    }
    final File directory =
        new File(activity.getFilesDir(), CAPTURE_DIRECTORY);
    if ((!directory.isDirectory() && !directory.mkdirs())
        || !directory.isDirectory()) {
      throw new IOException("Could not create capture directory.");
    }
    directory.setReadable(false, false);
    directory.setWritable(false, false);
    directory.setExecutable(false, false);
    if (!directory.setReadable(true, true)
        || !directory.setWritable(true, true)
        || !directory.setExecutable(true, true)) {
      throw new IOException("Could not restrict capture directory permissions.");
    }
    final NfcRfTransactionLease maintenanceLease =
        beginCapturePreparationLease(directory);
    try {
    synchronized (captureEpochLock) {
      synchronized (fileLock) {
        captureEpoch += 1L;
        captureReady = false;
        captureWritable = false;
        traceFile = null;
        traceBytes = 0L;
        reservedNfcTraceBytes = 0L;
        sequence.set(0L);
        sessionToken = newNativeSessionToken();
        grantNonce = newGrantNonce();
        expectedDartProcessSessionId = requestedProcessSessionId;
        dartProcessSessionId = null;
        lastDartHeartbeatMonotonicMicroseconds = 0L;
        lastPublishedBleSequence = 0L;
      }
      captureDirectory = directory;
        File newTraceFile = null;
        try {
          pruneOldNfcTraces(directory);
          prepareGrantContext(directory, maintenanceLease);
          newTraceFile =
              new File(
                  directory,
                  "nfc-"
                      + sessionToken
                      + "-"
                      + UUID.randomUUID().toString().replace("-", "")
                      + ".jsonl");
          if (!newTraceFile.createNewFile()) {
            throw new IOException("Capture file already exists.");
          }
          newTraceFile.setReadable(false, false);
          newTraceFile.setWritable(false, false);
          if (!newTraceFile.setReadable(true, true)
              || !newTraceFile.setWritable(true, true)) {
            throw new IOException("Could not restrict capture file permissions.");
          }
          synchronized (fileLock) {
            traceFile = newTraceFile;
            traceBytes = 0L;
            captureWritable = true;
          }
          if (!appendEvent("nfc.capture.ready", new JSONObject())) {
            throw new IOException("Could not durably record capture readiness.");
          }
          // Any failure in the final durable status write resets this flag before
          // a later start can succeed.
          captureReady = true;
          writeInitialCaptureStatus();
        } catch (IOException | RuntimeException error) {
          synchronized (fileLock) {
            captureReady = false;
            captureWritable = false;
            traceFile = null;
            traceBytes = 0L;
            reservedNfcTraceBytes = 0L;
          }
          synchronized (rfAuthorizationLock) {
            if (!rfTransactionLeaseBinding.isHeldByMaintenance(
                maintenanceLease)) {
              throw new IOException(
                  "Protocol authorization lease was lost during rollback.",
                  error);
            }
            deleteIfPresent(newTraceFile);
            deleteIfPresent(new File(directory, CAPTURE_STATUS_FILE));
            deleteIfPresent(new File(directory, GRANT_CONTEXT_FILE));
            deleteIfPresent(new File(directory, TARGET_CONTEXT_FILE));
            deleteIfPresent(new File(directory, TARGET_UNVERIFIED_PROBE_GRANT_FILE));
            deleteIfPresent(
                new File(directory, TARGET_UNVERIFIED_PROBE_GRANT_FILE + ".pending"));
            deleteIfPresent(
                new File(
                    directory,
                    TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE));
            deleteIfPresent(
                new File(
                    directory,
                    TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE + ".pending"));
            deleteIfPresent(
                new File(
                    directory,
                    TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE));
            deleteIfPresent(
                new File(
                    directory,
                    TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE + ".pending"));
            deleteIfPresent(new File(directory, NFC_PATCH_INFO_CONTEXT_FILE));
            deleteIfPresent(new File(directory, NFC_GEN1_FRAM_CAPTURE_FILE));
            syncDirectory(directory);
          }
          if (error instanceof IOException) {
            throw (IOException) error;
          }
          throw new IOException("Could not initialize protocol capture.", error);
        }
    }
    } finally {
      finishAuthorizationMutationLease(maintenanceLease);
    }
  }

  private void writeInitialCaptureStatus() throws IOException {
    if (!captureReady || !captureWritable || captureDirectory == null || traceFile == null) {
      throw new IOException("Protocol capture is not ready.");
    }
    final Instant now = Instant.now();
    final JSONObject status = new JSONObject();
    addNativeStatusIdentity(status);
    put(status, "processSessionId", expectedDartProcessSessionId);
    put(status, "bleTraceSessionId", JSONObject.NULL);
    put(status, "bleTraceFileName", JSONObject.NULL);
    put(status, "scannerState", "not_started");
    put(status, "scannerServiceUuids", new JSONArray());
    put(status, "sinkState", "not_started");
    put(status, "lastCommittedBleSequence", JSONObject.NULL);
    put(status, "lastCommittedBleRecordedAtUtc", JSONObject.NULL);
    put(status, "capacityReached", false);
    put(status, "sinkErrorCode", JSONObject.NULL);
    put(status, "heartbeatAtUtc", now.toString());
    put(status, "heartbeatMonotonicMicroseconds", SystemClock.elapsedRealtimeNanos() / 1_000L);
    put(status, "stopping", false);
    put(status, "activityResumed", resumed);
    put(status, "rfPointOfUseEligible", false);
    put(status, "statusCommittedAtUtc", now.toString());
    put(status, "statusCommittedAtElapsedRealtimeNanos", SystemClock.elapsedRealtimeNanos());

    final JSONObject event = new JSONObject();
    put(event, "scannerState", "not_started");
    put(event, "sinkState", "not_started");
    if (!appendEvent("ble.capture.status", event)) {
      invalidateCaptureStatus();
      throw new IOException("Could not durably record initial BLE capture status.");
    }
    persistCaptureStatus(status);
  }

  private synchronized void writeBleCaptureStatus(
      long expectedCaptureEpoch, Object arguments)
      throws IOException {
    if (expectedCaptureEpoch != captureEpoch) {
      throw new IllegalArgumentException(
          "Status belongs to another native capture session.");
    }
    if (!(arguments instanceof Map<?, ?>)) {
      throw new IllegalArgumentException("Expected a status map.");
    }
    if (!captureRequested
        || !captureReady
        || !captureWritable
        || captureDirectory == null
        || traceFile == null) {
      invalidateCaptureStatus();
      throw new IOException("Protocol capture is not active.");
    }
    final Map<?, ?> values = (Map<?, ?>) arguments;
    validateStatusKeys(values);
    final String processSessionId = requiredSafeToken(values, "processSessionId");
    if (!processSessionId.equals(expectedDartProcessSessionId)) {
      throw new IllegalArgumentException("Status belongs to another Dart process session.");
    }
    final String bleTraceSessionId = requiredSafeToken(values, "bleTraceSessionId");
    final String scannerState =
        requiredEnum(
            values,
            "scannerState",
            "not_started",
            "starting",
            "running",
            "suspended",
            "stopped",
            "error");
    final String sinkState = requiredEnum(values, "sinkState", "not_started", "healthy", "capacity_reached", "write_error", "closed");
    final boolean capacityReached = requiredBoolean(values, "capacityReached");
    final boolean stopping = requiredBoolean(values, "stopping");
    final String bleTraceFileName = optionalTraceFileName(values.get("bleTraceFileName"));
    if (bleTraceFileName != null) {
      final String expectedPrefix = "ble-" + bleTraceSessionId + "-";
      if (!bleTraceFileName.startsWith(expectedPrefix)
          || !bleTraceFileName
              .substring(expectedPrefix.length())
              .matches("^[0-9]{2}\\.jsonl$")) {
        throw new IllegalArgumentException(
            "BLE trace file does not belong to its trace session.");
      }
    }
    final Long lastCommittedSequence = optionalPositiveLong(values.get("lastCommittedBleSequence"));
    final String lastCommittedAt = optionalInstant(values.get("lastCommittedBleRecordedAtUtc"));
    final String sinkErrorCode = optionalSafeErrorCode(values.get("sinkErrorCode"));
    final String heartbeatAt = requiredInstant(values, "heartbeatAtUtc");
    final long heartbeatMonotonic = requiredPositiveLong(values, "heartbeatMonotonicMicroseconds");
    final JSONArray serviceUuids = validatedServiceUuids(values.get("scannerServiceUuids"));

    final long nativeNowMillis = System.currentTimeMillis();
    final long heartbeatMillis = Instant.parse(heartbeatAt).toEpochMilli();
    if (heartbeatMillis > nativeNowMillis + MAX_CLOCK_SKEW_MILLIS
        || nativeNowMillis - heartbeatMillis > 15_000L) {
      throw new IllegalArgumentException("Heartbeat is stale or in the future.");
    }
    if (dartProcessSessionId != null
        && !dartProcessSessionId.equals(processSessionId)) {
      throw new IllegalArgumentException("Process session changed without native restart.");
    }
    if (dartProcessSessionId != null
        && heartbeatMonotonic <= lastDartHeartbeatMonotonicMicroseconds) {
      throw new IllegalArgumentException("Process heartbeat did not advance.");
    }
    if ("healthy".equals(sinkState)) {
      if (capacityReached
          || bleTraceFileName == null
          || lastCommittedSequence == null
          || lastCommittedAt == null
          || sinkErrorCode != null) {
        throw new IllegalArgumentException("Healthy sink status is incomplete.");
      }
      final long lastCommitMillis = Instant.parse(lastCommittedAt).toEpochMilli();
      if (lastCommitMillis > nativeNowMillis + MAX_CLOCK_SKEW_MILLIS
          || nativeNowMillis - lastCommitMillis > 15_000L) {
        throw new IllegalArgumentException("Healthy sink commit is stale.");
      }
      if (dartProcessSessionId != null
          && lastCommittedSequence <= lastPublishedBleSequence) {
        throw new IllegalArgumentException("Healthy BLE trace sequence did not advance.");
      }
    } else if ("capacity_reached".equals(sinkState) && !capacityReached) {
      throw new IllegalArgumentException("Capacity status is inconsistent.");
    } else if ("write_error".equals(sinkState) && sinkErrorCode == null) {
      throw new IllegalArgumentException("Write error status needs a safe code.");
    }
    // The established Libre profile is filtered to exactly FDE3. A full-app
    // debug session can add exactly the reviewed AiDEX 181F service so the
    // production AiDEX/LinX driver and passive Libre recorder share one
    // physical scan. The explicit Yuwell passive profile is represented by an
    // exact empty list because its official discovery flow cannot be selected
    // reliably by advertised service UUID. Any other filter fails closed.
    if ("running".equals(scannerState)
        && !isExactProtocolCaptureFilter(serviceUuids)) {
      throw new IllegalArgumentException(
          "Running scanner does not use an approved protocol capture filter.");
    }

    final boolean rfPointOfUseEligible =
        "running".equals(scannerState)
            && "healthy".equals(sinkState)
            && !capacityReached
            && !stopping
            && resumed;
    if (!rfPointOfUseEligible) {
      revokeBleHostRfEligibility(true);
    }
    final JSONObject status = new JSONObject();
    addNativeStatusIdentity(status);
    put(status, "processSessionId", processSessionId);
    put(status, "bleTraceSessionId", bleTraceSessionId);
    put(status, "bleTraceFileName", bleTraceFileName == null ? JSONObject.NULL : bleTraceFileName);
    put(status, "scannerState", scannerState);
    put(status, "scannerServiceUuids", serviceUuids);
    put(status, "sinkState", sinkState);
    put(status, "lastCommittedBleSequence", lastCommittedSequence == null ? JSONObject.NULL : lastCommittedSequence);
    put(status, "lastCommittedBleRecordedAtUtc", lastCommittedAt == null ? JSONObject.NULL : lastCommittedAt);
    put(status, "capacityReached", capacityReached);
    put(status, "sinkErrorCode", sinkErrorCode == null ? JSONObject.NULL : sinkErrorCode);
    put(status, "heartbeatAtUtc", heartbeatAt);
    put(status, "heartbeatMonotonicMicroseconds", heartbeatMonotonic);
    put(status, "stopping", stopping);
    put(status, "activityResumed", resumed);
    put(status, "rfPointOfUseEligible", rfPointOfUseEligible);
    put(status, "statusCommittedAtUtc", Instant.now().toString());
    put(status, "statusCommittedAtElapsedRealtimeNanos", SystemClock.elapsedRealtimeNanos());

    final JSONObject event = new JSONObject();
    put(event, "processSessionId", processSessionId);
    put(event, "scannerState", scannerState);
    put(event, "sinkState", sinkState);
    put(event, "lastCommittedBleSequence", lastCommittedSequence == null ? JSONObject.NULL : lastCommittedSequence);
    put(event, "stopping", stopping);
    if (!appendEvent("ble.capture.status", event)) {
      invalidateCaptureStatus();
      throw new IOException("Could not durably audit BLE capture status.");
    }
    persistCaptureStatus(status);
    synchronized (rfAuthorizationLock) {
      dartProcessSessionId = processSessionId;
      lastDartHeartbeatMonotonicMicroseconds = heartbeatMonotonic;
      if (lastCommittedSequence != null) {
        lastPublishedBleSequence = lastCommittedSequence;
      }
    }
    if (rfPointOfUseEligible) {
      updateRfEligibility(true);
    }
  }

  private void addNativeStatusIdentity(JSONObject status) {
    put(status, "schemaVersion", 2);
    put(status, "nativeCaptureSessionId", sessionToken);
    put(status, "processId", android.os.Process.myPid());
    put(status, "versionCode", installedVersionCode);
    put(status, "lastUpdateTime", installedLastUpdateTime);
    put(status, "nativeCaptureWritable", captureWritable);
    put(status, "nfcTraceFileName", traceFile == null ? JSONObject.NULL : traceFile.getName());
  }

  private void persistCaptureStatus(JSONObject status) throws IOException {
    try {
      writePrivateJson(new File(captureDirectory, CAPTURE_STATUS_FILE), status);
    } catch (IOException error) {
      invalidateCaptureStatus();
      throw error;
    }
  }

  private void invalidateCaptureStatus() {
    captureWritable = false;
    revokeRfEligibility(true);
    final File directory = captureDirectory;
    if (directory != null) {
      deleteIfPresent(new File(directory, CAPTURE_STATUS_FILE));
      try {
        syncDirectory(directory);
      } catch (IOException ignored) {
        // A failed invalidation cannot be repaired safely in process. The
        // writable flag remains false so no NFC command or fresh heartbeat can
        // be emitted, and the harness also requires advancing heartbeats.
      }
    }
  }

  private void invalidateCaptureStatusForEpoch(long expectedCaptureEpoch) {
    synchronized (captureEpochLock) {
      if (expectedCaptureEpoch == captureEpoch) {
        invalidateCaptureStatus();
      }
    }
  }

  private void updateRfEligibility(boolean eligible) {
    if (!eligible) {
      revokeBleHostRfEligibility(true);
      return;
    }
    final boolean becameEligible;
    final long expectedCaptureEpoch = captureEpoch;
    final long statusElapsedRealtimeNanos;
    synchronized (rfAuthorizationLock) {
      if (!captureRequested || !resumed || !captureReady || !captureWritable) {
        bleCaptureRfEligible = false;
        lastBleEligibleStatusElapsedRealtimeNanos = 0L;
        rfEligibilityHandler.removeCallbacksAndMessages(null);
        return;
      }
      becameEligible = !bleCaptureRfEligible;
      bleCaptureRfEligible = true;
      statusElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos();
      lastBleEligibleStatusElapsedRealtimeNanos = statusElapsedRealtimeNanos;
    }
    scheduleRfEligibilityExpiry(
        expectedCaptureEpoch, statusElapsedRealtimeNanos);
    if (becameEligible) {
      publishReaderStatusForEpoch(expectedCaptureEpoch);
    }
  }

  private void scheduleRfEligibilityExpiry(
      long expectedCaptureEpoch, long expectedStatusElapsedRealtimeNanos) {
    rfEligibilityHandler.removeCallbacksAndMessages(null);
    final long delayMillis =
        (MAX_BLE_RF_STATUS_AGE_NANOS + 999_999L) / 1_000_000L;
    rfEligibilityHandler.postDelayed(
        () ->
            expireRfEligibilityIfStale(
                expectedCaptureEpoch, expectedStatusElapsedRealtimeNanos),
        delayMillis);
  }

  private void expireRfEligibilityIfStale(
      long expectedCaptureEpoch, long expectedStatusElapsedRealtimeNanos) {
    final long now = SystemClock.elapsedRealtimeNanos();
    final long remainingNanos;
    synchronized (rfAuthorizationLock) {
      if (expectedCaptureEpoch != captureEpoch
          || !bleCaptureRfEligible
          || expectedStatusElapsedRealtimeNanos <= 0L
          || lastBleEligibleStatusElapsedRealtimeNanos
              != expectedStatusElapsedRealtimeNanos
          || now < expectedStatusElapsedRealtimeNanos) {
        return;
      }
      remainingNanos =
          MAX_BLE_RF_STATUS_AGE_NANOS
              - (now - expectedStatusElapsedRealtimeNanos);
    }
    if (remainingNanos > 0L) {
      rfEligibilityHandler.postDelayed(
          () ->
              expireRfEligibilityIfStale(
                  expectedCaptureEpoch, expectedStatusElapsedRealtimeNanos),
          (remainingNanos + 999_999L) / 1_000_000L);
      return;
    }
    revokeBleHostRfEligibilityIfStatusMatches(
        expectedCaptureEpoch, expectedStatusElapsedRealtimeNanos);
  }

  private void revokeBleHostRfEligibilityIfStatusMatches(
      long expectedCaptureEpoch, long expectedStatusElapsedRealtimeNanos) {
    final NfcV cancelled;
    final Libre2NfcSetupAttempt cancelledAttempt;
    NfcRfTransactionLease maintenanceLease;
    final boolean notifyUi;
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasUnreservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch)
              || hasReservedExplicitNfcSetupTraceCapacity(
                  expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        if (expectedCaptureEpoch != captureEpoch
            || !bleCaptureRfEligible
            || lastBleEligibleStatusElapsedRealtimeNanos
                != expectedStatusElapsedRealtimeNanos) {
          return;
        }
        final long now = SystemClock.elapsedRealtimeNanos();
        if (now < expectedStatusElapsedRealtimeNanos
            || now - expectedStatusElapsedRealtimeNanos
                < MAX_BLE_RF_STATUS_AGE_NANOS) {
          return;
        }
        final Libre2NfcSetupAttempt currentAttempt =
            explicitNfcSetupAttempt;
        bleCaptureRfEligible = false;
        lastBleEligibleStatusElapsedRealtimeNanos = 0L;
        if (currentAttempt != null
            && isExplicitNfcSetupBindingReadyLocked(
                expectedCaptureEpoch,
                currentAttempt.rfAuthorizationGeneration(),
                now,
                currentAttempt,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)) {
          // A valid BLE heartbeat is required only by host-authorized RF
          // work. Preserve the exact app-owned NFC attempt and its generation.
          return;
        }
        cancelledAttempt = currentAttempt;
        notifyUi = captureRequested && resumed && cancelledAttempt == null;
        rfAuthorizationGeneration += 1L;
        if (cancelledAttempt != null) {
          maintenanceLease =
              terminalizeExplicitNfcSetupAttempt(
                  cancelledAttempt,
                  inFlightNfcV,
                  "nfc.explicit_setup.connection.cancelled",
                  "bleEligibilityExpired");
          cancelled = null;
        } else {
          cancelled = inFlightNfcV;
          inFlightNfcV = null;
          inFlightExplicitNfcSetupAttemptId = null;
          maintenanceLease =
              claimActiveRfTransactionLeaseForMaintenanceLocked(null);
        }
      }
    }
    cancelExplicitNfcSetupExpiry(cancelledAttempt);
    closeNfcVQuietly(cancelled);
    finishRfEligibilityRevocation(
        expectedCaptureEpoch, maintenanceLease, notifyUi, true);
    publishCancelledExplicitAttempt(cancelledAttempt);
  }

  private void revokeBleHostRfEligibility(boolean deleteGrant) {
    final NfcV cancelled;
    final Libre2NfcSetupAttempt cancelledAttempt;
    NfcRfTransactionLease maintenanceLease;
    final long expectedCaptureEpoch = captureEpoch;
    final boolean notifyUi;
    rfEligibilityHandler.removeCallbacksAndMessages(null);
    synchronized (captureEpochLock) {
      final boolean noHostAuthorizationArtifacts =
          grantKindForEpoch(expectedCaptureEpoch) == GrantKind.NONE;
      final boolean traceCapacityAvailable =
          hasUnreservedExplicitNfcSetupTraceCapacity(expectedCaptureEpoch)
              || hasReservedExplicitNfcSetupTraceCapacity(
                  expectedCaptureEpoch);
      synchronized (rfAuthorizationLock) {
        final Libre2NfcSetupAttempt currentAttempt =
            explicitNfcSetupAttempt;
        final long now = SystemClock.elapsedRealtimeNanos();
        final boolean wasBleCaptureRfEligible = bleCaptureRfEligible;
        bleCaptureRfEligible = false;
        lastBleEligibleStatusElapsedRealtimeNanos = 0L;
        if (currentAttempt != null
            && isExplicitNfcSetupBindingReadyLocked(
                expectedCaptureEpoch,
                currentAttempt.rfAuthorizationGeneration(),
                now,
                currentAttempt,
                traceCapacityAvailable,
                noHostAuthorizationArtifacts)) {
          // Scanner and BLE sink health do not authorize this exact one-read
          // NFC setup lane. Do not alter its attempt, lease, or generation.
          return;
        }
        cancelledAttempt = currentAttempt;
        notifyUi =
            wasBleCaptureRfEligible
                && captureRequested
                && resumed
                && cancelledAttempt == null;
        rfAuthorizationGeneration += 1L;
        if (cancelledAttempt != null) {
          maintenanceLease =
              terminalizeExplicitNfcSetupAttempt(
                  cancelledAttempt,
                  inFlightNfcV,
                  "nfc.explicit_setup.connection.cancelled",
                  "bleEligibilityRevoked");
          cancelled = null;
        } else {
          cancelled = inFlightNfcV;
          inFlightNfcV = null;
          inFlightExplicitNfcSetupAttemptId = null;
          maintenanceLease =
              claimActiveRfTransactionLeaseForMaintenanceLocked(null);
        }
      }
    }
    cancelExplicitNfcSetupExpiry(cancelledAttempt);
    closeNfcVQuietly(cancelled);
    finishRfEligibilityRevocation(
        expectedCaptureEpoch, maintenanceLease, notifyUi, deleteGrant);
    publishCancelledExplicitAttempt(cancelledAttempt);
  }

  private void revokeRfEligibility(boolean deleteGrant) {
    final NfcV cancelled;
    final Libre2NfcSetupAttempt cancelledAttempt;
    NfcRfTransactionLease maintenanceLease;
    final long expectedCaptureEpoch;
    final boolean notifyUi;
    rfEligibilityHandler.removeCallbacksAndMessages(null);
    synchronized (rfAuthorizationLock) {
      cancelledAttempt = explicitNfcSetupAttempt;
      notifyUi =
          bleCaptureRfEligible
              && captureRequested
              && resumed
              && cancelledAttempt == null;
      bleCaptureRfEligible = false;
      lastBleEligibleStatusElapsedRealtimeNanos = 0L;
      rfAuthorizationGeneration += 1L;
      expectedCaptureEpoch =
          cancelledAttempt == null
              ? captureEpoch
              : cancelledAttempt.captureEpoch();
      if (cancelledAttempt != null) {
        maintenanceLease =
            terminalizeExplicitNfcSetupAttempt(
                cancelledAttempt,
                inFlightNfcV,
                "nfc.explicit_setup.connection.cancelled",
                "authorizationRevoked");
        cancelled = null;
      } else {
        cancelled = inFlightNfcV;
        inFlightNfcV = null;
        inFlightExplicitNfcSetupAttemptId = null;
        maintenanceLease =
            claimActiveRfTransactionLeaseForMaintenanceLocked(null);
      }
    }
    cancelExplicitNfcSetupExpiry(cancelledAttempt);
    closeNfcVQuietly(cancelled);
    finishRfEligibilityRevocation(
        expectedCaptureEpoch, maintenanceLease, notifyUi, deleteGrant);
    publishCancelledExplicitAttempt(cancelledAttempt);
  }

  private void finishRfEligibilityRevocation(
      long expectedCaptureEpoch,
      NfcRfTransactionLease claimedMaintenanceLease,
      boolean notifyUi,
      boolean deleteGrant) {
    synchronized (rfAuthorizationLock) {
      if (quarantinedStreamingLease != null) {
        captureWritable = false;
        captureReady = false;
        return;
      }
      if (streamingAttempt != null && streamingAttempt.claimed
          && streamingAttempt.lease == activeHostRfTransactionLease) {
        streamingAttempt.cancelled = true;
        // Do not steal or release the callback's exact lease during cancellation.
        return;
      }
    }
    NfcRfTransactionLease maintenanceLease = claimedMaintenanceLease;
    if (deleteGrant && maintenanceLease == null) {
      maintenanceLease =
          beginAuthorizationMutationLease(expectedCaptureEpoch);
    }
    try {
      if (deleteGrant) {
        final File directory = captureDirectory;
        if (maintenanceLease == null
            || directory == null
            || !deleteAuthorizationArtifacts(
                directory,
                true,
                RfMutationOwner.MAINTENANCE,
                null,
                maintenanceLease)) {
          captureWritable = false;
          captureReady = false;
        }
      }
    } finally {
      if (maintenanceLease != null) {
        finishAuthorizationMutationLease(maintenanceLease);
      }
    }
    if (notifyUi) {
      publishUiEventForEpoch(
          expectedCaptureEpoch, "failed", null, null, "readFailed");
    }
  }

  private void revokeRfEligibilityForEpoch(
      long expectedCaptureEpoch, boolean deleteGrant) {
    synchronized (captureEpochLock) {
      if (expectedCaptureEpoch == captureEpoch) {
        revokeRfEligibility(deleteGrant);
      }
    }
  }

  private static String requiredSafeToken(Map<?, ?> values, String key) {
    final Object value = values.get(key);
    if (!(value instanceof String)
        || !((String) value).matches("^[A-Za-z0-9_-]{8,120}$")) {
      throw new IllegalArgumentException("Invalid status token.");
    }
    return (String) value;
  }

  private static void validateStatusKeys(Map<?, ?> values) {
    if (values.size() != 13) {
      throw new IllegalArgumentException("Unexpected BLE capture status fields.");
    }
    for (Object key : values.keySet()) {
      if (!(key instanceof String)) {
        throw new IllegalArgumentException("Invalid BLE capture status field.");
      }
      switch ((String) key) {
        case "processSessionId":
        case "bleTraceSessionId":
        case "bleTraceFileName":
        case "scannerState":
        case "scannerServiceUuids":
        case "sinkState":
        case "lastCommittedBleSequence":
        case "lastCommittedBleRecordedAtUtc":
        case "capacityReached":
        case "sinkErrorCode":
        case "heartbeatAtUtc":
        case "heartbeatMonotonicMicroseconds":
        case "stopping":
          break;
        default:
          throw new IllegalArgumentException("Unexpected BLE capture status field.");
      }
    }
  }

  private static String requiredEnum(
      Map<?, ?> values, String key, String... allowedValues) {
    final Object value = values.get(key);
    if (!(value instanceof String)) {
      throw new IllegalArgumentException("Invalid status enum.");
    }
    for (String allowed : allowedValues) {
      if (allowed.equals(value)) {
        return (String) value;
      }
    }
    throw new IllegalArgumentException("Invalid status enum.");
  }

  private static boolean requiredBoolean(Map<?, ?> values, String key) {
    final Object value = values.get(key);
    if (!(value instanceof Boolean)) {
      throw new IllegalArgumentException("Invalid status boolean.");
    }
    return (Boolean) value;
  }

  private static long requiredPositiveLong(Map<?, ?> values, String key) {
    final Long value = optionalPositiveLong(values.get(key));
    if (value == null) {
      throw new IllegalArgumentException("Invalid positive status integer.");
    }
    return value;
  }

  private static Long optionalPositiveLong(Object value) {
    if (value == null) {
      return null;
    }
    if (!(value instanceof Byte)
        && !(value instanceof Short)
        && !(value instanceof Integer)
        && !(value instanceof Long)) {
      throw new IllegalArgumentException("Invalid status integer.");
    }
    final long encoded = ((Number) value).longValue();
    if (encoded < 1L) {
      throw new IllegalArgumentException("Invalid status integer.");
    }
    return encoded;
  }

  private static String requiredInstant(Map<?, ?> values, String key) {
    final String value = optionalInstant(values.get(key));
    if (value == null) {
      throw new IllegalArgumentException("Invalid status timestamp.");
    }
    return value;
  }

  private static String optionalInstant(Object value) {
    if (value == null) {
      return null;
    }
    if (!(value instanceof String)) {
      throw new IllegalArgumentException("Invalid status timestamp.");
    }
    try {
      return Instant.parse((String) value).toString();
    } catch (RuntimeException error) {
      throw new IllegalArgumentException("Invalid status timestamp.", error);
    }
  }

  private static String optionalTraceFileName(Object value) {
    if (value == null) {
      return null;
    }
    if (!(value instanceof String)
        || !((String) value).matches("^ble-[A-Za-z0-9_-]{8,120}-[0-9]{2}\\.jsonl$")) {
      throw new IllegalArgumentException("Invalid BLE trace file name.");
    }
    return (String) value;
  }

  private static String optionalSafeErrorCode(Object value) {
    if (value == null) {
      return null;
    }
    if (!(value instanceof String)
        || !((String) value).matches("^[a-z][a-z0-9_]{0,63}$")) {
      throw new IllegalArgumentException("Invalid safe sink error code.");
    }
    return (String) value;
  }

  private static JSONArray validatedServiceUuids(Object value) {
    if (!(value instanceof List<?>)) {
      throw new IllegalArgumentException("Invalid scanner service list.");
    }
    final List<?> raw = (List<?>) value;
    if (raw.size() > 16) {
      throw new IllegalArgumentException("Scanner service list is too large.");
    }
    final JSONArray encoded = new JSONArray();
    final Set<String> unique = new HashSet<>();
    for (Object item : raw) {
      if (!(item instanceof String)) {
        throw new IllegalArgumentException("Invalid scanner service UUID.");
      }
      final String uuid = ((String) item).toLowerCase(Locale.ROOT);
      if (!uuid.matches("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
          || !unique.add(uuid)) {
        throw new IllegalArgumentException("Invalid scanner service UUID.");
      }
      encoded.put(uuid);
    }
    return encoded;
  }

  private static boolean isExactProtocolCaptureFilter(JSONArray serviceUuids) {
    return serviceUuids.length() == 0
        || (serviceUuids.length() == 1
            && LIBRE2_REFERENCE_SERVICE_UUID.equals(serviceUuids.optString(0, "")))
        || (serviceUuids.length() == 2
            && LIBRE2_REFERENCE_SERVICE_UUID.equals(serviceUuids.optString(0, ""))
            && AIDEX_CGM_SERVICE_UUID.equals(serviceUuids.optString(1, "")));
  }

  private static void pruneOldNfcTraces(File directory) throws IOException {
    final File[] traces =
        directory.listFiles(
            (parent, name) -> name.startsWith("nfc-") && name.endsWith(".jsonl"));
    if (traces == null) {
      throw new IOException("Could not inspect protocol capture retention.");
    }
    Arrays.sort(
        traces,
        Comparator.comparingLong(File::lastModified).thenComparing(File::getName));
    final int deleteCount = Math.max(0, traces.length - (MAX_NFC_TRACE_FILES - 1));
    for (int index = 0; index < deleteCount; index += 1) {
      if (!traces[index].delete()) {
        throw new IOException("Could not enforce protocol capture retention.");
      }
    }
  }

  private static void deleteIfPresent(File file) {
    if (file != null && file.exists()) {
      file.delete();
    }
  }

  private boolean deleteAuthorizationArtifacts(
      File directory,
      boolean deletePatchContext,
      RfMutationOwner mutationOwner,
      Libre2NfcSetupAttempt explicitAttempt,
      NfcRfTransactionLease maintenanceLease) {
    synchronized (rfAuthorizationLock) {
      if (directory == null
          || !directory.isDirectory()
          || !isRfMutationLeaseHeld(
              mutationOwner, explicitAttempt, maintenanceLease)) {
        return false;
      }
      boolean removed = true;
      final String[] grantNames = {
        TARGET_UNVERIFIED_PROBE_GRANT_FILE,
        TARGET_UNVERIFIED_PROBE_GRANT_FILE + ".pending",
        TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE,
        TARGET_UNVERIFIED_GEN1_FRAM_READ_GRANT_FILE + ".pending",
        TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE,
        TARGET_UNVERIFIED_GEN1_ACTIVATION_GRANT_FILE + ".pending",
      };
      for (String name : grantNames) {
        final File file = new File(directory, name);
        if (file.exists() && !file.delete()) {
          removed = false;
        }
      }
      if (deletePatchContext) {
        final File context =
            new File(directory, NFC_PATCH_INFO_CONTEXT_FILE);
        if (context.exists() && !context.delete()) {
          removed = false;
        }
      }
      try {
        syncDirectory(directory);
      } catch (IOException error) {
        return false;
      }
      return removed;
    }
  }

  @SuppressWarnings("deprecation")
  private void prepareGrantContext(
      File directory, NfcRfTransactionLease maintenanceLease)
      throws IOException {
    try {
      final PackageInfo packageInfo =
          activity.getPackageManager().getPackageInfo(activity.getPackageName(), 0);
      installedVersionCode =
          Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
              ? packageInfo.getLongVersionCode()
              : packageInfo.versionCode;
      installedLastUpdateTime = packageInfo.lastUpdateTime;
    } catch (PackageManager.NameNotFoundException error) {
      throw new IOException("Could not read installed build identity.", error);
    }

    synchronized (rfAuthorizationLock) {
      if (!rfTransactionLeaseBinding.isHeldByMaintenance(maintenanceLease)
          || !deleteAuthorizationArtifacts(
              directory,
              true,
              RfMutationOwner.MAINTENANCE,
              null,
              maintenanceLease)) {
        throw new IOException("Could not remove stale protocol authorization.");
      }
      final File staleTargetContext = new File(directory, TARGET_CONTEXT_FILE);
      if (staleTargetContext.exists() && !staleTargetContext.delete()) {
        throw new IOException("Could not remove a stale NFC target context.");
      }
      final File staleFramCapture =
          new File(directory, NFC_GEN1_FRAM_CAPTURE_FILE);
      if (staleFramCapture.exists() && !staleFramCapture.delete()) {
        throw new IOException("Could not remove a stale private FRAM capture.");
      }
      syncDirectory(directory);

      final JSONObject context = new JSONObject();
      put(context, "schemaVersion", GRANT_SCHEMA_VERSION);
      put(context, "nonce", grantNonce);
      put(context, "nativeCaptureSessionId", sessionToken);
      put(context, "processSessionId", expectedDartProcessSessionId);
      put(context, "versionCode", installedVersionCode);
      put(context, "lastUpdateTime", installedLastUpdateTime);
      put(
          context,
          "expectedReferenceIso15693ManufacturerPrefix",
          EXPECTED_REFERENCE_ISO15693_MANUFACTURER_PREFIX);
      writePrivateJson(new File(directory, GRANT_CONTEXT_FILE), context);
    }
  }

  private static void writePrivateJson(File file, JSONObject value)
      throws IOException {
    final File parent = file.getParentFile();
    if (parent == null || !parent.isDirectory()) {
      throw new IOException("Private protocol directory is unavailable.");
    }
    final File temporary =
        new File(
            parent,
            "." + file.getName() + ".tmp-" + UUID.randomUUID().toString().replace("-", ""));
    try {
      try (FileOutputStream output = new FileOutputStream(temporary, false)) {
        output.write(value.toString().getBytes(StandardCharsets.UTF_8));
        output.flush();
        output.getFD().sync();
      }
      temporary.setReadable(false, false);
      temporary.setWritable(false, false);
      if (!temporary.setReadable(true, true) || !temporary.setWritable(true, true)) {
        throw new IOException("Could not restrict private protocol status.");
      }
      try {
        Os.rename(temporary.getAbsolutePath(), file.getAbsolutePath());
      } catch (ErrnoException error) {
        throw new IOException("Could not publish private protocol status.", error);
      }
      syncDirectory(parent);
    } finally {
      deleteIfPresent(temporary);
    }
  }

  private static void syncDirectory(File directory) throws IOException {
    FileDescriptor descriptor = null;
    try {
      descriptor = Os.open(directory.getAbsolutePath(), OsConstants.O_RDONLY, 0);
      Os.fsync(descriptor);
    } catch (ErrnoException error) {
      throw new IOException("Could not sync private protocol directory.", error);
    } finally {
      if (descriptor != null) {
        try {
          Os.close(descriptor);
        } catch (ErrnoException error) {
          throw new IOException("Could not close private protocol directory.", error);
        }
      }
    }
  }

  private boolean appendEvent(String type, JSONObject data) {
    return appendEvent(-1L, false, type, data);
  }

  private boolean appendEventForEpoch(
      long expectedCaptureEpoch, String type, JSONObject data) {
    return appendEvent(expectedCaptureEpoch, false, type, data);
  }

  private boolean appendReservedEventForEpoch(
      long expectedCaptureEpoch, String type, JSONObject data) {
    return appendEvent(expectedCaptureEpoch, true, type, data);
  }

  private boolean appendEvent(
      long expectedCaptureEpoch,
      boolean consumeTransactionReservation,
      String type,
      JSONObject data) {
    synchronized (fileLock) {
      if ((expectedCaptureEpoch >= 0L
              && expectedCaptureEpoch != captureEpoch)
          || !captureWritable
          || traceFile == null) {
        return false;
      }
      final JSONObject event = new JSONObject();
      put(event, "schemaVersion", 1);
      put(event, "sequence", sequence.incrementAndGet());
      put(event, "recordedAtUtc", Instant.now().toString());
      put(event, "monotonicElapsedNanos", SystemClock.elapsedRealtimeNanos());
      put(event, "type", type);
      put(event, "data", data);
      final byte[] encoded =
          (event.toString() + "\n").getBytes(StandardCharsets.UTF_8);
      if (consumeTransactionReservation) {
        if (reservedNfcTraceBytes < encoded.length) {
          captureWritable = false;
          return false;
        }
        reservedNfcTraceBytes -= encoded.length;
      } else if (traceBytes + encoded.length + reservedNfcTraceBytes
          > MAX_NFC_TRACE_BYTES) {
        captureWritable = false;
        return false;
      }
      if (traceBytes + encoded.length + reservedNfcTraceBytes
          > MAX_NFC_TRACE_BYTES) {
        captureWritable = false;
        return false;
      }
      try (FileOutputStream output = new FileOutputStream(traceFile, true)) {
        output.write(encoded);
        output.flush();
        output.getFD().sync();
        traceBytes += encoded.length;
        return true;
      } catch (IOException ignored) {
        captureWritable = false;
        return false;
      }
    }
  }

  private static final class ProbeGrant {
    final String captureSessionId;
    final long captureEpoch;
    final long expiresAtEpochMillis;
    final long expiresAtElapsedRealtimeNanos;

    ProbeGrant(
        String captureSessionId,
        long captureEpoch,
        long expiresAtEpochMillis,
        long expiresAtElapsedRealtimeNanos) {
      this.captureSessionId = captureSessionId;
      this.captureEpoch = captureEpoch;
      this.expiresAtEpochMillis = expiresAtEpochMillis;
      this.expiresAtElapsedRealtimeNanos = expiresAtElapsedRealtimeNanos;
    }
  }

  private static final class FramReadGrant {
    final String captureSessionId;
    final String model;
    final String patchInfoSha256;
    final long captureEpoch;
    final long expiresAtEpochMillis;
    final long expiresAtElapsedRealtimeNanos;

    FramReadGrant(
        String captureSessionId,
        String model,
        String patchInfoSha256,
        long captureEpoch,
        long expiresAtEpochMillis,
        long expiresAtElapsedRealtimeNanos) {
      this.captureSessionId = captureSessionId;
      this.model = model;
      this.patchInfoSha256 = patchInfoSha256;
      this.captureEpoch = captureEpoch;
      this.expiresAtEpochMillis = expiresAtEpochMillis;
      this.expiresAtElapsedRealtimeNanos = expiresAtElapsedRealtimeNanos;
    }
  }

  private static final class ActivationGrant {
    final String captureSessionId;
    final String attemptId;
    final String patchInfoSha256;
    final String plannedRequestSha256;
    final String sourceCaptureSha256;
    final String sourceEncryptedFramSha256;
    final long captureEpoch;
    final long expiresAtEpochMillis;
    final long expiresAtElapsedRealtimeNanos;

    ActivationGrant(
        String captureSessionId,
        String attemptId,
        String patchInfoSha256,
        String plannedRequestSha256,
        String sourceCaptureSha256,
        String sourceEncryptedFramSha256,
        long captureEpoch,
        long expiresAtEpochMillis,
        long expiresAtElapsedRealtimeNanos) {
      this.captureSessionId = captureSessionId;
      this.attemptId = attemptId;
      this.patchInfoSha256 = patchInfoSha256;
      this.plannedRequestSha256 = plannedRequestSha256;
      this.sourceCaptureSha256 = sourceCaptureSha256;
      this.sourceEncryptedFramSha256 = sourceEncryptedFramSha256;
      this.captureEpoch = captureEpoch;
      this.expiresAtEpochMillis = expiresAtEpochMillis;
      this.expiresAtElapsedRealtimeNanos = expiresAtElapsedRealtimeNanos;
    }
  }

  private static final class PatchInfoClassification {
    final String model;
    final String securityGeneration;

    PatchInfoClassification(String model, String securityGeneration) {
      this.model = model;
      this.securityGeneration = securityGeneration;
    }
  }

  private enum RfMutationOwner {
    HOST,
    MAINTENANCE,
    EXPLICIT,
  }

  private enum ExplicitStateAdvance {
    CONNECTED,
    PATCH_INFO_ACCEPTED,
    FRAM_COMPLETE,
    LIFECYCLE_VALIDATED,
  }

  private enum GrantKind {
    NONE,
    PATCH_INFO,
    GEN1_FRAM_READ,
    GEN1_ACTIVATION,
    CONFLICT,
  }

  private static void put(JSONObject target, String key, Object value) {
    try {
      target.put(key, value);
    } catch (JSONException ignored) {
      // All values supplied here are JSON-safe. If that changes, omit the
      // diagnostic field rather than leaking it through another channel.
    }
  }

  private static String hex(byte[] bytes) {
    final char[] digits = "0123456789abcdef".toCharArray();
    final char[] encoded = new char[bytes.length * 2];
    for (int index = 0; index < bytes.length; index += 1) {
      final int value = bytes[index] & 0xff;
      encoded[index * 2] = digits[value >>> 4];
      encoded[index * 2 + 1] = digits[value & 0x0f];
    }
    return new String(encoded);
  }

  private static String iso15693ManufacturerPrefix(byte[] uid) {
    if (uid.length != 8) {
      return "invalid";
    }
    return hex(new byte[] {uid[7], uid[6]});
  }

  private static byte[] librePatchInfoCommand(byte[] uid) {
    if (uid.length != 8) {
      return null;
    }
    return new byte[] {
      LIBRE_PATCH_INFO_FLAGS,
      LIBRE_PATCH_INFO_CODE,
      uid[6],
    };
  }

  private static String sha256Hex(byte[] bytes) {
    try {
      return hex(java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
    } catch (java.security.NoSuchAlgorithmException impossible) {
      throw new IllegalStateException("SHA-256 is unavailable.", impossible);
    }
  }

  private static String sha256PatchInfoPayload(byte[] response) {
    if (response == null || response.length != 7) {
      throw new IllegalArgumentException(
          "Patch-info response must contain one status and six payload bytes.");
    }
    return sha256Hex(Arrays.copyOfRange(response, 1, response.length));
  }

  private static String newNativeSessionToken() {
    return System.currentTimeMillis()
        + "-"
        + UUID.randomUUID().toString().replace("-", "");
  }

  private static String newGrantNonce() {
    return UUID.randomUUID().toString().replace("-", "");
  }
}
