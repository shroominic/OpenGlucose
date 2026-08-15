package com.aidex.aidex_flutter;

import android.Manifest;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.util.Collections;
import java.util.Map;

public final class MainActivity extends FlutterActivity {
  private static final String CHANNEL_NAME = "com.aidex.cgm/android_live_update";
  private static final int NOTIFICATION_PERMISSION_REQUEST_CODE = 4106;

  private boolean requestedNotificationPermission;

  @Override
  public void configureFlutterEngine(FlutterEngine flutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL_NAME)
        .setMethodCallHandler(this::handleLiveUpdateCall);
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
          startLiveUpdateService(payload);
          result.success(null);
        } catch (RuntimeException error) {
          GlucoseLiveUpdateService.clearPersistedPayload(this);
          result.error("live_update_failed", "Could not start the live update.", null);
        }
        return;
      case "end":
        if (stopLiveUpdateService()) {
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
          stopLiveUpdateService();
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
        try {
          removeVisibleLiveUpdateForPrivacy();
          refreshLiveUpdateServiceIfActive();
        } catch (RuntimeException error) {
          // Consent has already been withdrawn. If the notification cannot
          // be rebuilt redacted, remove it and its cached payload rather than
          // surfacing a failure that could make Flutter restore consent.
          stopLiveUpdateService();
        }
        result.success(null);
        return;
      default:
        result.notImplemented();
    }
  }

  private void startLiveUpdateService(Map<String, Object> payload) {
    final Intent intent = new Intent(this, GlucoseLiveUpdateService.class);
    intent.setAction(GlucoseLiveUpdateService.ACTION_UPSERT);
    intent.putExtra("payload", new java.util.HashMap<>(payload));
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      startForegroundService(intent);
      return;
    }
    startService(intent);
  }

  private void refreshLiveUpdateServiceIfActive() {
    if (!GlucoseLiveUpdateService.hasPersistedPayload(this)) {
      return;
    }
    startLiveUpdateService(Collections.emptyMap());
  }

  private void removeVisibleLiveUpdateForPrivacy() {
    stopService(new Intent(this, GlucoseLiveUpdateService.class));
    final NotificationManager manager =
        (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
    if (manager != null) {
      manager.cancel(GlucoseLiveUpdateService.NOTIFICATION_ID);
    }
  }

  private boolean stopLiveUpdateService() {
    final boolean cleared = GlucoseLiveUpdateService.clearPersistedPayload(this);
    stopService(new Intent(this, GlucoseLiveUpdateService.class));
    return cleared;
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
