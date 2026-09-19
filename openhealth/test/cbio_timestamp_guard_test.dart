// No counter-derived timestamps can cross the shared presentation boundary.
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/live_activity_payload.dart';
import 'package:openglucose/src/session_presentation.dart';

import 'support/cbio_snapshot_fixture.dart';

void main() {
  final now = DateTime.utc(2026, 9, 19, 12);
  for (final index in [10067, 10515]) {
    test('raw index $index never becomes a glucose value or sensor clock', () {
      final raw = CgmReading(
        valueMgdl: 5.9,
        rawValue: 59,
        sensorMinute: index,
        source: CgmRecordSource.raw,
      );
      final snapshot = syntheticSurfaceSnapshot(
        readings: [raw],
        historySync: CgmHistorySyncState(storedCount: 1, lastSyncAt: now),
      );
      expect(readingTimeText(raw, now: now), '--');
      expect(currentReadingForSnapshot(snapshot, raw), isNull);
      final payload = buildLiveActivityPayload(
        snapshot: snapshot,
        latestReading: raw,
        preferences: const DisplayPreferences(),
        now: now,
      );
      expect(payload.valueText, '--');
      expect(payload.recordedAtIso8601, isNull);
      expect(payload.lastReadingText, '--');
      expect(payload.isStale, isTrue);
      expect(
        shouldPublishLiveActivity(
          snapshot: snapshot,
          latestReading: raw,
          now: now,
        ),
        isFalse,
      );
    });
  }

  test('unknown normalized sample time stays unknown despite receipt time', () {
    const reading = CgmReading(
      valueMgdl: 108,
      source: CgmRecordSource.standard,
      sensorMinute: 10067,
    );
    final snapshot = syntheticSurfaceSnapshot(
      readings: [reading],
      historySync: CgmHistorySyncState(lastSyncAt: now),
    );
    expect(
      liveSurfaceFreshnessAt(snapshot: snapshot, reading: reading, now: now),
      isNull,
    );
    expect(readingTimeText(reading, now: now), '--');
    expect(
      shouldPublishLiveActivity(
        snapshot: snapshot,
        latestReading: reading,
        now: now,
      ),
      isFalse,
    );
  });
}
