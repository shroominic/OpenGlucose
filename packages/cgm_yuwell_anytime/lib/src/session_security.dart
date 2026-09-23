import 'dart:math' as math;

import 'package:cgm_core/cgm_core.dart';

import 'authentication.dart';
import 'calibration_code.dart';
import 'errors.dart';

final _verifiedFirmwarePattern = RegExp(r'^[A-Z][A-Z0-9._-]{0,31}$');
final _historyGenerationPattern = RegExp(r'^[0-9a-f]{32}$');

/// Closed activation phases safe to persist in a secure credential record.
enum YuwellCredentialPhase {
  identityPrepared,
  authenticated,
  configured,
  activationPrepared,
  lowPowerPending,
  active,
}

/// Session material that must be stored in a platform secure store.
///
/// Implementations must use Android Keystore, Apple Keychain, or an equivalent
/// hardware-backed store. This package deliberately supplies no file,
/// preferences, database, or plaintext implementation.
final class YuwellSessionCredentials {
  const YuwellSessionCredentials({
    required this.communicationIdentity,
    required this.cipher,
    required this.k,
    required this.r,
    required this.transmitterComputed,
    required this.phase,
    this.activationStartedAt,
    this.initializationIndex = 15,
    this.verifiedFirmware,
    this.historyGeneration,
  });

  final YuwellCommunicationIdentity communicationIdentity;
  final int? cipher;
  final double k;
  final double r;
  final bool transmitterComputed;
  final YuwellCredentialPhase phase;
  final DateTime? activationStartedAt;
  final int initializationIndex;
  final String? verifiedFirmware;
  final String? historyGeneration;

  bool get canRestoreHistory =>
      verifiedFirmware != null &&
      historyGeneration != null &&
      _verifiedFirmwarePattern.hasMatch(verifiedFirmware!) &&
      _historyGenerationPattern.hasMatch(historyGeneration!);

  YuwellSessionCredentials copyWith({
    double? k,
    double? r,
    bool? transmitterComputed,
    YuwellCredentialPhase? phase,
    DateTime? activationStartedAt,
    int? initializationIndex,
    String? verifiedFirmware,
    String? historyGeneration,
  }) {
    final nextFirmware = verifiedFirmware ?? this.verifiedFirmware;
    final nextGeneration = historyGeneration ?? this.historyGeneration;
    if ((nextFirmware == null) != (nextGeneration == null)) {
      throw const YuwellProtocolFormatException(
        'secure credential history identity is incomplete',
      );
    }
    return YuwellSessionCredentials(
      communicationIdentity: communicationIdentity,
      cipher: cipher,
      k: k ?? this.k,
      r: r ?? this.r,
      transmitterComputed: transmitterComputed ?? this.transmitterComputed,
      phase: phase ?? this.phase,
      activationStartedAt: activationStartedAt ?? this.activationStartedAt,
      initializationIndex: initializationIndex ?? this.initializationIndex,
      verifiedFirmware: nextFirmware,
      historyGeneration: nextGeneration,
    );
  }

  /// Produces a sensitive record for immediate encryption by a secure store.
  Map<String, Object?> serializeForSecureStorage() {
    final hasFirmware = verifiedFirmware != null;
    final hasGeneration = historyGeneration != null;
    if (hasFirmware != hasGeneration || (hasFirmware && !canRestoreHistory)) {
      throw const YuwellProtocolFormatException(
        'secure credential history identity is invalid',
      );
    }
    return <String, Object?>{
      'version': canRestoreHistory ? 2 : 1,
      'communicationIdentity': communicationIdentity
          .serializeForSecureStorage(),
      'cipher': cipher,
      'k': k,
      'r': r,
      'transmitterComputed': transmitterComputed,
      'phase': phase.name,
      'activationStartedAt': activationStartedAt?.toUtc().toIso8601String(),
      'initializationIndex': initializationIndex,
      if (canRestoreHistory) ...<String, Object?>{
        'verifiedFirmware': verifiedFirmware,
        'historyGeneration': historyGeneration,
      },
    };
  }

  factory YuwellSessionCredentials.restoreFromSecureStorage(
    Map<String, Object?> record,
  ) {
    final version = record['version'];
    final expectedKeys = version == 1
        ? _credentialV1Keys
        : version == 2
        ? _credentialV2Keys
        : const <String>{};
    if (expectedKeys.isEmpty ||
        record.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(record.keys.toSet()).isNotEmpty ||
        record['communicationIdentity'] is! String ||
        (record['cipher'] != null && record['cipher'] is! int) ||
        record['k'] is! num ||
        record['r'] is! num ||
        record['transmitterComputed'] is! bool ||
        record['phase'] is! String ||
        record['initializationIndex'] is! int) {
      throw const YuwellProtocolFormatException(
        'secure credential record has an unsupported shape',
      );
    }
    final verifiedFirmware = version == 2 ? record['verifiedFirmware'] : null;
    final historyGeneration = version == 2 ? record['historyGeneration'] : null;
    if (version == 2 &&
        (verifiedFirmware is! String ||
            historyGeneration is! String ||
            !_verifiedFirmwarePattern.hasMatch(verifiedFirmware) ||
            !_historyGenerationPattern.hasMatch(historyGeneration))) {
      throw const YuwellProtocolFormatException(
        'secure credential history identity is invalid',
      );
    }
    final cipher = record['cipher'] as int?;
    final initializationIndex = record['initializationIndex']! as int;
    if ((cipher != null && (cipher < 0 || cipher > 0xff)) ||
        initializationIndex < 0 ||
        initializationIndex > 0xff) {
      throw const YuwellProtocolFormatException(
        'secure credential record contains an out-of-range value',
      );
    }
    final phaseName = record['phase']! as String;
    final phase = YuwellCredentialPhase.values
        .where((value) => value.name == phaseName)
        .firstOrNull;
    if (phase == null) {
      throw const YuwellProtocolFormatException(
        'secure credential record contains an unknown phase',
      );
    }
    if (phase == YuwellCredentialPhase.identityPrepared && cipher != null) {
      throw const YuwellProtocolFormatException(
        'prepared identity cannot contain a session cipher',
      );
    }
    if (phase != YuwellCredentialPhase.identityPrepared && cipher == null) {
      throw const YuwellProtocolFormatException(
        'authenticated credentials require a session cipher',
      );
    }
    final activationValue = record['activationStartedAt'];
    final activationStartedAt = switch (activationValue) {
      null => null,
      final String value => DateTime.tryParse(value)?.toUtc(),
      _ => null,
    };
    if (activationValue != null && activationStartedAt == null) {
      throw const YuwellProtocolFormatException(
        'secure credential record contains an invalid activation time',
      );
    }
    final k = (record['k']! as num).toDouble();
    final r = (record['r']! as num).toDouble();
    if (!k.isFinite || !r.isFinite || k < 0 || k >= 256 || r < 0 || r >= 256) {
      throw const YuwellProtocolFormatException(
        'secure credential record contains invalid coefficients',
      );
    }
    if ((phase == YuwellCredentialPhase.activationPrepared ||
            phase == YuwellCredentialPhase.lowPowerPending ||
            phase == YuwellCredentialPhase.active) &&
        activationStartedAt == null) {
      throw const YuwellProtocolFormatException(
        'activation credentials require an activation time',
      );
    }
    if (phase != YuwellCredentialPhase.activationPrepared &&
        phase != YuwellCredentialPhase.lowPowerPending &&
        phase != YuwellCredentialPhase.active &&
        activationStartedAt != null) {
      throw const YuwellProtocolFormatException(
        'inactive credentials cannot contain an activation time',
      );
    }
    return YuwellSessionCredentials(
      communicationIdentity: YuwellCommunicationIdentity.parse(
        record['communicationIdentity']! as String,
      ),
      cipher: cipher,
      k: k,
      r: r,
      transmitterComputed: record['transmitterComputed']! as bool,
      phase: phase,
      activationStartedAt: activationStartedAt,
      initializationIndex: initializationIndex,
      verifiedFirmware: verifiedFirmware as String?,
      historyGeneration: historyGeneration as String?,
    );
  }

  @override
  String toString() => 'YuwellSessionCredentials(<redacted>)';
}

const _credentialV1Keys = <String>{
  'version',
  'communicationIdentity',
  'cipher',
  'k',
  'r',
  'transmitterComputed',
  'phase',
  'activationStartedAt',
  'initializationIndex',
};

const _credentialV2Keys = <String>{
  ..._credentialV1Keys,
  'verifiedFirmware',
  'historyGeneration',
};

abstract interface class YuwellHistoryGenerationGenerator {
  String generate();
}

final class YuwellSecureHistoryGenerationGenerator
    implements YuwellHistoryGenerationGenerator {
  YuwellSecureHistoryGenerationGenerator({math.Random? random})
    : _random = random ?? math.Random.secure();

  final math.Random _random;

  @override
  String generate() => List<String>.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

abstract interface class YuwellCredentialStore {
  Future<YuwellSessionCredentials?> read(String storageKey);

  Future<void> write(String storageKey, YuwellSessionCredentials credentials);

  Future<void> delete(String storageKey);
}

/// A one-shot UI authorization gate for a fresh, state-changing activation.
///
/// The gate must consume an authorization created by a user interaction. It
/// must not return true merely because a preference was set previously.
abstract interface class YuwellActivationGate {
  Future<bool> consumeAuthorization(DiscoveredSensor sensor);
}

/// Result of decoding the transformed sensor-code response.
///
/// Implementations may use a separately reviewed clean-room decoder. They
/// must not load a library extracted from the vendor APK.
final class YuwellActivationParameters {
  const YuwellActivationParameters({
    required this.k,
    required this.r,
    required this.transmitterComputed,
    this.initializationIndex = 15,
  });

  final double k;
  final double r;
  final bool transmitterComputed;
  final int initializationIndex;

  @override
  String toString() => 'YuwellActivationParameters(<redacted>)';
}

abstract interface class YuwellSensorCodeDecoder {
  Future<YuwellActivationParameters> decode(List<int> decodedSensorCode);
}

/// Clean-room decoder for the reference CT5 calibration-code formats.
final class YuwellCt5SensorCodeDecoder implements YuwellSensorCodeDecoder {
  const YuwellCt5SensorCodeDecoder();

  @override
  Future<YuwellActivationParameters> decode(List<int> decodedSensorCode) async {
    if (decodedSensorCode.isEmpty ||
        decodedSensorCode.any((byte) => byte < 0x20 || byte > 0x7e)) {
      throw const YuwellProtocolFormatException(
        'decrypted calibration code is not printable ASCII',
      );
    }
    final decoded = YuwellCt5CalibrationCode.parse(
      String.fromCharCodes(decodedSensorCode),
    );
    if (decoded.lifeTimeCode != null && decoded.lifeTimeCode != 4) {
      throw const YuwellProtocolFormatException(
        'calibration code is not the reviewed 16-day branch',
      );
    }
    return YuwellActivationParameters(
      k: decoded.k,
      r: decoded.r,
      // The session independently proves this from firmware before it sends
      // the transmitter-computed initialization branch.
      transmitterComputed: true,
    );
  }
}

enum YuwellActivationWrite {
  setDate,
  setCommunicationId,
  configure,
  initialize,
  lowPower,
}

enum YuwellWriteIntentState { prepared, transmitted, unknown }

final class YuwellUnresolvedWriteIntent {
  const YuwellUnresolvedWriteIntent({
    required this.token,
    required this.operation,
    required this.state,
  });

  final String token;
  final YuwellActivationWrite operation;
  final YuwellWriteIntentState state;

  @override
  String toString() =>
      'YuwellUnresolvedWriteIntent(${operation.name}, ${state.name}, <redacted>)';
}

/// Durable journal for potentially persistent writes.
///
/// A prepared or unknown record must survive process death. A new activation
/// must stop when [hasUnresolved] returns true. Tokens are opaque and must not
/// contain a sensor ID, command bytes, credentials, or health data.
abstract interface class YuwellWriteIntentStore {
  Future<bool> hasUnresolved(String storageKey);

  Future<YuwellUnresolvedWriteIntent?> readUnresolved(String storageKey);

  Future<String> prepare(String storageKey, YuwellActivationWrite operation);

  /// Durably commits that a BLE write may occur.
  ///
  /// Callers must invoke this before entering the BLE stack. Thus [prepared]
  /// proves no write was attempted, while [transmitted] conservatively means
  /// the process can no longer distinguish before-write from after-write.
  Future<void> markTransmitted(String token);

  Future<void> markCompleted(String token);

  Future<void> markUnknown(String token);

  /// Cancels a prepared journal record when no BLE write was attempted.
  Future<void> cancelPrepared(String token);

  /// Clears an unresolved record only after reviewed read-only recovery.
  ///
  /// The operation and state must be copied from the exact snapshot used by the
  /// recovery proof. An intervening transition must conflict rather than clear
  /// a live write from the same token generation.
  Future<void> resolveRecovered(
    String token, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  });

  /// Atomically replaces a read-only-proven unresolved record with a fresh
  /// prepared retry record. The expected operation and state must come from the
  /// proven snapshot. A failed or conflicting commit must preserve the source.
  Future<String> replaceRecoveredWithPrepared(
    String token,
    String storageKey,
    YuwellActivationWrite operation, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  });
}

/// Generates an identity using an operating-system cryptographic RNG.
///
/// Generation is local and does not persist or log the value.
final class YuwellSecureIdentityGenerator {
  YuwellSecureIdentityGenerator({math.Random? random})
    : _random = random ?? math.Random.secure();

  final math.Random _random;

  YuwellCommunicationIdentity generate() {
    final value = List<int>.generate(12, (_) => _random.nextInt(10)).join();
    return YuwellCommunicationIdentity.parse(value);
  }
}
