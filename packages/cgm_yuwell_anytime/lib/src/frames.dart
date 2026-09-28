import 'checksum.dart';
import 'byte_utils.dart';
import 'commands.dart';
import 'errors.dart';
import 'history_record.dart';
import 'transform.dart';

/// Strict response helpers for the CT5 session state machine.
abstract final class YuwellCt5Responses {
  static List<int> requireResponse(
    Iterable<int> input, {
    required int opcode,
    int? exactLength,
  }) {
    final frame = requireValidSum8Frame(input, field: 'CT5 response');
    if (frame.first != opcode) {
      throw const YuwellProtocolFormatException(
        'CT5 response has an unexpected command',
      );
    }
    if (exactLength != null && frame.length != exactLength) {
      throw const YuwellProtocolFormatException(
        'CT5 response has an unexpected length',
      );
    }
    return frame;
  }

  static List<int> version(Iterable<int> input) {
    final frame = checkedProtocolBytes(input, field: 'version response');
    if (frame.length != 14 || frame.first != YuwellCt5Commands.versionCommand) {
      throw const YuwellProtocolFormatException(
        'version response has an unexpected shape',
      );
    }
    // This fixed-size response is the documented exception to sum8 framing.
    return frame;
  }

  static void selfCheckAccepted(Iterable<int> input) {
    requireResponse(
      input,
      opcode: YuwellCt5Commands.selfCheckCommand,
      exactLength: 20,
    );
  }

  static void dateAccepted(Iterable<int> input) {
    requireResponse(input, opcode: YuwellCt5Commands.setDateCommand);
  }

  static bool checkIdAccepted(Iterable<int> input) {
    final frame = requireResponse(
      input,
      opcode: YuwellCt5Commands.checkIdCommand,
    );
    if (frame.length < 7) {
      throw const YuwellProtocolFormatException(
        'check-ID response is too short',
      );
    }
    return frame[5] == 1;
  }

  static List<int> decodedSensorCode(
    Iterable<int> input, {
    required int cipher,
  }) {
    final frame = checkedProtocolBytes(input, field: 'sensor-code response');
    if ((frame.length != 18 && frame.length != 19 && frame.length != 22) ||
        frame.first != YuwellCt5Commands.querySensorCodeCommand) {
      throw const YuwellProtocolFormatException(
        'sensor-code response has an unexpected shape',
      );
    }
    // The SSN response is a documented exception to sum8 framing. Every byte
    // after the opcode belongs to the transformed calibration code.
    return YuwellCt5ByteTransform.decode(frame.sublist(1), key: cipher);
  }

  static void parametersAccepted(Iterable<int> input, {required int cipher}) {
    final frame = requireResponse(
      input,
      opcode: YuwellCt5Commands.setParametersCommand,
      exactLength: 14,
    );
    final clear = YuwellCt5ByteTransform.decode(
      frame.sublist(1, frame.length - 1),
      key: cipher,
    );
    if (clear.length != 12) {
      throw const YuwellProtocolFormatException(
        'setup response has an unexpected payload length',
      );
    }
  }

  static void initialized(Iterable<int> input) {
    requireResponse(input, opcode: YuwellCt5Commands.initializeCommand);
  }

  static void lowPowerAccepted(Iterable<int> input) {
    final frame = checkedProtocolBytes(input, field: 'low-power response');
    if (frame.isEmpty || frame.first != YuwellCt5Commands.lowPowerCommand) {
      throw const YuwellProtocolFormatException(
        'low-power response has an unexpected command',
      );
    }
  }

  static bool bindingStatus(Iterable<int> input) {
    final frame = requireResponse(
      input,
      opcode: YuwellCt5Commands.bindingStatusCommand,
    );
    if (frame.length < 14 || (frame[2] != 0 && frame[2] != 1)) {
      throw const YuwellProtocolFormatException(
        'binding-status response has an unexpected shape',
      );
    }
    // The reference TransmitterReset parser treats 0x22 as the status variant
    // that carries an unbind reason in byte 8. Accepting another value there
    // as simply "unbound" would let activation proceed on malformed evidence.
    if (frame[2] == 0 && frame[12] == 0x22 && frame[8] != 0 && frame[8] != 1) {
      throw const YuwellProtocolFormatException(
        'binding-status response has an invalid unbind reason',
      );
    }
    return frame[2] == 1;
  }
}

/// A decoded live record and its monotonic sample index.
final class YuwellLiveFrame {
  YuwellLiveFrame._({
    required this.opcode,
    required this.index,
    required this.record,
  });

  factory YuwellLiveFrame.parse(Iterable<int> input, {required int cipher}) {
    final frame = requireValidSum8Frame(input, field: 'live response');
    if (frame.length < 5 ||
        (frame.first != YuwellCt5Commands.liveCommand &&
            frame.first != YuwellCt5Commands.alternateLiveCommand)) {
      throw const YuwellProtocolFormatException(
        'live response has an unsupported shape',
      );
    }
    final expectedLength = switch (frame.first) {
      YuwellCt5Commands.liveCommand when frame.length == 15 => 11,
      YuwellCt5Commands.liveCommand when frame.length == 19 => 15,
      YuwellCt5Commands.alternateLiveCommand when frame.length == 21 => 17,
      _ => throw const YuwellProtocolFormatException(
        'live response has an unsupported record layout',
      ),
    };
    final clear = YuwellCt5ByteTransform.decode(
      frame.sublist(3, frame.length - 1),
      key: cipher,
    );
    if (clear.length != expectedLength) {
      throw const YuwellProtocolFormatException(
        'live response record length mismatch',
      );
    }
    return YuwellLiveFrame._(
      opcode: frame.first,
      index: frame[1] | (frame[2] << 8),
      record: YuwellHistoryRecord.parse(clear),
    );
  }

  final int opcode;
  final int index;
  final YuwellHistoryRecord record;

  bool get usesAlternatePath =>
      opcode == YuwellCt5Commands.alternateLiveCommand;

  @override
  String toString() =>
      'YuwellLiveFrame(opcode: $opcode, index: <redacted>, record: <redacted>)';
}

/// A strict decoded batch of CT5 history records.
final class YuwellHistoryFrame {
  YuwellHistoryFrame._({
    required this.opcode,
    required this.startIndex,
    required List<YuwellIndexedHistoryRecord> indexedRecords,
    required this.consumedSlots,
    required this.terminated,
    required this.layout,
  }) : indexedRecords = List<YuwellIndexedHistoryRecord>.unmodifiable(
         indexedRecords,
       );

  factory YuwellHistoryFrame.parse(
    Iterable<int> input, {
    required int cipher,
    YuwellHistoryRecordLayout? expectedLayout,
  }) {
    final frame = requireValidSum8Frame(input, field: 'history response');
    if (frame.length < 4 ||
        (frame.first != YuwellCt5Commands.historyCommand &&
            frame.first != YuwellCt5Commands.alternateHistoryCommand)) {
      throw const YuwellProtocolFormatException(
        'history response has an unsupported shape',
      );
    }
    final clear = YuwellCt5ByteTransform.decode(
      frame.sublist(3, frame.length - 1),
      key: cipher,
    );
    if (clear.isEmpty) {
      return YuwellHistoryFrame._(
        opcode: frame.first,
        startIndex: frame[1] | (frame[2] << 8),
        indexedRecords: const <YuwellIndexedHistoryRecord>[],
        consumedSlots: 0,
        terminated: true,
        layout: null,
      );
    }

    final layout = expectedLayout ?? _inferLayout(frame.first, clear.length);
    final recordLength = switch (layout) {
      YuwellHistoryRecordLayout.compact11 => 11,
      YuwellHistoryRecordLayout.voltage15 => 15,
      YuwellHistoryRecordLayout.alert17 => 17,
    };
    if (clear.length % recordLength != 0) {
      throw const YuwellProtocolFormatException(
        'history payload does not contain whole records',
      );
    }
    final startIndex = frame[1] | (frame[2] << 8);
    final records = <YuwellIndexedHistoryRecord>[];
    var consumedSlots = 0;
    var terminated = false;
    for (var offset = 0; offset < clear.length; offset += recordLength) {
      final bytes = clear.sublist(offset, offset + recordLength);
      if (_isEndSentinel(bytes)) {
        terminated = true;
        break;
      }
      final slot = offset ~/ recordLength;
      consumedSlots = slot + 1;
      if (_isInvalidSentinel(bytes)) {
        continue;
      }
      records.add(
        YuwellIndexedHistoryRecord(
          index: startIndex + slot,
          record: YuwellHistoryRecord.parse(bytes),
        ),
      );
    }
    return YuwellHistoryFrame._(
      opcode: frame.first,
      startIndex: startIndex,
      indexedRecords: records,
      consumedSlots: consumedSlots,
      terminated: terminated,
      layout: layout,
    );
  }

  final int opcode;
  final int startIndex;
  final YuwellHistoryRecordLayout? layout;
  final List<YuwellIndexedHistoryRecord> indexedRecords;
  final int consumedSlots;
  final bool terminated;

  List<YuwellHistoryRecord> get records =>
      indexedRecords.map((entry) => entry.record).toList(growable: false);

  static YuwellHistoryRecordLayout _inferLayout(int opcode, int length) {
    if (opcode == YuwellCt5Commands.alternateHistoryCommand) {
      if (length % 17 != 0) {
        throw const YuwellProtocolFormatException(
          'alternate history payload has an unexpected layout',
        );
      }
      return YuwellHistoryRecordLayout.alert17;
    }
    final candidates = <YuwellHistoryRecordLayout>[
      if (length % 11 == 0) YuwellHistoryRecordLayout.compact11,
      if (length % 15 == 0) YuwellHistoryRecordLayout.voltage15,
    ];
    if (candidates.length != 1) {
      throw const YuwellProtocolFormatException(
        'history payload layout is ambiguous',
      );
    }
    return candidates.single;
  }
}

final class YuwellIndexedHistoryRecord {
  const YuwellIndexedHistoryRecord({required this.index, required this.record});

  final int index;
  final YuwellHistoryRecord record;

  @override
  String toString() =>
      'YuwellIndexedHistoryRecord(index: <redacted>, record: <redacted>)';
}

bool _isEndSentinel(List<int> bytes) => bytes.every((byte) => byte == 0xfc);

bool _isInvalidSentinel(List<int> bytes) => bytes.every((byte) => byte == 0xff);
