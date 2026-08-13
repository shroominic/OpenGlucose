import 'dart:convert';

import 'timeline.dart';

/// Ephemeral connection metadata used to distinguish a user-confirmed new
/// sensor activation from a background restore or reconnect.
///
/// Drivers must treat a value of `false` as a hard prohibition on starting a
/// stopped or uninitialised sensor session. Callers should attach this only to
/// the in-memory sensor passed to a driver connection, never persist it with the
/// discovered sensor record.
const cgmAllowSessionActivationMetadataKey =
    'cgm.connect.allowSessionActivation';

enum CgmSyncStage {
  disconnected,
  scanning,
  connecting,
  bonding,
  pairing,
  activating,
  syncing,
  ready,
  error,
}

enum GlucoseUnit {
  mgdl,
  mmolL;

  double convertFromMgdl(double value) {
    return switch (this) {
      GlucoseUnit.mgdl => value,
      GlucoseUnit.mmolL => value / 18.0,
    };
  }

  String get label => switch (this) {
    GlucoseUnit.mgdl => 'mg/dL',
    GlucoseUnit.mmolL => 'mmol/L',
  };
}

enum CgmRecordSource { vendor, standard, broadcast, raw, calibration }

enum CgmLogLevel { debug, info, warning, error }

enum CgmUnsafeOperation {
  reset,
  shelfMode,
  unpair,
  clearStorage,
  factoryBiasTrim,
  factoryCurrentTrim,
}

class CgmCapabilities {
  const CgmCapabilities({
    this.supportsDirectBle = false,
    this.supportsVendorPairing = false,
    this.supportsAdvertisementGlucose = false,
    this.supportsHistory = false,
    this.supportsRawHistory = false,
    this.supportsCalibration = false,
    this.supportsDiagnostics = false,
    this.supportsUnsafeAdmin = false,
    this.supportsCommunicationInterval = false,
    this.supportsAutoUpdateControl = false,
  });

  final bool supportsDirectBle;
  final bool supportsVendorPairing;
  final bool supportsAdvertisementGlucose;
  final bool supportsHistory;
  final bool supportsRawHistory;
  final bool supportsCalibration;
  final bool supportsDiagnostics;
  final bool supportsUnsafeAdmin;
  final bool supportsCommunicationInterval;
  final bool supportsAutoUpdateControl;

  CgmCapabilities copyWith({
    bool? supportsDirectBle,
    bool? supportsVendorPairing,
    bool? supportsAdvertisementGlucose,
    bool? supportsHistory,
    bool? supportsRawHistory,
    bool? supportsCalibration,
    bool? supportsDiagnostics,
    bool? supportsUnsafeAdmin,
    bool? supportsCommunicationInterval,
    bool? supportsAutoUpdateControl,
  }) {
    return CgmCapabilities(
      supportsDirectBle: supportsDirectBle ?? this.supportsDirectBle,
      supportsVendorPairing:
          supportsVendorPairing ?? this.supportsVendorPairing,
      supportsAdvertisementGlucose:
          supportsAdvertisementGlucose ?? this.supportsAdvertisementGlucose,
      supportsHistory: supportsHistory ?? this.supportsHistory,
      supportsRawHistory: supportsRawHistory ?? this.supportsRawHistory,
      supportsCalibration: supportsCalibration ?? this.supportsCalibration,
      supportsDiagnostics: supportsDiagnostics ?? this.supportsDiagnostics,
      supportsUnsafeAdmin: supportsUnsafeAdmin ?? this.supportsUnsafeAdmin,
      supportsCommunicationInterval:
          supportsCommunicationInterval ?? this.supportsCommunicationInterval,
      supportsAutoUpdateControl:
          supportsAutoUpdateControl ?? this.supportsAutoUpdateControl,
    );
  }
}

class CgmAdvertisement {
  const CgmAdvertisement({
    required this.payloadHex,
    this.counter,
    this.phaseHex,
    this.glucoseTriplet = const <int>[],
    this.qualifiers = const <int>[],
    this.displayValueMgdl,
  });

  final String payloadHex;
  final int? counter;
  final String? phaseHex;
  final List<int> glucoseTriplet;
  final List<int> qualifiers;
  final double? displayValueMgdl;

  Map<String, Object?> toJson() => <String, Object?>{
    'payloadHex': payloadHex,
    'counter': counter,
    'phaseHex': phaseHex,
    'glucoseTriplet': glucoseTriplet,
    'qualifiers': qualifiers,
    'displayValueMgdl': displayValueMgdl,
  };

  factory CgmAdvertisement.fromJson(Map<String, Object?> json) {
    return CgmAdvertisement(
      payloadHex: json['payloadHex'] as String? ?? '',
      counter: json['counter'] as int?,
      phaseHex: json['phaseHex'] as String?,
      glucoseTriplet: ((json['glucoseTriplet'] as List<dynamic>?) ?? const [])
          .whereType<num>()
          .map((value) => value.toInt())
          .toList(growable: false),
      qualifiers: ((json['qualifiers'] as List<dynamic>?) ?? const [])
          .whereType<num>()
          .map((value) => value.toInt())
          .toList(growable: false),
      displayValueMgdl: (json['displayValueMgdl'] as num?)?.toDouble(),
    );
  }
}

class DiscoveredSensor {
  const DiscoveredSensor({
    required this.driverId,
    required this.deviceId,
    required this.displayName,
    required this.storageKey,
    required this.rssi,
    required this.capabilities,
    this.advertisement,
    this.notes,
    this.metadata = const <String, String>{},
  });

  final String driverId;
  final String deviceId;
  final String displayName;
  final String storageKey;
  final int rssi;
  final CgmCapabilities capabilities;
  final CgmAdvertisement? advertisement;
  final String? notes;
  final Map<String, String> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'driverId': driverId,
    'deviceId': deviceId,
    'displayName': displayName,
    'storageKey': storageKey,
    'rssi': rssi,
    'capabilities': <String, Object?>{
      'supportsDirectBle': capabilities.supportsDirectBle,
      'supportsVendorPairing': capabilities.supportsVendorPairing,
      'supportsAdvertisementGlucose': capabilities.supportsAdvertisementGlucose,
      'supportsHistory': capabilities.supportsHistory,
      'supportsRawHistory': capabilities.supportsRawHistory,
      'supportsCalibration': capabilities.supportsCalibration,
      'supportsDiagnostics': capabilities.supportsDiagnostics,
      'supportsUnsafeAdmin': capabilities.supportsUnsafeAdmin,
      'supportsCommunicationInterval':
          capabilities.supportsCommunicationInterval,
      'supportsAutoUpdateControl': capabilities.supportsAutoUpdateControl,
    },
    'advertisement': advertisement?.toJson(),
    'notes': notes,
    'metadata': metadata,
  };

  factory DiscoveredSensor.fromJson(Map<String, Object?> json) {
    final capabilitiesJson =
        json['capabilities'] as Map<String, Object?>? ?? const {};
    return DiscoveredSensor(
      driverId: json['driverId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      storageKey: json['storageKey'] as String? ?? '',
      rssi: (json['rssi'] as num?)?.toInt() ?? 0,
      capabilities: CgmCapabilities(
        supportsDirectBle:
            capabilitiesJson['supportsDirectBle'] as bool? ?? false,
        supportsVendorPairing:
            capabilitiesJson['supportsVendorPairing'] as bool? ?? false,
        supportsAdvertisementGlucose:
            capabilitiesJson['supportsAdvertisementGlucose'] as bool? ?? false,
        supportsHistory: capabilitiesJson['supportsHistory'] as bool? ?? false,
        supportsRawHistory:
            capabilitiesJson['supportsRawHistory'] as bool? ?? false,
        supportsCalibration:
            capabilitiesJson['supportsCalibration'] as bool? ?? false,
        supportsDiagnostics:
            capabilitiesJson['supportsDiagnostics'] as bool? ?? false,
        supportsUnsafeAdmin:
            capabilitiesJson['supportsUnsafeAdmin'] as bool? ?? false,
        supportsCommunicationInterval:
            capabilitiesJson['supportsCommunicationInterval'] as bool? ?? false,
        supportsAutoUpdateControl:
            capabilitiesJson['supportsAutoUpdateControl'] as bool? ?? false,
      ),
      advertisement: switch (json['advertisement']) {
        final Map<String, Object?> value => CgmAdvertisement.fromJson(value),
        _ => null,
      },
      notes: json['notes'] as String?,
      metadata: ((json['metadata'] as Map?) ?? const {}).map(
        (key, value) => MapEntry('$key', '$value'),
      ),
    );
  }
}

class CgmReading implements TimelineEntry {
  const CgmReading({
    required this.valueMgdl,
    required this.source,
    this.sensorMinute,
    this.recordedAt,
    this.rawValue,
    this.qualifier,
    this.isDisplayProvisional = false,
  });

  final double valueMgdl;
  final CgmRecordSource source;
  final int? sensorMinute;
  final DateTime? recordedAt;
  final int? rawValue;
  final int? qualifier;
  final bool isDisplayProvisional;

  /// Position on the shared health timeline.
  ///
  /// Uses [recordedAt] when known; readings without a wall-clock time (e.g.
  /// raw history not yet anchored to a session start) fall back to the Unix
  /// epoch so they sort before timestamped data rather than throwing.
  @override
  DateTime get timelineTimestamp =>
      recordedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.cgmReading;

  CgmReading copyWith({
    double? valueMgdl,
    CgmRecordSource? source,
    int? sensorMinute,
    DateTime? recordedAt,
    int? rawValue,
    int? qualifier,
    bool? isDisplayProvisional,
  }) {
    return CgmReading(
      valueMgdl: valueMgdl ?? this.valueMgdl,
      source: source ?? this.source,
      sensorMinute: sensorMinute ?? this.sensorMinute,
      recordedAt: recordedAt ?? this.recordedAt,
      rawValue: rawValue ?? this.rawValue,
      qualifier: qualifier ?? this.qualifier,
      isDisplayProvisional: isDisplayProvisional ?? this.isDisplayProvisional,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'valueMgdl': valueMgdl,
    'source': source.name,
    'sensorMinute': sensorMinute,
    'recordedAt': recordedAt?.toIso8601String(),
    'rawValue': rawValue,
    'qualifier': qualifier,
    'isDisplayProvisional': isDisplayProvisional,
  };

  factory CgmReading.fromJson(Map<String, Object?> json) {
    return CgmReading(
      valueMgdl: (json['valueMgdl'] as num?)?.toDouble() ?? 0,
      source: CgmRecordSource.values.byName(
        json['source'] as String? ?? CgmRecordSource.vendor.name,
      ),
      sensorMinute: (json['sensorMinute'] as num?)?.toInt(),
      recordedAt: switch (json['recordedAt']) {
        final String value when value.isNotEmpty => DateTime.tryParse(value),
        _ => null,
      },
      rawValue: (json['rawValue'] as num?)?.toInt(),
      qualifier: (json['qualifier'] as num?)?.toInt(),
      isDisplayProvisional: json['isDisplayProvisional'] as bool? ?? false,
    );
  }
}

class CgmSessionInfo {
  const CgmSessionInfo({
    this.manufacturer = '',
    this.model = '',
    this.serial = '',
    this.firmware = '',
    this.sessionStart,
    this.sessionStartPayloadHex = '',
    this.elapsedMinutes,
    this.sessionStopped = false,
    this.warmupMinutes = 60,
  });

  final String manufacturer;
  final String model;
  final String serial;
  final String firmware;
  final DateTime? sessionStart;
  final String sessionStartPayloadHex;
  final int? elapsedMinutes;
  final bool sessionStopped;
  final int warmupMinutes;

  CgmSessionInfo copyWith({
    String? manufacturer,
    String? model,
    String? serial,
    String? firmware,
    DateTime? sessionStart,
    String? sessionStartPayloadHex,
    int? elapsedMinutes,
    bool? sessionStopped,
    int? warmupMinutes,
  }) {
    return CgmSessionInfo(
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      serial: serial ?? this.serial,
      firmware: firmware ?? this.firmware,
      sessionStart: sessionStart ?? this.sessionStart,
      sessionStartPayloadHex:
          sessionStartPayloadHex ?? this.sessionStartPayloadHex,
      elapsedMinutes: elapsedMinutes ?? this.elapsedMinutes,
      sessionStopped: sessionStopped ?? this.sessionStopped,
      warmupMinutes: warmupMinutes ?? this.warmupMinutes,
    );
  }
}

class CgmHealthSnapshot {
  const CgmHealthSnapshot({
    this.statusText = '',
    this.batteryLow = false,
    this.expired = false,
    this.error = false,
    this.malfunction = false,
    this.signalLost = false,
    this.warningFlagsHex = '',
    this.sensorCheckHex = '',
  });

  final String statusText;
  final bool batteryLow;
  final bool expired;
  final bool error;
  final bool malfunction;
  final bool signalLost;
  final String warningFlagsHex;
  final String sensorCheckHex;

  CgmHealthSnapshot copyWith({
    String? statusText,
    bool? batteryLow,
    bool? expired,
    bool? error,
    bool? malfunction,
    bool? signalLost,
    String? warningFlagsHex,
    String? sensorCheckHex,
  }) {
    return CgmHealthSnapshot(
      statusText: statusText ?? this.statusText,
      batteryLow: batteryLow ?? this.batteryLow,
      expired: expired ?? this.expired,
      error: error ?? this.error,
      malfunction: malfunction ?? this.malfunction,
      signalLost: signalLost ?? this.signalLost,
      warningFlagsHex: warningFlagsHex ?? this.warningFlagsHex,
      sensorCheckHex: sensorCheckHex ?? this.sensorCheckHex,
    );
  }
}

class CgmHistorySyncState {
  const CgmHistorySyncState({
    this.inProgress = false,
    this.storedCount = 0,
    this.totalAvailable = 0,
    this.latestStoredOffset,
    this.startIndex,
    this.targetIndex,
    this.lastSyncAt,
  });

  final bool inProgress;
  final int storedCount;
  final int totalAvailable;
  final int? latestStoredOffset;
  final int? startIndex;
  final int? targetIndex;
  final DateTime? lastSyncAt;

  bool get isComplete {
    return !inProgress &&
        totalAvailable > 0 &&
        storedCount >= totalAvailable &&
        latestStoredOffset != null;
  }

  CgmHistorySyncState copyWith({
    bool? inProgress,
    int? storedCount,
    int? totalAvailable,
    int? latestStoredOffset,
    int? startIndex,
    int? targetIndex,
    DateTime? lastSyncAt,
  }) {
    return CgmHistorySyncState(
      inProgress: inProgress ?? this.inProgress,
      storedCount: storedCount ?? this.storedCount,
      totalAvailable: totalAvailable ?? this.totalAvailable,
      latestStoredOffset: latestStoredOffset ?? this.latestStoredOffset,
      startIndex: startIndex ?? this.startIndex,
      targetIndex: targetIndex ?? this.targetIndex,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }
}

class CgmCalibrationEntry {
  const CgmCalibrationEntry({
    required this.index,
    this.glucoseMgdl,
    this.sensorMinute,
    this.recordedAt,
    this.payloadHex = '',
  });

  final int index;
  final int? glucoseMgdl;
  final int? sensorMinute;
  final DateTime? recordedAt;
  final String payloadHex;
}

class CgmDiagnosticItem {
  const CgmDiagnosticItem({
    required this.key,
    required this.title,
    this.summary = '',
    this.rawHex = '',
    this.fields = const <String, String>{},
  });

  final String key;
  final String title;
  final String summary;
  final String rawHex;
  final Map<String, String> fields;
}

class CgmLogEntry {
  const CgmLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final CgmLogLevel level;
  final String message;
}

class CgmSessionSnapshot {
  const CgmSessionSnapshot({
    required this.stage,
    required this.statusText,
    required this.sensor,
    required this.capabilities,
    this.latestReading,
    this.lastAdvertisement,
    this.history = const <CgmReading>[],
    this.rawHistory = const <CgmReading>[],
    this.calibrations = const <CgmCalibrationEntry>[],
    this.diagnostics = const <CgmDiagnosticItem>[],
    this.sessionInfo = const CgmSessionInfo(),
    this.health = const CgmHealthSnapshot(),
    this.historySync = const CgmHistorySyncState(),
    this.metadata = const <String, String>{},
    this.lastError,
  });

  final CgmSyncStage stage;
  final String statusText;
  final DiscoveredSensor sensor;
  final CgmCapabilities capabilities;
  final CgmReading? latestReading;
  final CgmAdvertisement? lastAdvertisement;
  final List<CgmReading> history;
  final List<CgmReading> rawHistory;
  final List<CgmCalibrationEntry> calibrations;
  final List<CgmDiagnosticItem> diagnostics;
  final CgmSessionInfo sessionInfo;
  final CgmHealthSnapshot health;
  final CgmHistorySyncState historySync;
  final Map<String, String> metadata;
  final String? lastError;

  CgmSessionSnapshot copyWith({
    CgmSyncStage? stage,
    String? statusText,
    DiscoveredSensor? sensor,
    CgmCapabilities? capabilities,
    CgmReading? latestReading,
    CgmAdvertisement? lastAdvertisement,
    List<CgmReading>? history,
    List<CgmReading>? rawHistory,
    List<CgmCalibrationEntry>? calibrations,
    List<CgmDiagnosticItem>? diagnostics,
    CgmSessionInfo? sessionInfo,
    CgmHealthSnapshot? health,
    CgmHistorySyncState? historySync,
    Map<String, String>? metadata,
    String? lastError,
    bool clearLastError = false,
  }) {
    return CgmSessionSnapshot(
      stage: stage ?? this.stage,
      statusText: statusText ?? this.statusText,
      sensor: sensor ?? this.sensor,
      capabilities: capabilities ?? this.capabilities,
      latestReading: latestReading ?? this.latestReading,
      lastAdvertisement: lastAdvertisement ?? this.lastAdvertisement,
      history: history ?? this.history,
      rawHistory: rawHistory ?? this.rawHistory,
      calibrations: calibrations ?? this.calibrations,
      diagnostics: diagnostics ?? this.diagnostics,
      sessionInfo: sessionInfo ?? this.sessionInfo,
      health: health ?? this.health,
      historySync: historySync ?? this.historySync,
      metadata: metadata ?? this.metadata,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }
}

String prettyJson(Object? value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}
