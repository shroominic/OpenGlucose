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
  private static final String BRAND_NAME = "OpenGlucose";
  static final String ACTION_UPSERT =
      "com.aidex.aidex_flutter.action.UPSERT_LIVE_UPDATE";
  static final String ACTION_END =
      "com.aidex.aidex_flutter.action.END_LIVE_UPDATE";
  static final String PREFS_NAME = "glucose_live_update";
  static final String PREF_BACKGROUND_SENSOR = "background_sensor_name";
  static final String PREF_BACKGROUND_SERIAL = "background_sensor_serial";
  static final String PREF_SENSITIVE_LOCK_SCREEN_OPT_IN =
      "sensitive_lock_screen_opt_in";

  private static final String CHANNEL_ID = "glucose_live_updates";
  static final String PREF_LAST_PAYLOAD = "last_payload";
  private static final String EXTRA_PAYLOAD = "payload";
  static final int NOTIFICATION_ID = 64102;
  private static final int COLOR_TEAL = 0xFF2E7D74;

  /**
   * The payload carries the app's resolved language so a manual in-app
   * language override also applies to an Android system notification.
   */
  private enum LiveUpdateLanguage {
    ENGLISH("en"),
    SIMPLIFIED_CHINESE("zh");

    final String code;

    LiveUpdateLanguage(String code) {
      this.code = code;
    }

    static LiveUpdateLanguage fromPayload(Map<String, Object> payload) {
      final Object rawValue = payload.get("languageCode");
      if (rawValue != null && "zh".equalsIgnoreCase(rawValue.toString().trim())) {
        return SIMPLIFIED_CHINESE;
      }
      return ENGLISH;
    }
  }

  /**
   * Native fallback copy. Keep this separate from Flutter's display labels:
   * stageLabel is translated display text, not a protocol state.
   */
  private static final class LiveUpdateText {
    private LiveUpdateText() {}

    static String channelName(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "实时葡萄糖" : "Live glucose";
    }

    static String channelDescription(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE
          ? "CGM 会话进行期间显示实时葡萄糖更新。"
          : "Live glucose updates while the CGM session is active.";
    }

    static String sensorWarmingUp(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "传感器预热中" : "Sensor warming up";
    }

    static String waitingForSensor(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "正在等待传感器" : "Waiting for sensor";
    }

    static String waitingForGlucoseUpdate(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE
          ? "正在等待葡萄糖更新"
          : "Waiting for glucose update";
    }

    static String connecting(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "正在连接" : "Connecting";
    }

    static String error(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "出错" : "Error";
    }

    static String stale(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "数据已过时" : "Stale";
    }

    static String liveGlucose(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "实时葡萄糖" : "Live glucose";
    }

    static String openAppToViewGlucose(LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE
          ? "打开应用查看你的葡萄糖读数"
          : "Open the app to view your glucose";
    }

    static String updated(String time, LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE ? "更新于 " + time : "Updated " + time;
    }

    static String warmupTitle(int minutes, LiveUpdateLanguage language) {
      return language == LiveUpdateLanguage.SIMPLIFIED_CHINESE
          ? minutes + " 分钟"
          : minutes + " min";
    }

    static String stageLabel(
        String stageCode, boolean isWarmup, LiveUpdateLanguage language) {
      if (isWarmup) {
        return sensorWarmingUp(language);
      }
      if ("live".equals(stageCode)) {
        return liveGlucose(language);
      }
      if ("error".equals(stageCode)) {
        return error(language);
      }
      if ("progress".equals(stageCode)) {
        return connecting(language);
      }
      return waitingForSensor(language);
    }

    static String fallbackDetail(
        String stageCode,
        boolean isWarmup,
        String lastReadingText,
        boolean isStale,
        LiveUpdateLanguage language) {
      if (isWarmup) {
        return sensorWarmingUp(language);
      }
      if (isStale) {
        return stale(language);
      }
      if (lastReadingText != null && !"--".equals(lastReadingText) && !lastReadingText.isEmpty()) {
        return updated(lastReadingText, language);
      }
      if ("error".equals(stageCode)) {
        return error(language);
      }
      if ("progress".equals(stageCode)) {
        return connecting(language);
      }
      if ("live".equals(stageCode)) {
        return waitingForGlucoseUpdate(language);
      }
      return waitingForSensor(language);
    }
  }

  @Override
  public void onCreate() {
    super.onCreate();
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent != null && ACTION_END.equals(intent.getAction())) {
      clearPersistedPayload(this);
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

    ensureNotificationChannel(LiveUpdateLanguage.fromPayload(payload));

    if (!persistPayload(this, payload)) {
      stopForegroundCompat();
      stopSelf();
      return START_NOT_STICKY;
    }
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
    final LiveUpdateLanguage language = LiveUpdateLanguage.fromPayload(payload);
    final String valueText = stringValue(payload, "valueText", "--");
    final String unitText = stringValue(payload, "unitText", "mg/dL");
    final String detailText = stringValue(payload, "detailText", "");
    final String stageCode = stringValue(payload, "stageCode", "pending");
    final String lastReadingText = stringValue(payload, "lastReadingText", "--");
    final String trendSymbol = stringValue(payload, "trendSymbol", "");
    final String deltaText = stringValue(payload, "deltaText", "");
    final boolean isWarmup = booleanValue(payload, "isWarmup");
    final boolean isStale = booleanValue(payload, "isStale");
    final Integer warmupMinutes = validatedWarmupMinutes(payload);

    // Fail closed until the reviewed Flutter settings flow records consent.
    final SharedPreferences preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    if (!preferences.getBoolean(PREF_SENSITIVE_LOCK_SCREEN_OPT_IN, false)) {
      return buildRedactedNotification(payload);
    }

    final boolean hasValue =
        !isWarmup
            && !isStale
            && valueText != null
            && !"--".equals(valueText)
            && !valueText.isEmpty();
    final String title =
        warmupMinutes != null
            ? LiveUpdateText.warmupTitle(warmupMinutes, language)
            : hasValue ? valueText + " " + unitText : BRAND_NAME;
    final String text =
        !isStale && detailText != null && !detailText.isEmpty()
            ? detailText
            : LiveUpdateText.fallbackDetail(
                stageCode, isWarmup, lastReadingText, isStale, language);
    final String subText = BRAND_NAME;
    final String bigText = buildBigText(BRAND_NAME, text, trendSymbol, deltaText);
    final Notification publicVersion = buildRedactedNotification(payload);

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
        .setVisibility(Notification.VISIBILITY_PRIVATE)
        .setPublicVersion(publicVersion)
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

  /**
   * The lock-screen-safe version intentionally contains no glucose value,
   * sensor name, serial, trend, timestamp, or diagnostic detail. Android uses
   * it whenever notification content is hidden on the lock screen.
   */
  static Notification buildRedactedNotificationForTest(
      Context context, String channelId, PendingIntent contentIntent, String stageLabel) {
    return buildGenericRedactedNotification(
        context, channelId, contentIntent, LiveUpdateLanguage.ENGLISH);
  }

  private static Notification buildGenericRedactedNotification(
      Context context,
      String channelId,
      PendingIntent contentIntent,
      LiveUpdateLanguage language) {
    final Notification.Builder builder;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      builder = new Notification.Builder(context, channelId);
    } else {
      builder = new Notification.Builder(context);
    }
    return builder
        .setSmallIcon(R.drawable.ic_glucose_notification)
        .setContentTitle(BRAND_NAME)
        .setContentText(LiveUpdateText.openAppToViewGlucose(language))
        .setSubText(BRAND_NAME)
        .setContentIntent(contentIntent)
        .setCategory(Notification.CATEGORY_STATUS)
        .setVisibility(Notification.VISIBILITY_PUBLIC)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setShowWhen(false)
        .setColor(COLOR_TEAL)
        .build();
  }

  private Notification buildRedactedNotification(Map<String, Object> payload) {
    final LiveUpdateLanguage language = LiveUpdateLanguage.fromPayload(payload);
    final Integer remainingMinutes = validatedWarmupMinutes(payload);
    if (remainingMinutes != null) {
      final Notification.Builder builder;
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        builder = new Notification.Builder(this, CHANNEL_ID);
      } else {
        builder = new Notification.Builder(this);
      }
      return builder
          .setSmallIcon(R.drawable.ic_glucose_notification)
          .setContentTitle(LiveUpdateText.warmupTitle(remainingMinutes, language))
          .setContentText(LiveUpdateText.sensorWarmingUp(language))
          .setSubText(BRAND_NAME)
          .setContentIntent(buildLaunchIntent())
          .setCategory(Notification.CATEGORY_STATUS)
          .setVisibility(Notification.VISIBILITY_PUBLIC)
          .setOngoing(true)
          .setOnlyAlertOnce(true)
          .setShowWhen(false)
          .setColor(COLOR_TEAL)
          .build();
    }
    return buildGenericRedactedNotification(
        this, CHANNEL_ID, buildLaunchIntent(), language);
  }

  static Integer validatedWarmupMinutes(Map<String, Object> payload) {
    if (!booleanValue(payload, "isWarmup")) {
      return null;
    }
    final String valueText = stringValue(payload, "valueText", "");
    try {
      final int remainingMinutes = Integer.parseInt(valueText);
      return remainingMinutes >= 1 && remainingMinutes <= 180 ? remainingMinutes : null;
    } catch (NumberFormatException ignored) {
      return null;
    }
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

  private void ensureNotificationChannel(LiveUpdateLanguage language) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return;
    }
    final NotificationManager manager =
        (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    if (manager == null) {
      return;
    }
    NotificationChannel channel = manager.getNotificationChannel(CHANNEL_ID);
    if (channel == null) {
      channel =
          new NotificationChannel(
              CHANNEL_ID,
              LiveUpdateText.channelName(language),
              NotificationManager.IMPORTANCE_LOW);
    } else {
      // Android keeps a channel's delivery behavior under user control, while
      // its app-provided name and description can follow a language change.
      channel.setName(LiveUpdateText.channelName(language));
    }
    channel.setDescription(LiveUpdateText.channelDescription(language));
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

  static boolean persistPayload(Context context, Map<String, Object> payload) {
    final SharedPreferences preferences =
        context.getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    return preferences
        .edit()
        .putString(PREF_LAST_PAYLOAD, new JSONObject(payload).toString())
        .commit();
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
    final String configuredSensorName = preferences.getString(PREF_BACKGROUND_SENSOR, null);
    if (configuredSensorName == null || configuredSensorName.isEmpty()) {
      return Collections.emptyMap();
    }
    final HashMap<String, Object> payload = new HashMap<>();
    payload.put("sensorName", BRAND_NAME);
    payload.put("languageCode", LiveUpdateLanguage.ENGLISH.code);
    payload.put("stageCode", "live");
    payload.put("isWarmup", false);
    payload.put("valueText", "--");
    payload.put("unitText", "mg/dL");
    payload.put("stageLabel", LiveUpdateText.liveGlucose(LiveUpdateLanguage.ENGLISH));
    payload.put(
        "detailText",
        LiveUpdateText.waitingForGlucoseUpdate(LiveUpdateLanguage.ENGLISH));
    return payload;
  }

  static boolean clearPersistedPayload(Context context) {
    final SharedPreferences preferences =
        context.getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
    return preferences.edit().remove(PREF_LAST_PAYLOAD).commit();
  }

  static boolean sensitiveContentEnabled(Context context) {
    return context
        .getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        .getBoolean(PREF_SENSITIVE_LOCK_SCREEN_OPT_IN, false);
  }

  static boolean setSensitiveContentEnabled(Context context, boolean enabled) {
    return context
        .getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        .edit()
        .putBoolean(PREF_SENSITIVE_LOCK_SCREEN_OPT_IN, enabled)
        .commit();
  }

  static boolean hasPersistedPayload(Context context) {
    final String payload = context
        .getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        .getString(PREF_LAST_PAYLOAD, null);
    return payload != null && !payload.isEmpty();
  }

  private String buildBigText(
      String brandName, String detailText, String trendSymbol, String deltaText) {
    final StringBuilder builder = new StringBuilder(brandName);
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

  private static String stringValue(
      Map<String, Object> payload, String key, String fallback) {
    final Object value = payload.get(key);
    if (value == null) {
      return fallback;
    }
    final String text = value.toString().trim();
    return text.isEmpty() ? fallback : text;
  }

  private static boolean booleanValue(Map<String, Object> payload, String key) {
    return Boolean.TRUE.equals(payload.get(key));
  }
}
