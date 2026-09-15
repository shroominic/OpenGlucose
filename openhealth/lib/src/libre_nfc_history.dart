import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

/// Acquisition evidence is separate from the value's source/quality fields.
enum LibreHistoryOrigin {
  legacyUnknown,
  bleLive,
  nfcTrend,
  nfcHistory,
  bleTrend,
  bleHistory,
}

enum LibreHistoryTimestampBasis { legacyUnknown, phoneReceipt, sensorRelative }

final class LibreHistoryEntry {
  const LibreHistoryEntry({
    required this.reading,
    required this.origin,
    required this.firstReceivedAt,
    required this.timestampBasis,
  });

  final CgmReading reading;
  final LibreHistoryOrigin origin;
  final DateTime? firstReceivedAt;
  final LibreHistoryTimestampBasis timestampBasis;

  @override
  String toString() => 'LibreHistoryEntry(data: <redacted>)';
}

/// A decoded historical sample, never evidence of live glucose freshness.
/// Only NFC origins and provisional vendor values are admitted by the store.
final class LibreNfcHistorySample {
  const LibreNfcHistorySample({
    required this.reading,
    required this.firstReceivedAt,
    required this.origin,
  });

  final CgmReading reading;
  final DateTime firstReceivedAt;
  final LibreHistoryOrigin origin;

  @override
  String toString() => 'LibreNfcHistorySample(data: <redacted>)';
}

/// Obtain this opaque, single-use authority before starting a fresh NFC read.
/// Caller-created implementations are not accepted by a repository.
abstract interface class LibreNfcHistoryImportTicket {}

final class LibreNfcHistoryImportResult {
  const LibreNfcHistoryImportResult({
    required this.importedReadingCount,
    required this.state,
  });

  final int importedReadingCount;
  final LibreGen1ObservationState state;

  @override
  String toString() => 'LibreNfcHistoryImportResult(data: <redacted>)';
}
