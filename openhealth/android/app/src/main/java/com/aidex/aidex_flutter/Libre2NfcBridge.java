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
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;

import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Default-off read-only Android reader. Deliberately has no recorder/store/write methods. */
final class Libre2NfcBridge {
  private final Activity activity;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final NfcAdapter adapter;
  private final Libre2NfcSessionCoordinator coordinator;
  private volatile EventChannel.EventSink eventSink;
  private volatile long listenerGeneration;
  private String activeId;
  private Object activeBinding;
  private boolean destroyed;
  private volatile boolean resumed;
  private MethodChannel methods;
  private EventChannel eventChannel;

  Libre2NfcBridge(Activity activity) {
    this.activity = activity;
    adapter = NfcAdapter.getDefaultAdapter(activity);
    coordinator = new Libre2NfcSessionCoordinator(SystemClock::elapsedRealtimeNanos,
        this::acquireLease, new Libre2NfcSessionCoordinator.Reader() {
          public void start(Libre2NfcSessionCoordinator.TagCallback callback) throws Exception {
            adapter.enableReaderMode(activity, tag -> {
              final Libre2Gen1ReadTransaction.Transport transport = transport(tag);
              if (transport != null) callback.detected(transport);
            }, NfcAdapter.FLAG_READER_NFC_V | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK, null);
          }
          public void stop() throws Exception {
            adapter.disableReaderMode(activity);
          }
        }, worker, this::publish);
  }

  void register(BinaryMessenger messenger) {
    methods = new MethodChannel(messenger, "com.openglucose/libre2");
    methods.setMethodCallHandler(this::call);
    eventChannel = new EventChannel(messenger, "com.openglucose/libre2_events");
    eventChannel.setStreamHandler(
        new EventChannel.StreamHandler() {
          public void onListen(Object arguments, EventChannel.EventSink sink) {
            listenerGeneration++;
            eventSink = sink;
          }
          public void onCancel(Object arguments) {
            listenerGeneration++;
            eventSink = null;
            // Listener ownership is not RF ownership. A stale subscription
            // cancellation cannot stop a later explicitly owned attempt.
          }
        });
  }

  void onResume() { resumed = true; coordinator.resume(); }
  void onPause() {
    resumed = false;
    coordinator.pause();
    if (activeId != null) armCleanupDeadline(coordinator.binding(activeId));
  }
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    eventSink = null;
    listenerGeneration++;
    if (methods != null) methods.setMethodCallHandler(null);
    if (eventChannel != null) eventChannel.setStreamHandler(null);
    coordinator.detach();
    if (activeId != null) armCleanupDeadline(coordinator.binding(activeId));
    worker.shutdown();
  }

  private void call(MethodCall call, MethodChannel.Result result) {
    if ("capabilities".equals(call.method)) {
      if (!(call.arguments instanceof Map) || !((Map<?, ?>) call.arguments).isEmpty()) {
        fail(result, "bad_args"); return;
      }
      final Map<String, Object> value = new HashMap<>();
      value.put("schemaVersion", 1); value.put("backend", "readOnly");
      value.put("readAvailable", !destroyed && adapter != null && hasPermission());
      value.put("activationAvailable", false); value.put("streamingAvailable", false);
      value.put("receiverAvailable", false); value.put("rawCapture", false);
      result.success(value); return;
    }
    if (!"startLibre2NfcSetup".equals(call.method) && !"stopLibre2NfcSetup".equals(call.method)) {
      result.notImplemented(); return;
    }
    final String id = attemptId(call.arguments);
    if (id == null) { fail(result, "bad_args"); return; }
    if ("stopLibre2NfcSetup".equals(call.method)) { stop(id, result); return; }
    if (destroyed || adapter == null) { fail(result, "nfc_unavailable"); return; }
    if (!hasPermission()) { fail(result, "nfc_permission_missing"); return; }
    if (!adapter.isEnabled()) { fail(result, "nfc_disabled"); return; }
    try {
      final Object binding = coordinator.start(id);
      activeId = id;
      activeBinding = binding;
      main.postDelayed(() -> {
        coordinator.expire(binding);
        armCleanupDeadline(binding);
      }, 120_000L);
      result.success(null);
    } catch (Exception error) {
      final Object pending = coordinator.binding(id);
      if (pending != null) {
        activeId = id;
        activeBinding = pending;
        armCleanupDeadline(pending);
      }
      final String code = error.getMessage();
      fail(result, code != null && Arrays.asList("bad_args", "nfc_not_foreground",
          "nfc_cleanup_unconfirmed", "nfc_attempt_active", "nfc_state_blocked",
          "nfc_unavailable", "nfc_start_failed").contains(code) ? code : "nfc_state_blocked");
    }
  }

  private void stop(String id, MethodChannel.Result result) {
    final Object binding = coordinator.binding(id);
    final CompletableFuture<Void> stopped = coordinator.stop(id);
    armCleanupDeadline(binding);
    stopped.whenComplete((ignored, error) -> main.post(() -> {
      if (error == null && binding != null && binding == activeBinding) {
        activeId = null;
        activeBinding = null;
      }
      if (result != null) {
        if (error == null) result.success(null);
        else fail(result, "nfc_cleanup_unconfirmed");
      }
    }));
  }

  private void armCleanupDeadline(Object binding) {
    if (binding != null) main.postDelayed(() -> coordinator.quarantine(binding), 8_000L);
  }

  private boolean hasPermission() {
    return activity.checkSelfPermission(Manifest.permission.NFC) == PackageManager.PERMISSION_GRANTED;
  }

  private void publish(Map<String, Object> event) {
    final long expectedListener = listenerGeneration;
    final Object binding = coordinator.binding((String) event.get("attemptId"));
    main.post(() -> {
      if (!destroyed && eventSink != null && listenerGeneration == expectedListener
          && coordinator.acceptsEvent(binding, (String) event.get("event"))
          && (resumed || "failed".equals(event.get("event")))) eventSink.success(event);
    });
  }

  private Libre2Gen1ReadTransaction.Transport transport(Tag tag) {
    if (tag == null) return null;
    final byte[] uid = tag.getId();
    if (uid == null || uid.length != 8 || uid[7] != (byte) 0xe0 || uid[6] != 0x07) return null;
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

  private Libre2NfcSessionCoordinator.Lease acquireLease() throws Exception {
    final File directory = new File(activity.getFilesDir(), "protocol-captures");
    // This first slice has no migration authority. Any old receiver/calibration
    // or capture/grant/journal state blocks it; nothing is deleted or rewritten.
    absent(new File(activity.getNoBackupFilesDir(), "libre-gen1-streaming-v1.bin"));
    absent(new File(activity.getNoBackupFilesDir(), "libre-gen1-calibration-v1.bin"));
    try { Os.mkdir(directory.getAbsolutePath(), 0700); }
    catch (ErrnoException error) { if (error.errno != OsConstants.EEXIST) throw error; }
    requireDirectory(directory);
    // Persist the containing directory before acquiring any RF ownership. A
    // crash must not erase a newly created parent and its unresolved lease.
    sync(activity.getFilesDir());
    final String[] existing = directory.list();
    if (existing == null || existing.length != 0) throw new IOException("Legacy NFC state blocks reader.");
    final String ownerToken = UUID.randomUUID().toString();
    final NfcRfTransactionLease lease = NfcRfTransactionLease.tryAcquire(directory, ownerToken);
    if (lease == null) return null;
    final File leaseDirectory = new File(directory, NfcRfTransactionLease.DIRECTORY_NAME);
    final File ownerFile = new File(leaseDirectory, NfcRfTransactionLease.OWNER_PREFIX + ownerToken);
    Libre2NfcLeaseAcquisition.persist(new Libre2NfcLeaseAcquisition.Files() {
      public boolean held() { return lease.isHeldByThisOwner(); }
      public void syncOwner() throws Exception { syncOwnerFile(ownerFile); }
      public void syncLeaseDirectory() throws Exception {
        requireDirectory(leaseDirectory);
        sync(leaseDirectory);
      }
      public void syncCaptureDirectory() throws Exception { sync(directory); }
      public void syncAppFilesDirectory() throws Exception { sync(activity.getFilesDir()); }
    });
    return new Libre2NfcSessionCoordinator.Lease() {
      public boolean held() {
        try {
          requireDirectory(directory);
          absent(new File(activity.getNoBackupFilesDir(), "libre-gen1-streaming-v1.bin"));
          absent(new File(activity.getNoBackupFilesDir(), "libre-gen1-calibration-v1.bin"));
          final String[] names = directory.list();
          return names != null && names.length == 1
              && NfcRfTransactionLease.DIRECTORY_NAME.equals(names[0]) && lease.isHeldByThisOwner();
        } catch (Exception error) { return false; }
      }
      public boolean release() {
        // The lease directory was durable before RF. Finish all fallible sync
        // and owner checks before removing it. No post-delete sync may turn a
        // completed release into an uncertain result with no restart blocker.
        // A crash can restore a released lease; that conservatively blocks reuse.
        return Libre2NfcLeaseRelease.release(new Libre2NfcLeaseRelease.Files() {
          public boolean held() {
            return heldByCurrentOwner();
          }
          public void syncBeforeDelete() throws Exception { sync(directory); }
          public boolean removeExactOwner() { return lease.release(); }
        });
      }
      private boolean heldByCurrentOwner() { return held(); }
    };
  }

  private static void absent(File file) throws Exception {
    try { Os.lstat(file.getAbsolutePath()); }
    catch (ErrnoException error) { if (error.errno == OsConstants.ENOENT) return; throw error; }
    throw new IOException("Existing NFC state blocks reader.");
  }

  private static void requireDirectory(File directory) throws Exception {
    final StructStat stat = Os.lstat(directory.getAbsolutePath());
    if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != android.os.Process.myUid()
        || (stat.st_mode & 0777) != 0700) throw new IOException("NFC directory unavailable.");
  }

  private static void sync(File directory) throws Exception {
    final FileDescriptor fd = Os.open(directory.getAbsolutePath(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
    try { Os.fsync(fd); } finally { Os.close(fd); }
  }

  private static void syncOwnerFile(File file) throws Exception {
    final FileDescriptor fd = Os.open(file.getAbsolutePath(),
        OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW | OsConstants.O_NONBLOCK, 0);
    try {
      final StructStat stat = Os.fstat(fd);
      if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != android.os.Process.myUid()
          || (stat.st_mode & 0777) != 0600 || stat.st_size != 0) {
        throw new IOException("NFC lease owner unavailable.");
      }
      Os.fsync(fd);
    } finally { Os.close(fd); }
  }

  private static String attemptId(Object arguments) {
    if (!(arguments instanceof Map)) return null;
    final Map<?, ?> map = (Map<?, ?>) arguments;
    final Object id = map.get("attemptId");
    return map.size() == 1 && id instanceof String && ((String) id).matches("[A-Za-z0-9_-]{8,120}")
        ? (String) id : null;
  }

  private static void fail(MethodChannel.Result result, String code) {
    result.error(code, "Libre NFC read could not complete.", null);
  }
}
