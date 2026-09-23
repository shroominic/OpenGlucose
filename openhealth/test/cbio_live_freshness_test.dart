import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/live_activity_payload.dart';

/// Explicit legacy raw fixtures test generic quality exclusion. Protocol raw
/// records are now private, and their receipt times cannot make a normalized
/// glucose surface fresh or supply a sensor timestamp.
void main() {
  const sensor = DiscoveredSensor(
    driverId: 'cbio',
    deviceId: 'AA:BB:CC:DD:EE:FF',
    displayName: 'GS1 sensor',
    storageKey: 'cbio:synthetic',
    rssi: -55,
    capabilities: CgmCapabilities(
      supportsDirectBle: true,
      supportsHistory: true,
      supportsRawHistory: true,
      supportsDiagnostics: true,
    ),
  );
  const reading = CgmReading(
    valueMgdl: 111,
    source: CgmRecordSource.raw,
    sensorMinute: 42,
    rawValue: 1110,
    isDisplayProvisional: true,
  );

  CgmSessionSnapshot snapshotReceivedAt(DateTime? receivedAt) {
    return CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Live',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: reading,
      history: const <CgmReading>[reading],
      historySync: CgmHistorySyncState(
        storedCount: 1,
        lastSyncAt: receivedAt,
      ),
    );
  }

  LiveActivityPayload payloadFor(DateTime? receivedAt, DateTime now) {
    return buildLiveActivityPayload(
      snapshot: snapshotReceivedAt(receivedAt),
      latestReading: reading,
      preferences: const DisplayPreferences(),
      now: now,
    );
  }

  test('raw receipt freshness never stands in for normalized glucose time', () {
    final now = DateTime.utc(2026, 9, 18, 9);
    expect(reading.recordedAt, isNull);

    expect(
      payloadFor(now.subtract(const Duration(seconds: 30)), now).isStale,
      isTrue,
      reason: 'a recent raw batch is not a fresh glucose reading',
    );
    expect(
      payloadFor(now.subtract(const Duration(minutes: 9)), now).isStale,
      isTrue,
    );
    expect(
      payloadFor(now.subtract(const Duration(minutes: 25)), now).isStale,
      isTrue,
      reason: 'an idle link must go stale',
    );
  });

  test('a cbio session that never ingested anything is stale', () {
    final now = DateTime.utc(2026, 9, 18, 9);
    expect(payloadFor(null, now).isStale, isTrue);
  });

  test('receipt freshness never becomes a published sensor timestamp', () {
    final now = DateTime.utc(2026, 9, 18, 9);
    final payload = payloadFor(now.subtract(const Duration(seconds: 30)), now);
    expect(payload.recordedAtIso8601, isNull);
    expect(payload.lastReadingText, '--');
    expect(payload.valueText, '--');
  });

  test('a timestamped driver still judges freshness from its own reading', () {
    final now = DateTime.utc(2026, 9, 18, 9);
    const timestamped = DiscoveredSensor(
      driverId: 'synthetic-timestamped',
      deviceId: 'synthetic-timestamped',
      displayName: 'Timestamped sensor',
      storageKey: 'synthetic-timestamped',
      rssi: -50,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final readingWithClock = CgmReading(
      valueMgdl: 120,
      source: CgmRecordSource.broadcast,
      sensorMinute: 42,
      recordedAt: now.subtract(const Duration(minutes: 2)),
    );
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Connected',
      sensor: timestamped,
      capabilities: timestamped.capabilities,
      latestReading: readingWithClock,
      history: <CgmReading>[readingWithClock],
      // A stale receipt time must not override a fresh sensor reading.
      historySync: CgmHistorySyncState(
        storedCount: 1,
        lastSyncAt: now.subtract(const Duration(minutes: 40)),
      ),
    );
    final payload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: readingWithClock,
      preferences: const DisplayPreferences(),
      now: now,
    );
    expect(payload.isStale, isFalse);
    expect(payload.recordedAtIso8601, isNotNull);
  });
}
