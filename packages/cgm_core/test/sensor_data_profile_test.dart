import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  test('legacy profile preserves existing interpretation defaults', () {
    const profile = CgmSensorDataProfile.legacy;
    expect(profile.warmupMinutes, 60);
    expect(profile.expectedLifetimeMinutes, 21600);
    expect(profile.timestampBasis, CgmReadingTimestampBasis.sessionRelative);
    expect(profile.duplicatePolicy, CgmHistoryDuplicatePolicy.replaceExisting);
    expect(
      profile.currentReadingPolicy,
      CgmCurrentReadingPolicy.latestOrHistory,
    );
    expect(
      profile.retainedLifecyclePolicy,
      CgmRetainedLifecyclePolicy.inferFromReadings,
    );
    expect(profile.canInferRetainedLifecycle, isTrue);
  });

  test('receipt timestamps never permit retained lifecycle inference', () {
    const profile = CgmSensorDataProfile(
      timestampBasis: CgmReadingTimestampBasis.receivedAt,
      duplicatePolicy: CgmHistoryDuplicatePolicy.keepFirst,
      currentReadingPolicy: CgmCurrentReadingPolicy.liveOnly,
    );
    expect(profile.canInferRetainedLifecycle, isFalse);
    expect(profile.duplicatePolicy, CgmHistoryDuplicatePolicy.keepFirst);
    expect(profile.currentReadingPolicy, CgmCurrentReadingPolicy.liveOnly);
  });

  test('session-relative history does not itself prove activation timing', () {
    const profile = CgmSensorDataProfile(
      warmupMinutes: 45,
      expectedLifetimeMinutes: 23085,
      retainedLifecyclePolicy: CgmRetainedLifecyclePolicy.reportedOnly,
    );
    expect(profile.timestampBasis, CgmReadingTimestampBasis.sessionRelative);
    expect(profile.canInferRetainedLifecycle, isFalse);
    expect(profile.warmupMinutes, 45);
    expect(profile.expectedLifetimeMinutes, 23085);
  });

  test('acquisition-relative timestamps cannot infer lifecycle', () {
    for (final policy in CgmRetainedLifecyclePolicy.values) {
      final profile = CgmSensorDataProfile(
        timestampBasis: CgmReadingTimestampBasis.acquisitionRelative,
        retainedLifecyclePolicy: policy,
      );
      expect(profile.canInferRetainedLifecycle, isFalse);
    }
  });

  test('profile adoption is optional for an existing driver', () {
    final CgmDriver driver = _LegacyDriver();
    expect(driver, isNot(isA<CgmSensorDataProfileProvider>()));
    expect(
      _ProfiledDriver().sensorDataProfile,
      same(CgmSensorDataProfile.legacy),
    );
  });

  test('profile does not add fields to serialized readings', () {
    const reading = CgmReading(
      valueMgdl: 100,
      source: CgmRecordSource.vendor,
      sensorMinute: 100,
      isDisplayProvisional: true,
    );
    expect(
      reading.toJson().keys,
      unorderedEquals([
        'valueMgdl',
        'source',
        'sensorMinute',
        'recordedAt',
        'rawValue',
        'qualifier',
        'isDisplayProvisional',
      ]),
    );
  });

  test('debug validation rejects impossible declared timing', () {
    expect(
      () => CgmSensorDataProfile(warmupMinutes: -1),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => CgmSensorDataProfile(expectedLifetimeMinutes: 0),
      throwsA(isA<AssertionError>()),
    );
    expect(const CgmSensorDataProfile(warmupMinutes: 0).warmupMinutes, 0);
  });
}

class _LegacyDriver implements CgmDriver {
  @override
  String get driverId => 'synthetic-legacy';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream.empty();

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) =>
      throw UnsupportedError('No hardware in this contract test.');
}

final class _ProfiledDriver extends _LegacyDriver
    implements CgmSensorDataProfileProvider {
  @override
  CgmSensorDataProfile get sensorDataProfile => CgmSensorDataProfile.legacy;
}
