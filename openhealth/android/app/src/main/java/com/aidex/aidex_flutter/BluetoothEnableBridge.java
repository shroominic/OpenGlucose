package com.aidex.aidex_flutter;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

/** Uses Android's consent UI. Never changes bonds or enables the radio silently. */
final class BluetoothEnableBridge {
  private static final int ENABLE_REQUEST = 4210;
  private static final int PERMISSION_REQUEST = 4211;
  private final Activity activity;
  private MethodChannel channel;
  private MethodChannel.Result pending;

  BluetoothEnableBridge(Activity activity) { this.activity = activity; }

  void register(BinaryMessenger messenger) {
    channel = new MethodChannel(messenger, "com.openglucose/bluetooth");
    channel.setMethodCallHandler((call, result) -> {
      if (!"requestEnable".equals(call.method)) {
        result.notImplemented();
        return;
      }
      if (call.arguments != null || pending != null || activity.isFinishing()) {
        result.success("unavailable");
        return;
      }
      pending = result;
      try {
        if (Build.VERSION.SDK_INT >= 31
            && activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED) {
          activity.requestPermissions(
              new String[]{Manifest.permission.BLUETOOTH_CONNECT}, PERMISSION_REQUEST);
        } else {
          requestEnable();
        }
      } catch (RuntimeException ignored) {
        finish("unavailable");
      }
    });
  }

  private BluetoothAdapter adapter() {
    BluetoothManager manager = activity.getSystemService(BluetoothManager.class);
    return manager == null ? null : manager.getAdapter();
  }

  private void requestEnable() {
    try {
      BluetoothAdapter adapter = adapter();
      if (adapter == null) finish("unavailable");
      else if (adapter.isEnabled()) finish("enabled");
      else activity.startActivityForResult(
          new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_REQUEST);
    } catch (RuntimeException ignored) {
      finish("unavailable");
    }
  }

  void onActivityResult(int requestCode) {
    if (requestCode != ENABLE_REQUEST || pending == null) return;
    try {
      BluetoothAdapter adapter = adapter();
      finish(adapter != null && adapter.isEnabled() ? "enabled" : "cancelled");
    } catch (RuntimeException ignored) {
      finish("unavailable");
    }
  }

  void onRequestPermissionsResult(int requestCode, int[] results) {
    if (requestCode != PERMISSION_REQUEST || pending == null) return;
    if (results.length == 1 && results[0] == PackageManager.PERMISSION_GRANTED) {
      requestEnable();
    } else {
      finish("permissionRequired");
    }
  }

  private void finish(String value) {
    MethodChannel.Result result = pending;
    pending = null;
    if (result != null) result.success(value);
  }

  void destroy() {
    if (channel != null) channel.setMethodCallHandler(null);
    channel = null;
    finish("cancelled");
  }
}
