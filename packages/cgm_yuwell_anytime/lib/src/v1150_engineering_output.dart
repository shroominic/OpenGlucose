import 'package:cgm_core/cgm_core.dart';

import 'commands.dart';
import 'history_record.dart';
import 'session_security.dart';

/// Controls whether target-unverified V1150 values may reach the engineering
/// UI as explicitly provisional readings.
///
/// Production callers must use [disabled]. The engineering mode does not
/// establish clinical or publication equivalence with the official output.
enum YuwellV1150GlucoseOutputPolicy { disabled, engineeringProvisional }

/// A fail-closed projector for the transmitter-computed field in V1150
/// alternate records.
///
/// This projector deliberately requires a contiguous prefix beginning at
/// index zero. It does not reconstruct the vendor's stateful native algorithm.
/// The returned reading is always marked provisional.
final class YuwellV1150EngineeringOutput {
  YuwellV1150EngineeringOutput({
    this.policy = YuwellV1150GlucoseOutputPolicy.disabled,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const String supportedFirmware = 'V1150';
  static const int firstDisplayIndex = 14;
  static const int maximumIndex = 7694;
  static const int minimumPlausibleGlucoseMgDl = 20;
  static const int maximumPlausibleGlucoseMgDl = 600;
  static const Duration initializationClockOffset = Duration(seconds: 3);
  static const Duration sampleInterval = Duration(minutes: 3);

  final YuwellV1150GlucoseOutputPolicy policy;
  final DateTime Function() _clock;
  final Set<int> _pendingHistoryIndexes = <int>{};
  int _contiguousThrough = -1;
  bool _historyProofEstablished = false;

  /// Advances prefix proof for authenticated 0x47 history slots.
  ///
  /// [consumedSlots] includes parsed records and all-FF empty slots. An FC
  /// terminator is not consumed by [YuwellHistoryFrame] and must not be
  /// included. Publication still requires an active credential phase in
  /// [observe].
  void observeHistorySlots({
    required String firmware,
    required bool transmitterComputed,
    required YuwellCredentialPhase credentialPhase,
    required int opcode,
    required YuwellHistoryRecordLayout? layout,
    required int startIndex,
    required int consumedSlots,
    required DateTime? activationStartedAt,
    required int initializationIndex,
  }) {
    // Initialization recovery can prove slot continuity after activation was
    // prepared and while low power is pending. This never authorizes output:
    // [observe] still requires the durable active phase for every reading.
    final proofPhaseAllowed =
        credentialPhase == YuwellCredentialPhase.activationPrepared ||
        credentialPhase == YuwellCredentialPhase.lowPowerPending ||
        credentialPhase == YuwellCredentialPhase.active;
    if (policy != YuwellV1150GlucoseOutputPolicy.engineeringProvisional ||
        firmware != supportedFirmware ||
        !transmitterComputed ||
        !proofPhaseAllowed ||
        opcode != YuwellCt5Commands.alternateHistoryCommand ||
        layout != YuwellHistoryRecordLayout.alert17 ||
        activationStartedAt == null ||
        initializationIndex != 15 ||
        startIndex < 0 ||
        consumedSlots <= 0 ||
        startIndex > maximumIndex ||
        consumedSlots > maximumIndex - startIndex + 1) {
      return;
    }

    for (var index = startIndex; index < startIndex + consumedSlots; index++) {
      _observeHistoryIndex(index);
    }
  }

  /// Records one authenticated alternate-path observation and returns a
  /// provisional display reading only when every engineering gate passes.
  CgmReading? observe({
    required String firmware,
    required bool transmitterComputed,
    required YuwellCredentialPhase credentialPhase,
    required int opcode,
    required int index,
    required YuwellHistoryRecord record,
    required DateTime? activationStartedAt,
    required int initializationIndex,
  }) {
    if (policy != YuwellV1150GlucoseOutputPolicy.engineeringProvisional ||
        firmware != supportedFirmware ||
        !transmitterComputed ||
        credentialPhase != YuwellCredentialPhase.active ||
        (opcode != YuwellCt5Commands.alternateLiveCommand &&
            opcode != YuwellCt5Commands.alternateHistoryCommand) ||
        record.layout != YuwellHistoryRecordLayout.alert17 ||
        activationStartedAt == null ||
        initializationIndex != 15 ||
        index < 0 ||
        index > maximumIndex) {
      return null;
    }

    if (opcode == YuwellCt5Commands.alternateLiveCommand &&
        index > _contiguousThrough) {
      // A live notification may extend an already proven prefix by exactly
      // one slot. A gapped/high notification is ignored rather than retained,
      // so later history cannot retroactively turn it into prefix proof.
      if (!_historyProofEstablished || index != _contiguousThrough + 1) {
        return null;
      }
      _contiguousThrough = index;
    }
    if (index > _contiguousThrough || index < firstDisplayIndex) {
      return null;
    }

    // Only the no-error and explicit warmup-complete statuses are reviewed
    // for this engineering path. Unknown and lifecycle-ending statuses fail
    // closed even when the packed value is non-zero.
    if (record.errorCode != 0 && record.errorCode != 4) {
      return null;
    }
    final glucose = record.glucoseMgDl;
    if (glucose < minimumPlausibleGlucoseMgDl ||
        glucose > maximumPlausibleGlucoseMgDl) {
      return null;
    }

    final sensorMinute = (index + 1) * sampleInterval.inMinutes;
    final recordedAt = activationStartedAt
        .toUtc()
        .add(initializationClockOffset)
        .add(Duration(minutes: sensorMinute));
    if (recordedAt.isAfter(_clock().toUtc())) {
      return null;
    }

    return CgmReading(
      valueMgdl: glucose.toDouble(),
      source: CgmRecordSource.vendor,
      sensorMinute: sensorMinute,
      recordedAt: recordedAt,
      rawValue: glucose,
      qualifier: record.errorCode,
      isDisplayProvisional: true,
    );
  }

  void _observeHistoryIndex(int index) {
    if (index <= _contiguousThrough) return;
    _pendingHistoryIndexes.add(index);
    while (_pendingHistoryIndexes.remove(_contiguousThrough + 1)) {
      _contiguousThrough++;
      _historyProofEstablished = true;
    }
  }
}
