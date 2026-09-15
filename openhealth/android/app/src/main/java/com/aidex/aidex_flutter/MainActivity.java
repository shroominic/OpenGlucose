package com.aidex.aidex_flutter;

import android.Manifest;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.util.Collections;
import java.util.Map;

public final class MainActivity extends FlutterActivity {
  private static final String CHANNEL_NAME = "com.aidex.cgm/android_live_update";
  private static final String PROTOCOL_CAPTURE_METADATA =
      "com.openglucose.protocol_capture.available";
  private static final String LIBRE_READ_ONLY_METADATA =
      "com.openglucose.libre_nfc.read_only";
  private static final int NOTIFICATION_PERMISSION_REQUEST_CODE = 4106;

  private boolean requestedNotificationPermission;
  private BluetoothEnableBridge bluetoothEnableBridge;
  private DebugProtocolCaptureBridge protocolCaptureBridge;
  private Libre2NfcBridge libre2NfcBridge;
  private LibreGen1ReceiverBridge libreGen1ReceiverBridge;
  private YuwellSecureStoreBridge yuwellSecureStoreBridge;
  private ApplicationInfo readerBackendInfo;

  @Override
  public void configureFlutterEngine(FlutterEngine flutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    bluetoothEnableBridge = new BluetoothEnableBridge(this);
    bluetoothEnableBridge.register(flutterEngine.getDartExecutor().getBinaryMessenger());
    // Read both flags once. Unknown configuration must not fall through to a
    // second backend after an intermittent metadata read failure.
    try {
      readerBackendInfo = getPackageManager()
          .getApplicationInfo(getPackageName(), PackageManager.GET_META_DATA);
      if (readerBackendInfo.metaData != null
          && readerBackendInfo.metaData.containsKey(LIBRE_READ_ONLY_METADATA)
          && !(readerBackendInfo.metaData.get(LIBRE_READ_ONLY_METADATA) instanceof Boolean)) {
        readerBackendInfo = null;
      }
    } catch (PackageManager.NameNotFoundException | RuntimeException ignored) {
      readerBackendInfo = null;
    }
    new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL_NAME)
        .setMethodCallHandler(this::handleLiveUpdateCall);
    yuwellSecureStoreBridge = new YuwellSecureStoreBridge(this);
    yuwellSecureStoreBridge.register(
        flutterEngine.getDartExecutor().getBinaryMessenger());
    // Exactly one native reader backend. The default-off production reader
    // never shares reader mode with the private debug recorder.
    if (libreReadOnlyAvailable()) {
      libre2NfcBridge = new Libre2NfcBridge(this);
      libre2NfcBridge.register(flutterEngine.getDartExecutor().getBinaryMessenger());
      if (libreReceiverValidationAvailable()) {
        libreGen1ReceiverBridge = new LibreGen1ReceiverBridge(
            this, this::libreReceiverValidationAvailable);
        libreGen1ReceiverBridge.register(flutterEngine.getDartExecutor().getBinaryMessenger());
      }
    } else if (protocolCaptureAvailable()) {
      protocolCaptureBridge = new DebugProtocolCaptureBridge(this);
      protocolCaptureBridge.register(
          flutterEngine.getDartExecutor().getBinaryMessenger());
    }
  }

  private boolean libreReadOnlyAvailable() {
    final ApplicationInfo info = readerBackendInfo;
    return info != null && info.metaData != null && info.metaData.getBoolean(LIBRE_READ_ONLY_METADATA, false);
  }

  private boolean protocolCaptureAvailable() {
      final ApplicationInfo info = readerBackendInfo;
      return info != null && info.metaData != null
          && info.metaData.getBoolean(PROTOCOL_CAPTURE_METADATA, false)
          && (info.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
  }

  private boolean libreReceiverValidationAvailable() {
    final ApplicationInfo info = readerBackendInfo;
    return LibreGen1ReceiverBackendPolicy.allows(
        libreReadOnlyAvailable(),
        info != null && (info.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0,
        libre2NfcBridge != null,
        protocolCaptureBridge != null);
  }

  @Override
  protected void onResume() {
    super.onResume();
    if (protocolCaptureBridge != null) {
      protocolCaptureBridge.onResume();
    }
    if (libre2NfcBridge != null) libre2NfcBridge.onResume();
    if (libreGen1ReceiverBridge != null) libreGen1ReceiverBridge.onResume();
  }

  @Override
  protected void onPause() {
    if (libreGen1ReceiverBridge != null) libreGen1ReceiverBridge.onPause();
    if (libre2NfcBridge != null) libre2NfcBridge.onPause();
    if (protocolCaptureBridge != null) {
      protocolCaptureBridge.onPause();
    }
    super.onPause();
  }

  @Override
  public void cleanUpFlutterEngine(FlutterEngine flutterEngine) {
    if (bluetoothEnableBridge != null) {
      bluetoothEnableBridge.destroy();
      bluetoothEnableBridge = null;
    }
    if (libreGen1ReceiverBridge != null) {
      libreGen1ReceiverBridge.destroy();
      libreGen1ReceiverBridge = null;
    }
    if (libre2NfcBridge != null) {
      libre2NfcBridge.destroy();
      libre2NfcBridge = null;
    }
    super.cleanUpFlutterEngine(flutterEngine);
  }

  @Override
  protected void onDestroy() {
    if (bluetoothEnableBridge != null) {
      bluetoothEnableBridge.destroy();
      bluetoothEnableBridge = null;
    }
    if (libreGen1ReceiverBridge != null) {
      libreGen1ReceiverBridge.destroy();
      libreGen1ReceiverBridge = null;
    }
    if (libre2NfcBridge != null) {
      libre2NfcBridge.destroy();
      libre2NfcBridge = null;
    }
    if (protocolCaptureBridge != null) {
      protocolCaptureBridge.destroy();
      protocolCaptureBridge = null;
    }
    yuwellSecureStoreBridge = null;
    super.onDestroy();
  }

  @Override
  protected void onActivityResult(int requestCode, int resultCode, Intent data) {
    super.onActivityResult(requestCode, resultCode, data);
    if (bluetoothEnableBridge != null) bluetoothEnableBridge.onActivityResult(requestCode);
  }

  @Override
  public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
    super.onRequestPermissionsResult(requestCode, permissions, results);
    if (bluetoothEnableBridge != null) {
      bluetoothEnableBridge.onRequestPermissionsResult(requestCode, results);
    }
  }

  private void handleLiveUpdateCall(MethodCall call, MethodChannel.Result result) {
    switch (call.method) {
      case "upsert":
        final Map<String, Object> payload =
            call.arguments instanceof Map<?, ?>
                ? GlucoseLiveUpdateService.sanitizePayload((Map<?, ?>) call.arguments)
                : Collections.emptyMap();
        if (payload.isEmpty()) {
          result.error("bad_args", "Expected a non-empty live-update payload.", null);
          return;
        }
        if (!GlucoseLiveUpdateService.persistPayload(this, payload)) {
          result.error(
              "restricted_storage_failed",
              "Could not save private Android live-update state.",
              null);
          return;
        }
        try {
          maybeRequestNotificationPermission();
          startLiveUpdateService(payload, false, result);
        } catch (RuntimeException error) {
          stopLiveUpdateServiceSafely();
          result.error("live_update_failed", "Could not start the live update.", null);
        }
        return;
      case "keepConnectionActive":
        if (call.arguments != null) {
          result.error("bad_args", "Expected no connection-status arguments.", null);
          return;
        }
        // Connection ownership is independent of glucose-display consent. No
        // permission prompt, incoming payload, or sensor identifier is needed.
        startLiveUpdateService(Collections.emptyMap(), true, result);
        return;
      case "end":
        if (stopLiveUpdateServiceSafely()) {
          result.success(null);
        } else {
          result.error(
              "restricted_storage_failed",
              "Could not clear private Android live-update state.",
              null);
        }
        return;
      case "setBackgroundSensor":
        if (persistBackgroundSensor(call.arguments)) {
          result.success(null);
        } else {
          result.error(
              "restricted_storage_failed",
              "Could not save private Android background state.",
              null);
        }
        return;
      case "clearBackgroundSensor":
        if (clearBackgroundSensor()) {
          result.success(null);
        } else {
          result.error(
              "restricted_storage_failed",
              "Could not clear private Android background state.",
              null);
        }
        return;
      case "getSensitiveContentEnabled":
        result.success(GlucoseLiveUpdateService.sensitiveContentEnabled(this));
        return;
      case "setSensitiveContentEnabled":
        if (!(call.arguments instanceof Boolean)) {
          result.error("bad_args", "Expected a sensitive-content boolean.", null);
          return;
        }
        final boolean enabled = (Boolean) call.arguments;
        if (!GlucoseLiveUpdateService.setSensitiveContentEnabled(this, enabled)) {
          // Any failed privacy write fails closed. This also handles consent
          // withdrawal: never leave an existing glucose notification visible
          // merely because SharedPreferences could not persist the opt-out.
          GlucoseLiveUpdateService.setSensitiveContentEnabled(this, false);
          stopLiveUpdateServiceSafely();
          result.error(
              "restricted_storage_failed",
              "Could not save the live-notification privacy setting.",
              null);
          return;
        }
        if (enabled) {
          // Flutter publishes the current payload only after this preference
          // write succeeds. Keeping that second step separate lets Flutter
          // roll consent back if publishing fails.
          result.success(null);
          return;
        }
        final LiveUpdateServiceLifecycle.Operation previousService =
            GlucoseLiveUpdateService.LIFECYCLE.current();
        try {
          removeVisibleLiveUpdateForPrivacy();
          if (previousService != null) {
            startLiveUpdateService(Collections.emptyMap(), previousService.statusOnly, null);
          }
        } catch (RuntimeException error) {
          // Consent has already been withdrawn. If the notification cannot
          // be rebuilt redacted, remove it and its cached payload rather than
          // surfacing a failure that could make Flutter restore consent.
          stopLiveUpdateServiceSafely();
        }
        result.success(null);
        return;
      default:
        result.notImplemented();
    }
  }

  private void startLiveUpdateService(
      Map<String, Object> payload, boolean statusOnly, MethodChannel.Result result) {
    final LiveUpdateServiceLifecycle lifecycle = GlucoseLiveUpdateService.LIFECYCLE;
    final LiveUpdateServiceLifecycle.Operation operation = lifecycle.begin(statusOnly, failure -> {
      if (result == null) return;
      if (failure == null) {
        result.success(null);
      } else {
        result.error("live_update_failed", "Could not maintain the sensor connection service.", null);
      }
    });
    final Intent intent = new Intent(this, GlucoseLiveUpdateService.class);
    intent.setAction(statusOnly ? GlucoseLiveUpdateService.ACTION_CONNECTION_STATUS
        : GlucoseLiveUpdateService.ACTION_UPSERT);
    intent.putExtra(GlucoseLiveUpdateService.EXTRA_PROCESS_TOKEN, operation.incarnation);
    intent.putExtra(GlucoseLiveUpdateService.EXTRA_OPERATION_EPOCH, operation.epoch);
    if (!statusOnly) intent.putExtra("payload", new java.util.HashMap<>(payload));
    // Android accepts a start request before onStartCommand runs. Acknowledge
    // only after startForeground, and revoke late intents when startup expires.
    new Handler(Looper.getMainLooper()).postDelayed(() -> {
      if (lifecycle.timeout(operation)) stopLiveUpdateServiceSafely();
    }, LiveUpdateServiceLifecycle.START_TIMEOUT_MILLIS);
    try {
      if (statusOnly && !GlucoseLiveUpdateService.clearPersistedPayload(this)) {
        throw new IllegalStateException("Private status storage unavailable.");
      }
      final android.content.ComponentName component;
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        component = startForegroundService(intent);
      } else {
        component = startService(intent);
      }
      if (component == null) throw new IllegalStateException("Service start rejected.");
    } catch (RuntimeException error) {
      if (lifecycle.fail(operation, LiveUpdateServiceLifecycle.Failure.START_FAILED)) {
        stopLiveUpdateServiceSafely();
      }
    }
  }

  private void removeVisibleLiveUpdateForPrivacy() {
    GlucoseLiveUpdateService.LIFECYCLE.invalidate();
    stopService(new Intent(this, GlucoseLiveUpdateService.class));
    final NotificationManager manager =
        (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
    if (manager != null) {
      manager.cancel(GlucoseLiveUpdateService.NOTIFICATION_ID);
    }
  }

  private boolean stopLiveUpdateService() {
    // Revoke first: an already queued start must not resurrect an ended service.
    GlucoseLiveUpdateService.LIFECYCLE.invalidate();
    try {
      return GlucoseLiveUpdateService.clearPersistedPayload(this);
    } finally {
      stopService(new Intent(this, GlucoseLiveUpdateService.class));
    }
  }

  private boolean stopLiveUpdateServiceSafely() {
    try {
      return stopLiveUpdateService();
    } catch (RuntimeException error) {
      return false;
    }
  }

  private void maybeRequestNotificationPermission() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      return;
    }
    if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
        == PackageManager.PERMISSION_GRANTED) {
      return;
    }
    if (requestedNotificationPermission) {
      return;
    }
    requestedNotificationPermission = true;
    requestPermissions(
        new String[] {Manifest.permission.POST_NOTIFICATIONS},
        NOTIFICATION_PERMISSION_REQUEST_CODE);
  }

  private boolean persistBackgroundSensor(Object arguments) {
    if (!(arguments instanceof Map<?, ?>)) {
      return false;
    }
    final SharedPreferences preferences =
        getSharedPreferences(GlucoseLiveUpdateService.PREFS_NAME, MODE_PRIVATE);
    final SharedPreferences.Editor editor = preferences.edit();
    final Map<?, ?> rawArguments = (Map<?, ?>) arguments;
    editor.putString(
        GlucoseLiveUpdateService.PREF_BACKGROUND_SENSOR,
        stringArgument(rawArguments.get("sensorName")));
    editor.putString(
        GlucoseLiveUpdateService.PREF_BACKGROUND_SERIAL,
        stringArgument(rawArguments.get("serial")));
    return editor.commit();
  }

  private boolean clearBackgroundSensor() {
    final SharedPreferences preferences =
        getSharedPreferences(GlucoseLiveUpdateService.PREFS_NAME, MODE_PRIVATE);
    return preferences
        .edit()
        .remove(GlucoseLiveUpdateService.PREF_BACKGROUND_SENSOR)
        .remove(GlucoseLiveUpdateService.PREF_BACKGROUND_SERIAL)
        .commit();
  }

  private String stringArgument(Object value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty() ? null : text;
  }
}
