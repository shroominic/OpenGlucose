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
