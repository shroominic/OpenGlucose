// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

CbioSessionEvidence evidence({
  CbioSessionOutcome outcome = CbioSessionOutcome.completed,
  bool targetAcquired = true,
  bool gattReleased = true,
  int notifications = 4,
  Map<CbioWriteKind, int>? writes,
  List<int> glucoseIndices = const [10, 11],
  List<int> rawIndices = const [1, 2],
  List<int> rawGlucoseValues = const [400, 503],
  Map<String, int> errors = const {},
  String unitStatus = 'unverified',
}) => CbioSessionEvidence(
  harness: 'openhealth/integration_test/cbio_glucose_query_test.dart',
  harnessRevision: 'test',
  appPackage: 'com.openglucose.app.debug',
  appRevision: 'test',
  platform: 'android',
  unitStatus: unitStatus,
  startedAtUtc: DateTime.utc(2026, 1, 1),
  endedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 42),
  outcome: outcome,
  targetAcquired: targetAcquired,
  gattReleased: gattReleased,
  notifications: notifications,
  writeKinds:
      writes ??
      const {
        CbioWriteKind.deviceInformationRead: 1,
        CbioWriteKind.glucoseRead: 2,
      },
  requiredWrites: const {
    CbioWriteKind.deviceInformationRead,
    CbioWriteKind.glucoseRead,
  },
  allowedWrites: const {
    CbioWriteKind.deviceInformationRead,
    CbioWriteKind.glucoseRead,
  },
  glucoseIndices: glucoseIndices,
  rawIndices: rawIndices,
  rawGlucoseValues: rawGlucoseValues,
  errors: errors,
);

void main() {
  test('a completed session satisfies every invariant', () {
    final record = evidence();
    expect(record.invariantViolations(), isEmpty);
    expect(record.duration, const Duration(seconds: 42));
  });

  test('invariants fail closed on the ways a session can go wrong', () {
    expect(
      evidence(
        writes: const {CbioWriteKind.unclassified: 1},
      ).invariantViolations(),
      contains('write_outside_allowed_set:unclassified'),
    );
    expect(
      evidence(
        writes: const {CbioWriteKind.deviceInformationRead: 1},
      ).invariantViolations(),
      contains('completed_without_required_write:glucose_read'),
    );
    expect(
      evidence(errors: const {'weird_reason': 1}).invariantViolations(),
      contains('unknown_error_reason:weird_reason'),
    );
    // A recorded reason is reported in the artifact but does not by itself
    // invalidate a run: a bounded window that answers late is still a verdict.
    expect(
      evidence(errors: const {'write_failed': 1}).invariantViolations(),
      isEmpty,
    );
    expect(
      evidence(gattReleased: false).invariantViolations(),
      contains('gatt_not_released'),
    );
    // A run that never acquired a target has no link to release.
    expect(
      evidence(
        gattReleased: false,
        targetAcquired: false,
        outcome: CbioSessionOutcome.abortedNoTarget,
        notifications: 0,
        writes: const {},
        glucoseIndices: const [],
        rawIndices: const [],
        rawGlucoseValues: const [],
        errors: const {'target_missing': 1},
      ).invariantViolations(),
      isEmpty,
    );
    expect(
      evidence(targetAcquired: false).invariantViolations(),
      contains('completed_without_target'),
    );
    expect(
      evidence(
        notifications: 0,
        glucoseIndices: const [],
        rawIndices: const [],
      ).invariantViolations(),
      contains('completed_without_notifications'),
    );
    expect(
      evidence(unitStatus: 'mg/dL').invariantViolations(),
      contains('unit_status_claimed'),
    );
  });

  test('indices must be ordered and deduplicated but may have gaps', () {
    expect(
      evidence(glucoseIndices: const [10, 11, 30]).invariantViolations(),
      isEmpty,
    );
    expect(
      evidence(glucoseIndices: const [11, 10]).invariantViolations(),
      contains('glucose_indices_not_ordered_or_unique'),
    );
    expect(
      evidence(glucoseIndices: const [10, 10]).invariantViolations(),
      contains('glucose_indices_not_ordered_or_unique'),
    );
  });

  test('raw values must stay inside the 10-bit envelope', () {
    expect(
      evidence(rawGlucoseValues: [0, 1023]).invariantViolations(),
      isEmpty,
    );
    expect(
      evidence(rawGlucoseValues: const [1024]).invariantViolations(),
      contains('raw_glucose_outside_envelope'),
    );
  });

  test('walked writes classify against the safety envelope', () {
    expect(
      CbioWriteKind.classify([0x03, 0xf0, 0x04, 0x09]),
      CbioWriteKind.deviceInformationRead,
    );
    expect(
      CbioWriteKind.classify([0x06, 0x0a, 0x00, 0x00, 0x00, 0x00, 0xf0]),
      CbioWriteKind.glucoseRead,
    );
    expect(
      CbioWriteKind.classify([0x06, 0x08, 0x00, 0x00, 0x00, 0x00, 0xf2]),
      CbioWriteKind.rawHistoryRead,
    );
    expect(
      CbioWriteKind.classify([0x06, 0x03, 1, 2, 3, 4, 0xed]),
      CbioWriteKind.clockSet,
    );
    expect(
      CbioWriteKind.classify([0x19, 0x01, 0x00, 0, 0, 0, 0, 0, 0x00]),
      CbioWriteKind.authentication,
    );
    for (final forbidden in [
      <int>[0x07, 0x01],
      <int>[0x05, 0x03],
      <int>[0x06, 0x01, 0x00],
      <int>[],
    ]) {
      expect(CbioWriteKind.classify(forbidden), CbioWriteKind.unclassified);
    }
  });

  test('the artifact is schema-shaped and carries no identity leaks', () {
    final json =
        jsonDecode(jsonEncode(evidence().toJson())) as Map<String, Object?>;
    expect(json['schema'], 'cbio.session-evidence/1');
    expect(json['outcome'], 'completed');
    expect(json['unitStatus'], 'unverified');
    expect(
      (json['identity'] as Map)['appPackage'],
      'com.openglucose.app.debug',
    );
    expect(json['records'], {
      'glucose': {'count': 2, 'firstIndex': 10, 'lastIndex': 11},
      'raw': {'count': 2, 'firstIndex': 1, 'lastIndex': 2},
      'rawGlucoseMinimum': 400,
      'rawGlucoseMaximum': 503,
    });
    expect(json['writes'], {'device_information_read': 1, 'glucose_read': 2});
    final encoded = jsonEncode(json);
    expect(
      RegExp(r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}').hasMatch(encoded),
      isFalse,
    );
    expect(RegExp(r'[0-9a-f]{32,}').hasMatch(encoded), isFalse);
  });

  test('a recorded artifact validates and leak paths are caught', () {
    final artifact =
        jsonDecode(jsonEncode(evidence().toJson())) as Map<String, Object?>;
    expect(cbioSessionEvidenceArtifactViolations(artifact), isEmpty);

    Map<String, Object?> mutated(void Function(Map<String, Object?>) change) {
      final copy =
          jsonDecode(jsonEncode(evidence().toJson())) as Map<String, Object?>;
      change(copy);
      return copy;
    }

    expect(
      cbioSessionEvidenceArtifactViolations(artifact['outcome']),
      contains('artifact_not_an_object'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          copy['schema'] = 'cbio.session-evidence/2';
        }),
      ),
      contains('unknown_schema'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          copy['unitStatus'] = 'mg/dL';
        }),
      ),
      contains('unit_status_claimed'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          (copy['errors']! as Map<String, Object?>)['made_up'] = 1;
        }),
      ),
      contains('error_reason_unknown:made_up'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          (copy['writes']! as Map<String, Object?>)['activation'] = 1;
        }),
      ),
      contains('write_kind_unknown:activation'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          final records = copy['records']! as Map<String, Object?>;
          records['rawGlucoseMaximum'] = cbioRawGlucoseMaximum + 1;
        }),
      ),
      contains('raw_glucose_outside_envelope:rawGlucoseMaximum'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          copy['endedAtUtc'] = '2025-01-01T00:00:00.000Z';
        }),
      ),
      contains('clock_moved_backwards'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
          (copy['identity']! as Map<String, Object?>)['platform'] =
              'android AA:BB:CC:DD:EE:FF';
        }),
      ),
      contains('identity_leak'),
    );
    expect(
      cbioSessionEvidenceArtifactViolations(
        mutated((copy) {
        (copy['identity']! as Map<String, Object?>)['platform'] = 'a' * 40;
        }),
      ),
      contains('identity_leak'),
    );
  });
}
