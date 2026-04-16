import 'dart:io';

import 'package:flutter/services.dart';

import 'live_activity_payload.dart';

class AndroidLiveUpdateBridge {
  AndroidLiveUpdateBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.aidex.cgm/android_live_update',
  );

  static Future<void> upsert(LiveActivityPayload payload) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('upsert', payload.toMap());
    } catch (_) {}
  }

  static Future<void> setBackgroundSensor({
    required String sensorName,
    String? serial,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(
        'setBackgroundSensor',
        <String, Object?>{'sensorName': sensorName, 'serial': serial},
      );
    } catch (_) {}
  }

  static Future<void> clearBackgroundSensor() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('clearBackgroundSensor');
    } catch (_) {}
  }

  static Future<void> end() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('end');
    } catch (_) {}
  }
}
