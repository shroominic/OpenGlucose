import 'dart:convert';

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Keystore persistence for Yuwell CT5 credentials and write intents.
///
/// The Android bridge derives opaque aliases with a device-local HMAC key,
/// encrypts values with AES-GCM, and durably commits journal transitions before
/// this class completes an awaited call. Unsupported platforms fail closed;
/// there is no preferences, file, or non-Keychain Apple fallback.
final class YuwellSecureSessionStore
    implements YuwellCredentialStore, YuwellWriteIntentStore {
  YuwellSecureSessionStore()
    : _channel = const MethodChannel(channelName),
      _supported = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @visibleForTesting
  YuwellSecureSessionStore.testing({
    required MethodChannel channel,
    bool supported = true,
  }) : _channel = channel,
       _supported = supported;

  static const String channelName = 'com.openglucose/yuwell_secure_store';

  final MethodChannel _channel;
  final bool _supported;

  @override
  Future<YuwellSessionCredentials?> read(String storageKey) async {
    final encoded = await _invoke<String>(
      'readCredential',
      <String, Object?>{'storageKey': storageKey},
    );
    if (encoded == null) {
      return null;
    }
    return YuwellSessionCredentials.restoreFromSecureStorage(
      _decodeRecord(encoded, label: 'credential'),
    );
  }

  @override
  Future<void> write(
    String storageKey,
    YuwellSessionCredentials credentials,
  ) async {
    await _invoke<void>('writeCredential', <String, Object?>{
      'storageKey': storageKey,
      'credential': jsonEncode(credentials.serializeForSecureStorage()),
    });
  }

  @override
  Future<void> delete(String storageKey) async {
    await _invoke<void>('deleteCredential', <String, Object?>{
      'storageKey': storageKey,
    });
  }

  @override
  Future<bool> hasUnresolved(String storageKey) async {
    final result = await _invoke<bool>('hasUnresolved', <String, Object?>{
      'storageKey': storageKey,
    });
    if (result == null) {
      throw StateError('Yuwell secure storage returned an invalid result.');
    }
    return result;
  }

  @override
  Future<YuwellUnresolvedWriteIntent?> readUnresolved(
    String storageKey,
  ) async {
    final value = await _invoke<Object>('readUnresolved', <String, Object?>{
      'storageKey': storageKey,
    });
    if (value == null) {
      return null;
    }
    if (value is! Map ||
        value['token'] is! String ||
        value['operation'] is! String ||
        value['state'] is! String) {
      throw const YuwellProtocolFormatException(
        'secure write journal has an unsupported shape',
      );
    }
    final operationName = value['operation']! as String;
    final stateName = value['state']! as String;
    final operation = YuwellActivationWrite.values
        .where((candidate) => candidate.name == operationName)
        .firstOrNull;
    final state = YuwellWriteIntentState.values
        .where((candidate) => candidate.name == stateName)
        .firstOrNull;
    if (operation == null || state == null) {
      throw const YuwellProtocolFormatException(
        'secure write journal has an unsupported value',
      );
    }
    return YuwellUnresolvedWriteIntent(
      token: value['token']! as String,
      operation: operation,
      state: state,
    );
  }

  @override
  Future<String> prepare(
    String storageKey,
    YuwellActivationWrite operation,
  ) async {
    final token = await _invoke<String>('prepare', <String, Object?>{
      'storageKey': storageKey,
      'operation': operation.name,
    });
    if (token == null || token.isEmpty) {
      throw StateError('Yuwell secure storage returned an invalid result.');
    }
    return token;
  }

  @override
  Future<void> markTransmitted(String token) async {
    await _invoke<void>('markTransmitted', <String, Object?>{'token': token});
  }

  @override
  Future<void> markCompleted(String token) async {
    await _invoke<void>('markCompleted', <String, Object?>{'token': token});
  }

  @override
  Future<void> markUnknown(String token) async {
    await _invoke<void>('markUnknown', <String, Object?>{'token': token});
  }

  @override
  Future<void> cancelPrepared(String token) async {
    await _invoke<void>('cancelPrepared', <String, Object?>{'token': token});
  }

  @override
  Future<void> resolveRecovered(
    String token, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async {
    await _invoke<void>('resolveRecovered', <String, Object?>{
      'token': token,
      'expectedOperation': expectedOperation.name,
      'expectedState': expectedState.name,
    });
  }

  @override
  Future<String> replaceRecoveredWithPrepared(
    String token,
    String storageKey,
    YuwellActivationWrite operation, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async {
    final replacement = await _invoke<String>(
      'replaceRecoveredWithPrepared',
      <String, Object?>{
        'token': token,
        'storageKey': storageKey,
        'operation': operation.name,
        'expectedOperation': expectedOperation.name,
        'expectedState': expectedState.name,
      },
    );
    if (replacement == null || replacement.isEmpty) {
      throw StateError('Yuwell secure storage returned an invalid result.');
    }
    return replacement;
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    if (!_supported) {
      throw UnsupportedError(
        'Yuwell activation secure storage is available only on Android.',
      );
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      // Discard native messages and details. Platform crypto providers must not
      // cause private identifiers, keys, or records to reach crash reports.
      if (error.code == 'conflict') {
        throw StateError('A Yuwell activation write is already unresolved.');
      }
      if (error.code == 'bad_args') {
        throw ArgumentError('Invalid Yuwell secure-store request.');
      }
      throw StateError('Yuwell secure storage failed closed.');
    } on MissingPluginException {
      throw StateError('Yuwell secure storage failed closed.');
    }
  }

  static Map<String, Object?> _decodeRecord(
    String encoded, {
    required String label,
  }) {
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) {
        throw const FormatException();
      }
      return value.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on Object {
      throw YuwellProtocolFormatException(
        'secure $label record is malformed',
      );
    }
  }
}
