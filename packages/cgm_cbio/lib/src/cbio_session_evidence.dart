// SPDX-License-Identifier: GPL-3.0-only
/// Durable, redacted evidence for one device-backed GS1 session.
///
/// A device harness builds exactly one record per run, asserts
/// [CbioSessionEvidence.invariantViolations] before the run is allowed to pass,
/// and emits [CbioSessionEvidence.toJson] as one machine-readable line. The
/// record is the reviewable artifact of a hardware run: the outcome, the counts
/// and ranges the session actually produced, the bounded timing, the closed
/// error taxonomy, and the app/harness identity.
///
/// The record cannot carry a sensor address, credential bytes, vendor material,
/// or a physical glucose unit. Values stay raw and [unitStatus] stays
/// `unverified`.
library;

import 'dart:convert';

/// Terminal state of one harness run.
enum CbioSessionOutcome {
  /// The session ran every required step and produced its required evidence.
  completed('completed'),

  /// No FF30 advertiser was found inside the acquisition budget.
  abortedNoTarget('aborted_no_target'),

  /// The link came up without the FF31 notify / FF32 write pair.
  abortedMissingCharacteristics('aborted_missing_characteristics'),

  /// The link never acknowledged the authentication frame.
  abortedAuthenticationFailed('aborted_authentication_failed'),

  /// The run threw before it reached a verdict.
  failed('failed');

  const CbioSessionOutcome(this.wire);

  /// Stable wire value used inside the evidence artifact.
  final String wire;
}

/// Class of command frame a harness wrote, classified from its plaintext.
enum CbioWriteKind {
  /// Vendor device-information read `03 F0 selector C`.
  deviceInformationRead('device_information_read'),

  /// Vendor masked link setup `19 01 00 ... C`.
  authentication('authentication'),

  /// Vendor clock frame `06 03 LE32(epoch) C`.
  clockSet('clock_set'),

  /// Vendor glucose read `06 0A LE16(index) 00 00 C`.
  glucoseRead('glucose_read'),

  /// Vendor raw history read `06 08 LE16(index) 00 00 C`.
  rawHistoryRead('raw_history_read'),

  /// Any command this library does not recognise.
  unclassified('unclassified');

  const CbioWriteKind(this.wire);

  /// Stable wire value used inside the evidence artifact.
  final String wire;

  /// Classifies one plaintext command frame.
  ///
  /// Only frames the safety envelope allows are named. Everything else stays
  /// [unclassified], and a harness fails its invariants when it writes anything
  /// outside its own allow-list, so an unknown or administrative command (an
  /// activation, reset, threshold, calibration, key-registration or firmware
  /// frame) can never be sent unnoticed.
  static CbioWriteKind classify(List<int> plaintext) {
    if (plaintext.length < 2) return CbioWriteKind.unclassified;
    final command = plaintext[0];
    final selector = plaintext[1];
    if (command == 0x03 && selector == 0xf0) {
      return CbioWriteKind.deviceInformationRead;
    }
    if (command == 0x19 && selector == 0x01) {
      return CbioWriteKind.authentication;
    }
    if (command == 0x06) {
      return switch (selector) {
        0x0a => CbioWriteKind.glucoseRead,
        0x08 => CbioWriteKind.rawHistoryRead,
        0x03 => CbioWriteKind.clockSet,
        _ => CbioWriteKind.unclassified,
      };
    }
    return CbioWriteKind.unclassified;
  }
}

/// Closed reason vocabulary for [CbioSessionEvidence.errors].
///
/// A reason outside this set is a failed invariant, so the artifact can never
/// grow an ad-hoc string that hides a new failure mode.
const Set<String> cbioSessionErrorReasons = <String>{
  'target_missing',
  'scan_failed',
  'connect_failed',
  'discover_failed',
  'characteristic_missing',
  'mtu_failed',
  'subscribe_failed',
  'write_failed',
  'auth_rejected',
  'auth_timeout',
  'serial_read_failed',
  'reply_timeout',
  'decode_rejected',
  'disconnect_failed',
  'unexpected_error',
};

/// Highest raw value the 10-bit packed glucose field can hold.
const int cbioRawGlucoseMaximum = 0x3ff;

/// Highest value the 16-bit raw payload word can hold.
const int cbioRawPayloadMaximum = 0xffff;

/// Identity strings that must never appear in an evidence artifact: a Bluetooth
/// address in colon or dash form, or a long hex run that could carry credential
/// or vendor material.
final List<RegExp> _forbiddenEvidencePatterns = <RegExp>[
  RegExp(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'),
  RegExp(r'[0-9A-Fa-f]{32,}'),
];

/// Validates one decoded evidence artifact as it is read back from a device log.
///
/// Pure and host-testable. An empty result means the artifact can be trusted as
/// hardware evidence: schema and closed vocabularies hold, ranges are inside the
/// observed envelope, timing is forward-moving, and no identity leaks.
List<String> cbioSessionEvidenceArtifactViolations(Object? decoded) {
  if (decoded is! Map<String, Object?>) return const ['artifact_not_an_object'];
  final violations = <String>[];
  if (decoded['schema'] != 'cbio.session-evidence/2') {
    violations.add('unknown_schema');
  }
  final identity = decoded['identity'];
  if (identity is! Map) {
    violations.add('identity_missing');
  } else {
    for (final key in const [
      'harness',
      'harnessRevision',
      'appPackage',
      'appRevision',
      'platform',
    ]) {
      final value = identity[key];
      if (value is! String || value.trim().isEmpty) {
        violations.add('identity_missing:$key');
      }
    }
  }
  final outcome = decoded['outcome'];
  if (outcome is! String) {
    violations.add('outcome_missing');
  } else if (!CbioSessionOutcome.values.any((value) => value.wire == outcome)) {
    violations.add('outcome_unknown');
  }
  if (decoded['unitStatus'] != 'unverified') {
    violations.add('unit_status_claimed');
  }
  for (final key in const ['targetAcquired', 'gattReleased']) {
    if (decoded[key] is! bool) violations.add('${key}_not_boolean');
  }
  final notifications = decoded['notifications'];
  if (notifications is! int || notifications < 0) {
    violations.add('notifications_not_a_count');
  }
  final writes = decoded['writes'];
  if (writes is! Map) {
    violations.add('writes_missing');
  } else {
    final known = <String>{for (final kind in CbioWriteKind.values) kind.wire};
    for (final entry in writes.entries) {
      if (!known.contains(entry.key)) {
        violations.add('write_kind_unknown:${entry.key}');
      }
      if (entry.value is! int || (entry.value as int) < 0) {
        violations.add('write_count_invalid:${entry.key}');
      }
    }
  }
  final errors = decoded['errors'];
  if (errors is! Map) {
    violations.add('errors_missing');
  } else {
    for (final entry in errors.entries) {
      if (!cbioSessionErrorReasons.contains(entry.key)) {
        violations.add('error_reason_unknown:${entry.key}');
      }
      if (entry.value is! int || (entry.value as int) < 0) {
        violations.add('error_count_invalid:${entry.key}');
      }
    }
  }
  violations.addAll(_recordViolations(decoded['records']));
  violations.addAll(_timingViolations(decoded));
  final encoded = jsonEncode(decoded);
  for (final pattern in _forbiddenEvidencePatterns) {
    if (pattern.hasMatch(encoded)) violations.add('identity_leak');
  }
  return violations;
}

List<String> _recordViolations(Object? records) {
  if (records is! Map) return const ['records_missing'];
  final violations = <String>[];
  for (final key in const ['glucose', 'raw']) {
    final block = records[key];
    if (block is! Map) {
      violations.add('records_missing:$key');
      continue;
    }
    final count = block['count'];
    final first = block['firstIndex'];
    final last = block['lastIndex'];
    if (count is! int || count < 0) {
      violations.add('record_count_invalid:$key');
      continue;
    }
    if (count == 0) {
      if (first != null || last != null) violations.add('empty_range:$key');
      continue;
    }
    if (first is! int || last is! int || first < 0 || last < first) {
      violations.add('record_range_invalid:$key');
    }
    if (last is int && last > 0xffff) {
      violations.add('record_index_out_of_bounds:$key');
    }
  }
  violations.addAll(
    _valueBlockViolations(
      records['rawPayload'],
      'rawPayload',
      cbioRawPayloadMaximum,
    ),
  );
  violations.addAll(
    _valueBlockViolations(
      records['processedGlucose'],
      'processedGlucose',
      cbioRawGlucoseMaximum,
    ),
  );
  final raw = records['raw'];
  final payload = records['rawPayload'];
  if (raw is Map && payload is Map) {
    final rawCount = raw['count'];
    final payloadCount = payload['count'];
    if (rawCount is int && payloadCount is int && rawCount != payloadCount) {
      violations.add('raw_payload_count_disagrees_with_records');
    }
  }
  return violations;
}

/// Validates one `{count, minimum, maximum, nonZero}` value block.
///
/// Every session carries both blocks, including a session that decoded nothing:
/// an absent block cannot be told apart from a field that is genuinely empty,
/// which is the ambiguity that made an all-zero raw reading unreadable.
List<String> _valueBlockViolations(Object? block, String name, int maximum) {
  if (block is! Map) return ['record_values_missing:$name'];
  final violations = <String>[];
  final count = block['count'];
  if (count is! int || count < 0) {
    return ['record_value_count_invalid:$name'];
  }
  for (final key in const ['minimum', 'maximum', 'nonZero']) {
    final value = block[key];
    if (count == 0) {
      if (value != null) violations.add('record_value_not_null:$name:$key');
      continue;
    }
    if (value is! int || value < 0 || value > maximum) {
      violations.add('record_value_outside_envelope:$name:$key');
    }
  }
  final nonZero = block['nonZero'];
  if (nonZero is int && (nonZero < 0 || nonZero > count)) {
    violations.add('record_value_nonzero_out_of_range:$name');
  }
  final minimum = block['minimum'];
  final blockMaximum = block['maximum'];
  if (minimum is int && blockMaximum is int && minimum > blockMaximum) {
    violations.add('record_value_range_inverted:$name');
  }
  return violations;
}

List<String> _timingViolations(Map<String, Object?> decoded) {
  final violations = <String>[];
  final started = DateTime.tryParse(decoded['startedAtUtc'] as String? ?? '');
  final ended = DateTime.tryParse(decoded['endedAtUtc'] as String? ?? '');
  if (started == null || ended == null) {
    violations.add('timing_not_parsable');
    return violations;
  }
  if (ended.isBefore(started)) violations.add('clock_moved_backwards');
  final duration = decoded['durationMilliseconds'];
  if (duration is! int || duration < 0) {
    violations.add('duration_invalid');
  } else if ((ended.difference(started).inMilliseconds - duration).abs() >
      1000) {
    violations.add('duration_disagrees_with_timestamps');
  }
  return violations;
}

/// Evidence for one device-backed GS1 session.
///
/// Every field is either a count, a range, a bounded duration, a closed reason,
/// or fixed identity text. There is deliberately no field that can hold a
/// sensor address or credential material.
final class CbioSessionEvidence {
  const CbioSessionEvidence({
    required this.harness,
    required this.harnessRevision,
    required this.appPackage,
    required this.appRevision,
    required this.platform,
    required this.unitStatus,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.outcome,
    required this.targetAcquired,
    required this.gattReleased,
    required this.notifications,
    required this.writeKinds,
    required this.requiredWrites,
    required this.allowedWrites,
    required this.glucoseIndices,
    required this.rawIndices,
    required this.rawPayloadValues,
    required this.processedGlucoseValues,
    required this.errors,
    this.schema = 'cbio.session-evidence/2',
  });

  /// Artifact schema identifier.
  final String schema;

  /// Repository-relative path of the harness that produced this record.
  final String harness;

  /// Revision the harness was built from, or `unknown`.
  final String harnessRevision;

  /// Android package of the app that hosted the run.
  final String appPackage;

  /// Revision of the app build, or `unknown`.
  final String appRevision;

  /// Device platform string, without any hardware serial or network identity.
  final String platform;

  /// Always `unverified`: the raw scale has no reference measurement.
  final String unitStatus;

  /// Session start, UTC.
  final DateTime startedAtUtc;

  /// Session end, UTC.
  final DateTime endedAtUtc;

  /// Terminal state of the run.
  final CbioSessionOutcome outcome;

  /// Whether an FF30 target was located.
  final bool targetAcquired;

  /// Whether the GATT link was released before the harness returned.
  ///
  /// Only meaningful once [targetAcquired] is true: a run that never found a
  /// sensor has no link to release.
  final bool gattReleased;

  /// Number of FF31 notifications observed.
  final int notifications;

  /// Count of command frames written, per classified kind.
  final Map<CbioWriteKind, int> writeKinds;

  /// Kinds this harness must have written for [outcome] to be `completed`.
  final Set<CbioWriteKind> requiredWrites;

  /// Kinds this harness is allowed to write at all.
  final Set<CbioWriteKind> allowedWrites;

  /// Sensor indices of the glucose records the run decoded.
  final List<int> glucoseIndices;

  /// Sensor indices of the raw history records the run decoded.
  final List<int> rawIndices;

  /// Payload words the run decoded from `08` records, one per raw record.
  ///
  /// This is the field the app's live path renders. It has no verified scale.
  final List<int> rawPayloadValues;

  /// The firmware's processed field, one per `08` record, plus the packed
  /// values of any `0A` batch the run decoded.
  ///
  /// Kept separate from [rawPayloadValues] so an empty processed field can never
  /// be mistaken for a measured zero again.
  final List<int> processedGlucoseValues;

  /// Closed failure reasons observed, per count.
  final Map<String, int> errors;

  /// Session duration.
  Duration get duration => endedAtUtc.difference(startedAtUtc);

  /// Every invariant the record is expected to satisfy.
  ///
  /// Pure and host-testable: the device harnesses assert this is empty, so a
  /// regression in the read path fails the run instead of printing a line that
  /// a human has to re-read.
  List<String> invariantViolations() {
    final violations = <String>[];
    if (targetAcquired && !gattReleased) violations.add('gatt_not_released');
    if (endedAtUtc.isBefore(startedAtUtc)) {
      violations.add('clock_moved_backwards');
    }
    if (unitStatus != 'unverified') violations.add('unit_status_claimed');
    if (schema != 'cbio.session-evidence/2') violations.add('unknown_schema');
    for (final kind in writeKinds.keys) {
      if (!allowedWrites.contains(kind)) {
        violations.add('write_outside_allowed_set:${kind.wire}');
      }
    }
    for (final reason in errors.keys) {
      if (!cbioSessionErrorReasons.contains(reason)) {
        violations.add('unknown_error_reason:$reason');
      }
    }
    if (notifications == 0 &&
        (glucoseIndices.isNotEmpty || rawIndices.isNotEmpty)) {
      violations.add('records_without_notifications');
    }
    if (!_isOrderedAndUnique(glucoseIndices)) {
      violations.add('glucose_indices_not_ordered_or_unique');
    }
    if (!_isOrderedAndUnique(rawIndices)) {
      violations.add('raw_indices_not_ordered_or_unique');
    }
    for (final value in rawPayloadValues) {
      if (value < 0 || value > cbioRawPayloadMaximum) {
        violations.add('raw_payload_outside_envelope');
        break;
      }
    }
    for (final value in processedGlucoseValues) {
      if (value < 0 || value > cbioRawGlucoseMaximum) {
        violations.add('processed_glucose_outside_envelope');
        break;
      }
    }
    if (rawIndices.isNotEmpty && rawPayloadValues.length != rawIndices.length) {
      violations.add('raw_payload_count_disagrees_with_records');
    }
    if (outcome == CbioSessionOutcome.completed) {
      if (!targetAcquired) violations.add('completed_without_target');
      if (notifications == 0) {
        violations.add('completed_without_notifications');
      }
      for (final kind in requiredWrites) {
        if ((writeKinds[kind] ?? 0) < 1) {
          violations.add('completed_without_required_write:${kind.wire}');
        }
      }
    }
    return violations;
  }

  /// The redacted, schema'd artifact.
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schema,
    'identity': <String, Object?>{
      'harness': harness,
      'harnessRevision': harnessRevision,
      'appPackage': appPackage,
      'appRevision': appRevision,
      'platform': platform,
    },
    'outcome': outcome.wire,
    'targetAcquired': targetAcquired,
    'gattReleased': gattReleased,
    'unitStatus': unitStatus,
    'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
    'endedAtUtc': endedAtUtc.toUtc().toIso8601String(),
    'durationMilliseconds': duration.inMilliseconds,
    'notifications': notifications,
    'writes': <String, int>{
      for (final entry in writeKinds.entries) entry.key.wire: entry.value,
    },
    'records': <String, Object?>{
      'glucose': _describe(glucoseIndices),
      'raw': _describe(rawIndices),
      'rawPayload': _describeValues(rawPayloadValues),
      'processedGlucose': _describeValues(processedGlucoseValues),
    },
    'errors': Map<String, int>.of(errors),
  };

  static Map<String, Object?> _describe(List<int> indices) => <String, Object?>{
    'count': indices.length,
    'firstIndex': indices.isEmpty ? null : indices.first,
    'lastIndex': indices.isEmpty ? null : indices.last,
  };

  /// Describes one decoded value series without implying a unit.
  ///
  /// `nonZero` is what separates "this field is empty" from "this field is
  /// zero": a decoder that reads the wrong field reports a full count and no
  /// non-zero sample.
  static Map<String, Object?> _describeValues(
    List<int> values,
  ) => <String, Object?>{
    'count': values.length,
    'minimum': values.isEmpty ? null : values.reduce((a, b) => a < b ? a : b),
    'maximum': values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b),
    'nonZero': values.where((value) => value != 0).length,
  };

  /// Gaps are expected: a bounded window can skip stored indices. Duplicates
  /// and out-of-order indices are not, because they mean the harness merged
  /// overlapping replies without deduplicating them.
  static bool _isOrderedAndUnique(List<int> values) {
    for (var i = 1; i < values.length; i += 1) {
      if (values[i] <= values[i - 1]) return false;
    }
    return true;
  }
}
