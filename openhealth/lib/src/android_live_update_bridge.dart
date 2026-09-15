import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'live_activity_payload.dart';

/// Injectable transport for Android's connection-service lifecycle. Starting
/// the service does not grant permission to publish sensitive readings.
abstract interface class AndroidLiveUpdateClient {
  Future<void> upsert(LiveActivityPayload payload);
  Future<void> keepConnectionActive();
  Future<void> end();
}

class PlatformAndroidLiveUpdateClient implements AndroidLiveUpdateClient {
  const PlatformAndroidLiveUpdateClient();

  @override
  Future<void> upsert(LiveActivityPayload payload) =>
      AndroidLiveUpdateBridge.upsert(payload);

  @override
  Future<void> keepConnectionActive() =>
      AndroidLiveUpdateBridge.keepConnectionActive();

  @override
  Future<void> end() => AndroidLiveUpdateBridge.end();
}

/// Orders native service commands and drops superseded, not-yet-started
/// updates. In-flight starts must settle before an end can confirm completion.
/// Native ownership epochs additionally reject late Android start intents.
class AndroidLiveUpdateDispatcher {
  AndroidLiveUpdateDispatcher({
    required AndroidLiveUpdateClient client,
    Duration commandTimeout = const Duration(seconds: 12),
  }) : _client = client,
       _commandTimeout = commandTimeout {
    if (commandTimeout <= Duration.zero) {
      throw ArgumentError.value(commandTimeout, 'commandTimeout');
    }
  }

  final AndroidLiveUpdateClient _client;
  final Duration _commandTimeout;
  Future<void> _pending = Future<void>.value();
  int _revision = 0;

  Future<void> update({
    required bool keepConnectionActive,
    LiveActivityPayload? eligiblePayload,
  }) {
    final revision = ++_revision;
    final operation = _pending.then((_) async {
      // Only replace queued starts. Each end is a native stop barrier whose
      // caller must receive that stop's actual completion or failure, even if
      // a newer refresh/end/start is already queued behind it.
      if (keepConnectionActive && revision != _revision) return;
      final command = !keepConnectionActive
          ? _client.end()
          : eligiblePayload == null
          ? _client.keepConnectionActive()
          : _client.upsert(eligiblePayload);
      // A timeout reports uncertainty, not native stop success. Later commands
      // still run; their native epochs revoke any delayed start from this one.
      await command.timeout(_commandTimeout);
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> end() => update(keepConnectionActive: false);
}

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

  /// A fixed native status-only notification. No readings, identifiers,
  /// arbitrary strings, or notification permission prompt cross this path.
  static Future<void> keepConnectionActive() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('keepConnectionActive');
  }

  static Future<bool> sensitiveContentEnabled() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return await _channel.invokeMethod<bool>('getSensitiveContentEnabled') ??
        false;
  }

  static Future<void> setSensitiveContentEnabled({
    required bool enabled,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('setSensitiveContentEnabled', enabled);
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
