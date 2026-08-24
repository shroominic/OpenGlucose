import 'dart:async';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'apple_health_context_import_state.dart';
import 'persistence/health_repository_lifecycle.dart';

/// The maximum time span a single Apple Health import may request.
///
/// This is enforced by both Dart and the native channel. It keeps a user
/// initiated sync bounded even when no incremental anchor exists yet.
const kAppleHealthContextImportMaximumRange = Duration(days: 31);

/// The rolling time span used for an Apple Health context sync.
const kAppleHealthContextImportRange = Duration(days: 30);

/// Apple Health categories intentionally supported by this partial importer.
///
/// Blood glucose, Health Connect, background delivery, and display overlays
/// are outside this change.
enum AppleHealthContextDataType {
  sleep,
  workout,
  heartRate
  ;

  String get nativeKey => switch (this) {
    AppleHealthContextDataType.sleep => 'sleep',
    AppleHealthContextDataType.workout => 'workout',
    AppleHealthContextDataType.heartRate => 'heartRate',
  };

  HealthSampleKind get sampleKind => switch (this) {
    AppleHealthContextDataType.sleep => HealthSampleKind.sleep,
    AppleHealthContextDataType.workout => HealthSampleKind.activity,
    AppleHealthContextDataType.heartRate => HealthSampleKind.heartRate,
  };

  static AppleHealthContextDataType fromNativeKey(String value) {
    for (final type in values) {
      if (type.nativeKey == value) {
        return type;
      }
    }
    throw const FormatException('Unsupported Apple Health context type.');
  }
}

/// Whether Apple Health context import can run on this device.
enum AppleHealthContextAvailability { available, unavailable }

/// The result of asking iOS to show the Apple Health read-access sheet.
///
/// Apple does not disclose whether a user granted read access. [requested]
/// means only that iOS accepted the request; a later sync can still return no
/// accessible data.
enum AppleHealthContextAuthorizationStatus { requested, unavailable, failed }

/// The visible state of the context-import permission and sync flow.
enum AppleHealthContextAccessState {
  off,
  unavailable,
  locked,
  retry,
  authorizationRequested,
  ready,
  noAccessibleData,
  failed,
  disabledForMode,
}

/// Outcome of a context import attempt.
enum AppleHealthContextImportStatus {
  ok,
  noAccessibleData,
  partial,
  unavailable,
  locked,
  retry,
  anchorInvalid,
  notEnabled,
  failed,
}

/// A validated, finite time window passed to the native HealthKit reader.
class AppleHealthContextImportWindow {
  AppleHealthContextImportWindow({
    required DateTime start,
    required DateTime end,
  }) : start = start.toUtc(),
       end = end.toUtc() {
    if (!this.end.isAfter(this.start)) {
      throw ArgumentError(
        'Apple Health import window must have positive size.',
      );
    }
    if (this.end.difference(this.start) >
        kAppleHealthContextImportMaximumRange) {
      throw ArgumentError('Apple Health import window is too large.');
    }
  }

  final DateTime start;
  final DateTime end;

  bool contains(DateTime value) {
    final instant = value.toUtc();
    return !instant.isBefore(start) && !instant.isAfter(end);
  }
}

/// Result of an Apple Health read-permission request.
class AppleHealthContextAuthorizationResult {
  const AppleHealthContextAuthorizationResult(this.status);

  final AppleHealthContextAuthorizationStatus status;
}

/// One source-type result returned by an incremental native query.
///
/// The source-owned anchor advances only after this result has been persisted
/// in the local repository. This keeps a storage failure from losing changes.
class AppleHealthContextTypeBatch {
  const AppleHealthContextTypeBatch({
    required this.type,
    required this.status,
    this.sleepSamples = const <SleepSample>[],
    this.workoutSamples = const <ActivitySample>[],
    this.heartRateSamples = const <HeartRateSample>[],
    this.tombstones = const <HealthImportTombstone>[],
    this.nextAnchor,
    this.mayHaveMore = false,
  });

  final AppleHealthContextDataType type;
  final AppleHealthContextImportStatus status;
  final List<SleepSample> sleepSamples;
  final List<ActivitySample> workoutSamples;
  final List<HeartRateSample> heartRateSamples;
  final List<HealthImportTombstone> tombstones;
  final String? nextAnchor;
  final bool mayHaveMore;

  int get recordCount =>
      sleepSamples.length + workoutSamples.length + heartRateSamples.length;

  int get deletionCount => tombstones.length;
}

/// Aggregate result for all deliberately enabled Apple Health context types.
class AppleHealthContextImportResult {
  const AppleHealthContextImportResult({
    required this.status,
    this.batches = const <AppleHealthContextTypeBatch>[],
  });

  final AppleHealthContextImportStatus status;
  final List<AppleHealthContextTypeBatch> batches;

  int get recordCount =>
      batches.fold<int>(0, (total, batch) => total + batch.recordCount);

  int get deletionCount =>
      batches.fold<int>(0, (total, batch) => total + batch.deletionCount);
}

/// Platform boundary for the opt-in Apple Health context reader.
abstract interface class AppleHealthContextImportService {
  bool get isSupported;

  Future<AppleHealthContextAvailability> checkAvailability();

  Future<AppleHealthContextAuthorizationResult> requestAuthorization(
    Set<AppleHealthContextDataType> types,
  );

  Future<AppleHealthContextImportResult> importContext({
    required AppleHealthContextImportWindow window,
    required Map<AppleHealthContextDataType, String> anchors,
  });
}

/// Native iOS implementation backed by `HKAnchoredObjectQuery`.
///
/// The channel has no Android implementation by design. This service never
/// logs platform payloads, values, UUIDs, source identifiers, or anchors.
class HealthKitContextImportService implements AppleHealthContextImportService {
  HealthKitContextImportService({
    MethodChannel? channel,
    bool Function()? supportCheck,
  }) : _channel =
           channel ??
           const MethodChannel('com.openglucose.app/health_context_import'),
       _supportCheck = supportCheck ?? _isRunningOnIOS;

  final MethodChannel _channel;
  final bool Function() _supportCheck;

  static const _schemaVersion = 1;

  @override
  bool get isSupported => _supportCheck();

  static bool _isRunningOnIOS() => Platform.isIOS;

  @override
  Future<AppleHealthContextAvailability> checkAvailability() async {
    if (!isSupported) {
      return AppleHealthContextAvailability.unavailable;
    }
    try {
      final response = await _channel.invokeMethod<Object?>('availability');
      final map = _stringKeyedMap(response);
      _requireSchemaVersion(map);
      return map['status'] == 'available'
          ? AppleHealthContextAvailability.available
          : AppleHealthContextAvailability.unavailable;
    } on Object {
      return AppleHealthContextAvailability.unavailable;
    }
  }

  @override
  Future<AppleHealthContextAuthorizationResult> requestAuthorization(
    Set<AppleHealthContextDataType> types,
  ) async {
    if (!isSupported || !_hasExactSupportedTypes(types)) {
      return const AppleHealthContextAuthorizationResult(
        AppleHealthContextAuthorizationStatus.unavailable,
      );
    }
    try {
      final response = await _channel.invokeMethod<Object?>(
        'requestAuthorization',
        <String, Object>{
          'schemaVersion': _schemaVersion,
          'types': _nativeKeys(types),
        },
      );
      final map = _stringKeyedMap(response);
      _requireSchemaVersion(map);
      return switch (map['status']) {
        'requested' => const AppleHealthContextAuthorizationResult(
          AppleHealthContextAuthorizationStatus.requested,
        ),
        'unavailable' => const AppleHealthContextAuthorizationResult(
          AppleHealthContextAuthorizationStatus.unavailable,
        ),
        _ => const AppleHealthContextAuthorizationResult(
          AppleHealthContextAuthorizationStatus.failed,
        ),
      };
    } on Object {
      return const AppleHealthContextAuthorizationResult(
        AppleHealthContextAuthorizationStatus.failed,
      );
    }
  }

  @override
  Future<AppleHealthContextImportResult> importContext({
    required AppleHealthContextImportWindow window,
    required Map<AppleHealthContextDataType, String> anchors,
  }) async {
    if (!isSupported) {
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.unavailable,
      );
    }
    try {
      final response = await _channel.invokeMethod<Object?>(
        'sync',
        <String, Object>{
          'schemaVersion': _schemaVersion,
          'types': _nativeKeys(AppleHealthContextDataType.values.toSet()),
          'startMs': window.start.millisecondsSinceEpoch,
          'endMs': window.end.millisecondsSinceEpoch,
          'anchors': <String, String>{
            for (final entry in anchors.entries)
              entry.key.nativeKey: _validateAnchor(entry.value),
          },
        },
      );
      return _decodeImportResult(response, window);
    } on Object {
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.failed,
      );
    }
  }

  AppleHealthContextImportResult _decodeImportResult(
    Object? response,
    AppleHealthContextImportWindow window,
  ) {
    final map = _stringKeyedMap(response);
    _requireSchemaVersion(map);
    final status = _decodeStatus(map['status']);
    if (status == AppleHealthContextImportStatus.unavailable ||
        status == AppleHealthContextImportStatus.locked ||
        status == AppleHealthContextImportStatus.retry ||
        status == AppleHealthContextImportStatus.failed) {
      return AppleHealthContextImportResult(status: status);
    }
    final rawBatches = _objectList(map['results']);
    if (rawBatches.length != AppleHealthContextDataType.values.length) {
      throw const FormatException('Apple Health context result is incomplete.');
    }
    final batches = rawBatches
        .map((value) => _decodeBatch(value, window))
        .toList(growable: false);
    final kinds = batches.map((batch) => batch.type).toSet();
    if (kinds.length != AppleHealthContextDataType.values.length ||
        !kinds.containsAll(AppleHealthContextDataType.values)) {
      throw const FormatException(
        'Apple Health context result has duplicate types.',
      );
    }
    return AppleHealthContextImportResult(status: status, batches: batches);
  }

  AppleHealthContextTypeBatch _decodeBatch(
    Object? raw,
    AppleHealthContextImportWindow window,
  ) {
    final map = _stringKeyedMap(raw);
    final type = AppleHealthContextDataType.fromNativeKey(
      _requiredString(map, 'type'),
    );
    final status = _decodeStatus(map['status']);
    if (status == AppleHealthContextImportStatus.partial) {
      throw const FormatException(
        'Apple Health type result cannot be partial.',
      );
    }
    final mayHaveMore = _requiredBool(map, 'mayHaveMore');
    if (status == AppleHealthContextImportStatus.failed ||
        status == AppleHealthContextImportStatus.unavailable ||
        status == AppleHealthContextImportStatus.locked ||
        status == AppleHealthContextImportStatus.retry ||
        status == AppleHealthContextImportStatus.anchorInvalid) {
      _requireEmptyBatch(map);
      return AppleHealthContextTypeBatch(type: type, status: status);
    }
    if (status == AppleHealthContextImportStatus.noAccessibleData &&
        map['nextAnchor'] == null) {
      _requireEmptyBatch(map);
      return AppleHealthContextTypeBatch(type: type, status: status);
    }
    final nextAnchor = _validateAnchor(_requiredString(map, 'nextAnchor'));
    final tombstones = _decodeTombstones(type, _objectList(map['deletedIds']));
    return switch (type) {
      AppleHealthContextDataType.sleep => AppleHealthContextTypeBatch(
        type: type,
        status: status,
        sleepSamples: _objectList(
          map['samples'],
        ).map((sample) => _decodeSleep(sample, window)).toList(growable: false),
        tombstones: tombstones,
        nextAnchor: nextAnchor,
        mayHaveMore: mayHaveMore,
      ),
      AppleHealthContextDataType.workout => AppleHealthContextTypeBatch(
        type: type,
        status: status,
        workoutSamples: _objectList(map['samples'])
            .map((sample) => _decodeWorkout(sample, window))
            .toList(growable: false),
        tombstones: tombstones,
        nextAnchor: nextAnchor,
        mayHaveMore: mayHaveMore,
      ),
      AppleHealthContextDataType.heartRate => AppleHealthContextTypeBatch(
        type: type,
        status: status,
        heartRateSamples: _objectList(map['samples'])
            .map((sample) => _decodeHeartRate(sample, window))
            .toList(growable: false),
        tombstones: tombstones,
        nextAnchor: nextAnchor,
        mayHaveMore: mayHaveMore,
      ),
    };
  }

  SleepSample _decodeSleep(Object? raw, AppleHealthContextImportWindow window) {
    final map = _stringKeyedMap(raw);
    final start = _timestamp(map, 'startMs');
    final end = _timestamp(map, 'endMs');
    _requireBoundedInterval(start, end, window);
    return SleepSample(
      start: start,
      end: end,
      stage: _decodeSleepStage(_requiredString(map, 'sleepStage')),
      source: DataSource.appleHealth,
      provenance: _provenance(map),
    );
  }

  ActivitySample _decodeWorkout(
    Object? raw,
    AppleHealthContextImportWindow window,
  ) {
    final map = _stringKeyedMap(raw);
    final start = _timestamp(map, 'startMs');
    final end = _timestamp(map, 'endMs');
    _requireBoundedInterval(start, end, window);
    return ActivitySample(
      start: start,
      end: end,
      type: ActivityType.workout,
      source: DataSource.appleHealth,
      workoutLabel: _optionalNonBlankString(map, 'workoutLabel'),
      provenance: _provenance(map),
    );
  }

  HeartRateSample _decodeHeartRate(
    Object? raw,
    AppleHealthContextImportWindow window,
  ) {
    final map = _stringKeyedMap(raw);
    final timestamp = _timestamp(map, 'timestampMs');
    if (!window.contains(timestamp)) {
      throw const FormatException(
        'Heart-rate sample is outside its request window.',
      );
    }
    final rawBpm = map['bpm'];
    if (rawBpm is! num) {
      throw const FormatException('Heart-rate sample is invalid.');
    }
    final bpm = rawBpm.toDouble();
    if (!bpm.isFinite || bpm <= 0) {
      throw const FormatException('Heart-rate sample is invalid.');
    }
    return HeartRateSample(
      timestamp: timestamp,
      bpm: bpm,
      source: DataSource.appleHealth,
      provenance: _provenance(map),
    );
  }

  List<HealthImportTombstone> _decodeTombstones(
    AppleHealthContextDataType type,
    List<Object?> rawIds,
  ) {
    final identities = <String>{};
    return rawIds
        .map((rawId) {
          if (rawId is! String) {
            throw const FormatException(
              'Apple Health deletion identity is invalid.',
            );
          }
          final externalId = _validateExternalId(rawId);
          if (!identities.add(externalId)) {
            throw const FormatException(
              'Apple Health deletion identities are duplicated.',
            );
          }
          return HealthImportTombstone(
            kind: type.sampleKind,
            provenance: HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.appleHealth,
                externalId: externalId,
              ),
              isDeleted: true,
            ),
          );
        })
        .toList(growable: false);
  }

  HealthSampleProvenance _provenance(Map<String, Object?> map) {
    final method = _requiredString(map, 'recordingMethod');
    final recordingMethod = switch (method) {
      'automatic' => HealthRecordingMethod.automatic,
      'manual' => HealthRecordingMethod.manual,
      'unknown' => HealthRecordingMethod.unknown,
      _ => throw const FormatException(
        'Apple Health recording method is invalid.',
      ),
    };
    return HealthSampleProvenance(
      identity: HealthImportIdentity(
        platform: HealthSourcePlatform.appleHealth,
        externalId: _validateExternalId(_requiredString(map, 'id')),
      ),
      sourceApplicationId: _optionalNonBlankString(map, 'sourceApplicationId'),
      sourceName: _optionalNonBlankString(map, 'sourceName'),
      sourceDevice: _optionalNonBlankString(map, 'sourceDevice'),
      sourceDeviceModel: _optionalNonBlankString(map, 'sourceDeviceModel'),
      recordingMethod: recordingMethod,
      sourceRevision: _optionalNonBlankString(map, 'sourceRevision'),
    );
  }

  static List<String> _nativeKeys(Set<AppleHealthContextDataType> types) =>
      types.map((type) => type.nativeKey).toList(growable: false)..sort();

  static bool _hasExactSupportedTypes(Set<AppleHealthContextDataType> types) =>
      types.length == AppleHealthContextDataType.values.length &&
      types.containsAll(AppleHealthContextDataType.values);

  static AppleHealthContextImportStatus _decodeStatus(Object? value) =>
      switch (value) {
        'ok' => AppleHealthContextImportStatus.ok,
        'noAccessibleData' => AppleHealthContextImportStatus.noAccessibleData,
        'partial' => AppleHealthContextImportStatus.partial,
        'unavailable' => AppleHealthContextImportStatus.unavailable,
        'locked' => AppleHealthContextImportStatus.locked,
        'retry' => AppleHealthContextImportStatus.retry,
        'anchorInvalid' => AppleHealthContextImportStatus.anchorInvalid,
        'failed' => AppleHealthContextImportStatus.failed,
        _ => throw const FormatException(
          'Apple Health context status is invalid.',
        ),
      };

  static SleepStage _decodeSleepStage(String value) => switch (value) {
    'awake' => SleepStage.awake,
    'light' => SleepStage.light,
    'deep' => SleepStage.deep,
    'rem' => SleepStage.rem,
    'asleep' => SleepStage.asleep,
    'inBed' => SleepStage.inBed,
    _ => throw const FormatException('Apple Health sleep stage is invalid.'),
  };

  static Map<String, Object?> _stringKeyedMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Apple Health context response is invalid.');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException(
          'Apple Health context response is invalid.',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static List<Object?> _objectList(Object? value) {
    if (value is! List) {
      throw const FormatException('Apple Health context response is invalid.');
    }
    return List<Object?>.from(value);
  }

  static String _requiredString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('Apple Health context response is invalid.');
    }
    return value;
  }

  static String? _optionalNonBlankString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const FormatException('Apple Health context response is invalid.');
    }
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  static bool _requiredBool(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! bool) {
      throw const FormatException('Apple Health context response is invalid.');
    }
    return value;
  }

  static DateTime _timestamp(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! int || value < 0) {
      throw const FormatException('Apple Health context response is invalid.');
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  static void _requireBoundedInterval(
    DateTime start,
    DateTime end,
    AppleHealthContextImportWindow window,
  ) {
    if (end.isBefore(start) ||
        !window.contains(start) ||
        !window.contains(end)) {
      throw const FormatException(
        'Apple Health interval is outside its request window.',
      );
    }
  }

  static String _validateExternalId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw const FormatException('Apple Health record identity is invalid.');
    }
    return normalized;
  }

  static String _validateAnchor(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 32768) {
      throw const FormatException('Apple Health import anchor is invalid.');
    }
    return normalized;
  }

  static void _requireSchemaVersion(Map<String, Object?> map) {
    if (map['schemaVersion'] != _schemaVersion) {
      throw const FormatException(
        'Apple Health context schema is unsupported.',
      );
    }
  }

  static void _requireEmptyBatch(Map<String, Object?> map) {
    if (_objectList(map['samples']).isNotEmpty ||
        _objectList(map['deletedIds']).isNotEmpty ||
        map['nextAnchor'] != null ||
        _requiredBool(map, 'mayHaveMore')) {
      throw const FormatException('Failed Apple Health batch must be empty.');
    }
  }
}

/// Supplies the wall clock at the composition edge and in deterministic tests.
typedef AppleHealthContextClock = DateTime Function();

/// Owns the explicit opt-in, bounded import, per-type anchor, and persistence
/// flow. It deliberately does not render imported values or identifiers.
class AppleHealthContextImportController extends ChangeNotifier {
  AppleHealthContextImportController({
    required SharedPreferences preferences,
    AppleHealthContextImportStateStore? importStateStore,
    AppHealthRepositoryLifecycle? repositoryLifecycle,
    AppleHealthContextImportService? service,
    AppleHealthContextClock? clock,
    this.readsAllowed = true,
  }) : _preferences = preferences,
       _importStateStore =
           importStateStore ??
           (readsAllowed
               ? throw ArgumentError.notNull('importStateStore')
               : InMemoryAppleHealthContextImportStateStore()),
       _repositoryLifecycle =
           repositoryLifecycle ??
           AppHealthRepositoryLifecycle(
             () => Future<HealthRepository>.error(
               StateError('Apple Health context repository is not configured.'),
             ),
           ),
       _service = service ?? HealthKitContextImportService(),
       _clock = clock ?? DateTime.now;

  static const _enabledKey = 'openHealth.appleHealthContextImport.enabled';

  final SharedPreferences _preferences;
  final AppleHealthContextImportStateStore _importStateStore;
  final AppHealthRepositoryLifecycle _repositoryLifecycle;
  final AppleHealthContextImportService _service;
  final AppleHealthContextClock _clock;

  /// Immutable gate for mock/demo drivers and other modes that must not read
  /// personal Apple Health data. It is independent from user consent.
  final bool readsAllowed;

  final Map<AppleHealthContextDataType, String> _anchors =
      <AppleHealthContextDataType, String>{};
  bool _enabled = false;
  bool _busy = false;
  AppleHealthContextAvailability _availability =
      AppleHealthContextAvailability.unavailable;
  AppleHealthContextAccessState _accessState =
      AppleHealthContextAccessState.off;
  DateTime? _lastSyncedAt;
  String? _statusMessage;

  bool get isSupported => _service.isSupported;
  bool get enabled => _enabled;
  bool get busy => _busy;
  AppleHealthContextAvailability get availability => _availability;
  AppleHealthContextAccessState get accessState => _accessState;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get statusMessage => _statusMessage;

  /// Loads local consent and cursors, then performs only an availability check.
  /// It does not request permission or read HealthKit records.
  Future<void> initialize() async {
    _enabled = readsAllowed && (_preferences.getBool(_enabledKey) ?? false);
    if (!readsAllowed) {
      _enabled = false;
      _accessState = AppleHealthContextAccessState.disabledForMode;
      return;
    }
    if (!_service.isSupported) {
      _enabled = false;
      _accessState = AppleHealthContextAccessState.unavailable;
      return;
    }
    try {
      await _importStateStore.initialize();
      _restoreImportState(_importStateStore.state);
    } on Object {
      _enabled = false;
      _anchors.clear();
      _accessState = AppleHealthContextAccessState.failed;
      _statusMessage = 'Local Apple Health import state could not be read.';
      await _preferences.setBool(_enabledKey, false);
      notifyListeners();
      return;
    }
    _availability = await _service.checkAvailability();
    if (_availability == AppleHealthContextAvailability.unavailable) {
      _enabled = false;
      _accessState = AppleHealthContextAccessState.unavailable;
      await _preferences.setBool(_enabledKey, false);
    } else if (_enabled) {
      _accessState = AppleHealthContextAccessState.authorizationRequested;
    }
    notifyListeners();
  }

  /// Stops future reads when disabled. Existing local context is retained;
  /// verified deletion is explicitly outside this partial implementation.
  Future<void> setEnabled({required bool enabled}) async {
    if (_busy) {
      return;
    }
    if (!readsAllowed) {
      _enabled = false;
      _accessState = AppleHealthContextAccessState.disabledForMode;
      _statusMessage =
          'Apple Health context import is unavailable in this mode.';
      notifyListeners();
      return;
    }
    if (!enabled) {
      _enabled = false;
      _accessState = AppleHealthContextAccessState.off;
      _statusMessage = null;
      await _preferences.setBool(_enabledKey, false);
      notifyListeners();
      return;
    }
    if (!_service.isSupported) {
      _availability = AppleHealthContextAvailability.unavailable;
      _accessState = AppleHealthContextAccessState.unavailable;
      _statusMessage = 'Apple Health context import is only available on iOS.';
      notifyListeners();
      return;
    }

    _busy = true;
    _statusMessage = null;
    notifyListeners();
    try {
      _availability = await _service.checkAvailability();
      if (_availability == AppleHealthContextAvailability.unavailable) {
        _enabled = false;
        _accessState = AppleHealthContextAccessState.unavailable;
        _statusMessage = 'Apple Health is unavailable on this device.';
        await _preferences.setBool(_enabledKey, false);
        return;
      }
      final authorization = await _service.requestAuthorization(
        AppleHealthContextDataType.values.toSet(),
      );
      switch (authorization.status) {
        case AppleHealthContextAuthorizationStatus.requested:
          _enabled = true;
          _accessState = AppleHealthContextAccessState.authorizationRequested;
          _statusMessage =
              'Apple Health read access was requested. Apple does not disclose '
              'whether read access was granted; sync to check for accessible data.';
          await _preferences.setBool(_enabledKey, true);
        case AppleHealthContextAuthorizationStatus.unavailable:
          _enabled = false;
          _availability = AppleHealthContextAvailability.unavailable;
          _accessState = AppleHealthContextAccessState.unavailable;
          _statusMessage = 'Apple Health is unavailable on this device.';
          await _preferences.setBool(_enabledKey, false);
        case AppleHealthContextAuthorizationStatus.failed:
          _enabled = false;
          _accessState = AppleHealthContextAccessState.failed;
          _statusMessage = 'Apple Health access could not be requested.';
          await _preferences.setBool(_enabledKey, false);
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Imports only the supported context families for a rolling, bounded range.
  ///
  /// Native anchors are passed per type. A type cursor is stored only after
  /// that type's samples and tombstones have reached the local repository.
  Future<AppleHealthContextImportResult> syncNow() async {
    if (_busy) {
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.failed,
      );
    }
    if (!readsAllowed) {
      _accessState = AppleHealthContextAccessState.disabledForMode;
      _statusMessage =
          'Apple Health context import is unavailable in this mode.';
      notifyListeners();
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.unavailable,
      );
    }
    if (!_service.isSupported ||
        _availability == AppleHealthContextAvailability.unavailable) {
      _availability = AppleHealthContextAvailability.unavailable;
      _accessState = AppleHealthContextAccessState.unavailable;
      _statusMessage = 'Apple Health is unavailable on this device.';
      notifyListeners();
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.unavailable,
      );
    }
    if (!_enabled) {
      _accessState = AppleHealthContextAccessState.off;
      _statusMessage = 'Turn on Apple Health context import before syncing.';
      notifyListeners();
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.notEnabled,
      );
    }

    _busy = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final end = _clock().toUtc();
      final window = AppleHealthContextImportWindow(
        start: end.subtract(kAppleHealthContextImportRange),
        end: end,
      );
      final result = await _service.importContext(
        window: window,
        anchors: Map<AppleHealthContextDataType, String>.unmodifiable(_anchors),
      );
      return await _persistResult(result, syncedAt: end, window: window);
    } on Object {
      _accessState = AppleHealthContextAccessState.failed;
      _statusMessage = 'Apple Health context import could not be completed.';
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.failed,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<AppleHealthContextImportResult> _persistResult(
    AppleHealthContextImportResult result, {
    required DateTime syncedAt,
    required AppleHealthContextImportWindow window,
  }) async {
    switch (result.status) {
      case AppleHealthContextImportStatus.unavailable:
        _availability = AppleHealthContextAvailability.unavailable;
        _enabled = false;
        _accessState = AppleHealthContextAccessState.unavailable;
        _statusMessage = 'Apple Health is unavailable on this device.';
        await _preferences.setBool(_enabledKey, false);
        return result;
      case AppleHealthContextImportStatus.locked:
        _accessState = AppleHealthContextAccessState.locked;
        _statusMessage =
            'Unlock this iPhone and try Apple Health import again.';
        return result;
      case AppleHealthContextImportStatus.retry:
        _accessState = AppleHealthContextAccessState.retry;
        _statusMessage =
            'Apple Health context import could not finish. Try again.';
        return result;
      case AppleHealthContextImportStatus.failed:
        _accessState = AppleHealthContextAccessState.failed;
        _statusMessage = 'Apple Health context import could not be completed.';
        return result;
      case AppleHealthContextImportStatus.notEnabled:
        _accessState = AppleHealthContextAccessState.off;
        _statusMessage = 'Turn on Apple Health context import before syncing.';
        return result;
      case AppleHealthContextImportStatus.anchorInvalid:
        _accessState = AppleHealthContextAccessState.failed;
        _statusMessage = 'Apple Health context import could not be completed.';
        return result;
      case AppleHealthContextImportStatus.ok:
      case AppleHealthContextImportStatus.noAccessibleData:
      case AppleHealthContextImportStatus.partial:
        break;
    }

    var anyPersisted = false;
    var anyFailure = result.status == AppleHealthContextImportStatus.partial;
    var mayHaveMore = false;
    _validateResult(result);
    final repository = await _repositoryLifecycle.acquire();
    for (final batch in result.batches) {
      if (batch.status == AppleHealthContextImportStatus.failed ||
          batch.status == AppleHealthContextImportStatus.unavailable ||
          batch.status == AppleHealthContextImportStatus.locked ||
          batch.status == AppleHealthContextImportStatus.retry ||
          batch.status == AppleHealthContextImportStatus.anchorInvalid) {
        if (batch.status == AppleHealthContextImportStatus.anchorInvalid) {
          await _clearAnchor(batch.type);
        }
        anyFailure = true;
        continue;
      }
      try {
        _validateBatch(batch, window: window);
        if (batch.nextAnchor == null) {
          // A native no-data error has no new cursor. It is intentionally
          // indistinguishable from an empty unreadable result, but cannot
          // advance the rolling predicate or trigger retention expiry.
          continue;
        }
        await _persistBatch(repository, batch);
        // An anchored query with a rolling predicate cannot later report every
        // deletion for a record that has fallen outside that predicate. Purge
        // only the matching platform/type window before its cursor advances,
        // so a failed purge leaves the old anchor in place for a safe retry.
        await repository.purgeImportedSamplesBefore(
          kind: batch.type.sampleKind,
          platform: HealthSourcePlatform.appleHealth,
          cutoff: window.start,
        );
        await _persistAnchor(batch.type, batch.nextAnchor!);
        anyPersisted = true;
        mayHaveMore = mayHaveMore || batch.mayHaveMore;
      } on Object {
        // Do not advance this type's cursor. Repeating an imported object is
        // safe because the source-aware repository upserts by external ID.
        anyFailure = true;
      }
    }

    if (!anyPersisted && anyFailure) {
      _accessState = AppleHealthContextAccessState.failed;
      _statusMessage = 'Apple Health context import could not be completed.';
      return const AppleHealthContextImportResult(
        status: AppleHealthContextImportStatus.failed,
      );
    }

    await _persistImportState(lastSyncedAt: syncedAt);
    _lastSyncedAt = syncedAt;
    final recordCount = result.recordCount;
    if (recordCount == 0 && result.deletionCount == 0 && !anyFailure) {
      _accessState = AppleHealthContextAccessState.noAccessibleData;
      _statusMessage =
          'No accessible data. Apple may return this for empty data or unavailable read access.';
    } else if (anyFailure) {
      _accessState = AppleHealthContextAccessState.ready;
      _statusMessage = 'Some Apple Health context changes were saved.';
    } else {
      _accessState = AppleHealthContextAccessState.ready;
      _statusMessage = recordCount == 0
          ? 'Apple Health context is up to date.'
          : 'Imported $recordCount context record(s).';
    }
    if (mayHaveMore) {
      _statusMessage =
          '${_statusMessage!} Sync again to continue this bounded import.';
    }
    return AppleHealthContextImportResult(
      status: anyFailure
          ? AppleHealthContextImportStatus.partial
          : result.status == AppleHealthContextImportStatus.noAccessibleData
          ? AppleHealthContextImportStatus.noAccessibleData
          : AppleHealthContextImportStatus.ok,
      batches: result.batches,
    );
  }

  Future<void> _persistBatch(
    HealthRepository repository,
    AppleHealthContextTypeBatch batch,
  ) async {
    switch (batch.type) {
      case AppleHealthContextDataType.sleep:
        await repository.upsertSleepSamples(batch.sleepSamples);
      case AppleHealthContextDataType.workout:
        await repository.upsertActivitySamples(batch.workoutSamples);
      case AppleHealthContextDataType.heartRate:
        await repository.upsertHeartRateSamples(batch.heartRateSamples);
    }
    await repository.reconcileImportTombstones(batch.tombstones);
  }

  Future<void> _persistAnchor(
    AppleHealthContextDataType type,
    String anchor,
  ) async {
    final normalized = HealthKitContextImportService._validateAnchor(anchor);
    await _persistImportState(
      anchors: <AppleHealthContextDataType, String>{
        ..._anchors,
        type: normalized,
      },
    );
    _anchors[type] = normalized;
  }

  Future<void> _clearAnchor(AppleHealthContextDataType type) async {
    final updated = <AppleHealthContextDataType, String>{..._anchors}
      ..remove(type);
    await _persistImportState(anchors: updated);
    _anchors.remove(type);
  }

  Future<void> _persistImportState({
    Map<AppleHealthContextDataType, String>? anchors,
    DateTime? lastSyncedAt,
  }) {
    final selectedAnchors = anchors ?? _anchors;
    return _importStateStore.save(
      AppleHealthContextImportState(
        lastSyncedAt: lastSyncedAt ?? _lastSyncedAt,
        anchors: <String, String>{
          for (final entry in selectedAnchors.entries)
            entry.key.nativeKey: entry.value,
        },
      ),
    );
  }

  void _restoreImportState(AppleHealthContextImportState state) {
    _lastSyncedAt = state.lastSyncedAt;
    for (final type in AppleHealthContextDataType.values) {
      final anchor = state.anchors[type.nativeKey];
      if (anchor != null) {
        _anchors[type] = HealthKitContextImportService._validateAnchor(anchor);
      }
    }
  }

  void _validateBatch(
    AppleHealthContextTypeBatch batch, {
    required AppleHealthContextImportWindow window,
  }) {
    if (batch.status != AppleHealthContextImportStatus.ok &&
        batch.status != AppleHealthContextImportStatus.noAccessibleData) {
      throw const FormatException('Apple Health batch status is invalid.');
    }
    if (batch.nextAnchor == null &&
        (batch.status != AppleHealthContextImportStatus.noAccessibleData ||
            batch.recordCount != 0 ||
            batch.deletionCount != 0 ||
            batch.mayHaveMore)) {
      throw const FormatException('Apple Health batch is missing an anchor.');
    }
    switch (batch.type) {
      case AppleHealthContextDataType.sleep:
        if (batch.workoutSamples.isNotEmpty ||
            batch.heartRateSamples.isNotEmpty) {
          throw const FormatException(
            'Apple Health batch contains wrong samples.',
          );
        }
      case AppleHealthContextDataType.workout:
        if (batch.sleepSamples.isNotEmpty ||
            batch.heartRateSamples.isNotEmpty) {
          throw const FormatException(
            'Apple Health batch contains wrong samples.',
          );
        }
      case AppleHealthContextDataType.heartRate:
        if (batch.sleepSamples.isNotEmpty || batch.workoutSamples.isNotEmpty) {
          throw const FormatException(
            'Apple Health batch contains wrong samples.',
          );
        }
    }
    final seen = <String>{};
    for (final sample in <Object>[
      ...batch.sleepSamples,
      ...batch.workoutSamples,
      ...batch.heartRateSamples,
    ]) {
      final provenance = switch (sample) {
        SleepSample(:final provenance) => provenance,
        ActivitySample(:final provenance) => provenance,
        HeartRateSample(:final provenance) => provenance,
        _ => null,
      };
      if (provenance == null) {
        throw const FormatException(
          'Apple Health sample provenance is invalid.',
        );
      }
      final identity = provenance.identity;
      if (identity.platform != HealthSourcePlatform.appleHealth ||
          provenance.isDeleted) {
        throw const FormatException(
          'Apple Health sample provenance is invalid.',
        );
      }
      if (!seen.add(identity.stableKey)) {
        throw const FormatException(
          'Apple Health batch has duplicate identities.',
        );
      }
      switch (sample) {
        case SleepSample(:final start, :final end, :final source):
          if (source != DataSource.appleHealth ||
              end.isBefore(start) ||
              !window.contains(start) ||
              !window.contains(end)) {
            throw const FormatException(
              'Apple Health sleep sample is outside its request window.',
            );
          }
        case ActivitySample(:final start, :final end, :final source):
          if (source != DataSource.appleHealth ||
              end.isBefore(start) ||
              !window.contains(start) ||
              !window.contains(end)) {
            throw const FormatException(
              'Apple Health workout sample is outside its request window.',
            );
          }
        case HeartRateSample(:final timestamp, :final source):
          if (source != DataSource.appleHealth || !window.contains(timestamp)) {
            throw const FormatException(
              'Apple Health heart-rate sample is outside its request window.',
            );
          }
        default:
          throw const FormatException('Apple Health sample is invalid.');
      }
    }
    for (final tombstone in batch.tombstones) {
      if (tombstone.kind != batch.type.sampleKind ||
          tombstone.provenance.identity.platform !=
              HealthSourcePlatform.appleHealth ||
          !tombstone.provenance.isDeleted ||
          !seen.add(tombstone.provenance.identity.stableKey)) {
        throw const FormatException('Apple Health tombstone is invalid.');
      }
    }
  }

  void _validateResult(AppleHealthContextImportResult result) {
    if (result.batches.length != AppleHealthContextDataType.values.length) {
      throw const FormatException('Apple Health context result is incomplete.');
    }
    final types = result.batches.map((batch) => batch.type).toSet();
    if (types.length != AppleHealthContextDataType.values.length ||
        !types.containsAll(AppleHealthContextDataType.values)) {
      throw const FormatException(
        'Apple Health context result has duplicate types.',
      );
    }
    if (result.status == AppleHealthContextImportStatus.noAccessibleData &&
        result.batches.any(
          (batch) =>
              batch.status != AppleHealthContextImportStatus.noAccessibleData ||
              batch.recordCount != 0 ||
              batch.deletionCount != 0,
        )) {
      throw const FormatException(
        'No-data Apple Health result contains changes.',
      );
    }
    final hasTypeFailure = result.batches.any(
      (batch) =>
          batch.status == AppleHealthContextImportStatus.failed ||
          batch.status == AppleHealthContextImportStatus.unavailable ||
          batch.status == AppleHealthContextImportStatus.locked ||
          batch.status == AppleHealthContextImportStatus.retry ||
          batch.status == AppleHealthContextImportStatus.anchorInvalid,
    );
    if (result.status == AppleHealthContextImportStatus.ok && hasTypeFailure) {
      throw const FormatException(
        'Successful Apple Health result contains a failed type.',
      );
    }
    if (result.status == AppleHealthContextImportStatus.partial &&
        !hasTypeFailure) {
      throw const FormatException(
        'Partial Apple Health result is missing a failed type.',
      );
    }
  }
}
