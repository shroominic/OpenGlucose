import 'dart:async';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_gen1_fresh_nfc_history.dart';
import 'package:openglucose/src/libre_nfc_history.dart';

const _attemptId = 'synthetic_nfc_attempt';
const _bootstrapId = 'synthetic_receiver_1234';
const _uid = [1, 2, 3, 4, 5, 6, 7, 0xe0];
const _patch = [0x9d, 8, 0x30, 1, 0x34, 0x12];
final _receipt = DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456);

LibreGen1StreamingBootstrap _bootstrap({
  String id = _bootstrapId,
  List<int> uid = _uid,
  List<int> patch = _patch,
}) => LibreGen1StreamingBootstrap(
  bootstrapId: id,
  deviceId: '02:00:00:00:00:01',
  uid: LibreGen1Uid.algorithmOrder(uid),
  initialPatchInfo: LibreGen1PatchInfo(patch),
  streamingBase: 0,
  lifecycle: LibreGen1LifecycleState.active,
);

Map<String, Object?> _response() => {
  'attemptId': _attemptId,
  'bootstrapId': _bootstrapId,
  'uid': List<int>.of(_uid),
  'receiverInitialPatchInfo': List<int>.of(_patch),
  'currentPatchInfo': [..._patch.take(4), 0x78, 0x56],
  'encryptedFram': List<int>.filled(344, 42),
  'observedAtUtc': '${_receipt.toIso8601String().replaceFirst('Z', '')}789Z',
};

LibreNfcHistorySample _sample({
  int minute = 120,
  int scanMinute = 120,
  DateTime? receipt,
  CgmRecordSource source = CgmRecordSource.vendor,
  bool provisional = true,
  double glucose = 100,
  LibreHistoryOrigin origin = LibreHistoryOrigin.nfcTrend,
}) {
  final receivedAt = receipt ?? _receipt;
  return LibreNfcHistorySample(
    reading: CgmReading(
      valueMgdl: glucose,
      source: source,
      isDisplayProvisional: provisional,
      sensorMinute: minute,
      recordedAt: receivedAt.subtract(Duration(minutes: scanMinute - minute)),
    ),
    firstReceivedAt: receivedAt,
    origin: origin,
  );
}

LibreGen1DecodedNfcHistory _decoded({
  int scanMinute = 120,
  DateTime? receipt,
  List<LibreNfcHistorySample>? samples,
}) => LibreGen1DecodedNfcHistory(
  scanMinute: scanMinute,
  receivedAt: receipt ?? _receipt,
  samples: samples ?? [_sample()],
);

Matcher _fails(LibreGen1FreshNfcFailure kind) => throwsA(
  isA<LibreGen1FreshNfcHistoryException>().having((e) => e.kind, 'kind', kind),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Decoder decoder;
  late Object? response;
  late List<(String, Map<String, Object?>)> calls;
  late LibreGen1FreshNfcHistoryReader reader;

  setUp(() {
    decoder = _Decoder((_) => _decoded());
    response = _response();
    calls = [];
    reader = LibreGen1FreshNfcHistoryReader(
      supported: true,
      invokeMethod: (method, arguments) async {
        calls.add((method, arguments));
        return response;
      },
    );
  });

  Future<LibreGen1DecodedNfcHistory> read() => reader.readDecoded(
    bootstrap: _bootstrap(),
    attemptId: _attemptId,
    decoder: decoder,
  );

  test(
    'only exact fresh method and IDs, with original UTC microseconds',
    () async {
      decoder.decode = (evidence) {
        expect(evidence.uid, _uid);
        expect(evidence.receiverInitialPatchInfo, _patch);
        expect(evidence.currentPatchInfo, [..._patch.take(4), 0x78, 0x56]);
        expect(evidence.encryptedFram, hasLength(344));
        expect(evidence.observedAtUtc, _receipt);
        expect(evidence.observedAtUtc.isUtc, isTrue);
        return _decoded();
      };
      final result = await read();
      expect(result.scanMinute, 120);
      expect(result.receivedAt, _receipt);
      expect(calls, hasLength(1));
      expect(calls.single.$1, LibreGen1FreshNfcHistoryReader.methodName);
      expect(calls.single.$2, {
        'attemptId': _attemptId,
        'bootstrapId': _bootstrapId,
      });
      expect(decoder.calls, 1);
      expect(result.samples.clear, throwsUnsupportedError);
    },
  );

  test('owned buffers are immutable copies, then wiped and revoked', () async {
    late LibreGen1FreshNfcEvidence captured;
    late List<List<int>> views;
    decoder.decode = (evidence) {
      captured = evidence;
      views = [
        evidence.uid,
        evidence.receiverInitialPatchInfo,
        evidence.currentPatchInfo,
        evidence.encryptedFram,
      ];
      for (final bytes in views) {
        expect(() => bytes[0] = 255, throwsUnsupportedError);
      }
      ((response! as Map)['uid'] as List<int>)[0] = 200;
      expect(evidence.uid, _uid);
      return _decoded();
    };
    await read();
    for (final bytes in views) {
      expect(bytes.every((byte) => byte == 0), isTrue);
    }
    expect(() => captured.uid, _fails(LibreGen1FreshNfcFailure.revoked));
    expect(((response! as Map)['encryptedFram'] as List<int>).first, 42);
    expect(captured.toString(), 'LibreGen1FreshNfcEvidence(data: <redacted>)');
  });

  test(
    'decoder errors are redacted and still clear all owned buffers',
    () async {
      late List<int> captured;
      decoder.decode = (evidence) {
        captured = evidence.encryptedFram;
        throw StateError('synthetic-private-payload');
      };
      await expectLater(
        read(),
        _fails(LibreGen1FreshNfcFailure.invalidDecodedHistory),
      );
      expect(captured.every((byte) => byte == 0), isTrue);
      expect(
        const LibreGen1FreshNfcHistoryException(
          LibreGen1FreshNfcFailure.invalidDecodedHistory,
        ).toString(),
        'LibreGen1FreshNfcHistoryException(invalidDecodedHistory)',
      );
    },
  );

  test(
    'missing, extra, wrong identity and malformed byte fields fail closed',
    () async {
      final invalid = <Object?>[
        null,
        [],
        'synthetic-private-response',
        {..._response(), 'unexpected': true},
        {..._response()}..remove('observedAtUtc'),
        {..._response(), 'attemptId': 'synthetic_other_attempt'},
        {..._response(), 'bootstrapId': 'synthetic_other_receiver'},
        {
          ..._response(),
          'uid': [42, ..._uid.skip(1)],
        },
        {
          ..._response(),
          'receiverInitialPatchInfo': [..._patch.take(5), 0xff],
        },
        {
          ..._response(),
          'currentPatchInfo': [0x9d, 8, 0x31, 1, 0x78, 0x56],
        },
        {
          ..._response(),
          'currentPatchInfo': [0xdf, 8, 0x30, 1, 0, 0],
        },
      ];
      for (final field in [
        'uid',
        'receiverInitialPatchInfo',
        'currentPatchInfo',
        'encryptedFram',
      ]) {
        final valid = _response()[field]! as List<int>;
        invalid.addAll([
          {..._response(), field: valid.take(valid.length - 1).toList()},
          {
            ..._response(),
            field: [...valid, 0],
          },
          {
            ..._response(),
            field: [-1, ...valid.skip(1)],
          },
          {
            ..._response(),
            field: [256, ...valid.skip(1)],
          },
          {
            ..._response(),
            field: [1.0, ...valid.skip(1)],
          },
          {
            ..._response(),
            field: ['1', ...valid.skip(1)],
          },
          {..._response(), field: null},
        ]);
      }
      for (final value in invalid) {
        response = value;
        await expectLater(
          read(),
          _fails(LibreGen1FreshNfcFailure.invalidEvidence),
        );
      }
      expect(decoder.calls, 0);
    },
  );

  test(
    'strict UTC rejects ambiguous, overflow and malformed timestamps',
    () async {
      for (final value in <Object?>[
        null,
        123,
        '2026-01-02T03:04:05',
        '2026-01-02T03:04:05+00:00',
        '2026-01-02T03:04:05z',
        '2026-02-30T03:04:05Z',
        '2026-01-02T24:00:00Z',
        '2026-01-02T03:04:60Z',
        '2026-01-02T03:04:05.1234567890Z',
        '2026-01-02 03:04:05Z',
      ]) {
        response = {..._response(), 'observedAtUtc': value};
        await expectLater(
          read(),
          _fails(LibreGen1FreshNfcFailure.invalidEvidence),
        );
      }
      expect(decoder.calls, 0);
      for (final value in ['2026-01-02T03:04:05Z', '2026-01-02T03:04:05.1Z']) {
        response = {..._response(), 'observedAtUtc': value};
        decoder.decode = (evidence) =>
            _decoded(receipt: evidence.observedAtUtc, samples: []);
        expect((await read()).receivedAt, DateTime.parse(value));
      }
    },
  );

  test(
    'bad request/model and unsupported platforms never invoke native',
    () async {
      for (final item in [
        (_bootstrap(), 'short'),
        (_bootstrap(), 'synthetic/bad_attempt'),
        (_bootstrap(), 'a' * 121),
        (_bootstrap(id: 'short'), _attemptId),
        (_bootstrap(id: 'a' * 121), _attemptId),
        (_bootstrap(uid: [1, 2, 3, 4, 5, 6, 6, 0xe0]), _attemptId),
      ]) {
        await expectLater(
          reader.readDecoded(
            bootstrap: item.$1,
            attemptId: item.$2,
            decoder: decoder,
          ),
          _fails(LibreGen1FreshNfcFailure.invalidEvidence),
        );
      }
      // Unsupported models are rejected by the bootstrap contract before a
      // reader request can be constructed.
      expect(
        () => _bootstrap(patch: [0xc6, 9, 0x31, 1, 0, 0]),
        throwsA(isA<LibreGen1LiveException>()),
      );
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final guarded = LibreGen1FreshNfcHistoryReader(
            invokeMethod: (method, args) async {
              calls.add((method, args));
              return response;
            },
          );
          await expectLater(
            guarded.readDecoded(
              bootstrap: _bootstrap(),
              attemptId: _attemptId,
              decoder: decoder,
            ),
            _fails(LibreGen1FreshNfcFailure.unavailable),
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      expect(calls, isEmpty);
      expect(decoder.calls, 0);
    },
  );

  test('native failures remain closed with no calibration fallback', () async {
    for (final error in <Exception>[
      PlatformException(
        code: 'libre_history_evidence_unavailable',
        message: 'synthetic-private-message',
      ),
      MissingPluginException('synthetic-private-plugin'),
      Exception('synthetic-private-state'),
    ]) {
      final failing = LibreGen1FreshNfcHistoryReader(
        supported: true,
        invokeMethod: (method, args) async {
          calls.add((method, args));
          throw error;
        },
      );
      await expectLater(
        failing.readDecoded(
          bootstrap: _bootstrap(),
          attemptId: _attemptId,
          decoder: decoder,
        ),
        _fails(LibreGen1FreshNfcFailure.unavailable),
      );
    }
    expect(
      calls.every(
        (call) => call.$1 == LibreGen1FreshNfcHistoryReader.methodName,
      ),
      isTrue,
    );
    expect(decoder.calls, 0);
  });

  testWidgets('timeout discards a late native reply without decoding', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    reader = LibreGen1FreshNfcHistoryReader(
      supported: true,
      invokeMethod: (_, _) => pending.future,
    );
    final failure = expectLater(
      read(),
      _fails(LibreGen1FreshNfcFailure.timedOut),
    );
    await tester.pump(const Duration(seconds: 16));
    await failure;
    pending.complete(_response());
    await tester.pump();
    expect(decoder.calls, 0);
  });

  test(
    'revoked or replaced pending attempt cannot decode a late result',
    () async {
      for (final replace in [false, true]) {
        final pending = Completer<Object?>();
        var calls = 0;
        reader = LibreGen1FreshNfcHistoryReader(
          supported: true,
          invokeMethod: (_, _) =>
              calls++ == 0 ? pending.future : Future.value(_response()),
        );
        final failure = expectLater(
          read(),
          _fails(LibreGen1FreshNfcFailure.revoked),
        );
        if (replace) {
          await read();
        } else {
          reader.revoke();
        }
        pending.complete(_response());
        await failure;
      }
      expect(decoder.calls, 1);
    },
  );

  test(
    'revocation during synchronous decoding still blocks delivery',
    () async {
      late List<int> bytes;
      decoder.decode = (evidence) {
        bytes = evidence.encryptedFram;
        reader.revoke();
        return _decoded();
      };
      await expectLater(read(), _fails(LibreGen1FreshNfcFailure.revoked));
      expect(bytes.every((value) => value == 0), isTrue);
    },
  );

  test('malformed decoder output cannot cross the reader boundary', () async {
    final invalid = [
      _decoded(scanMinute: -1),
      _decoded(scanMinute: 65536),
      _decoded(receipt: _receipt.add(const Duration(seconds: 1))),
      _decoded(samples: [_sample(), _sample()]),
      _decoded(samples: [_sample(minute: 121)]),
      _decoded(samples: [_sample(minute: 59)]),
      _decoded(samples: [_sample(minute: 100)]),
      _decoded(
        samples: [_sample(minute: 110, origin: LibreHistoryOrigin.nfcHistory)],
      ),
      _decoded(samples: [_sample(origin: LibreHistoryOrigin.nfcHistory)]),
      _decoded(samples: [_sample(origin: LibreHistoryOrigin.bleLive)]),
      _decoded(samples: [_sample(origin: LibreHistoryOrigin.bleTrend)]),
      _decoded(samples: [_sample(origin: LibreHistoryOrigin.bleHistory)]),
      _decoded(samples: [_sample(origin: LibreHistoryOrigin.legacyUnknown)]),
      _decoded(samples: [_sample(provisional: false)]),
      _decoded(samples: [_sample(source: CgmRecordSource.raw)]),
      _decoded(samples: [_sample(glucose: double.nan)]),
      _decoded(samples: [_sample(glucose: double.infinity)]),
      _decoded(samples: [_sample(glucose: 0)]),
      _decoded(samples: [_sample(glucose: 2147483648)]),
      _decoded(
        samples: [_sample(receipt: _receipt.add(const Duration(seconds: 1)))],
      ),
      _decoded(samples: List.filled(49, _sample())),
      _decoded(
        samples: [
          _sample(minute: 105, origin: LibreHistoryOrigin.nfcHistory),
          _sample(),
        ],
      ),
    ];
    for (final value in invalid) {
      decoder.decode = (_) => value;
      await expectLater(
        read(),
        _fails(LibreGen1FreshNfcFailure.invalidDecodedHistory),
      );
    }
  });

  test('history rejects slots older than the current 32-record ring', () async {
    for (final minute in [60, 105, 120]) {
      decoder.decode = (_) => _decoded(
        scanMinute: 600,
        samples: [
          _sample(
            minute: minute,
            scanMinute: 600,
            origin: LibreHistoryOrigin.nfcHistory,
          ),
        ],
      );
      if (minute < 120) {
        await expectLater(
          read(),
          _fails(LibreGen1FreshNfcFailure.invalidDecodedHistory),
        );
      } else {
        expect((await read()).samples.single.reading.sensorMinute, 120);
      }
    }
  });

  test(
    'normal reader contract has no GPL or historical calibration import',
    () {
      final source = File(
        'lib/src/libre_gen1_fresh_nfc_history.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('cgm_libre2_glucose')));
      expect(source, isNot(contains('libre_gen1_glucose_adapter.dart')));
      expect(source, isNot(contains('readCalibrationEvidence')));
      expect(source, isNot(contains('dart:io')));
      expect(source, contains('kDebugMode'));
      expect(source, contains('TargetPlatform.android'));
      expect(
        reader.toString(),
        'LibreGen1FreshNfcHistoryReader(data: <redacted>)',
      );
      expect(
        _decoded().toString(),
        'LibreGen1DecodedNfcHistory(data: <redacted>)',
      );
    },
  );
}

final class _Decoder implements LibreGen1NfcHistoryDecoder {
  _Decoder(this.decode);
  LibreGen1DecodedNfcHistory Function(LibreGen1FreshNfcEvidence) decode;
  int calls = 0;

  @override
  LibreGen1DecodedNfcHistory decodeFreshNfc(
    LibreGen1FreshNfcEvidence evidence,
  ) {
    calls++;
    return decode(evidence);
  }
}
