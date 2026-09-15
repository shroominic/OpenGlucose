package com.aidex.aidex_flutter;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.tech.NfcV;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.time.Instant;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Android transport for the debug-exclusive, recorder-free receiver read purpose. */
final class LibreGen1ReceiverHistoryBridge {
  private final Activity activity;
  private final LibreGen1ReceiverCoordinator.Guard allowed;
  private final NfcAdapter adapter;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final LibreGen1ReceiverHistoryCoordinator coordinator;
  private EventChannel channel;
  private volatile EventChannel.EventSink sink;
  private volatile long listenerGeneration;
  private volatile boolean destroyed;
  private volatile boolean resumed;
  private String activeId;

  LibreGen1ReceiverHistoryBridge(Activity activity, LibreGen1StreamingJournal journal,
      LibreGen1ReceiverCoordinator.Guard allowed, LibreGen1ReceiverCoordinator.Guard rfAllowed,
      Executor worker) {
    this.activity = activity; this.allowed = allowed;
    adapter = NfcAdapter.getDefaultAdapter(activity);
    coordinator = new LibreGen1ReceiverHistoryCoordinator(journal,
        token -> LibreGen1ReceiverLease.acquire(activity, token),
        () -> !destroyed && rfAllowed.allowed(), () -> LibreGen1ReceiverLease.idle(activity),
        SystemClock::elapsedRealtimeNanos,
        Instant::now, new Libre2NfcSessionCoordinator.Reader() {
          public void start(Libre2NfcSessionCoordinator.TagCallback callback) {
            adapter.enableReaderMode(activity, tag -> {
              final Libre2Gen1ReadTransaction.Transport transport = transport(tag);
              if (transport != null) callback.detected(transport);
            }, NfcAdapter.FLAG_READER_NFC_V | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK, null);
          }
          public void stop() { adapter.disableReaderMode(activity); }
        }, worker, this::publish);
  }

  void register(BinaryMessenger messenger) {
    channel = new EventChannel(messenger, "com.openglucose/libre2_receiver_history_events");
    channel.setStreamHandler(new EventChannel.StreamHandler() {
      public void onListen(Object arguments, EventChannel.EventSink listener) {
        listenerGeneration++; sink = listener;
      }
      public void onCancel(Object arguments) {
        listenerGeneration++; sink = null;
        // Stream ownership never substitutes for the exact attempt's stop.
      }
    });
  }

  void onResume() { resumed = true; coordinator.resume(); }
  void onPause() {
    resumed = false; coordinator.pause();
    if (activeId != null) armCleanup(coordinator.binding(activeId));
  }
  void destroy() {
    if (destroyed) return;
    destroyed = true; resumed = false; sink = null; listenerGeneration++;
    if (channel != null) channel.setStreamHandler(null);
    coordinator.detach();
    if (activeId != null) armCleanup(coordinator.binding(activeId));
  }

  boolean call(MethodCall call, MethodChannel.Result result) {
    if ("historyCapabilities".equals(call.method)) {
      if (!(call.arguments instanceof Map) || !((Map<?, ?>) call.arguments).isEmpty()) fail(result, "bad_args");
      else result.success(LibreGen1ReceiverHistoryCoordinator.capabilities(available()));
      return true;
    }
    if (!Arrays.asList("startLibreGen1HistoryRead", "stopLibreGen1HistoryRead",
        "readLibreGen1FreshHistoryEvidence", "discardLibreGen1FreshHistoryEvidence").contains(call.method)) return false;
    try {
      final String id = LibreGen1ReceiverHistoryCoordinator.target(call.arguments)[0];
      if ("stopLibreGen1HistoryRead".equals(call.method)) {
        final Object binding = coordinator.binding(id);
        final CompletableFuture<Void> stopped = coordinator.stop(call.arguments);
        armCleanup(binding);
        stopped.whenComplete((ignored, failure) -> main.post(() -> {
          if (failure == null) result.success(null);
          else fail(result, "nfc_cleanup_unconfirmed");
        }));
      } else if ("discardLibreGen1FreshHistoryEvidence".equals(call.method)) {
        coordinator.discard(call.arguments); result.success(null);
      } else if ("readLibreGen1FreshHistoryEvidence".equals(call.method)) {
        // Coordinator rechecks current identity, clocks and explicit stop here,
        // then wipes all transferred arrays after synchronous channel encoding.
        coordinator.deliver(call.arguments, result::success);
      } else {
        if (!available()) throw new IllegalStateException("nfc_unavailable");
        if (!adapter.isEnabled()) throw new IllegalStateException("nfc_disabled");
        try {
          final Object binding = coordinator.start(call.arguments);
          activeId = id; coordinator.bindDeadline(binding);
          main.postDelayed(() -> { coordinator.expire(binding); armCleanup(binding); }, 120_000L);
          result.success(null);
        } catch (Exception failure) {
          final Object binding = coordinator.binding(id);
          if (binding != null) { activeId = id; coordinator.bindDeadline(binding); armCleanup(binding); }
          throw failure;
        }
      }
    } catch (Exception failure) {
      final String code = failure.getMessage();
      fail(result, Arrays.asList("bad_args", "nfc_unavailable", "nfc_disabled", "nfc_not_foreground",
          "nfc_attempt_active", "nfc_attempt_mismatch", "nfc_cleanup_unconfirmed", "nfc_state_blocked",
          "nfc_start_failed", "libre_history_evidence_unavailable").contains(code)
          ? code : "libre_history_evidence_unavailable");
    }
    return true;
  }

  private boolean available() {
    try {
      return !destroyed && allowed.allowed() && adapter != null
          && activity.checkSelfPermission(Manifest.permission.NFC) == PackageManager.PERMISSION_GRANTED;
    } catch (RuntimeException unavailable) { return false; }
  }
  private void armCleanup(Object binding) {
    if (binding != null) main.postDelayed(() -> coordinator.quarantine(binding), 8_000L);
  }
  private void publish(Map<String, Object> event) {
    final long expectedListener = listenerGeneration;
    final Object binding = coordinator.binding((String) event.get("attemptId"));
    main.post(() -> {
      if (!destroyed && sink != null && listenerGeneration == expectedListener
          && coordinator.acceptsEvent(binding, (String) event.get("event"))
          && (resumed || "failed".equals(event.get("event")))) sink.success(event);
    });
  }
  private Libre2Gen1ReadTransaction.Transport transport(Tag tag) {
    if (tag == null || tag.getId() == null) return null;
    final byte[] uid = tag.getId().clone();
    final boolean supported = uid.length == 8 && uid[7] == (byte) 0xe0 && uid[6] == 7;
    Arrays.fill(uid, (byte) 0);
    if (!supported) return null;
    final NfcV nfc = NfcV.get(tag);
    if (nfc == null) return null;
    return new Libre2Gen1ReadTransaction.Transport() {
      public byte[] uid() { return tag.getId().clone(); }
      public int maxTransceiveLength() { return nfc.getMaxTransceiveLength(); }
      public void connect() throws Exception { nfc.connect(); }
      public byte[] transceive(byte[] request) throws Exception { return nfc.transceive(request); }
      public void close() throws Exception { nfc.close(); }
    };
  }
  private static void fail(MethodChannel.Result result, String code) {
    result.error(code, "Libre history read is unavailable.", null);
  }
}
