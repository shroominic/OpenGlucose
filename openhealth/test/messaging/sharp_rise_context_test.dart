import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/messaging/message_context.dart';
import 'package:openglucose/src/mock_scenarios.dart';

final _now = DateTime.utc(2026, 6, 22, 12);

void main() {
  group('detectSharpRise', () {
    test(
      'derives the rising 95 to 111 to 131 tail as 36 mg/dL in 10 minutes',
      () {
        final readings = _readings(<double>[95, 111, 131]);

        final signal = detectSharpRise(
          snapshot: _readySnapshot(readings),
          readings: readings,
          isWarmingUp: false,
          now: _now,
        );

        expect(signal, isNotNull);
        expect(signal!.changeMgdl, 36);
        expect(signal.durationMinutes, 10);
        expect(signal.englishChangeText, 'Up 36 mg/dL in 10 minutes');
      },
    );

    test('accepts inclusive current and trailing-window boundaries', () {
      final lowerCurrent = _readings(
        <double>[60, 80, 100],
        startMinutesAgo: 10,
      );
      final upperCurrent = _readings(
        <double>[139, 159, 179],
        startMinutesAgo: 20,
        middleMinutesAgo: 10,
      );

      expect(
        detectSharpRise(
          snapshot: _readySnapshot(lowerCurrent),
          readings: lowerCurrent,
          isWarmingUp: false,
          now: _now,
        ),
        isNotNull,
      );
      expect(
        detectSharpRise(
          snapshot: _readySnapshot(upperCurrent),
          readings: upperCurrent,
          isWarmingUp: false,
          now: _now,
        ),
        isNotNull,
      );
    });

    test('requires the actual live latest reading to complete the tail', () {
      final history = _readings(
        <double>[95, 111, 131],
        startMinutesAgo: 15,
        middleMinutesAgo: 10,
      );
      final liveHigh = _reading(180, at: _now);
      final liveProvisional = _reading(
        131,
        at: _now,
        provisional: true,
      );
      final liveQualifying = _reading(131, at: _now);

      expect(
        _detect(history, latestReading: liveHigh),
        isNull,
        reason: 'a high live reading must suppress a history-only nudge',
      );
      expect(
        _detect(history, latestReading: liveProvisional),
        isNull,
        reason: 'a provisional live reading must suppress a history-only nudge',
      );
      expect(
        _detect(history.take(2).toList(), latestReading: liveQualifying),
        isNull,
        reason: 'the selected history tail must end at the live current sample',
      );
      expect(
        _detect(<CgmReading>[...history.take(2), liveQualifying]),
        isNotNull,
      );
    });

    test('chooses the most recent coherent qualifying trailing window', () {
      final history = <CgmReading>[
        _reading(120, at: _now.subtract(const Duration(minutes: 20))),
        _reading(95, at: _now.subtract(const Duration(minutes: 10))),
        _reading(111, at: _now.subtract(const Duration(minutes: 5))),
      ];
      final latest = _reading(131, at: _now);

      final signal = _detect(history, latestReading: latest);

      expect(signal?.changeMgdl, 36);
      expect(signal?.durationMinutes, 10);
    });

    test('clears a stale signal only when clearing is explicit', () {
      final signal = SharpRiseSignal(
        changeMgdl: 36,
        durationMinutes: 10,
        tailStart: DateTime(2026, 6, 22, 11, 50),
      );
      final context = MessageContext(
        hasSession: true,
        isWarmingUp: false,
        hasReadings: true,
        now: _now,
        sharpRise: signal,
      );

      expect(context.copyWith().sharpRise, same(signal));
      expect(context.copyWith(clearSharpRise: true).sharpRise, isNull);
    });

    test('rejects strict freshness, ordering, gap, and slope boundaries', () {
      final history = _readings(<double>[95, 111]);
      final latest = _reading(131, at: _now);
      final sparse = <CgmReading>[
        _reading(95, at: _now.subtract(const Duration(minutes: 20))),
        _reading(111, at: _now.subtract(const Duration(minutes: 9))),
        _reading(131, at: _now),
      ];
      final fractionalSlope = <CgmReading>[
        _reading(
          95,
          at: _now.subtract(const Duration(minutes: 10, milliseconds: 500)),
        ),
        _reading(105, at: _now.subtract(const Duration(minutes: 5))),
        _reading(115, at: _now),
      ];
      final duplicate = <CgmReading>[
        _reading(95, at: _now.subtract(const Duration(minutes: 10))),
        _reading(111, at: _now.subtract(const Duration(minutes: 5))),
        _reading(111, at: _now.subtract(const Duration(minutes: 5))),
        _reading(131, at: _now),
      ];
      final outOfOrder = <CgmReading>[
        _reading(95, at: _now.subtract(const Duration(minutes: 10))),
        _reading(111, at: _now.subtract(const Duration(minutes: 5))),
        _reading(105, at: _now.subtract(const Duration(minutes: 7))),
        _reading(131, at: _now),
      ];

      expect(
        _detect(
          history,
          latestReading: latest,
          now: _now.add(const Duration(minutes: 6)),
        ),
        isNotNull,
      );
      expect(
        _detect(
          history,
          latestReading: latest,
          now: _now.add(const Duration(minutes: 6, microseconds: 1)),
        ),
        isNull,
      );
      expect(
        _detect(<CgmReading>[
          ...history,
          _reading(131, at: _now.add(const Duration(microseconds: 1))),
        ]),
        isNull,
      );
      expect(_detect(sparse), isNull);
      expect(_detect(fractionalSlope), isNull);
      expect(_detect(duplicate), isNull);
      expect(_detect(outOfOrder), isNull);
    });

    test(
      'fails closed for unsafe, stale, malformed, or non-qualifying input',
      () {
        final qualifying = _readings(<double>[95, 111, 131]);
        final cases =
            <
              String,
              ({
                CgmSessionSnapshot snapshot,
                List<CgmReading> readings,
                bool warming,
                DateTime now,
              })
            >{
              'warmup': (
                snapshot: _readySnapshot(qualifying),
                readings: qualifying,
                warming: true,
                now: _now,
              ),
              'disconnected': (
                snapshot: _readySnapshot(qualifying).copyWith(
                  stage: CgmSyncStage.disconnected,
                ),
                readings: qualifying,
                warming: false,
                now: _now,
              ),
              'health error': (
                snapshot: _readySnapshot(qualifying).copyWith(
                  health: const CgmHealthSnapshot(error: true),
                ),
                readings: qualifying,
                warming: false,
                now: _now,
              ),
              'malfunction': (
                snapshot: _readySnapshot(qualifying).copyWith(
                  health: const CgmHealthSnapshot(malfunction: true),
                ),
                readings: qualifying,
                warming: false,
                now: _now,
              ),
              'signal loss': (
                snapshot: _readySnapshot(qualifying).copyWith(
                  health: const CgmHealthSnapshot(signalLost: true),
                ),
                readings: qualifying,
                warming: false,
                now: _now,
              ),
              'expired': (
                snapshot: _readySnapshot(qualifying).copyWith(
                  health: const CgmHealthSnapshot(expired: true),
                ),
                readings: qualifying,
                warming: false,
                now: _now,
              ),
              'stale latest': (
                snapshot: _readySnapshot(qualifying),
                readings: qualifying,
                warming: false,
                now: _now.add(const Duration(minutes: 7)),
              ),
              'provisional latest': (
                snapshot: _readySnapshot(_provisional(qualifying)),
                readings: _provisional(qualifying),
                warming: false,
                now: _now,
              ),
              'insufficient readings': (
                snapshot: _readySnapshot(qualifying.take(2).toList()),
                readings: qualifying.take(2).toList(),
                warming: false,
                now: _now,
              ),
              'sparse gap': (
                snapshot: _readySnapshot(
                  _readings(
                    <double>[95, 111, 131],
                    startMinutesAgo: 21,
                    middleMinutesAgo: 5,
                  ),
                ),
                readings: _readings(
                  <double>[95, 111, 131],
                  startMinutesAgo: 21,
                  middleMinutesAgo: 5,
                ),
                warming: false,
                now: _now,
              ),
              'falling step': (
                snapshot: _readySnapshot(_readings(<double>[95, 132, 131])),
                readings: _readings(<double>[95, 132, 131]),
                warming: false,
                now: _now,
              ),
              'low current': (
                snapshot: _readySnapshot(_readings(<double>[59, 79, 99])),
                readings: _readings(<double>[59, 79, 99]),
                warming: false,
                now: _now,
              ),
              'high current': (
                snapshot: _readySnapshot(_readings(<double>[144, 162, 180])),
                readings: _readings(<double>[144, 162, 180]),
                warming: false,
                now: _now,
              ),
              'non-finite': (
                snapshot: _readySnapshot(
                  _readings(<double>[95, 111, double.nan]),
                ),
                readings: _readings(<double>[95, 111, double.nan]),
                warming: false,
                now: _now,
              ),
              'untimestamped': (
                snapshot: _readySnapshot(<CgmReading>[
                  ...qualifying.take(2),
                  const CgmReading(
                    valueMgdl: 131,
                    source: CgmRecordSource.vendor,
                  ),
                ]),
                readings: <CgmReading>[
                  ...qualifying.take(2),
                  const CgmReading(
                    valueMgdl: 131,
                    source: CgmRecordSource.vendor,
                  ),
                ],
                warming: false,
                now: _now,
              ),
            };

        for (final entry in cases.entries) {
          final input = entry.value;
          expect(
            _detect(
              input.readings,
              snapshot: input.snapshot,
              now: input.now,
              isWarmingUp: input.warming,
            ),
            isNull,
            reason: '${entry.key} must suppress the wellness nudge',
          );
        }
      },
    );
  });
}

List<CgmReading> _readings(
  List<double> values, {
  int startMinutesAgo = 10,
  int? middleMinutesAgo,
}) {
  final minutesAgo = switch (values.length) {
    3 => <int>[startMinutesAgo, middleMinutesAgo ?? startMinutesAgo ~/ 2, 0],
    _ => List<int>.generate(
      values.length,
      (index) => (values.length - 1 - index) * 5,
    ),
  };
  return List<CgmReading>.generate(
    values.length,
    (index) => CgmReading(
      valueMgdl: values[index],
      source: CgmRecordSource.vendor,
      recordedAt: _now.subtract(Duration(minutes: minutesAgo[index])),
    ),
  );
}

List<CgmReading> _provisional(List<CgmReading> readings) => <CgmReading>[
  ...readings.take(readings.length - 1),
  readings.last.copyWith(isDisplayProvisional: true),
];

CgmSessionSnapshot _readySnapshot(
  List<CgmReading> readings, {
  CgmReading? latestReading,
}) => MockScenarioCatalog(clock: () => _now)
    .buildSnapshot(MockScenario.activeNormal)
    .copyWith(history: readings, latestReading: latestReading ?? readings.last);

CgmReading _reading(
  double value, {
  required DateTime at,
  bool provisional = false,
}) => CgmReading(
  valueMgdl: value,
  source: CgmRecordSource.vendor,
  recordedAt: at,
  isDisplayProvisional: provisional,
);

SharpRiseSignal? _detect(
  List<CgmReading> readings, {
  CgmSessionSnapshot? snapshot,
  CgmReading? latestReading,
  bool isWarmingUp = false,
  DateTime? now,
}) {
  final effectiveSnapshot =
      snapshot ?? _readySnapshot(readings, latestReading: latestReading);
  return detectSharpRise(
    snapshot: effectiveSnapshot,
    readings: readings,
    latestReading: latestReading ?? effectiveSnapshot.latestReading,
    isWarmingUp: isWarmingUp,
    now: now ?? _now,
  );
}
