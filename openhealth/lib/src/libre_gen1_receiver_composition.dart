import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';

import 'app_controller.dart';
import 'cgm_driver_registry.dart';
import 'libre_gen1_fresh_nfc_history.dart';
import 'libre_gen1_receiver_history_platform.dart';
import 'libre_gen1_receiver_store.dart';
import 'libre_gen1_receiver_transport.dart';
import 'libre_nfc_history_sync.dart';
import 'libre_nfc_history_tools.dart';
import 'sensor_connection_policy.dart';
import 'sensor_history_repository.dart';

/// Private Android validation of an existing receiver, without a recorder.
/// Native capability supplies the opt-in gate. Only the explicit private entry
/// can inject a decoder; normal main supplies none. This never enrolls a sensor.
final class LibreGen1ReceiverComposition {
  LibreGen1ReceiverComposition._(
    BleTransport transport,
    LibreGen1ReceiverStore store,
    LibreGen1ObservationStore observationStore,
    LibreGen1GlucoseDecoderProvider? decoderProvider,
  ) : _store = store,
      _decoderProvider = decoderProvider,
      driver = LibreGen1Driver(
        transport: LibreGen1ReceiverTransport(
          delegate: transport,
          store: store,
        ),
        bootstrapProvider: store,
        counterStore: store,
        glucoseDecoderProvider: decoderProvider,
        observationStore: observationStore,
        requireDurableObservations: true,
      );

  final LibreGen1Driver driver;
  final LibreGen1ReceiverStore _store;
  final LibreGen1GlucoseDecoderProvider? _decoderProvider;

  static Future<LibreGen1ReceiverComposition?> tryCreate({
    required BleTransport transport,
    required bool validationEnabled,
    required LibreGen1ObservationStore observationStore,
    LibreGen1ReceiverStore? store,
    LibreGen1GlucoseDecoderProvider? decoderProvider,
    bool requireAvailable = false,
    @visibleForTesting Duration capabilityTimeout = const Duration(seconds: 3),
  }) async {
    if (!validationEnabled ||
        !kDebugMode ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      if (requireAvailable) _unavailable();
      return null;
    }
    final receiverStore = store ?? LibreGen1ReceiverStore();
    try {
      // This read grants no RF ownership. A missing, malformed or late reply
      // must not prevent the existing AiDEX registry from being constructed.
      if (!await receiverStore.isAvailable().timeout(
        capabilityTimeout,
        onTimeout: () => false,
      )) {
        if (requireAvailable) _unavailable();
        return null;
      }
      return LibreGen1ReceiverComposition._(
        transport,
        receiverStore,
        observationStore,
        decoderProvider,
      );
    } catch (_) {
      if (requireAvailable) _unavailable();
      return null;
    }
  }

  CgmDriverRegistration get registration => CgmDriverRegistration(
    driver: driver,
    scanServiceUuids: LibreGen1Driver.scanServiceUuids,
    discover: driver.mapScanResult,
    connectionPolicy: SensorConnectionPolicy.externalSetupOnly,
    prepareDiscovery: () async {
      await driver.reloadBootstrap();
    },
  );

  /// Restricted storage read only. Explicit Connect still needs a fresh exact
  /// advertisement, native receiver lease and durable login counter.
  Future<DiscoveredSensor?> prepareConnection() async {
    if (!await driver.reloadBootstrap()) return null;
    return driver.bootstrappedSensor;
  }

  /// Tool creation is lazy: no bootstrap read, platform probe, scan, or decoder
  /// call occurs until the user starts an attempt. Each attempt owns its platform.
  LibreNfcHistoryTools? createHistoryTools({
    required CgmAppController controller,
    required SensorHistoryRepository repository,
    @visibleForTesting
    LibreGen1ReceiverHistoryPlatform Function()? historyPlatformFactory,
  }) {
    final decoder = _decoderProvider;
    if (decoder == null || decoder is! LibreGen1NfcHistoryDecoder) return null;
    final historyDecoder = decoder as LibreGen1NfcHistoryDecoder;
    return LibreNfcHistoryTools(
      readBootstrap: _store.readBootstrap,
      resumeConnection: controller.resumeLibreHistoryConnection,
      createSync: () {
        final platform =
            historyPlatformFactory?.call() ??
            LibreGen1ReceiverHistoryPlatform();
        try {
          // The bound read session owns platform disposal. Before that session
          // is made, the platform/reader have no listeners, timers or native I/O.
          return LibreNfcHistorySync(
            controller: controller,
            repository: repository,
            sessionFactory: platform.createReadSession,
            reader: platform.createFreshReader(),
            decoder: historyDecoder,
          );
        } catch (_) {
          platform.dispose();
          rethrow;
        }
      },
    );
  }

  static Never _unavailable() => throw StateError(
    'Private Libre receiver capability is unavailable.',
  );
}
