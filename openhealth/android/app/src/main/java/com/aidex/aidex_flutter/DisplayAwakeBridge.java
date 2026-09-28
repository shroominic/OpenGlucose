package com.aidex.aidex_flutter;

import android.app.Activity;
import android.content.Context;
import android.os.PowerManager;
import android.view.WindowManager;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Holds the display interactive for the window a discovery scan needs it.
 *
 * <p>Android's {@code ScanManager} refuses an unfiltered (opportunistic) BLE
 * scan while the display is off - "Cannot start unfiltered scan in screen-off.
 * This scan will be resumed later" - and reports that by returning nothing at
 * all, which reads on screen as "no sensor nearby". The rule is about the
 * display, so a scan window that needs the unfiltered pass holds the display
 * awake for its duration, and the same bridge answers whether the display is
 * interactive so a scan that could not run is never reported as an empty one.
 *
 * <p>{@code FLAG_KEEP_SCREEN_ON} is scoped to this activity's window: it stops
 * the display sleeping while the app is in front and has no effect once the
 * user leaves the app, so no wake lock is taken and nothing outlives the scan.
 */
final class DisplayAwakeBridge {
  static final String CHANNEL_NAME = "com.aidex.cgm/display";

  private final Activity activity;

  DisplayAwakeBridge(Activity activity) {
    this.activity = activity;
  }

  void register(BinaryMessenger messenger) {
    new MethodChannel(messenger, CHANNEL_NAME)
        .setMethodCallHandler(this::handleMethodCall);
  }

  private void handleMethodCall(MethodCall call, MethodChannel.Result result) {
    switch (call.method) {
      case "hold":
        setKeepScreenOn(true);
        result.success(null);
        return;
      case "release":
        setKeepScreenOn(false);
        result.success(null);
        return;
      case "isInteractive":
        result.success(isInteractive());
        return;
      default:
        result.notImplemented();
        return;
    }
  }

  private boolean isInteractive() {
    final PowerManager powerManager =
        (PowerManager) activity.getSystemService(Context.POWER_SERVICE);
    if (powerManager == null) {
      // A build without the power service cannot answer, and an app that
      // cannot tell must never claim a scan was declined.
      return true;
    }
    return powerManager.isInteractive();
  }

  private void setKeepScreenOn(boolean keepOn) {
    activity.runOnUiThread(
        () -> {
          if (activity.isFinishing() || activity.isDestroyed()) {
            return;
          }
          if (keepOn) {
            activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
          } else {
            activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
          }
        });
  }
}
