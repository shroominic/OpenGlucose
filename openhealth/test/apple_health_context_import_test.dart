import 'dart:collection';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/apple_health_context_import.dart';
import 'package:openglucose/src/apple_health_context_import_state.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/integrations_settings_pane.dart';
import 'package:openglucose/src/persistence/health_repository_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabledKey = 'openHealth.appleHealthContextImport.enabled';

class _MemoryAppleHealthContextImportStateStore
    implements AppleHealthContextImportStateStore {
  _MemoryAppleHealthContextImportStateStore({
    Map<String, String> anchors = const <String, String>{},
    DateTime? lastSyncedAt,
  }) : _state = AppleHealthContextImportState(
         anchors: anchors,
         lastSyncedAt: lastSyncedAt,
       );

  AppleHealthContextImportState _state;
  bool _initialized = false;

  Map<String, String> get anchors => _state.anchors;
  DateTime? get lastSyncedAt => _state.lastSyncedAt;

  @override
  AppleHealthContextImportState get state {
    if (!_initialized) {
      throw StateError('State store is not initialized.');
    }
    return _state;
  }

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<void> save(AppleHealthContextImportState state) async {
    _state = AppleHealthContextImportState(
      anchors: state.anchors,
      lastSyncedAt: state.lastSyncedAt,
    );
  }
}

class _FakeContextService implements AppleHealthContextImportService {
  bool supported = true;
  AppleHealthContextAvailability availability =
      AppleHealthContextAvailability.available;
  AppleHealthContextAuthorizationStatus authorizationStatus =
      AppleHealthContextAuthorizationStatus.requested;
  int availabilityCalls = 0;
  int authorizationCalls = 0;
  int importCalls = 0;
  final List<Set<AppleHealthContextDataType>> authorizationTypes =
      <Set<AppleHealthContextDataType>>[];
  final List<AppleHealthContextImportWindow> windows =
      <AppleHealthContextImportWindow>[];
  final List<Map<AppleHealthContextDataType, String>> anchors =
      <Map<AppleHealthContextDataType, String>>[];
  final Queue<AppleHealthContextImportResult> results =
      Queue<AppleHealthContextImportResult>();

  @override
  bool get isSupported => supported;

  @override
  Future<AppleHealthContextAvailability> checkAvailability() async {
    availabilityCalls += 1;
    return availability;
  }

  @override
  Future<AppleHealthContextImportResult> importContext({
    required AppleHealthContextImportWindow window,
    required Map<AppleHealthContextDataType, String> anchors,
  }) async {
    importCalls += 1;
    windows.add(window);
    this.anchors.add(Map<AppleHealthContextDataType, String>.of(anchors));
    return results.removeFirst();
  }

  @override
  Future<AppleHealthContextAuthorizationResult> requestAuthorization(
    Set<AppleHealthContextDataType> types,
  ) async {
    authorizationCalls += 1;
    authorizationTypes.add(Set<AppleHealthContextDataType>.of(types));
    return AppleHealthContextAuthorizationResult(authorizationStatus);
  }
}

class _FailingSleepRepository extends InMemoryHealthRepository {
  @override
  Future<void> upsertSleepSamples(Iterable<SleepSample> samples) async {
    throw StateError('synthetic repository failure');
  }
}

class _FailingExpiryRepository extends InMemoryHealthRepository {
  @override
  Future<int> purgeImportedSamplesBefore({
    required HealthSampleKind kind,
    required HealthSourcePlatform platform,
    required DateTime cutoff,
  }) {
    if (kind == HealthSampleKind.heartRate) {
      throw StateError('synthetic expiry failure');
    }
    return super.purgeImportedSamplesBefore(
      kind: kind,
      platform: platform,
      cutoff: cutoff,
    );
  }
}

HealthSampleProvenance _provenance(String externalId) => HealthSampleProvenance(
  identity: HealthImportIdentity(
    platform: HealthSourcePlatform.appleHealth,
    externalId: externalId,
  ),
  sourceApplicationId: 'example.synthetic.source',
  sourceName: 'Synthetic source',
  sourceDevice: 'Synthetic device',
  sourceDeviceModel: 'Synthetic model',
  recordingMethod: HealthRecordingMethod.automatic,
  sourceRevision: 'synthetic-revision',
);

AppleHealthContextTypeBatch _sleepBatch({
  AppleHealthContextImportStatus status = AppleHealthContextImportStatus.ok,
  List<SleepSample> samples = const <SleepSample>[],
  List<HealthImportTombstone> tombstones = const <HealthImportTombstone>[],
  String anchor = 'anchor-sleep-1',
}) => AppleHealthContextTypeBatch(
  type: AppleHealthContextDataType.sleep,
  status: status,
  sleepSamples: samples,
  tombstones: tombstones,
  nextAnchor: anchor,
);

AppleHealthContextTypeBatch _workoutBatch({
  AppleHealthContextImportStatus status = AppleHealthContextImportStatus.ok,
  List<ActivitySample> samples = const <ActivitySample>[],
  String anchor = 'anchor-workout-1',
}) => AppleHealthContextTypeBatch(
  type: AppleHealthContextDataType.workout,
  status: status,
  workoutSamples: samples,
  nextAnchor: anchor,
);

AppleHealthContextTypeBatch _heartRateBatch({
  AppleHealthContextImportStatus status = AppleHealthContextImportStatus.ok,
  List<HeartRateSample> samples = const <HeartRateSample>[],
  List<HealthImportTombstone> tombstones = const <HealthImportTombstone>[],
  String anchor = 'anchor-heart-rate-1',
}) => AppleHealthContextTypeBatch(
  type: AppleHealthContextDataType.heartRate,
  status: status,
  heartRateSamples: samples,
  tombstones: tombstones,
  nextAnchor: anchor,
);

AppleHealthContextImportResult _noAccessibleDataResult() =>
    AppleHealthContextImportResult(
      status: AppleHealthContextImportStatus.noAccessibleData,
      batches: <AppleHealthContextTypeBatch>[
        _sleepBatch(status: AppleHealthContextImportStatus.noAccessibleData),
        _workoutBatch(status: AppleHealthContextImportStatus.noAccessibleData),
        _heartRateBatch(
          status: AppleHealthContextImportStatus.noAccessibleData,
        ),
      ],
    );

void main() {
  final now = DateTime.utc(2026, 8, 24, 12);

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<SharedPreferences> loadPreferences() =>
      SharedPreferences.getInstance();

  AppleHealthContextImportController controller({
    required SharedPreferences preferences,
    required AppleHealthContextImportStateStore stateStore,
    required HealthRepository repository,
    required _FakeContextService service,
    AppleHealthContextClock? clock,
    bool readsAllowed = true,
  }) => AppleHealthContextImportController(
    preferences: preferences,
    importStateStore: stateStore,
    repositoryLifecycle: AppHealthRepositoryLifecycle(() async => repository),
    service: service,
    clock: clock ?? () => now,
    readsAllowed: readsAllowed,
  );

  test('requires opt-in before it reads Apple Health context', () async {
    final preferences = await loadPreferences();
    final service = _FakeContextService();
    final context = controller(
      preferences: preferences,
      stateStore: _MemoryAppleHealthContextImportStateStore(),
      repository: InMemoryHealthRepository(),
      service: service,
    );
    await context.initialize();

    final result = await context.syncNow();

    expect(result.status, AppleHealthContextImportStatus.notEnabled);
    expect(service.authorizationCalls, 0);
    expect(service.importCalls, 0);
    expect(context.accessState, AppleHealthContextAccessState.off);
  });

  test('requests exactly the three approved context types on opt-in', () async {
    final preferences = await loadPreferences();
    final service = _FakeContextService();
    final context = controller(
      preferences: preferences,
      stateStore: _MemoryAppleHealthContextImportStateStore(),
      repository: InMemoryHealthRepository(),
      service: service,
    );
    await context.initialize();

    await context.setEnabled(enabled: true);

    expect(context.enabled, isTrue);
    expect(
      context.accessState,
      AppleHealthContextAccessState.authorizationRequested,
    );
    expect(service.authorizationCalls, 1);
    expect(
      service.authorizationTypes.single,
      AppleHealthContextDataType.values.toSet(),
    );
    expect(preferences.getBool(_enabledKey), isTrue);
  });

  test(
    'imports source-aware context in a bounded window and persists anchors',
    () async {
      final preferences = await loadPreferences();
      final stateStore = _MemoryAppleHealthContextImportStateStore();
      final repository = InMemoryHealthRepository();
      final service = _FakeContextService();
      final sleepAt = now.subtract(const Duration(hours: 8));
      final workoutAt = now.subtract(const Duration(hours: 4));
      final heartRateAt = now.subtract(const Duration(hours: 1));
      service.results.add(
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(
              samples: <SleepSample>[
                SleepSample(
                  start: sleepAt,
                  end: sleepAt.add(const Duration(hours: 7)),
                  stage: SleepStage.asleep,
                  source: DataSource.appleHealth,
                  provenance: _provenance('synthetic-sleep'),
                ),
              ],
            ),
            _workoutBatch(
              samples: <ActivitySample>[
                ActivitySample(
                  start: workoutAt,
                  end: workoutAt.add(const Duration(minutes: 45)),
                  type: ActivityType.workout,
                  source: DataSource.appleHealth,
                  workoutLabel: 'workout',
                  provenance: _provenance('synthetic-workout'),
                ),
              ],
            ),
            _heartRateBatch(
              samples: <HeartRateSample>[
                HeartRateSample(
                  timestamp: heartRateAt,
                  bpm: 72,
                  source: DataSource.appleHealth,
                  provenance: _provenance('synthetic-heart-rate'),
                ),
              ],
            ),
          ],
        ),
      );
      final context = controller(
        preferences: preferences,
        stateStore: stateStore,
        repository: repository,
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.ok);
      expect(
        service.windows.single.start,
        now.subtract(kAppleHealthContextImportRange),
      );
      expect(service.windows.single.end, now);
      expect(
        service.windows.single.end.difference(service.windows.single.start),
        lessThanOrEqualTo(kAppleHealthContextImportMaximumRange),
      );
      expect(
        (await repository.querySleepSamples())
            .single
            .provenance!
            .identity
            .platform,
        HealthSourcePlatform.appleHealth,
      );
      expect(
        (await repository.queryActivitySamples())
            .single
            .provenance!
            .identity
            .platform,
        HealthSourcePlatform.appleHealth,
      );
      expect(
        (await repository.queryHeartRateSamples())
            .single
            .provenance!
            .identity
            .platform,
        HealthSourcePlatform.appleHealth,
      );
      expect(stateStore.anchors['sleep'], 'anchor-sleep-1');
      expect(stateStore.anchors['workout'], 'anchor-workout-1');
      expect(
        stateStore.anchors['heartRate'],
        'anchor-heart-rate-1',
      );
      expect(stateStore.lastSyncedAt, now);
    },
  );

  test('uses stored anchors and replaces repeated source identities', () async {
    final preferences = await loadPreferences();
    final stateStore = _MemoryAppleHealthContextImportStateStore();
    final repository = InMemoryHealthRepository();
    final firstService = _FakeContextService()
      ..results.add(
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(
              samples: <SleepSample>[
                SleepSample(
                  start: now.subtract(const Duration(hours: 8)),
                  end: now.subtract(const Duration(hours: 1)),
                  stage: SleepStage.asleep,
                  source: DataSource.appleHealth,
                  provenance: _provenance('same-source-record'),
                ),
              ],
            ),
            _workoutBatch(),
            _heartRateBatch(),
          ],
        ),
      );
    final first = controller(
      preferences: preferences,
      stateStore: stateStore,
      repository: repository,
      service: firstService,
    );
    await first.initialize();
    await first.setEnabled(enabled: true);
    await first.syncNow();

    final secondService = _FakeContextService()
      ..results.add(
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(
              anchor: 'anchor-sleep-2',
              samples: <SleepSample>[
                SleepSample(
                  start: now.subtract(const Duration(hours: 8)),
                  end: now.subtract(const Duration(hours: 1)),
                  stage: SleepStage.deep,
                  source: DataSource.appleHealth,
                  provenance: _provenance('same-source-record'),
                ),
              ],
            ),
            _workoutBatch(anchor: 'anchor-workout-2'),
            _heartRateBatch(anchor: 'anchor-heart-rate-2'),
          ],
        ),
      );
    final restored = controller(
      preferences: preferences,
      stateStore: stateStore,
      repository: repository,
      service: secondService,
    );
    await restored.initialize();

    await restored.syncNow();

    expect(
      secondService.anchors.single[AppleHealthContextDataType.sleep],
      'anchor-sleep-1',
    );
    final samples = await repository.querySleepSamples();
    expect(samples, hasLength(1));
    expect(samples.single.stage, SleepStage.deep);
    expect(stateStore.anchors['sleep'], 'anchor-sleep-2');
  });

  test('applies a returned deletion as an Apple Health tombstone', () async {
    final preferences = await loadPreferences();
    final stateStore = _MemoryAppleHealthContextImportStateStore();
    final repository = InMemoryHealthRepository();
    final service = _FakeContextService()
      ..results.addAll(<AppleHealthContextImportResult>[
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(),
            _workoutBatch(),
            _heartRateBatch(
              samples: <HeartRateSample>[
                HeartRateSample(
                  timestamp: now.subtract(const Duration(minutes: 30)),
                  bpm: 70,
                  source: DataSource.appleHealth,
                  provenance: _provenance('deleted-source-record'),
                ),
              ],
            ),
          ],
        ),
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(anchor: 'anchor-sleep-2'),
            _workoutBatch(anchor: 'anchor-workout-2'),
            _heartRateBatch(
              anchor: 'anchor-heart-rate-2',
              tombstones: <HealthImportTombstone>[
                HealthImportTombstone(
                  kind: HealthSampleKind.heartRate,
                  provenance: HealthSampleProvenance(
                    identity: HealthImportIdentity(
                      platform: HealthSourcePlatform.appleHealth,
                      externalId: 'deleted-source-record',
                    ),
                    isDeleted: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ]);
    final context = controller(
      preferences: preferences,
      stateStore: stateStore,
      repository: repository,
      service: service,
    );
    await context.initialize();
    await context.setEnabled(enabled: true);
    await context.syncNow();
    await context.syncNow();

    expect(await repository.queryHeartRateSamples(), isEmpty);
    final tombstones = await repository.queryImportTombstones(
      kind: HealthSampleKind.heartRate,
      platform: HealthSourcePlatform.appleHealth,
    );
    expect(tombstones, hasLength(1));
    expect(tombstones.single.provenance.isDeleted, isTrue);
  });

  test(
    'purges aged Apple Health records before a rolling-window anchor advances',
    () async {
      final preferences = await loadPreferences();
      final stateStore = _MemoryAppleHealthContextImportStateStore();
      final repository = InMemoryHealthRepository();
      final service = _FakeContextService();
      var currentTime = now;
      final agedTimestamp = now.subtract(const Duration(days: 29));
      service.results.addAll(<AppleHealthContextImportResult>[
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(),
            _workoutBatch(),
            _heartRateBatch(
              samples: <HeartRateSample>[
                HeartRateSample(
                  timestamp: agedTimestamp,
                  bpm: 70,
                  source: DataSource.appleHealth,
                  provenance: _provenance('aged-heart-rate'),
                ),
              ],
            ),
          ],
        ),
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.noAccessibleData,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(
              status: AppleHealthContextImportStatus.noAccessibleData,
              anchor: 'anchor-sleep-2',
            ),
            _workoutBatch(
              status: AppleHealthContextImportStatus.noAccessibleData,
              anchor: 'anchor-workout-2',
            ),
            _heartRateBatch(
              status: AppleHealthContextImportStatus.noAccessibleData,
              anchor: 'anchor-heart-rate-2',
            ),
          ],
        ),
      ]);
      final context = controller(
        preferences: preferences,
        stateStore: stateStore,
        repository: repository,
        service: service,
        clock: () => currentTime,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);
      await context.syncNow();

      expect(await repository.queryHeartRateSamples(), hasLength(1));
      currentTime = now.add(const Duration(days: 2));
      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.noAccessibleData);
      expect(await repository.queryHeartRateSamples(), isEmpty);
      expect(
        stateStore.anchors['heartRate'],
        'anchor-heart-rate-2',
      );
      expect(
        service.anchors.last[AppleHealthContextDataType.heartRate],
        'anchor-heart-rate-1',
      );
    },
  );

  test('does not advance an anchor when rolling-window expiry fails', () async {
    final preferences = await loadPreferences();
    final stateStore = _MemoryAppleHealthContextImportStateStore();
    final service = _FakeContextService()
      ..results.add(
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(),
            _workoutBatch(),
            _heartRateBatch(),
          ],
        ),
      );
    final context = controller(
      preferences: preferences,
      stateStore: stateStore,
      repository: _FailingExpiryRepository(),
      service: service,
    );
    await context.initialize();
    await context.setEnabled(enabled: true);

    final result = await context.syncNow();

    expect(result.status, AppleHealthContextImportStatus.partial);
    expect(stateStore.anchors['sleep'], 'anchor-sleep-1');
    expect(stateStore.anchors['workout'], 'anchor-workout-1');
    expect(stateStore.anchors.containsKey('heartRate'), isFalse);
  });

  test('does not advance a type anchor when local persistence fails', () async {
    final preferences = await loadPreferences();
    final stateStore = _MemoryAppleHealthContextImportStateStore();
    final service = _FakeContextService()
      ..results.add(
        AppleHealthContextImportResult(
          status: AppleHealthContextImportStatus.ok,
          batches: <AppleHealthContextTypeBatch>[
            _sleepBatch(
              samples: <SleepSample>[
                SleepSample(
                  start: now.subtract(const Duration(hours: 8)),
                  end: now.subtract(const Duration(hours: 1)),
                  stage: SleepStage.asleep,
                  source: DataSource.appleHealth,
                  provenance: _provenance('unpersisted-source-record'),
                ),
              ],
            ),
            _workoutBatch(),
            _heartRateBatch(),
          ],
        ),
      );
    final context = controller(
      preferences: preferences,
      stateStore: stateStore,
      repository: _FailingSleepRepository(),
      service: service,
    );
    await context.initialize();
    await context.setEnabled(enabled: true);

    final result = await context.syncNow();

    expect(result.status, AppleHealthContextImportStatus.partial);
    expect(stateStore.anchors.containsKey('sleep'), isFalse);
    expect(stateStore.anchors['workout'], 'anchor-workout-1');
    expect(
      stateStore.anchors['heartRate'],
      'anchor-heart-rate-1',
    );
  });

  test(
    'does not persist or advance an out-of-window Apple Health type',
    () async {
      final preferences = await loadPreferences();
      final stateStore = _MemoryAppleHealthContextImportStateStore();
      final repository = InMemoryHealthRepository();
      final service = _FakeContextService()
        ..results.add(
          AppleHealthContextImportResult(
            status: AppleHealthContextImportStatus.ok,
            batches: <AppleHealthContextTypeBatch>[
              _sleepBatch(
                samples: <SleepSample>[
                  SleepSample(
                    start: now.subtract(const Duration(days: 31)),
                    end: now.subtract(const Duration(days: 30)),
                    stage: SleepStage.asleep,
                    source: DataSource.appleHealth,
                    provenance: _provenance('outside-window'),
                  ),
                ],
              ),
              _workoutBatch(),
              _heartRateBatch(),
            ],
          ),
        );
      final context = controller(
        preferences: preferences,
        stateStore: stateStore,
        repository: repository,
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.partial);
      expect(await repository.querySleepSamples(), isEmpty);
      expect(stateStore.anchors.containsKey('sleep'), isFalse);
      expect(stateStore.anchors['workout'], 'anchor-workout-1');
      expect(
        stateStore.anchors['heartRate'],
        'anchor-heart-rate-1',
      );
    },
  );

  test(
    'rejects an aggregate success result that contains a failed type',
    () async {
      final preferences = await loadPreferences();
      final stateStore = _MemoryAppleHealthContextImportStateStore();
      final service = _FakeContextService()
        ..results.add(
          AppleHealthContextImportResult(
            status: AppleHealthContextImportStatus.ok,
            batches: <AppleHealthContextTypeBatch>[
              const AppleHealthContextTypeBatch(
                type: AppleHealthContextDataType.sleep,
                status: AppleHealthContextImportStatus.failed,
              ),
              _workoutBatch(),
              _heartRateBatch(),
            ],
          ),
        );
      final context = controller(
        preferences: preferences,
        stateStore: stateStore,
        repository: InMemoryHealthRepository(),
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.failed);
      expect(stateStore.anchors, isEmpty);
      expect(context.statusMessage, isNot(contains('failed type')));
    },
  );

  test(
    'clears only the malformed type anchor for a partial native result',
    () async {
      final preferences = await loadPreferences();
      final stateStore = _MemoryAppleHealthContextImportStateStore(
        anchors: const <String, String>{'sleep': 'stored-sleep-anchor'},
      );
      final service = _FakeContextService()
        ..results.add(
          AppleHealthContextImportResult(
            status: AppleHealthContextImportStatus.partial,
            batches: <AppleHealthContextTypeBatch>[
              const AppleHealthContextTypeBatch(
                type: AppleHealthContextDataType.sleep,
                status: AppleHealthContextImportStatus.anchorInvalid,
              ),
              _workoutBatch(),
              _heartRateBatch(),
            ],
          ),
        );
      final context = controller(
        preferences: preferences,
        stateStore: stateStore,
        repository: InMemoryHealthRepository(),
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.partial);
      expect(stateStore.anchors.containsKey('sleep'), isFalse);
      expect(stateStore.anchors['workout'], 'anchor-workout-1');
      expect(
        stateStore.anchors['heartRate'],
        'anchor-heart-rate-1',
      );
    },
  );

  test(
    'reports no accessible data without claiming a read-permission result',
    () async {
      final preferences = await loadPreferences();
      final service = _FakeContextService()
        ..results.add(_noAccessibleDataResult());
      final context = controller(
        preferences: preferences,
        stateStore: _MemoryAppleHealthContextImportStateStore(),
        repository: InMemoryHealthRepository(),
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.noAccessibleData);
      expect(
        context.accessState,
        AppleHealthContextAccessState.noAccessibleData,
      );
      expect(context.statusMessage, contains('No accessible data'));
      expect(context.statusMessage, isNot(contains('granted')));
      expect(context.statusMessage, isNot(contains('denied')));
    },
  );

  test(
    'surfaces a safe locked-state message without native error detail',
    () async {
      final preferences = await loadPreferences();
      final service = _FakeContextService()
        ..results.add(
          const AppleHealthContextImportResult(
            status: AppleHealthContextImportStatus.locked,
          ),
        );
      final context = controller(
        preferences: preferences,
        stateStore: _MemoryAppleHealthContextImportStateStore(),
        repository: InMemoryHealthRepository(),
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.locked);
      expect(context.accessState, AppleHealthContextAccessState.locked);
      expect(context.statusMessage, contains('Unlock'));
      expect(context.statusMessage, isNot(contains('HKError')));
    },
  );

  test(
    'surfaces a safe retry-state message without native error detail',
    () async {
      final preferences = await loadPreferences();
      final service = _FakeContextService()
        ..results.add(
          const AppleHealthContextImportResult(
            status: AppleHealthContextImportStatus.retry,
          ),
        );
      final context = controller(
        preferences: preferences,
        stateStore: _MemoryAppleHealthContextImportStateStore(),
        repository: InMemoryHealthRepository(),
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.retry);
      expect(context.accessState, AppleHealthContextAccessState.retry);
      expect(context.statusMessage, contains('Try again'));
      expect(context.statusMessage, isNot(contains('synthetic')));
    },
  );

  test(
    'does not call Apple Health in a mode that disallows personal reads',
    () async {
      final preferences = await loadPreferences();
      final service = _FakeContextService();
      final context = controller(
        preferences: preferences,
        stateStore: _MemoryAppleHealthContextImportStateStore(),
        repository: InMemoryHealthRepository(),
        service: service,
        readsAllowed: false,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);
      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.unavailable);
      expect(service.availabilityCalls, 0);
      expect(service.authorizationCalls, 0);
      expect(service.importCalls, 0);
      expect(context.enabled, isFalse);
    },
  );

  test(
    'fails closed on an incomplete source result and does not expose errors',
    () async {
      final preferences = await loadPreferences();
      final stateStore = _MemoryAppleHealthContextImportStateStore();
      final service = _FakeContextService()
        ..results.add(
          AppleHealthContextImportResult(
            status: AppleHealthContextImportStatus.ok,
            batches: <AppleHealthContextTypeBatch>[_sleepBatch()],
          ),
        );
      final context = controller(
        preferences: preferences,
        stateStore: stateStore,
        repository: InMemoryHealthRepository(),
        service: service,
      );
      await context.initialize();
      await context.setEnabled(enabled: true);

      final result = await context.syncNow();

      expect(result.status, AppleHealthContextImportStatus.failed);
      expect(stateStore.anchors, isEmpty);
      expect(context.statusMessage, isNot(contains('synthetic')));
    },
  );

  test('native transport rejects an unknown response schema', () async {
    const channel = MethodChannel('test.apple-health-context-import');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'sync') {
        return <String, Object>{'schemaVersion': 999, 'status': 'ok'};
      }
      return <String, Object>{'schemaVersion': 1, 'status': 'available'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = HealthKitContextImportService(
      channel: channel,
      supportCheck: () => true,
    );

    final result = await service.importContext(
      window: AppleHealthContextImportWindow(
        start: now.subtract(kAppleHealthContextImportRange),
        end: now,
      ),
      anchors: const <AppleHealthContextDataType, String>{},
    );

    expect(result.status, AppleHealthContextImportStatus.failed);
  });

  test(
    'native authorization transport preserves safe public statuses',
    () async {
      const channel = MethodChannel('test.apple-health-context-authorization');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var nativeStatus = 'requested';
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'requestAuthorization':
            return <String, Object>{
              'schemaVersion': 1,
              'status': nativeStatus,
            };
          case 'availability':
            return <String, Object>{'schemaVersion': 1, 'status': 'available'};
          default:
            throw StateError('Unexpected method.');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = HealthKitContextImportService(
        channel: channel,
        supportCheck: () => true,
      );

      Future<void> expectStatus(
        String response,
        AppleHealthContextAuthorizationStatus expected,
      ) async {
        nativeStatus = response;
        final authorization = await service.requestAuthorization(
          AppleHealthContextDataType.values.toSet(),
        );
        expect(authorization.status, expected);
      }

      await expectStatus(
        'requested',
        AppleHealthContextAuthorizationStatus.requested,
      );
      await expectStatus(
        'unavailable',
        AppleHealthContextAuthorizationStatus.unavailable,
      );
      await expectStatus(
        'locked',
        AppleHealthContextAuthorizationStatus.locked,
      );
      await expectStatus('retry', AppleHealthContextAuthorizationStatus.retry);
      await expectStatus(
        'noAccessibleData',
        AppleHealthContextAuthorizationStatus.noAccessibleData,
      );
      await expectStatus(
        'failed',
        AppleHealthContextAuthorizationStatus.failed,
      );
    },
  );

  test(
    'authorization errors retain explicit opt-in with safe public guidance',
    () async {
      final preferences = await loadPreferences();

      Future<void> expectAuthorizationState(
        AppleHealthContextAuthorizationStatus authorizationStatus,
        AppleHealthContextAccessState expectedState,
        String messageFragment,
      ) async {
        await preferences.setBool(_enabledKey, false);
        final service = _FakeContextService()
          ..authorizationStatus = authorizationStatus;
        final context = controller(
          preferences: preferences,
          stateStore: _MemoryAppleHealthContextImportStateStore(),
          repository: InMemoryHealthRepository(),
          service: service,
        );
        await context.initialize();

        await context.setEnabled(enabled: true);

        expect(context.enabled, isTrue);
        expect(preferences.getBool(_enabledKey), isTrue);
        expect(context.accessState, expectedState);
        expect(context.statusMessage, contains(messageFragment));
        expect(context.statusMessage, isNot(contains('HKError')));
      }

      await expectAuthorizationState(
        AppleHealthContextAuthorizationStatus.locked,
        AppleHealthContextAccessState.locked,
        'Unlock',
      );
      await expectAuthorizationState(
        AppleHealthContextAuthorizationStatus.retry,
        AppleHealthContextAccessState.retry,
        'Try again',
      );
      await expectAuthorizationState(
        AppleHealthContextAuthorizationStatus.noAccessibleData,
        AppleHealthContextAccessState.noAccessibleData,
        'No accessible data',
      );
    },
  );

  test(
    'native transport accepts no-data batches that cannot advance a cursor',
    () async {
      const channel = MethodChannel('test.apple-health-context-no-data');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'sync') {
          return <String, Object?>{
            'schemaVersion': 1,
            'status': 'noAccessibleData',
            'results': <Object?>[
              for (final type in <String>['sleep', 'workout', 'heartRate'])
                <String, Object?>{
                  'type': type,
                  'status': 'noAccessibleData',
                  'samples': <Object?>[],
                  'deletedIds': <Object?>[],
                  'nextAnchor': null,
                  'mayHaveMore': false,
                },
            ],
          };
        }
        return <String, Object>{'schemaVersion': 1, 'status': 'available'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = HealthKitContextImportService(
        channel: channel,
        supportCheck: () => true,
      );

      final result = await service.importContext(
        window: AppleHealthContextImportWindow(
          start: now.subtract(kAppleHealthContextImportRange),
          end: now,
        ),
        anchors: const <AppleHealthContextDataType, String>{},
      );

      expect(result.status, AppleHealthContextImportStatus.noAccessibleData);
      expect(result.batches, hasLength(3));
      expect(
        result.batches.every((batch) => batch.nextAnchor == null),
        isTrue,
      );
    },
  );

  test('native transport preserves a safe locked state', () async {
    const channel = MethodChannel('test.apple-health-context-locked');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'sync') {
        return <String, Object>{'schemaVersion': 1, 'status': 'locked'};
      }
      return <String, Object>{'schemaVersion': 1, 'status': 'available'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = HealthKitContextImportService(
      channel: channel,
      supportCheck: () => true,
    );

    final result = await service.importContext(
      window: AppleHealthContextImportWindow(
        start: now.subtract(kAppleHealthContextImportRange),
        end: now,
      ),
      anchors: const <AppleHealthContextDataType, String>{},
    );

    expect(result.status, AppleHealthContextImportStatus.locked);
    expect(result.batches, isEmpty);
  });

  testWidgets('settings exposes the separate opt-in import control', (
    tester,
  ) async {
    final preferences = await loadPreferences();
    final service = _FakeContextService();
    final context = controller(
      preferences: preferences,
      stateStore: _MemoryAppleHealthContextImportStateStore(),
      repository: InMemoryHealthRepository(),
      service: service,
    );
    await context.initialize();
    final appController = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    final healthExport = HealthExportController(
      preferences: preferences,
      writesAllowed: false,
    )..initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: IntegrationsSettingsPane(
          healthExport: healthExport,
          healthContextImport: context,
          controller: appController,
        ),
      ),
    );

    expect(find.text('Apple Health context'), findsOneWidget);
    expect(find.text('Import now'), findsOneWidget);
    expect(
      find.textContaining('does not disclose read permission'),
      findsOneWidget,
    );
    await tester.tap(find.text('Import Apple Health context'));
    await tester.pumpAndSettle();

    expect(context.enabled, isTrue);
    expect(service.authorizationCalls, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Import now'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    appController.dispose();
  });
}
