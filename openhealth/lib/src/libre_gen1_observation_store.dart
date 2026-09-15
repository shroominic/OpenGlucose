import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'sensor_history_repository.dart';

/// The receiver and app controller share one repository mutation queue.
/// This adapter owns no second cache, queue, preference key, or sensor action.
final class LibreGen1HistoryObservationStore
    implements LibreGen1ObservationStore {
  const LibreGen1HistoryObservationStore(this.repository);

  final SensorHistoryRepository repository;

  @override
  Future<LibreGen1ObservationState> load(LibreGen1ObservationBinding binding) =>
      repository.loadLibre(binding);

  @override
  Future<LibreGen1ObservationCommit> commit(
    LibreGen1ObservationBinding binding, {
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings = const [],
  }) => repository.commitLibre(
    binding,
    sensorMinute: sensorMinute,
    receivedAt: receivedAt,
    reading: reading,
    historicalReadings: historicalReadings,
  );
}
