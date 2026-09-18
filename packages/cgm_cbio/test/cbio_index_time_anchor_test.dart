import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

/// One stored record as the archive assembles it.
CbioRawGlucoseRecord _record({
  required int index,
  required int rawTime,
  int rawCurrent = 64,
}) => CbioRawGlucoseRecord(
  index: index,
  rawTime: rawTime,
  reindex: index,
  rawTemperature: 315,
  rawDump: 0,
  rawCurrent: rawCurrent,
  rawExtra: 0,
);

/// The #146 capture: 448 stored records, each one minute apart, whose counter
/// renders as a clock 7 h 28 m away from the phone that fetched them.
List<CbioRawGlucoseRecord> _counterOnlyRecords(int newestTime, int count) =>
    <CbioRawGlucoseRecord>[
      for (var offset = count - 1; offset >= 0; offset -= 1)
        _record(index: 10067 - offset, rawTime: newestTime - offset * 60),
    ];

void main() {
  group('CbioIndexTimeAnchor', () {
    test('steps 60 s per index from the anchored position', () {
      final anchor = CbioIndexTimeAnchor(
        anchorIndex: 10067,
        coveredFromIndex: 9600,
        anchorEpochSeconds: 1789710000,
        observedAt: DateTime.fromMillisecondsSinceEpoch(
          1789710000 * 1000,
          isUtc: true,
        ),
        clockReferenceEpochSeconds: 1789709000,
      );

      expect(anchor.timeForIndex(10067).isUtc, isTrue);
      expect(
        anchor.timeForIndex(10067),
        DateTime.fromMillisecondsSinceEpoch(1789710000 * 1000, isUtc: true),
      );
      expect(
        anchor.timeForIndex(10066),
        anchor.timeForIndex(10067).subtract(const Duration(minutes: 1)),
      );
      expect(
        anchor.timeForIndex(10067 - 448),
        anchor
            .timeForIndex(10067)
            .subtract(const Duration(hours: 7, minutes: 28)),
      );
      // The position is the anchor's, so its own stamp survives localisation
      // by the device instead of being re-derived from the counter.
      expect(
        anchor.timeForIndex(10067).toLocal().millisecondsSinceEpoch ~/ 1000,
        1789710000,
      );
      expect(anchor.coversIndex(10066), isTrue);
      expect(anchor.coversIndex(9599), isFalse);
      expect(anchor.uncertainty, const Duration(seconds: 60));
    });

    test('round-trips through snapshot metadata', () {
      final anchor = CbioIndexTimeAnchor(
        anchorIndex: 4210,
        coveredFromIndex: 4001,
        anchorEpochSeconds: 1789710000,
        observedAt: DateTime.fromMillisecondsSinceEpoch(
          1789710012 * 1000,
          isUtc: true,
        ),
        clockReferenceEpochSeconds: 1789709000,
      );
      final restored = CbioIndexTimeAnchor.fromMetadata(anchor.toMetadata())!;

      expect(restored.anchorIndex, anchor.anchorIndex);
      expect(restored.coveredFromIndex, anchor.coveredFromIndex);
      expect(restored.anchorEpochSeconds, anchor.anchorEpochSeconds);
      expect(restored.observedAt, anchor.observedAt);
      expect(restored.clockReferenceEpochSeconds, 1789709000);
      expect(restored.source, CbioAnchorSource.appSetSensorClock);
      expect(
        CbioIndexTimeAnchor.fromMetadata(const <String, String>{}),
        isNull,
      );
      expect(
        CbioIndexTimeAnchor.fromMetadata(const <String, String>{
          cbioAnchorIndexMetadataKey: '4210',
        }),
        isNull,
        reason: 'half an anchor is not an anchor',
      );
    });

    test('reads clock agreement against the app clock it was paired with', () {
      final anchor = CbioIndexTimeAnchor(
        anchorIndex: 12,
        coveredFromIndex: 8,
        anchorEpochSeconds: 1789710000,
        observedAt: DateTime.fromMillisecondsSinceEpoch(
          1789710060 * 1000,
          isUtc: true,
        ),
      );

      expect(anchor.clockAgreement, const Duration(minutes: -1));
    });
  });

  group('deriveCbioIndexTimeAnchor', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      1789710000 * 1000,
      isUtc: true,
    );

    test(
      'anchors the newest position when the sensor took the written clock',
      () {
        final records = _counterOnlyRecords(1789710000, 4);
        final anchor = deriveCbioIndexTimeAnchor(
          records: records,
          clockReferenceEpochSeconds: 1789709940,
          now: now,
        )!;

        expect(anchor.anchorIndex, 10067);
        expect(anchor.anchorEpochSeconds, 1789710000);
        expect(anchor.coveredFromIndex, 10064);
        expect(anchor.source, CbioAnchorSource.appSetSensorClock);
        expect(anchor.coversIndex(10064), isTrue);
        expect(anchor.coversIndex(10063), isFalse);
        expect(anchor.clockAgreement, Duration.zero);
      },
    );

    test('refuses the counter-as-clock case of #146', () {
      // 448 records fetched in one minute: the sensor's stamps sit 7 h 28 m
      // away from the app's clock, so nothing may be rendered from them.
      final records = _counterOnlyRecords(1789710000 - 448 * 60, 448);

      expect(
        deriveCbioIndexTimeAnchor(
          records: records,
          clockReferenceEpochSeconds: 1789710000 - 448 * 60,
          now: now,
        ),
        isNull,
      );
      expect(
        deriveCbioIndexTimeAnchor(
          records: records,
          clockReferenceEpochSeconds: 1789710000,
          now: now,
          tolerance: const Duration(hours: 8),
        ),
        isNotNull,
        reason: 'the refusal is the tolerance, not the arithmetic',
      );
    });

    test('refuses an anchor the session has no clock reference for', () {
      expect(
        deriveCbioIndexTimeAnchor(
          records: _counterOnlyRecords(1789710000, 3),
          clockReferenceEpochSeconds: null,
          now: now,
        ),
        isNull,
      );
      expect(
        deriveCbioIndexTimeAnchor(
          records: const <CbioRawGlucoseRecord>[],
          clockReferenceEpochSeconds: 1789710000,
          now: now,
        ),
        isNull,
      );
    });

    test('covers only the unbroken 60 s step back from the anchor', () {
      final records = <CbioRawGlucoseRecord>[
        _record(index: 98, rawTime: 1789710000 - 120),
        // A hole in the archive: the next record is two positions later.
        _record(index: 100, rawTime: 1789710000 - 60),
        _record(index: 101, rawTime: 1789710000),
      ];

      final anchor = deriveCbioIndexTimeAnchor(
        records: records,
        clockReferenceEpochSeconds: 1789709940,
        now: now,
      )!;

      expect(anchor.anchorIndex, 101);
      expect(
        anchor.coveredFromIndex,
        100,
        reason: 'the range stops at the hole instead of spanning it',
      );
    });

    test('covers only the unbroken counter step back from the anchor', () {
      final records = <CbioRawGlucoseRecord>[
        // The sensor restarted its own counter: the step is not 60 s.
        _record(index: 200, rawTime: 1789710000 - 9000),
        _record(index: 201, rawTime: 1789710000 - 60),
        _record(index: 202, rawTime: 1789710000),
      ];

      final anchor = deriveCbioIndexTimeAnchor(
        records: records,
        clockReferenceEpochSeconds: 1789709940,
        now: now,
      )!;

      expect(anchor.coveredFromIndex, 201);
    });
  });
}
