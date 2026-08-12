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
    await _channel.invokeMethod<void>('upsert', payload.toMap());
  }

  static Future<void> setBackgroundSensor({
    required String sensorName,
    String? serial,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('setBackgroundSensor', <String, Object?>{
      'sensorName': sensorName,
      'serial': serial,
    });
  }

  static Future<void> clearBackgroundSensor() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('clearBackgroundSensor');
  }

  static Future<void> end() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('end');
  }
}
