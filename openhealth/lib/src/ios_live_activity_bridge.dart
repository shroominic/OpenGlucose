import 'dart:io';

import 'package:flutter/services.dart';

import 'live_activity_payload.dart';

class IosLiveActivityBridge {
  IosLiveActivityBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.aidex.cgm/live_activity',
  );

  static Future<void> upsert(LiveActivityPayload payload) async {
    if (!Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>('upsert', payload.toMap());
  }

  static Future<bool> sensitiveContentEnabled() async {
    if (!Platform.isIOS) {
      return false;
    }
    return await _channel.invokeMethod<bool>('getSensitiveContentEnabled') ??
        false;
  }

  static Future<void> setSensitiveContentEnabled({
    required bool enabled,
  }) async {
    if (!Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>('setSensitiveContentEnabled', enabled);
  }

  static Future<void> setBackgroundSensor({
    required String sensorName,
    String? serial,
  }) async {
    if (!Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>('setBackgroundSensor', <String, Object?>{
      'sensorName': sensorName,
      'serial': serial,
    });
  }

  static Future<void> clearBackgroundSensor() async {
    if (!Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>('clearBackgroundSensor');
  }

  static Future<void> end() async {
    if (!Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>('end');
  }
}
