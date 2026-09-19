import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/persistence/cbio_private_state_adapter.dart';
import 'package:openglucose/src/persistence/sensor_state_identity.dart';

const _indexKey = 'openHealth.sensorArchive';
const _manifestKey = 'openHealth.driverState.cbio.rawArchives.v1';
const _binding = 'WyJjYmlvIiwic3ludGhldGljIl0';
const _rawKey = 'openHealth.history.cbio.v1.$_binding';
const _fullKey = 'openHealth.history.cbio.fullRecords.v1.$_binding';
const _legacyKey = 'openHealth.history.v2.$_binding';
const _normalizedKey = 'openHealth.history.normalized.v1.$_binding';

void main() {
  test(
    'full capability stores opaque bytes only in the bound private blob',
    () async {
      final before = {
        _rawKey: ' original legacy bytes\n',
        _normalizedKey: '[]',
        _indexKey: '[{"id":"unchanged"}]',
      };
      final store = _Store(before);
      final adapter = CbioPrivateStateAdapter(store);
      expect(adapter, isA<CbioFullRecordStore>());
      await adapter.writeFullRecords('synthetic', ' opaque full envelope\n');
      expect(store.values, {...before, _fullKey: ' opaque full envelope\n'});
      expect(
        await adapter.readFullRecords('synthetic'),
        ' opaque full envelope\n',
      );
      expect(await adapter.read('synthetic'), before[_rawKey]);
      expect(await adapter.readFullRecords('foreign'), isNull);
      await adapter.writeFullRecords('foreign', 'separate binding');
      expect(
        await adapter.readFullRecords('synthetic'),
        ' opaque full envelope\n',
      );
      expect(await adapter.readFullRecords('foreign'), 'separate binding');
    },
  );

  test(
    'full read preserves malformed present bytes without legacy fallback',
    () async {
      final adapter = CbioPrivateStateAdapter(
        _Store({
          _rawKey: 'legacy',
          _fullKey: '{malformed',
        }),
      );
      expect(await adapter.readFullRecords('synthetic'), '{malformed');
      expect(await adapter.readFullRecords('missing'), isNull);
    },
  );

  test('full routes reject empty bindings', () async {
    final store = _Store({});
    final adapter = CbioPrivateStateAdapter(store);
    await expectLater(adapter.readFullRecords(''), throwsArgumentError);
    expect(() => adapter.writeFullRecords('', 'opaque'), throwsArgumentError);
    expect(store.values, isEmpty);
  });

  test('legacy digest hashes exact UTF8 bytes without normalization', () {
    final adapter = CbioPrivateStateAdapter(_Store({}));
    expect(
      adapter.legacySha256(''),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      adapter.legacySha256('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      adapter.legacySha256('abc\n'),
      'edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb',
    );
    expect(
      adapter.legacySha256('é'),
      '4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c',
    );
  });

  test('failed full write leaves every previous route untouched', () async {
    final before = {
      _fullKey: 'old full',
      _rawKey: ' legacy\n',
      _indexKey: '[]',
    };
    final store = _Store(before)..failKey = _fullKey;
    await expectLater(
      CbioPrivateStateAdapter(store).writeFullRecords('synthetic', 'new full'),
      throwsStateError,
    );
    expect(store.values, before);
  });

  test('empty private sensor keys cannot create unbound routes', () async {
    final adapter = CbioPrivateStateAdapter(_Store({}));
    await expectLater(adapter.read(''), throwsArgumentError);
    expect(() => adapter.write('', 'opaque'), throwsArgumentError);
  });

  test(
    'legacy archive identity is verified without opening raw bytes',
    () async {
      final id = base64Url
          .encode(utf8.encode('cbio|synthetic|123'))
          .replaceAll('=', '');
      final key = 'openHealth.history.archive.$id';
      final raw = _descriptor(id: id, historyKey: key);
      final normalized = _descriptor(
        id: 'normalized-archive',
        historyKey: '$_normalizedKey.archive.123',
      );
      final store = _Store({
        _indexKey: jsonEncode([raw, normalized]),
        key: '{opaque',
      });
      await CbioPrivateStateAdapter(store).migrateLegacyArchives();
      expect(jsonDecode(store.values[_indexKey]!), [normalized]);
      expect(_manifest(store)['archives'], [raw]);
      expect(store.values[key], '{opaque');
    },
  );

  test(
    'raw-v1 archive moves privately without rewriting its envelope',
    () async {
      final raw = _descriptor(historyKey: _rawKey);
      final store = _Store({
        _indexKey: jsonEncode([raw]),
        _rawKey: ' raw bytes\n',
      });
      await CbioPrivateStateAdapter(store).migrateLegacyArchives();
      expect(jsonDecode(store.values[_indexKey]!), isEmpty);
      expect(_manifest(store)['archives'], [raw]);
      expect(store.values[_rawKey], ' raw bytes\n');
    },
  );

  test(
    'interrupted durable manifest copy retries without duplication',
    () async {
      final raw = _descriptor();
      final original = jsonEncode([
        raw,
        Map.fromEntries(raw.entries.toList().reversed),
      ]);
      final store = _Store({_indexKey: original});
      store.failKey = _manifestKey;
      store.commitBeforeFailure = true;
      await expectLater(
        CbioPrivateStateAdapter(store).migrateLegacyArchives(),
        throwsStateError,
      );
      expect(store.values[_indexKey], original);
      final copied = store.values[_manifestKey];
      store.failKey = null;
      await CbioPrivateStateAdapter(store).migrateLegacyArchives();
      expect(store.values[_manifestKey], copied);
      expect(_manifest(store)['archives'], [raw]);
      expect(jsonDecode(store.values[_indexKey]!), isEmpty);
    },
  );

  for (final collision in [
    _descriptor(historyKey: _rawKey),
    _descriptor(id: 'another-id'),
  ]) {
    test(
      'existing private manifest collision preserves originals $collision',
      () async {
        final before = {
          _indexKey: jsonEncode([collision]),
          _manifestKey: jsonEncode({
            'schemaVersion': 1,
            'archives': [_descriptor()],
            'sourceIndexes': <String>[],
          }),
        };
        final store = _Store(before);
        await expectLater(
          CbioPrivateStateAdapter(store).migrateLegacyArchives(),
          throwsFormatException,
        );
        expect(store.values, before);
      },
    );
  }

  for (final invalid in [
    {'schemaVersion': 1.0, 'archives': <Object>[], 'sourceIndexes': <String>[]},
    {
      'schemaVersion': 1,
      'archives': <Object>[],
      'sourceIndexes': [3],
    },
    {
      'schemaVersion': 1,
      'archives': <Object>[],
      'sourceIndexes': ['{}'],
    },
    {
      'schemaVersion': 1,
      'archives': [_descriptor(historyKey: _normalizedKey)],
      'sourceIndexes': <String>[],
    },
    {
      'schemaVersion': 1,
      'archives': [
        _descriptor(driver: 'aidex', historyKey: 'openHealth.history.other'),
      ],
      'sourceIndexes': <String>[],
    },
    {
      'schemaVersion': 1,
      'archives': <Object>[],
      'sourceIndexes': <String>[],
      'unknown': true,
    },
  ]) {
    test(
      'invalid manifest is rejected even with no normal index: $invalid',
      () async {
        final before = {_manifestKey: jsonEncode(invalid)};
        final store = _Store(before);
        await expectLater(
          CbioPrivateStateAdapter(store).migrateLegacyArchives(),
          throwsFormatException,
        );
        expect(store.values, before);
      },
    );
  }

  test('different ids sharing one raw key fail without writes', () async {
    final before = {
      _indexKey: jsonEncode([_descriptor(), _descriptor(id: 'second')]),
    };
    final store = _Store(before);
    await expectLater(
      CbioPrivateStateAdapter(store).migrateLegacyArchives(),
      throwsFormatException,
    );
    expect(store.values, before);
  });

  for (final key in [
    'openHealth.history.archive.raw-one',
    '$_normalizedKey.archive.',
  ]) {
    test('unverified archive routing fails closed: $key', () async {
      final before = {
        _indexKey: jsonEncode([_descriptor(historyKey: key)]),
      };
      final store = _Store(before);
      await expectLater(
        CbioPrivateStateAdapter(store).migrateLegacyArchives(),
        throwsFormatException,
      );
      expect(store.values, before);
    });
  }

  test('canonical bindings keep same storage keys distinct across drivers', () {
    DiscoveredSensor sensor(String driver) => DiscoveredSensor(
      driverId: driver,
      deviceId: 'not-the-storage-key',
      displayName: 'Same display name',
      storageKey: 'shared',
      rssi: -60,
      capabilities: const CgmCapabilities(),
    );
    expect(
      encodedSensorStateIdentity(sensor('cbio')),
      'WyJjYmlvIiwic2hhcmVkIl0',
    );
    expect(
      encodedSensorStateIdentity(sensor('aidex')),
      'WyJhaWRleCIsInNoYXJlZCJd',
    );
  });

  test(
    'private read and write reuse exact raw route and opaque bytes',
    () async {
      const original = ' { "future": 9, "malformed-for-codec": true }\n';
      final store = _Store({_rawKey: original, _legacyKey: '[old raw]'});
      final adapter = CbioPrivateStateAdapter(store);
      expect(await adapter.read('synthetic'), original);
      const replacement = '{"checkpoint":"opaque"}\n';
      await adapter.write('synthetic', replacement);
      expect(store.values[_rawKey], replacement);
      expect(store.values[_legacyKey], '[old raw]');
      expect(store.values.containsKey(_normalizedKey), isFalse);
    },
  );

  test('missing raw route never falls back to legacy or normalized', () async {
    final store = _Store({_legacyKey: '[legacy]', _normalizedKey: '[normal]'});
    expect(await CbioPrivateStateAdapter(store).read('synthetic'), isNull);
    expect(store.values, {_legacyKey: '[legacy]', _normalizedKey: '[normal]'});
  });

  test('copies raw descriptors and original index before filtering', () async {
    final raw = _descriptor();
    final other =
        _descriptor(
            id: 'other',
            driver: 'aidex',
            historyKey: 'openHealth.history.other',
          )
          ..['futureField'] = {
            'nested': [1, null, true],
          };
    final normalized = _descriptor(
      id: 'normalized',
      historyKey: _normalizedKey,
    );
    final original = ' \n${jsonEncode([other, raw, normalized])}\n ';
    final store = _Store({_indexKey: original, _legacyKey: '{unreadable raw'});
    store.beforeWrite = (key, _) {
      if (key == _manifestKey) expect(store.values[_indexKey], original);
      if (key == _indexKey) {
        final copied = _manifest(store);
        expect(copied['sourceIndexes'], [original]);
        expect(copied['archives'], [raw]);
      }
    };
    await CbioPrivateStateAdapter(store).migrateLegacyArchives();
    expect(jsonDecode(store.values[_indexKey]!), [other, normalized]);
    expect(store.values[_legacyKey], '{unreadable raw');
    final manifest = _manifest(store);
    expect(manifest['schemaVersion'], 1);
    expect(manifest['archives'], [raw]);
    expect(manifest['sourceIndexes'], [original]);
    final after = Map<String, String>.of(store.values);
    await CbioPrivateStateAdapter(store).migrateLegacyArchives();
    expect(store.values, after);
  });

  test('failed descriptor copy preserves original index and blob', () async {
    final original = jsonEncode([_descriptor()]);
    final store = _Store({_indexKey: original, _legacyKey: '[raw]'});
    store.failKey = _manifestKey;
    await expectLater(
      CbioPrivateStateAdapter(store).migrateLegacyArchives(),
      throwsStateError,
    );
    expect(store.values, {_indexKey: original, _legacyKey: '[raw]'});
  });

  for (final committed in [false, true]) {
    test(
      'interrupted normal-index write retries without duplicate copy $committed',
      () async {
        final raw = _descriptor();
        final original = jsonEncode([raw]);
        final store = _Store({_indexKey: original, _legacyKey: '[raw]'});
        store.failKey = _indexKey;
        store.commitBeforeFailure = committed;
        await expectLater(
          CbioPrivateStateAdapter(store).migrateLegacyArchives(),
          throwsStateError,
        );
        expect(store.values[_legacyKey], '[raw]');
        final copied = store.values[_manifestKey];
        expect(copied, isNotNull);
        if (!committed) expect(store.values[_indexKey], original);
        store.failKey = null;
        await CbioPrivateStateAdapter(store).migrateLegacyArchives();
        expect(jsonDecode(store.values[_indexKey]!), isEmpty);
        expect(store.values[_manifestKey], copied);
        expect(_manifest(store)['archives'], [raw]);
        expect(_manifest(store)['sourceIndexes'], [original]);
      },
    );
  }

  for (final bad in [
    '{',
    '{"schemaVersion":2,"archives":[],"sourceIndexes":[]}',
    '{"schemaVersion":1,"archives":{},"sourceIndexes":[]}',
  ]) {
    test('invalid private manifest fails closed: $bad', () async {
      final before = {
        _manifestKey: bad,
        _indexKey: jsonEncode([_descriptor()]),
        _legacyKey: '[raw]',
      };
      final store = _Store(before);
      await expectLater(
        CbioPrivateStateAdapter(store).migrateLegacyArchives(),
        throwsFormatException,
      );
      expect(store.values, before);
    });
  }

  final malformed = <Object?>[
    'not a descriptor',
    {..._descriptor(), 'driverId': ''},
    {..._descriptor(), 'storageKey': 3},
    {..._descriptor(), 'historyKey': 'openHealth.history.v2.foreign-binding'},
    {..._descriptor(), 'historyKey': 'openHealth.history.unknown.raw'},
    {
      ..._descriptor(),
      'historyKey': 'openHealth.history.normalized.v1.foreign-binding',
    },
  ];
  for (var i = 0; i < malformed.length; i++) {
    test('ambiguous archive $i preserves all originals', () async {
      final before = {
        _indexKey: jsonEncode([_descriptor(), malformed[i]]),
        _legacyKey: '[raw]',
      };
      final store = _Store(before);
      await expectLater(
        CbioPrivateStateAdapter(store).migrateLegacyArchives(),
        throwsFormatException,
      );
      expect(store.values, before);
    });
  }

  test('descriptor id collision fails before any durable write', () async {
    final before = {
      _indexKey: jsonEncode([
        _descriptor(),
        _descriptor(historyKey: _rawKey),
      ]),
    };
    final store = _Store(before);
    await expectLater(
      CbioPrivateStateAdapter(store).migrateLegacyArchives(),
      throwsFormatException,
    );
    expect(store.values, before);
  });

  test(
    'another driver claiming a raw route is not silently consumed',
    () async {
      final before = {
        _indexKey: jsonEncode([_descriptor(driver: 'aidex')]),
        _legacyKey: '[raw]',
      };
      final store = _Store(before);
      await expectLater(
        CbioPrivateStateAdapter(store).migrateLegacyArchives(),
        throwsFormatException,
      );
      expect(store.values, before);
    },
  );
}

Map<String, Object?> _descriptor({
  String id = 'raw-one',
  String driver = 'cbio',
  String historyKey = _legacyKey,
}) => {
  'id': id,
  'historyKey': historyKey,
  'driverId': driver,
  'storageKey': 'synthetic',
  'deviceId': 'synthetic-device',
  'displayName': 'Synthetic sensor',
  'reason': 'disconnected',
  'readingCount': 1,
  'isUnreconciled': true,
};

class _Store implements HealthStateStore {
  _Store(Map<String, String> initial) : values = Map.of(initial);
  final Map<String, String> values;
  String? failKey;
  bool commitBeforeFailure = false;
  void Function(String, String)? beforeWrite;
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String value) async {
    beforeWrite?.call(key, value);
    if (key == failKey && !commitBeforeFailure) {
      throw StateError('synthetic failure');
    }
    values[key] = value;
    if (key == failKey) throw StateError('synthetic interruption');
  }

  @override
  Future<void> remove(String key) async =>
      throw StateError('Migration must not delete');
}

Map<String, dynamic> _manifest(_Store store) =>
    jsonDecode(store.values[_manifestKey]!) as Map<String, dynamic>;
