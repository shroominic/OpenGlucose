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
  final latest = controller.displayLatestReading;
  final warmup = snapshot == null
      ? null
      : computeWarmupStatus(snapshot, latestReading: latest, now: now);
  return MessageContext(
    hasSession: hasSession,
    isWarmingUp: warmup?.phase == WarmupPhase.warming,
    // CBIO raw records do not populate a glucose chart. They must not enable
    // glucose-reading tips merely because a raw diagnostic value is visible.
    hasReadings:
        latest != null && snapshot != null && !isCbioSnapshot(snapshot),
    now: now ?? DateTime.now(),
  );
}
