import 'dart:convert';
import 'dart:math' as math;

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value seam so [YuwellMacosKeychainSessionStore] is unit
/// testable without a platform-channel fake. The default implementation
/// delegates to [FlutterSecureStorage], which uses the macOS Keychain.
abstract interface class YuwellMacosKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Keeps Yuwell session material available only while this Mac is unlocked
/// and prevents it from migrating to another device or syncing via iCloud.
const MacOsOptions yuwellMacosKeychainOptions = MacOsOptions(
  accessibility: KeychainAccessibility.unlocked_this_device,
  synchronizable: false,
);

/// Process-lifetime fallback for a build that cannot reach the Keychain.
///
/// An ad-hoc code signature has no Team ID, and macOS Keychain Services can
/// then fail every item with `errSecMissingEntitlement` (-34018) because it
/// cannot resolve a default keychain-access-group — independent of anything
/// in this app's entitlements plist. Until this build is signed with a real
/// Team ID, [YuwellMacosKeychainSessionStore] can use this instead so a
/// single supervised debug run can still proceed.
///
/// This keeps every state-machine guard in [YuwellMacosKeychainSessionStore]
/// (one-shot activation, the fail-closed write journal, ...); it only trades
/// away surviving process death, which does not matter for a short debug
/// attempt that is itself the whole lifetime of the session. It must never
/// back a normal build.
final class YuwellMacosInMemoryKeyValueStore
    implements YuwellMacosKeyValueStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

final class _FlutterSecureKeyValueStore implements YuwellMacosKeyValueStore {
  const _FlutterSecureKeyValueStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) =>
      _storage.read(key: key, mOptions: yuwellMacosKeychainOptions);

  @override
  Future<void> write(String key, String value) => _storage.write(
    key: key,
    value: value,
    mOptions: yuwellMacosKeychainOptions,
  );

  @override
  Future<void> delete(String key) =>
      _storage.delete(key: key, mOptions: yuwellMacosKeychainOptions);
}

/// macOS Keychain persistence for Yuwell CT5 credentials and write intents.
///
/// This is the Mac-BLE-debug counterpart to the Android-only
/// `YuwellSecureSessionStore`: the same [YuwellCredentialStore] and
/// [YuwellWriteIntentStore] contracts, backed by `flutter_secure_storage`'s
/// macOS Keychain implementation instead of an Android Keystore bridge. It is
/// wired only from the private macOS debug entry point; normal application
/// builds keep using the Android store and register no Yuwell driver on
/// macOS.
///
/// Every Keychain item name is an HMAC-SHA256 of the caller's storage key (or
/// token) under a device-local secret that is itself Keychain-held — never
/// the storage key, a token, or any sensor identity in the clear. Journal
/// entries are addressed by opaque random tokens and never contain command
/// bytes or health data.
final class YuwellMacosKeychainSessionStore
    implements YuwellCredentialStore, YuwellWriteIntentStore {
  YuwellMacosKeychainSessionStore({
    YuwellMacosKeyValueStore? keyValueStore,
    math.Random? random,
  }) : _store =
           keyValueStore ??
           _FlutterSecureKeyValueStore(const FlutterSecureStorage()),
       _random = random ?? math.Random.secure();

  final YuwellMacosKeyValueStore _store;
  final math.Random _random;
  Future<List<int>>? _secretFuture;

  static const _secretAlias = 'ct5.macos.device-secret.v1';
  static const _tokenPrefix = 'ct5.macos.intent.v1.';

  // ---- YuwellCredentialStore ----

  @override
  Future<YuwellSessionCredentials?> read(String storageKey) async {
    final encoded = await _readAlias('cred', storageKey);
    if (encoded == null) {
      return null;
    }
    return YuwellSessionCredentials.restoreFromSecureStorage(
      _decodeMap(encoded, label: 'credential'),
    );
  }

  @override
  Future<void> write(
    String storageKey,
    YuwellSessionCredentials credentials,
  ) => _writeAlias(
    'cred',
    storageKey,
    jsonEncode(credentials.serializeForSecureStorage()),
  );

  @override
  Future<void> delete(String storageKey) => _deleteAlias('cred', storageKey);

  // ---- YuwellWriteIntentStore ----

  @override
  Future<bool> hasUnresolved(String storageKey) async =>
      (await _readAlias('journal-ptr', storageKey)) != null;

  @override
  Future<YuwellUnresolvedWriteIntent?> readUnresolved(
    String storageKey,
  ) async {
    final token = await _readAlias('journal-ptr', storageKey);
    if (token == null) {
      return null;
    }
    final entry = await _requireEntry(token);
    return YuwellUnresolvedWriteIntent(
      token: token,
      operation: entry.operation,
      state: entry.state,
    );
  }

  @override
  Future<String> prepare(
    String storageKey,
    YuwellActivationWrite operation,
  ) async {
    if (await _readAlias('journal-ptr', storageKey) != null) {
      throw StateError('A Yuwell activation write is already unresolved.');
    }
    final token = await _newToken();
    await _writeEntry(
      token,
      _JournalEntry(
        storageKey: storageKey,
        operation: operation,
        state: YuwellWriteIntentState.prepared,
      ),
    );
    await _writeAlias('journal-ptr', storageKey, token);
    return token;
  }

  @override
  Future<void> markTransmitted(String token) async {
    final entry = await _requireEntry(token);
    if (entry.state != YuwellWriteIntentState.prepared) {
      throw StateError('Only a prepared write intent can be transmitted.');
    }
    await _writeEntry(
      token,
      _JournalEntry(
        storageKey: entry.storageKey,
        operation: entry.operation,
        state: YuwellWriteIntentState.transmitted,
      ),
    );
  }

  @override
  Future<void> markUnknown(String token) async {
    final entry = await _requireEntry(token);
    await _writeEntry(
      token,
      _JournalEntry(
        storageKey: entry.storageKey,
        operation: entry.operation,
        state: YuwellWriteIntentState.unknown,
      ),
    );
  }

  @override
  Future<void> markCompleted(String token) async {
    final entry = await _requireEntry(token);
    if (entry.state != YuwellWriteIntentState.transmitted) {
      // A never-transmitted (prepared) or ambiguous-outcome (unknown) write
      // must go through cancelPrepared or the recovery path instead of a
      // blind "completed" — this is the fail-closed boundary the durable
      // journal exists to enforce.
      throw StateError('Only a transmitted write intent can complete.');
    }
    await _clearJournal(token: token, storageKey: entry.storageKey);
  }

  @override
  Future<void> cancelPrepared(String token) async {
    final entry = await _requireEntry(token);
    if (entry.state != YuwellWriteIntentState.prepared) {
      throw StateError('Only a prepared write intent can be cancelled.');
    }
    await _clearJournal(token: token, storageKey: entry.storageKey);
  }

  @override
  Future<void> resolveRecovered(
    String token, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async {
    final entry = await _requireEntry(token);
    _requireSnapshot(entry, expectedOperation, expectedState);
    await _clearJournal(token: token, storageKey: entry.storageKey);
  }

  @override
  Future<String> replaceRecoveredWithPrepared(
    String token,
    String storageKey,
    YuwellActivationWrite operation, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async {
    final entry = await _requireEntry(token);
    if (entry.storageKey != storageKey) {
      throw StateError('Replacement storage key does not match the token.');
    }
    _requireSnapshot(entry, expectedOperation, expectedState);
    if (operation != expectedOperation) {
      throw StateError('Replacement must retry the same operation.');
    }
    final replacement = await _newToken();
    // Write the new generation, then flip the pointer, then drop the old
    // entry. A failure at any step leaves the prior token fully resolvable:
    // the source is never removed before its replacement is durable.
    await _writeEntry(
      replacement,
      _JournalEntry(
        storageKey: storageKey,
        operation: operation,
        state: YuwellWriteIntentState.prepared,
      ),
    );
    await _writeAlias('journal-ptr', storageKey, replacement);
    await _deleteAlias('journal-entry', token);
    return replacement;
  }

  // ---- internals ----

  void _requireSnapshot(
    _JournalEntry entry,
    YuwellActivationWrite expectedOperation,
    YuwellWriteIntentState expectedState,
  ) {
    if (entry.operation != expectedOperation || entry.state != expectedState) {
      throw StateError('Stale write-intent snapshot.');
    }
  }

  Future<_JournalEntry> _requireEntry(String token) async {
    final encoded = await _readAlias('journal-entry', token);
    if (encoded == null) {
      throw StateError('No unresolved Yuwell write intent for this token.');
    }
    final map = _decodeMap(encoded, label: 'write intent');
    final storageKey = map['storageKey'];
    final operationName = map['operation'];
    final stateName = map['state'];
    if (storageKey is! String ||
        operationName is! String ||
        stateName is! String) {
      throw const YuwellProtocolFormatException(
        'macOS write-intent journal entry has an unsupported shape',
      );
    }
    final operation = YuwellActivationWrite.values
        .where((value) => value.name == operationName)
        .firstOrNull;
    final state = YuwellWriteIntentState.values
        .where((value) => value.name == stateName)
        .firstOrNull;
    if (operation == null || state == null) {
      throw const YuwellProtocolFormatException(
        'macOS write-intent journal entry has an unsupported value',
      );
    }
    return _JournalEntry(
      storageKey: storageKey,
      operation: operation,
      state: state,
    );
  }

  Future<void> _writeEntry(String token, _JournalEntry entry) => _writeAlias(
    'journal-entry',
    token,
    jsonEncode(<String, Object?>{
      'storageKey': entry.storageKey,
      'operation': entry.operation.name,
      'state': entry.state.name,
    }),
  );

  Future<void> _clearJournal({
    required String token,
    required String storageKey,
  }) async {
    await _deleteAlias('journal-entry', token);
    final currentToken = await _readAlias('journal-ptr', storageKey);
    if (currentToken == token) {
      await _deleteAlias('journal-ptr', storageKey);
    }
  }

  Future<String> _newToken() async {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return '$_tokenPrefix${_hex(bytes)}';
  }

  Future<String?> _readAlias(String namespace, String key) async {
    try {
      return await _store.read(await _alias(namespace, key));
    } on Object catch (error) {
      if (error is StateError || error is YuwellProtocolFormatException) {
        rethrow;
      }
      throw StateError('Yuwell macOS secure storage failed closed.');
    }
  }

  Future<void> _writeAlias(String namespace, String key, String value) async {
    try {
      await _store.write(await _alias(namespace, key), value);
    } on Object catch (error) {
      if (error is StateError) {
        rethrow;
      }
      throw StateError('Yuwell macOS secure storage failed closed.');
    }
  }

  Future<void> _deleteAlias(String namespace, String key) async {
    try {
      await _store.delete(await _alias(namespace, key));
    } on Object catch (error) {
      if (error is StateError) {
        rethrow;
      }
      throw StateError('Yuwell macOS secure storage failed closed.');
    }
  }

  Future<String> _alias(String namespace, String key) async {
    final secret = await _deviceSecret();
    final digest = Hmac(
      sha256,
      secret,
    ).convert(utf8.encode('$namespace:$key'));
    return 'ct5.macos.$namespace.v1.$digest';
  }

  Future<List<int>> _deviceSecret() =>
      _secretFuture ??= _loadOrCreateDeviceSecret();

  Future<List<int>> _loadOrCreateDeviceSecret() async {
    try {
      final existing = await _store.read(_secretAlias);
      if (existing != null) {
        return base64Decode(existing);
      }
      final generated = List<int>.generate(32, (_) => _random.nextInt(256));
      await _store.write(_secretAlias, base64Encode(generated));
      return generated;
    } on Object {
      throw StateError('Yuwell macOS secure storage failed closed.');
    }
  }

  Map<String, Object?> _decodeMap(String encoded, {required String label}) {
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

final class _JournalEntry {
  const _JournalEntry({
    required this.storageKey,
    required this.operation,
    required this.state,
  });

  final String storageKey;
  final YuwellActivationWrite operation;
  final YuwellWriteIntentState state;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
