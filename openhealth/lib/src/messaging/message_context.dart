import 'package:flutter/foundation.dart';

/// An immutable, side-effect-free snapshot of the app state that message
/// triggers are allowed to read.
///
/// Keeping triggers dependent only on this (rather than on the whole
/// [CgmAppController]) makes message selection a pure function — trivial to
/// unit-test and impossible to accidentally mutate. The controller builds one
/// of these from the live session on every change; tips/info-boxes added later
/// just add fields here if they need new signals.
@immutable
class MessageContext {
  const MessageContext({
    required this.hasSession,
    required this.isWarmingUp,
    required this.hasReadings,
    required this.now,
  });

  /// A sensor session is selected/connected (i.e. the dashboard is showing,
  /// not the scan screen).
  final bool hasSession;

  /// The sensor is inside its warmup window (no trustworthy readings yet).
  final bool isWarmingUp;

  /// At least one glucose reading is available to display.
  final bool hasReadings;

  /// Wall-clock time, injected so time-based triggers are testable.
  final DateTime now;

  MessageContext copyWith({
    bool? hasSession,
    bool? isWarmingUp,
    bool? hasReadings,
    DateTime? now,
  }) {
    return MessageContext(
      hasSession: hasSession ?? this.hasSession,
      isWarmingUp: isWarmingUp ?? this.isWarmingUp,
      hasReadings: hasReadings ?? this.hasReadings,
      now: now ?? this.now,
    );
  }
}
