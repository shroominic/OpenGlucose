package com.aidex.aidex_flutter;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import java.io.Serializable;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

import org.json.JSONException;
import org.json.JSONObject;

public final class GlucoseLiveUpdateService extends Service {
  static final String ACTION_UPSERT =
      "com.aidex.aidex_flutter.action.UPSERT_LIVE_UPDATE";
  static final String ACTION_END =
      "com.aidex.aidex_flutter.action.END_LIVE_UPDATE";
  static final String PREFS_NAME = "glucose_live_update";
  static final String PREF_BACKGROUND_SENSOR = "background_sensor_name";
  static final String PREF_BACKGROUND_SERIAL = "background_sensor_serial";

  private static final String CHANNEL_ID = "glucose_live_updates";
  private static final String CHANNEL_NAME = "Live glucose";
  static final String PREF_LAST_PAYLOAD = "last_payload";
  private static final String EXTRA_PAYLOAD = "payload";
  private static final int NOTIFICATION_ID = 64102;
  private static final int COLOR_TEAL = 0xFF2E7D74;

  @Override
  public void onCreate() {
    super.onCreate();
    ensureNotificationChannel();
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent != null && ACTION_END.equals(intent.getAction())) {
      clearPersistedPayload();
      stopForegroundCompat();
      stopSelf();
      return START_NOT_STICKY;
    }

    Map<String, Object> payload = payloadFromIntent(intent);
    if (payload.isEmpty()) {
      payload = loadPersistedPayload();
    }
    if (payload.isEmpty()) {
      payload = buildFallbackPayload();
    }
    if (payload.isEmpty()) {
      stopForegroundCompat();
      stopSelf();
      return START_NOT_STICKY;
    }

    persistPayload(payload);
    final Notification notification = buildNotification(payload);
    startForegroundCompat(notification);
    return START_STICKY;
  }

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }

  static HashMap<String, Object> sanitizePayload(Map<?, ?> rawPayload) {
    final HashMap<String, Object> payload = new HashMap<>();
    for (Map.Entry<?, ?> entry : rawPayload.entrySet()) {
      if (entry.getKey() == null || entry.getValue() == null) {
        continue;
      }
      final Object value = entry.getValue();
      if (value instanceof String || value instanceof Number || value instanceof Boolean) {
        payload.put(entry.getKey().toString(), value);
      }
    }
    return payload;
  }

  private void startForegroundCompat(Notification notification) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(
          NOTIFICATION_ID,
          notification,
          ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
      return;
    }
    startForeground(NOTIFICATION_ID, notification);
  }

  private void stopForegroundCompat() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE);
      return;
    }
    stopForeground(true);
  }

  private Notification buildNotification(Map<String, Object> payload) {
    final String sensorName = stringValue(payload, "sensorName", "OpenGlucose");
    final String valueText = stringValue(payload, "valueText", "--");
    final String unitText = stringValue(payload, "unitText", "mg/dL");
    final String detailText = stringValue(payload, "detailText", "Waiting for sensor");
    final String stageLabel = stringValue(payload, "stageLabel", "Live");
    final String lastReadingText = stringValue(payload, "lastReadingText", "--");
    final String trendSymbol = stringValue(payload, "trendSymbol", "");
    final String deltaText = stringValue(payload, "deltaText", "");

    final boolean hasValue = valueText != null && !"--".equals(valueText) && !valueText.isEmpty();
    final String title = hasValue ? valueText + " " + unitText : sensorName;
    final String text =
        detailText != null && !detailText.isEmpty()
            ? detailText
            : fallbackDetail(stageLabel, lastReadingText);
    final String subText = hasValue ? sensorName : stageLabel;
    final String bigText = buildBigText(sensorName, text, trendSymbol, deltaText);

    final Notification.Builder builder;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      builder = new Notification.Builder(this, CHANNEL_ID);
    } else {
      builder = new Notification.Builder(this);
    }
    builder
        .setSmallIcon(R.drawable.ic_glucose_notification)
        .setContentTitle(title)
        .setContentText(text)
        .setSubText(subText)
        .setStyle(new Notification.BigTextStyle().bigText(bigText))
        .setContentIntent(buildLaunchIntent())
        .setCategory(Notification.CATEGORY_STATUS)
        .setVisibility(Notification.VISIBILITY_PUBLIC)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setShowWhen(false)
        .setColor(COLOR_TEAL);

    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      builder.setPriority(Notification.PRIORITY_LOW);
    }

    requestImmediateForeground(builder);
    requestPromotedOngoing(builder);
    return builder.build();
  }

  private PendingIntent buildLaunchIntent() {
    final Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
    if (launchIntent == null) {
      return null;
    }
    launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
    final int flags;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      flags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
    } else {
      flags = PendingIntent.FLAG_UPDATE_CURRENT;
    }
    return PendingIntent.getActivity(this, 0, launchIntent, flags);
  }

  private void ensureNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return;
    }
    final NotificationManager manager =
        (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    if (manager == null || manager.getNotificationChannel(CHANNEL_ID) != null) {
      return;
    }
    final NotificationChannel channel =
        new NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW);
    channel.setDescription("Live glucose updates while the CGM session is active.");
    channel.setShowBadge(false);
    manager.createNotificationChannel(channel);
  }

  private void requestPromotedOngoing(Notification.Builder builder) {
    tryInvoke(builder, "setRequestPromotedOngoing", new Class<?>[] {boolean.class}, true);
  }

  private void requestImmediateForeground(Notification.Builder builder) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
      return;
    }
    tryInvoke(
        builder,
        "setForegroundServiceBehavior",
        new Class<?>[] {int.class},
        Notification.FOREGROUND_SERVICE_IMMEDIATE);
  }

  private void tryInvoke(
      Notification.Builder builder, String methodName, Class<?>[] argumentTypes, Object argument) {
    try {
      final Method method = builder.getClass().getMethod(methodName, argumentTypes);
      method.invoke(builder, argument);
    } catch (Exception ignored) {
    }
  }

  private Map<String, Object> payloadFromIntent(Intent intent) {
    if (intent == null) {
      return Collections.emptyMap();
    }
    final Serializable extra = intent.getSerializableExtra(EXTRA_PAYLOAD);
    if (!(extra instanceof HashMap<?, ?>)) {
      return Collections.emptyMap();
    }
    return sanitizePayload((HashMap<?, ?>) extra);
  }

  private void persistPayload(Map<String, Object> payload) {
    final SharedPreferences preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    preferences.edit().putString(PREF_LAST_PAYLOAD, new JSONObject(payload).toString()).apply();
  }

  private Map<String, Object> loadPersistedPayload() {
    final SharedPreferences preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    final String rawPayload = preferences.getString(PREF_LAST_PAYLOAD, null);
    if (rawPayload == null || rawPayload.isEmpty()) {
      return Collections.emptyMap();
    }
    try {
      final JSONObject json = new JSONObject(rawPayload);
      final HashMap<String, Object> payload = new HashMap<>();
      final Iterator<String> keys = json.keys();
      while (keys.hasNext()) {
        final String key = keys.next();
        final Object value = json.get(key);
        if (value != JSONObject.NULL) {
          payload.put(key, value);
        }
      }
      return payload;
    } catch (JSONException ignored) {
      return Collections.emptyMap();
    }
  }

  private Map<String, Object> buildFallbackPayload() {
    final SharedPreferences preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    final String sensorName = preferences.getString(PREF_BACKGROUND_SENSOR, null);
    if (sensorName == null || sensorName.isEmpty()) {
      return Collections.emptyMap();
    }
    final HashMap<String, Object> payload = new HashMap<>();
    payload.put("sensorName", sensorName);
    payload.put("valueText", "--");
    payload.put("unitText", "mg/dL");
    payload.put("stageLabel", "Live");
    payload.put("detailText", "Waiting for glucose update");
    return payload;
  }

  private void clearPersistedPayload() {
    final SharedPreferences preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    preferences.edit().remove(PREF_LAST_PAYLOAD).apply();
  }

  private String buildBigText(
      String sensorName, String detailText, String trendSymbol, String deltaText) {
    final StringBuilder builder = new StringBuilder(sensorName);
    if (detailText != null && !detailText.isEmpty()) {
      builder.append(" • ").append(detailText);
    }
    if ((trendSymbol != null && !trendSymbol.isEmpty())
        || (deltaText != null && !deltaText.isEmpty())) {
      builder.append(" • ");
      if (trendSymbol != null && !trendSymbol.isEmpty()) {
        builder.append(trendSymbol).append(' ');
      }
      if (deltaText != null && !deltaText.isEmpty()) {
        builder.append(deltaText);
      } else if (builder.charAt(builder.length() - 1) == ' ') {
        builder.deleteCharAt(builder.length() - 1);
      }
    }
    return builder.toString();
  }

  private String fallbackDetail(String stageLabel, String lastReadingText) {
    if (lastReadingText != null && !"--".equals(lastReadingText) && !lastReadingText.isEmpty()) {
      return "Updated " + lastReadingText;
    }
    return stageLabel == null || stageLabel.isEmpty() ? "Waiting for glucose update" : stageLabel;
  }

  private String stringValue(Map<String, Object> payload, String key, String fallback) {
    final Object value = payload.get(key);
    if (value == null) {
      return fallback;
    }
    final String text = value.toString().trim();
    return text.isEmpty() ? fallback : text;
  }
}
