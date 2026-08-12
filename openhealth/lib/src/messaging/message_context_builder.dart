import '../app_controller.dart';
import '../session_presentation.dart';
import 'message_context.dart';

/// Bridges the live [CgmAppController] into a pure [MessageContext] for the
/// messaging engine. Kept separate from [CgmAppController] so the messaging
/// subsystem stays a clean, optional add-on that other branches don't have to
/// reason about.
MessageContext buildMessageContext(
  CgmAppController controller, {
  DateTime? now,
}) {
  final snapshot = controller.snapshot;
  final hasSession = snapshot != null;
  final latest = controller.latestReading;
  final warmup = snapshot == null
      ? null
      : computeWarmupStatus(snapshot, latestReading: latest, now: now);
  return MessageContext(
    hasSession: hasSession,
    isWarmingUp: warmup?.phase == WarmupPhase.warming,
    hasReadings: latest != null,
    now: now ?? DateTime.now(),
  );
}
