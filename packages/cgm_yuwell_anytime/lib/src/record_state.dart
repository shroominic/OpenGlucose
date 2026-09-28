import 'dart:convert';

import 'commands.dart';
import 'errors.dart';
import 'frames.dart';
import 'history_record.dart';

const _driverId = 'yuwell-anytime';
const _schemaVersion = 1;
const _maximumSlots = 7695;
const _maximumEncodedBytes = 524288;

final _lowerHex64 = RegExp(r'^[0-9a-f]{64}$');
final _lowerHex32 = RegExp(r'^[0-9a-f]{32}$');
final _firmwarePattern = RegExp(r'^[A-Z][A-Z0-9._-]{0,31}$');

final class YuwellRecordBinding {
  const YuwellRecordBinding({
    required this.sensorBinding,
    required this.historyGeneration,
    required this.firmware,
    required this.historyOpcode,
    required this.layout,
  });

  String get driverId => _driverId;
  final String sensorBinding;
  final String historyGeneration;
  final String firmware;
  final int historyOpcode;
  final YuwellHistoryRecordLayout layout;

  @override
  String toString() => 'YuwellRecordBinding(<redacted>)';
}

sealed class YuwellRecordSlot {
  const YuwellRecordSlot();
}

final class YuwellRawRecordSlot extends YuwellRecordSlot {
  YuwellRawRecordSlot(Iterable<int> bytes)
    : bytes = YuwellHistoryRecord.parse(bytes).rawBytes;

  final List<int> bytes;

  @override
  String toString() => 'YuwellRawRecordSlot(<redacted>)';
}

final class YuwellEmptyRecordSlot extends YuwellRecordSlot {
  const YuwellEmptyRecordSlot();

  @override
  String toString() => 'YuwellEmptyRecordSlot(<redacted>)';
}

final class YuwellRecordBatch {
  YuwellRecordBatch({
    required int startIndex,
    required int consumedSlots,
    required Iterable<YuwellIndexedHistoryRecord> records,
  }) : _startIndex = startIndex,
       _consumedSlots = consumedSlots,
       _records = List<YuwellIndexedHistoryRecord>.unmodifiable(records);

  final int _startIndex;
  final int _consumedSlots;
  final List<YuwellIndexedHistoryRecord> _records;

  @override
  String toString() => 'YuwellRecordBatch(<redacted>)';
}

final class YuwellRecordState {
  YuwellRecordState._({
    required this.binding,
    required List<YuwellRecordSlot> slots,
  }) : slots = List<YuwellRecordSlot>.unmodifiable(slots);

  factory YuwellRecordState.empty({required YuwellRecordBinding binding}) {
    _validateBinding(binding);
    return YuwellRecordState._(
      binding: binding,
      slots: const <YuwellRecordSlot>[],
    );
  }

  factory YuwellRecordState.decode(String encoded) {
    if (utf8.encode(encoded).length > _maximumEncodedBytes) {
      throw const YuwellProtocolFormatException(
        'record state exceeds the encoded size limit',
      );
    }
    late final Object? value;
    try {
      value = jsonDecode(encoded);
    } catch (_) {
      throw const YuwellProtocolFormatException(
        'record state is not valid JSON',
      );
    }
    if (value is! Map ||
        !_hasExactKeys(value, const <String>[
          'version',
          'driverId',
          'sensorBinding',
          'historyGeneration',
          'firmware',
          'historyOpcode',
          'layout',
          'slots',
        ]) ||
        value['version'] != _schemaVersion ||
        value['driverId'] != _driverId ||
        value['sensorBinding'] is! String ||
        value['historyGeneration'] is! String ||
        value['firmware'] is! String ||
        value['historyOpcode'] is! int ||
        value['layout'] is! String ||
        value['slots'] is! List) {
      throw const YuwellProtocolFormatException(
        'record state has an unsupported shape',
      );
    }
    final layoutName = value['layout']! as String;
    final layout = YuwellHistoryRecordLayout.values
        .where((candidate) => candidate.name == layoutName)
        .firstOrNull;
    if (layout == null) {
      throw const YuwellProtocolFormatException(
        'record state has an unsupported layout',
      );
    }
    final binding = YuwellRecordBinding(
      sensorBinding: value['sensorBinding']! as String,
      historyGeneration: value['historyGeneration']! as String,
      firmware: value['firmware']! as String,
      historyOpcode: value['historyOpcode']! as int,
      layout: layout,
    );
    _validateBinding(binding);
    final encodedSlots = value['slots']! as List;
    if (encodedSlots.length > _maximumSlots) {
      throw const YuwellProtocolFormatException(
        'record state contains too many slots',
      );
    }
    final slots = <YuwellRecordSlot>[];
    for (final encodedSlot in encodedSlots) {
      if (encodedSlot is! Map || encodedSlot['kind'] is! String) {
        throw const YuwellProtocolFormatException(
          'record state contains a malformed slot',
        );
      }
      switch (encodedSlot['kind']) {
        case 'empty':
          if (!_hasExactKeys(encodedSlot, const <String>['kind'])) {
            throw const YuwellProtocolFormatException(
              'empty record slot has an unsupported shape',
            );
          }
          slots.add(const YuwellEmptyRecordSlot());
        case 'record':
          if (!_hasExactKeys(encodedSlot, const <String>['kind', 'bytes']) ||
              encodedSlot['bytes'] is! String) {
            throw const YuwellProtocolFormatException(
              'raw record slot has an unsupported shape',
            );
          }
          final encodedBytes = encodedSlot['bytes']! as String;
          late final List<int> bytes;
          try {
            bytes = base64Decode(encodedBytes);
          } catch (_) {
            throw const YuwellProtocolFormatException(
              'raw record slot contains malformed base64',
            );
          }
          if (base64Encode(bytes) != encodedBytes) {
            throw const YuwellProtocolFormatException(
              'raw record slot contains noncanonical base64',
            );
          }
          final slot = YuwellRawRecordSlot(bytes);
          _requireSlotLayout(slot, binding.layout);
          slots.add(slot);
        default:
          throw const YuwellProtocolFormatException(
            'record state contains an unknown slot kind',
          );
      }
    }
    final state = YuwellRecordState._(binding: binding, slots: slots);
    if (state.encode() != encoded) {
      throw const YuwellProtocolFormatException(
        'record state is not canonically encoded',
      );
    }
    return state;
  }

  final YuwellRecordBinding binding;
  final List<YuwellRecordSlot> slots;

  int get nextIndex => slots.length;

  String encode() {
    final value = <String, Object?>{
      'version': _schemaVersion,
      'driverId': binding.driverId,
      'sensorBinding': binding.sensorBinding,
      'historyGeneration': binding.historyGeneration,
      'firmware': binding.firmware,
      'historyOpcode': binding.historyOpcode,
      'layout': binding.layout.name,
      'slots': <Object?>[
        for (final slot in slots)
          switch (slot) {
            final YuwellRawRecordSlot raw => <String, Object?>{
              'kind': 'record',
              'bytes': base64Encode(raw.bytes),
            },
            YuwellEmptyRecordSlot() => const <String, Object?>{'kind': 'empty'},
          },
      ],
    };
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > _maximumEncodedBytes) {
      throw const YuwellProtocolFormatException(
        'record state exceeds the encoded size limit',
      );
    }
    return encoded;
  }

  void requireBinding(YuwellRecordBinding expected) {
    _validateBinding(expected);
    if (binding.driverId != expected.driverId ||
        binding.sensorBinding != expected.sensorBinding ||
        binding.historyGeneration != expected.historyGeneration ||
        binding.firmware != expected.firmware ||
        binding.historyOpcode != expected.historyOpcode ||
        binding.layout != expected.layout) {
      throw const YuwellProtocolFormatException(
        'record state belongs to a different binding',
      );
    }
  }

  YuwellRecordState appendBatch(YuwellRecordBatch batch) {
    final start = batch._startIndex;
    final consumed = batch._consumedSlots;
    final end = start + consumed;
    if (start < 0 ||
        start >= _maximumSlots ||
        consumed <= 0 ||
        consumed > _maximumSlots ||
        end > _maximumSlots ||
        start > nextIndex) {
      throw const YuwellProtocolFormatException(
        'record batch is outside the contiguous slot range',
      );
    }
    final recordsByIndex = <int, YuwellHistoryRecord>{};
    var previousIndex = start - 1;
    for (final indexed in batch._records) {
      if (indexed.index < start ||
          indexed.index >= end ||
          indexed.index <= previousIndex ||
          indexed.record.layout != binding.layout) {
        throw const YuwellProtocolFormatException(
          'record batch contains an invalid indexed record',
        );
      }
      previousIndex = indexed.index;
      recordsByIndex[indexed.index] = indexed.record;
    }
    final nextSlots = List<YuwellRecordSlot>.of(slots);
    for (var index = start; index < end; index++) {
      final record = recordsByIndex[index];
      final candidate = record == null
          ? const YuwellEmptyRecordSlot()
          : YuwellRawRecordSlot(record.rawBytes);
      if (index < nextSlots.length) {
        if (!_sameSlot(nextSlots[index], candidate)) {
          throw const YuwellProtocolFormatException(
            'record batch conflicts with an existing slot',
          );
        }
      } else {
        nextSlots.add(candidate);
      }
    }
    return YuwellRecordState._(binding: binding, slots: nextSlots);
  }

  @override
  String toString() => 'YuwellRecordState(<redacted>)';
}

void _validateBinding(YuwellRecordBinding binding) {
  if (binding.driverId != _driverId ||
      !_lowerHex64.hasMatch(binding.sensorBinding) ||
      !_lowerHex32.hasMatch(binding.historyGeneration) ||
      !_firmwarePattern.hasMatch(binding.firmware)) {
    throw const YuwellProtocolFormatException(
      'record binding has an unsupported shape',
    );
  }
  final supportedPair = switch (binding.historyOpcode) {
    YuwellCt5Commands.alternateHistoryCommand =>
      binding.layout == YuwellHistoryRecordLayout.alert17,
    YuwellCt5Commands.historyCommand =>
      binding.layout == YuwellHistoryRecordLayout.compact11 ||
          binding.layout == YuwellHistoryRecordLayout.voltage15,
    _ => false,
  };
  if (!supportedPair) {
    throw const YuwellProtocolFormatException(
      'record binding opcode and layout do not match',
    );
  }
}

void _requireSlotLayout(
  YuwellRawRecordSlot slot,
  YuwellHistoryRecordLayout layout,
) {
  final expectedLength = switch (layout) {
    YuwellHistoryRecordLayout.compact11 => 11,
    YuwellHistoryRecordLayout.voltage15 => 15,
    YuwellHistoryRecordLayout.alert17 => 17,
  };
  if (slot.bytes.length != expectedLength) {
    throw const YuwellProtocolFormatException(
      'raw record slot does not match the bound layout',
    );
  }
}

bool _sameSlot(YuwellRecordSlot first, YuwellRecordSlot second) {
  if (first is YuwellEmptyRecordSlot && second is YuwellEmptyRecordSlot) {
    return true;
  }
  if (first is! YuwellRawRecordSlot || second is! YuwellRawRecordSlot) {
    return false;
  }
  if (first.bytes.length != second.bytes.length) return false;
  for (var index = 0; index < first.bytes.length; index++) {
    if (first.bytes[index] != second.bytes[index]) return false;
  }
  return true;
}

bool _hasExactKeys(Map<Object?, Object?> value, List<String> expected) {
  if (value.length != expected.length) return false;
  var index = 0;
  for (final key in value.keys) {
    if (key != expected[index]) return false;
    index++;
  }
  return true;
}
