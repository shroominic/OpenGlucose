import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'libre_nfc_history_sync.dart';

/// Optional composition for an explicitly requested, bound Libre history read.
/// Merely creating or showing these tools does not read storage or start RF.
/// Normal builds do not import a glucose decoder through this contract.
final class LibreNfcHistoryTools {
  const LibreNfcHistoryTools({
    required this.createSync,
    required this.readBootstrap,
    this.resumeConnection,
  });

  final LibreNfcHistorySyncController Function() createSync;
  final Future<LibreGen1StreamingBootstrap?> Function() readBootstrap;

  /// Resume the exact saved target after confirmed NFC disposal. A successful
  /// foreground sync may request this once as the final step of the user's
  /// action. Cancellation/failure requires an explicit retry. The controller
  /// must reject a changed target, cleanup quarantine, or an already-used pause.
  final Future<void> Function(DiscoveredSensor sensor)? resumeConnection;
}
