import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../health_state_store.dart';
import 'sensor_state_identity.dart';

/// Opaque package state and legacy raw archives, never normalized glucose.
class CbioPrivateStateAdapter implements CbioFullRecordStore {
  CbioPrivateStateAdapter(this._store);

  final HealthStateStore _store;
  static const _manifestKey = 'openHealth.driverState.cbio.rawArchives.v1';
  static const _indexKey = 'openHealth.sensorArchive';

  @override
  Future<String?> readFullRecords(String sensorKey) async => _store.getString(
    'openHealth.history.cbio.fullRecords.v1.${_binding('cbio', sensorKey)}',
  );

  @override
  Future<void> writeFullRecords(String sensorKey, String envelope) =>
      _store.setString(
        'openHealth.history.cbio.fullRecords.v1.${_binding('cbio', sensorKey)}',
        envelope,
      );

  @override
  String legacySha256(String legacyEnvelope) =>
      crypto.sha256.convert(utf8.encode(legacyEnvelope)).toString();

  @override
  Future<String?> read(String sensorKey) async => _store.getString(
    'openHealth.history.cbio.v1.${_binding('cbio', sensorKey)}',
  );

  @override
  Future<void> write(String sensorKey, String envelope) => _store.setString(
    'openHealth.history.cbio.v1.${_binding('cbio', sensorKey)}',
    envelope,
  );

  /// Run during bootstrap, before the normal archive index is consumed.
  ///
  /// All validation precedes writes. Each store write is atomic; ordering the
  /// private copy first makes interruption retryable without deleting raw bytes.
  Future<void> migrateLegacyArchives() async {
    final manifestText = _store.getString(_manifestKey);
    final archives = <Map<String, dynamic>>[];
    final sources = <String>[];
    final identities = _ArchiveIdentities();
    if (manifestText != null) {
      final manifest = jsonDecode(manifestText);
      if (manifest is! Map<String, dynamic> ||
          manifest['schemaVersion'] is! int ||
          manifest['schemaVersion'] != 1 ||
          manifest['archives'] is! List ||
          manifest['sourceIndexes'] is! List ||
          manifest.keys.any(
            (key) => !const {
              'schemaVersion',
              'archives',
              'sourceIndexes',
            }.contains(key),
          )) {
        throw const FormatException('Invalid private archive manifest');
      }
      for (final value in manifest['archives'] as List) {
        final descriptor = _descriptor(value);
        if (!_isRaw(descriptor)) {
          throw const FormatException('Invalid private archive route');
        }
        if (identities.add(descriptor)) archives.add(descriptor);
      }
      for (final source in manifest['sourceIndexes'] as List) {
        if (source is! String) {
          throw const FormatException('Invalid private archive source');
        }
        _validatedIndex(source);
        if (!sources.contains(source)) sources.add(source);
      }
    }

    final indexText = _store.getString(_indexKey);
    if (indexText == null) return;
    final index = _validatedIndex(indexText);
    final retained = <Map<String, dynamic>>[];
    var foundRaw = false;
    var manifestChanged = false;
    for (final descriptor in index) {
      final isNew = identities.add(descriptor);
      if (_isRaw(descriptor)) {
        foundRaw = true;
        if (isNew) {
          archives.add(descriptor);
          manifestChanged = true;
        }
      } else {
        retained.add(descriptor);
      }
    }
    if (!foundRaw) return;
    if (!sources.contains(indexText)) {
      sources.add(indexText);
      manifestChanged = true;
    }
    if (manifestChanged || manifestText == null) {
      await _store.setString(
        _manifestKey,
        jsonEncode({
          'schemaVersion': 1,
          'archives': archives,
          'sourceIndexes': sources,
        }),
      );
    }
    await _store.setString(_indexKey, jsonEncode(retained));
  }

  static List<Map<String, dynamic>> _validatedIndex(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! List) {
      throw const FormatException('Invalid archive index');
    }
    final identities = _ArchiveIdentities();
    return decoded.map((value) {
      final descriptor = _descriptor(value);
      _isRaw(descriptor);
      identities.add(descriptor);
      return descriptor;
    }).toList();
  }

  static Map<String, dynamic> _descriptor(Object? value) {
    if (value is! Map<String, dynamic> ||
        const ['id', 'driverId', 'storageKey', 'historyKey'].any(
          (key) => value[key] is! String || (value[key] as String).isEmpty,
        )) {
      throw const FormatException('Invalid archive descriptor');
    }
    return value;
  }

  static bool _isRaw(Map<String, dynamic> descriptor) {
    final driver = descriptor['driverId'] as String;
    final storageKey = descriptor['storageKey'] as String;
    final key = descriptor['historyKey'] as String;
    final binding = _binding(driver, storageKey);
    const normalized = 'openHealth.history.normalized.v1.';
    if (key.startsWith(normalized)) {
      final expected = '$normalized$binding';
      if (key != expected &&
          !(key.startsWith('$expected.archive.') &&
              key.length > '$expected.archive.'.length)) {
        throw const FormatException('Archive binding mismatch');
      }
      return false;
    }
    const raw = 'openHealth.history.cbio.v1.';
    const legacy = 'openHealth.history.v2.';
    if (key.startsWith(raw) || key.startsWith(legacy)) {
      final prefix = key.startsWith(raw) ? raw : legacy;
      if (key != '$prefix$binding' || (prefix == raw && driver != 'cbio')) {
        throw const FormatException('Archive binding mismatch');
      }
      return driver == 'cbio';
    }
    const archived = 'openHealth.history.archive.';
    if (key.startsWith(archived)) {
      final id = descriptor['id'] as String;
      if (key != '$archived$id') {
        throw const FormatException('Archive identity mismatch');
      }
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(id)));
      final prefix = '$driver|$storageKey|';
      if (!decoded.startsWith(prefix) ||
          decoded.length == prefix.length ||
          base64Url.encode(utf8.encode(decoded)).replaceAll('=', '') != id) {
        throw const FormatException('Archive identity mismatch');
      }
      return driver == 'cbio';
    }
    if (driver == 'cbio') {
      throw const FormatException('Unknown private archive route');
    }
    return false;
  }

  static String _binding(String driver, String storageKey) {
    if (storageKey.isEmpty) throw ArgumentError('Empty sensor key');
    return encodedSensorStateIdentity(
      DiscoveredSensor(
        driverId: driver,
        deviceId: '',
        displayName: '',
        storageKey: storageKey,
        rssi: 0,
        capabilities: const CgmCapabilities(),
      ),
    );
  }
}

class _ArchiveIdentities {
  final _ids = <String, Map<String, dynamic>>{};
  final _keys = <String, Map<String, dynamic>>{};

  bool add(Map<String, dynamic> descriptor) {
    final id = descriptor['id'] as String;
    final key = descriptor['historyKey'] as String;
    final previousId = _ids[id];
    final previousKey = _keys[key];
    if ((previousId != null && !_equal(previousId, descriptor)) ||
        (previousKey != null && !_equal(previousKey, descriptor))) {
      throw const FormatException('Conflicting archive identities');
    }
    _ids[id] = descriptor;
    _keys[key] = descriptor;
    return previousId == null;
  }

  static bool _equal(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
            (key) => b.containsKey(key) && _equal(a[key], b[key]),
          );
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every(
            (i) => _equal(a[i], b[i]),
          );
    }
    return a == b;
  }
}
