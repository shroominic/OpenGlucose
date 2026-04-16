package com.aidex.aidex_flutter;

import android.Manifest;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

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
        maybeRequestNotificationPermission();
        startLiveUpdateService(call.arguments);
        result.success(null);
        return;
      case "end":
        stopLiveUpdateService();
        result.success(null);
        return;
      case "setBackgroundSensor":
        persistBackgroundSensor(call.arguments);
        result.success(null);
        return;
      case "clearBackgroundSensor":
        clearBackgroundSensor();
        result.success(null);
        return;
      default:
        result.notImplemented();
    }
  }

  private void startLiveUpdateService(Object arguments) {
    final Intent intent = new Intent(this, GlucoseLiveUpdateService.class);
    intent.setAction(GlucoseLiveUpdateService.ACTION_UPSERT);
    if (arguments instanceof Map<?, ?>) {
      intent.putExtra(
          "payload", GlucoseLiveUpdateService.sanitizePayload((Map<?, ?>) arguments));
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      startForegroundService(intent);
      return;
    }
    startService(intent);
  }

  private void stopLiveUpdateService() {
    final SharedPreferences preferences =
        getSharedPreferences(GlucoseLiveUpdateService.PREFS_NAME, MODE_PRIVATE);
    preferences.edit().remove(GlucoseLiveUpdateService.PREF_LAST_PAYLOAD).apply();
    stopService(new Intent(this, GlucoseLiveUpdateService.class));
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

  private void persistBackgroundSensor(Object arguments) {
    final SharedPreferences preferences =
        getSharedPreferences(GlucoseLiveUpdateService.PREFS_NAME, MODE_PRIVATE);
    final SharedPreferences.Editor editor = preferences.edit();
    if (arguments instanceof Map<?, ?>) {
      final Map<?, ?> rawArguments = (Map<?, ?>) arguments;
      editor.putString(
          GlucoseLiveUpdateService.PREF_BACKGROUND_SENSOR,
          stringArgument(rawArguments.get("sensorName")));
      editor.putString(
          GlucoseLiveUpdateService.PREF_BACKGROUND_SERIAL,
          stringArgument(rawArguments.get("serial")));
    }
    editor.apply();
  }

  private void clearBackgroundSensor() {
    final SharedPreferences preferences =
        getSharedPreferences(GlucoseLiveUpdateService.PREFS_NAME, MODE_PRIVATE);
    preferences
        .edit()
        .remove(GlucoseLiveUpdateService.PREF_BACKGROUND_SENSOR)
        .remove(GlucoseLiveUpdateService.PREF_BACKGROUND_SERIAL)
        .apply();
  }

  private String stringArgument(Object value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty() ? null : text;
  }
}
