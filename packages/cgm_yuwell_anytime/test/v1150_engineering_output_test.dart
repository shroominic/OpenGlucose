import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  final activation = DateTime.utc(2026, 9, 2, 12);
  final afterWarmup = DateTime.utc(2026, 9, 2, 13);

  YuwellV1150EngineeringOutput projector({
    YuwellV1150GlucoseOutputPolicy policy =
        YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
    DateTime? now,
  }) => YuwellV1150EngineeringOutput(
    policy: policy,
    clock: () => now ?? afterWarmup,
  );

  CgmReading? observe(
    YuwellV1150EngineeringOutput output,
    int index, {
    String firmware = 'V1150',
    bool transmitterComputed = true,
    YuwellCredentialPhase phase = YuwellCredentialPhase.active,
    int opcode = YuwellCt5Commands.alternateHistoryCommand,
    YuwellHistoryRecord? record,
    DateTime? startedAt,
    bool omitStart = false,
    int initializationIndex = 15,
  }) => output.observe(
    firmware: firmware,
    transmitterComputed: transmitterComputed,
    credentialPhase: phase,
    opcode: opcode,
    index: index,
    record: record ?? alertRecord(glucoseMgDl: 123),
    activationStartedAt: omitStart ? null : (startedAt ?? activation),
    initializationIndex: initializationIndex,
  );

  void consumeHistory(
    YuwellV1150EngineeringOutput output, {
    required int startIndex,
    required int consumedSlots,
    String firmware = 'V1150',
    bool transmitterComputed = true,
    YuwellCredentialPhase phase = YuwellCredentialPhase.active,
    int opcode = YuwellCt5Commands.alternateHistoryCommand,
    YuwellHistoryRecordLayout? layout = YuwellHistoryRecordLayout.alert17,
    DateTime? startedAt,
    bool omitStart = false,
    int initializationIndex = 15,
  }) => output.observeHistorySlots(
    firmware: firmware,
    transmitterComputed: transmitterComputed,
    credentialPhase: phase,
    opcode: opcode,
    layout: layout,
    startIndex: startIndex,
    consumedSlots: consumedSlots,
    activationStartedAt: omitStart ? null : (startedAt ?? activation),
    initializationIndex: initializationIndex,
  );

  void proveHistoryThrough(
    YuwellV1150EngineeringOutput output,
    int lastIndex,
  ) => consumeHistory(output, startIndex: 0, consumedSlots: lastIndex + 1);

  void observePrefix(YuwellV1150EngineeringOutput output, int lastIndex) {
    proveHistoryThrough(output, lastIndex);
    for (var index = 0; index <= lastIndex; index++) {
      observe(output, index);
    }
  }

  CgmReading? observeFirstDisplay({
    String firmware = 'V1150',
    bool transmitterComputed = true,
    YuwellCredentialPhase phase = YuwellCredentialPhase.active,
    int opcode = YuwellCt5Commands.alternateHistoryCommand,
    YuwellHistoryRecord? record,
    bool omitStart = false,
    int initializationIndex = 15,
  }) {
    final output = projector();
    proveHistoryThrough(output, 14);
    for (var index = 0; index < 14; index++) {
      observe(output, index);
    }
    return observe(
      output,
      14,
      firmware: firmware,
      transmitterComputed: transmitterComputed,
      phase: phase,
      opcode: opcode,
      record: record,
      omitStart: omitStart,
      initializationIndex: initializationIndex,
    );
  }

  test('default policy never exposes a glucose reading', () {
    final output = YuwellV1150EngineeringOutput(clock: () => afterWarmup);
    observePrefix(output, 13);

    expect(observe(output, 14), isNull);
  });

  test('projects the first post-warmup point as explicitly provisional', () {
    final output = projector();
    observePrefix(output, 13);

    final reading = observe(
      output,
      14,
      opcode: YuwellCt5Commands.alternateLiveCommand,
      record: alertRecord(glucoseMgDl: 147, status: 4, trend: 2),
    );

    expect(reading, isNotNull);
    expect(reading!.valueMgdl, 147);
    expect(reading.source, CgmRecordSource.vendor);
    expect(reading.sensorMinute, 45);
    expect(reading.recordedAt, DateTime.utc(2026, 9, 2, 12, 45, 3));
    expect(reading.rawValue, 147);
    expect(reading.qualifier, 4);
    expect(reading.isDisplayProvisional, isTrue);
  });

  test('requires a contiguous prefix from index zero', () {
    final output = projector();

    expect(observe(output, 14), isNull);
    proveHistoryThrough(output, 14);
    expect(observe(output, 14), isNotNull);
  });

  test('an FF history slot advances proof without becoming a reading', () {
    final output = projector();

    // Slot zero represents an authenticated all-FF record. Slots 1 through
    // 14 contain parsed records, so index 14 remains the first publication.
    consumeHistory(output, startIndex: 0, consumedSlots: 15);
    for (var index = 1; index < 14; index++) {
      expect(observe(output, index), isNull);
    }

    expect(observe(output, 14), isNotNull);
  });

  test('a gapped live record is not retained as later prefix proof', () {
    final output = projector();

    expect(
      observe(output, 14, opcode: YuwellCt5Commands.alternateLiveCommand),
      isNull,
    );
    observePrefix(output, 13);

    // If the old high record had been retained, index 15 would now be the
    // exact next live sample. It must remain blocked until a new index 14
    // observation closes the gap.
    expect(
      observe(output, 15, opcode: YuwellCt5Commands.alternateLiveCommand),
      isNull,
    );
    expect(
      observe(output, 14, opcode: YuwellCt5Commands.alternateLiveCommand),
      isNotNull,
    );
    expect(
      observe(output, 15, opcode: YuwellCt5Commands.alternateLiveCommand),
      isNotNull,
    );
  });

  test('a history overlap after exact-next live remains deterministic', () {
    final output = projector();
    observePrefix(output, 14);

    final live = observe(
      output,
      15,
      opcode: YuwellCt5Commands.alternateLiveCommand,
      record: alertRecord(glucoseMgDl: 131),
    );
    expect(live, isNotNull);

    consumeHistory(output, startIndex: 15, consumedSlots: 1);
    final historyCopy = observe(
      output,
      15,
      record: alertRecord(glucoseMgDl: 131),
    );
    expect(historyCopy?.toJson(), live?.toJson());
    expect(
      observe(output, 16, opcode: YuwellCt5Commands.alternateLiveCommand),
      isNotNull,
    );
  });

  test('uses exact three-second init offset and three-minute sample time', () {
    final output = projector();
    observePrefix(output, 14);
    consumeHistory(output, startIndex: 15, consumedSlots: 1);

    final reading = observe(output, 15);

    expect(reading, isNotNull);
    expect(reading!.sensorMinute, 48);
    expect(reading.recordedAt, DateTime.utc(2026, 9, 2, 12, 48, 3));
  });

  group('fails closed', () {
    test('for firmware, session, path, layout, and activation mismatches', () {
      final cases = <CgmReading? Function()>[
        () => observeFirstDisplay(firmware: 'V1149'),
        () => observeFirstDisplay(transmitterComputed: false),
        () => observeFirstDisplay(phase: YuwellCredentialPhase.lowPowerPending),
        () => observeFirstDisplay(opcode: YuwellCt5Commands.liveCommand),
        () => observeFirstDisplay(record: voltageRecord(glucoseMgDl: 123)),
        () => observeFirstDisplay(omitStart: true),
        () => observeFirstDisplay(initializationIndex: 14),
      ];

      for (final blocked in cases) {
        expect(blocked(), isNull);
      }
    });

    test('during warmup and for unreviewed statuses', () {
      final output = projector();
      observePrefix(output, 13);
      consumeHistory(output, startIndex: 14, consumedSlots: 2);

      expect(observe(output, 13), isNull);
      expect(
        observe(output, 14, record: alertRecord(glucoseMgDl: 123, status: 1)),
        isNull,
      );
      expect(
        observe(output, 15, record: alertRecord(glucoseMgDl: 123, status: 105)),
        isNull,
      );
    });

    test('for indexes outside the reviewed sensor lifetime', () {
      expect(observe(projector(), -1), isNull);
      expect(
        observe(projector(), YuwellV1150EngineeringOutput.maximumIndex + 1),
        isNull,
      );
    });

    test('when history slot bounds are invalid', () {
      for (final bounds in <(int, int)>[
        (-1, 15),
        (0, 0),
        (0, YuwellV1150EngineeringOutput.maximumIndex + 2),
        (YuwellV1150EngineeringOutput.maximumIndex, 2),
      ]) {
        final output = projector();
        consumeHistory(output, startIndex: bounds.$1, consumedSlots: bounds.$2);
        expect(observe(output, 14), isNull);
      }
    });

    test('recovery proof advances before active but cannot emit early', () {
      final output = projector();
      consumeHistory(
        output,
        startIndex: 0,
        consumedSlots: 15,
        phase: YuwellCredentialPhase.lowPowerPending,
      );

      expect(
        observe(output, 14, phase: YuwellCredentialPhase.lowPowerPending),
        isNull,
      );
      expect(observe(output, 14), isNotNull);
    });

    test('pre-activation history cannot establish prefix proof', () {
      for (final phase in <YuwellCredentialPhase>[
        YuwellCredentialPhase.identityPrepared,
        YuwellCredentialPhase.authenticated,
        YuwellCredentialPhase.configured,
      ]) {
        final output = projector();
        consumeHistory(output, startIndex: 0, consumedSlots: 15, phase: phase);
        expect(observe(output, 14), isNull);
      }
    });

    test('for zero, implausible, and future values', () {
      final output = projector(now: DateTime.utc(2026, 9, 2, 12, 44));
      observePrefix(output, 13);
      consumeHistory(output, startIndex: 14, consumedSlots: 1);

      expect(observe(output, 14, record: alertRecord(glucoseMgDl: 0)), isNull);
      expect(observe(output, 14, record: alertRecord(glucoseMgDl: 19)), isNull);
      expect(
        observe(output, 14, record: alertRecord(glucoseMgDl: 601)),
        isNull,
      );
      expect(observe(output, 14), isNull);
    });
  });
}

YuwellHistoryRecord alertRecord({
  required int glucoseMgDl,
  int status = 0,
  int trend = 1,
}) => YuwellHistoryRecord.parse(<int>[
  0x00,
  0x64,
  0x00,
  0x78,
  0x46,
  0x19,
  (trend << 4) | ((glucoseMgDl >> 8) & 0x0f),
  glucoseMgDl & 0xff,
  status,
  0x01,
  0x02,
  0x03,
  0x04,
  0x12,
  0x34,
  0x00,
  0x00,
]);

YuwellHistoryRecord voltageRecord({required int glucoseMgDl}) =>
    YuwellHistoryRecord.parse(<int>[
      0x00,
      0x64,
      0x00,
      0x78,
      0x46,
      0x19,
      0x10 | ((glucoseMgDl >> 8) & 0x0f),
      glucoseMgDl & 0xff,
      0x00,
      0x01,
      0x02,
      0x03,
      0x04,
      0x12,
      0x34,
    ]);
