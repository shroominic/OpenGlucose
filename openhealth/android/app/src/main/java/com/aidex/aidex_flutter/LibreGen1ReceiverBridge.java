package com.aidex.aidex_flutter;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Recorder-free existing-receiver interface. Not registered by the default app.
 * Native composition must exclude the debug recorder for this bridge's lifetime.
 */
final class LibreGen1ReceiverBridge {
  private final Activity activity;
  private final LibreGen1ReceiverCoordinator.Guard backendExclusive;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final LibreGen1StreamingJournal journal;
  private final LibreGen1ReceiverCoordinator coordinator;
  private final LibreGen1ReceiverHistoryBridge history;
  private volatile boolean destroyed;
  private MethodChannel methods;

  LibreGen1ReceiverBridge(Activity activity, LibreGen1ReceiverCoordinator.Guard backendExclusive) {
    this.activity = activity;
    this.backendExclusive = backendExclusive;
    journal = LibreGen1StreamingStore.journal(activity);
    coordinator = new LibreGen1ReceiverCoordinator(journal,
        token -> LibreGen1ReceiverLease.acquire(activity, token), this::allowed);
    history = new LibreGen1ReceiverHistoryBridge(activity, journal, this::allowed,
        () -> allowed() && !coordinator.hasBinding(), worker);
  }

  void register(BinaryMessenger messenger) {
    if (!allowed() || methods != null) throw new IllegalStateException("Receiver backend unavailable.");
    methods = new MethodChannel(messenger, "com.openglucose/libre2_receiver");
    methods.setMethodCallHandler(this::call);
    history.register(messenger);
  }

  void onResume() { history.onResume(); }
  void onPause() { history.onPause(); }

  void destroy() {
    destroyed = true;
    history.destroy();
    if (methods != null) methods.setMethodCallHandler(null);
    worker.shutdown();
    // Destruction is not proof that a Flutter-owned BLE connection closed.
    // Never remove the durable lease or reset a receiver/counter here.
  }

  private boolean allowed() {
    try { return !destroyed && backendExclusive.allowed(); }
    catch (RuntimeException unavailable) { return false; }
  }

  private void call(MethodCall call, MethodChannel.Result result) {
    if (history.call(call, result)) return;
    if ("capabilities".equals(call.method)) {
      if (!(call.arguments instanceof Map) || !((Map<?, ?>) call.arguments).isEmpty()) {
        fail(result, "bad_args"); return;
      }
      final Map<String, Object> value = new HashMap<>();
      value.put("schemaVersion", 1);
      value.put("backend", "receiver");
      value.put("restoreAvailable", allowed());
      value.put("enrollmentAvailable", false);
      value.put("rawCapture", false);
      result.success(value);
      return;
    }
    if (!Arrays.asList("readLibreGen1StreamingBootstrap", "readLibreGen1CalibrationEvidence",
        "acquireLibreGen1Receiver", "reserveLibreGen1UnlockCount", "markLibreGen1LoginOutcome",
        "releaseLibreGen1Receiver").contains(call.method)) {
      result.notImplemented(); return;
    }
    if (!allowed()) { fail(result, "libre_receiver_unavailable"); return; }
    try {
      worker.execute(() -> {
        try {
          if (!allowed()) throw new IllegalStateException();
          final Object value = execute(call);
          main.post(() -> {
            if (allowed()) result.success(value);
            else {
              clearResult(value);
              fail(result, "libre_receiver_unavailable");
            }
          });
        } catch (Exception failure) {
          main.post(() -> fail(result, "libre_receiver_unavailable"));
        }
      });
    } catch (RuntimeException failure) { fail(result, "libre_receiver_unavailable"); }
  }

  private Object execute(MethodCall call) throws Exception {
    if ("readLibreGen1CalibrationEvidence".equals(call.method)) {
      return readCalibration(LibreGen1ReceiverCoordinator.token(
          LibreGen1ReceiverCoordinator.arguments(call.arguments, "bootstrapId"), "bootstrapId"));
    }
    return coordinator.call(call.method, call.arguments);
  }

  /** Protected cache only. No capture/host fallback, lazy write, or counter mutation. */
  private Map<String, Object> readCalibration(String bootstrapId) throws Exception {
    synchronized (journal) {
      LibreGen1StreamingJournal.Record record = null;
      LibreGen1CalibrationEvidence evidence = null;
      byte[] encoded = null;
      try {
        if (!allowed()) throw new IllegalStateException();
        record = journal.read();
        if (record == null || !"confirmed".equals(record.state)
            || !record.bootstrapId.equals(bootstrapId)) return null;
        encoded = new LibreGen1CalibrationStore(activity).read();
        if (encoded == null) return null;
        evidence = LibreGen1CalibrationEvidence.decode(encoded, bootstrapId, record.uid, record.initialPatchInfo);
        if (!allowed()) throw new IllegalStateException();
        final Map<String, Object> result = new HashMap<>();
        result.put("bootstrapId", evidence.bootstrapId);
        result.put("uid", evidence.uid());
        result.put("receiverInitialPatchInfo", evidence.receiverInitialPatchInfo());
        result.put("calibrationPatchInfo", evidence.calibrationPatchInfo());
        result.put("encryptedFram", evidence.encryptedFram());
        return result;
      } catch (Exception unavailable) {
        // Factory evidence is optional. Invalid or unavailable evidence never
        // authorizes glucose, but it must not rewrite or reset a valid receiver.
        return null;
      } finally {
        if (record != null) {
          Arrays.fill(record.uid, (byte) 0);
          Arrays.fill(record.initialPatchInfo, (byte) 0);
        }
        if (encoded != null) Arrays.fill(encoded, (byte) 0);
        if (evidence != null) evidence.close();
      }
    }
  }

  private static void clearResult(Object value) {
    if (value instanceof Map) {
      for (Object item : ((Map<?, ?>) value).values()) {
        if (item instanceof byte[]) Arrays.fill((byte[]) item, (byte) 0);
      }
    }
  }

  private static void fail(MethodChannel.Result result, String code) {
    result.error(code, "Libre receiver is unavailable.", null);
  }
}
