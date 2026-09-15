import 'dart:async';
import 'dart:io';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'debug_shared_scan_transport.dart';
import 'app_controller.dart';
import 'cgm_driver_registry.dart';
import 'demo_driver.dart';
import 'local_ble_trace_sink.dart';
import 'libre_gen1_receiver_composition.dart';
import 'libre_gen1_secure_store.dart';
import 'libre_gen1_fresh_nfc_history.dart';
import 'libre2_nfc_setup.dart';
import 'libre_nfc_history_sync.dart';
import 'libre_nfc_history_tools.dart';
import 'mock_scenarios.dart';
import 'protocol_capture_observation_driver.dart';
import 'protocol_capture_profile.dart';
import 'protocol_capture_status.dart';
import 'sensor_connection_policy.dart';
import 'sensor_history_repository.dart';
import 'yuwell_secure_session_store.dart';

/// When built with `--dart-define=OG_DEMO=true`, native/simulator builds use the
/// in-memory [DemoCgmDriver] instead of the real BLE driver, so the app can be
/// exercised in the iOS simulator (which has no Bluetooth). Defaults to false,
/// so production builds are unchanged and keep using the real Aidex driver.
const bool kOgDemo = bool.fromEnvironment('OG_DEMO', defaultValue: false);

/// Initial mock scenario for OG_DEMO builds, e.g.
/// `--dart-define=OG_SCENARIO=activeHigh`. Unknown/empty values fall back to
/// [MockScenario.activeNormal]. Ignored unless OG_DEMO is set. The scenario can
/// also be switched at runtime from the Developer settings tab.
const String kOgScenario = String.fromEnvironment('OG_SCENARIO');

/// Enables a sensitive, app-private BLE protocol trace in Android debug builds.
///
/// The flag is intentionally disabled by default and rejected in non-debug
/// builds. Raw captures must remain local and must never be attached to a
/// public issue or committed to the repository.
const bool kOgProtocolTrace = bool.fromEnvironment('OG_PROTOCOL_TRACE');

/// Keeps the reviewed AiDEX/LinX driver available in an explicitly requested
/// full-UI protocol-capture build.
///
/// The dedicated capture entry point does not set this flag and therefore
/// remains observation-only. Release builds reject protocol tracing before
/// this option can have any effect.
const bool kOgProtocolCaptureLiveAidex = bool.fromEnvironment(
  'OG_PROTOCOL_CAPTURE_LIVE_AIDEX',
);

/// Enables the reviewed Yuwell driver inside an Android debug trace build.
///
/// This does not weaken the driver's one-shot activation gate or durable
/// unknown-write journal. Raw BLE data stays in the app-private trace sink.
const bool kOgProtocolCaptureLiveYuwell = bool.fromEnvironment(
  'OG_PROTOCOL_CAPTURE_LIVE_YUWELL',
);

/// Enables only the NFC-bound Gen1 receiver in the private Android recorder.
const bool kOgProtocolCaptureLiveLibre = bool.fromEnvironment(
  'OG_PROTOCOL_CAPTURE_LIVE_LIBRE',
);

const String _canonicalAidexCgmServiceUuid =
    '0000181f-0000-1000-8000-00805f9b34fb';

const MethodChannel _protocolCaptureChannel = MethodChannel(
  'com.openglucose/protocol_capture',
);

LocalBleTraceSink? _protocolTraceSink;
RecordingBleTransport? _recordingProtocolDelegate;
FlutterBluePlusScanStartTracker? _protocolScanStartTracker;
DebugSharedScanTransport? _protocolTraceTransport;
ProtocolCaptureStatusPublisher? _protocolCaptureStatus;
AppLifecycleListener? _protocolCaptureLifecycle;
Future<void>? _protocolCaptureStopFuture;
bool _protocolCaptureActive = false;
String? _protocolCaptureProcessSessionId;
LibreGen1Driver? _protocolLibreDriver;
LibreGen1GlucoseDecoderProvider? _protocolLibreGlucoseDecoderProvider;
LibreGen1ReceiverComposition? _recorderFreeLibreReceiver;
LibreGen1ObservationStore? _libreObservationStore;
final _privateRecorderFreeDecoder =
    PrivateRecorderFreeLibreDecoderConfiguration();
bool _platformConfigurationStarted = false;

/// Optional private-bench injection. Normal main imports no decoder adapter.
/// This does not start capture, read calibration, or touch a sensor.
void configurePrivateLibreGlucoseDecoder(
  LibreGen1GlucoseDecoderProvider provider,
) {
  if (!platformLibreGen1StreamingEnabled || _protocolCaptureActive) {
    throw StateError('Libre decoder requires pre-start Android debug capture.');
  }
  _protocolLibreGlucoseDecoderProvider = provider;
}

/// Private entry only. No GPL adapter is imported through this provider seam.
/// Native capability is still required when the driver is later composed.
void configurePrivateRecorderFreeLibreGlucoseDecoder(
  LibreGen1GlucoseDecoderProvider provider,
) {
  _privateRecorderFreeDecoder.configure(
    provider,
    supported: kDebugMode && !kIsWeb && Platform.isAndroid,
    incompatibleMode:
        kOgDemo ||
        kOgProtocolTrace ||
        kOgProtocolCaptureLiveAidex ||
        kOgProtocolCaptureLiveYuwell ||
        kOgProtocolCaptureLiveLibre ||
        _protocolCaptureActive ||
        _protocolLibreGlucoseDecoderProvider != null,
    configurationStarted: _platformConfigurationStarted,
  );
}

/// Small per-process configuration state, separately testable without native
/// code or mutable platform overrides. It never starts a driver or reads data.
@visibleForTesting
final class PrivateRecorderFreeLibreDecoderConfiguration {
  LibreGen1GlucoseDecoderProvider? _provider;
  LibreGen1GlucoseDecoderProvider? get provider => _provider;

  void configure(
    LibreGen1GlucoseDecoderProvider provider, {
    required bool supported,
    required bool incompatibleMode,
    required bool configurationStarted,
  }) {
    if (!supported ||
        incompatibleMode ||
        configurationStarted ||
        _provider != null) {
      throw StateError(
        'Private Libre decoder requires pre-start recorder-free Android debug.',
      );
    }
    _provider = provider;
  }
}

bool get platformProtocolCaptureEnabled =>
    kOgProtocolTrace && kDebugMode && Platform.isAndroid;

bool get platformLibreGen1StreamingEnabled =>
    platformProtocolCaptureEnabled &&
    kOgProtocolCaptureLiveLibre &&
    selectedProtocolCaptureProfile() == ProtocolCaptureProfile.libre;

/// Saved-receiver restoration is not NFC streaming/enrollment authority.
bool get platformLibreGen1ReceiverRestoreEnabled =>
    platformLibreGen1StreamingEnabled || _recorderFreeLibreReceiver != null;

/// Only the explicit private entry can supply a fresh-history decoder. Normal
/// main supplies none; recorder-free history never falls back to captured files.
LibreNfcHistoryTools? createPlatformLibreNfcHistoryTools({
  required CgmAppController controller,
  required SensorHistoryRepository repository,
}) {
  final receiver = _recorderFreeLibreReceiver;
  if (!kOgProtocolTrace && receiver != null) {
    return receiver.createHistoryTools(
      controller: controller,
      repository: repository,
    );
  }
  final decoder = _protocolLibreGlucoseDecoderProvider;
  if (!platformLibreGen1StreamingEnabled ||
      !_protocolCaptureActive ||
      _protocolLibreDriver == null ||
      decoder == null ||
      decoder is! LibreGen1NfcHistoryDecoder) {
    return null;
  }
  return LibreNfcHistoryTools(
    readBootstrap: LibreGen1SecureStore().readBootstrap,
    resumeConnection: controller.resumeLibreHistoryConnection,
    createSync: () => LibreNfcHistorySync(
      controller: controller,
      repository: repository,
      session: PlatformLibre2NfcSetupSession(
        allowActivationProof: false,
        allowTerminalReadRevocation: true,
      ),
      reader: LibreGen1FreshNfcHistoryReader(),
      decoder: decoder as LibreGen1NfcHistoryDecoder,
    ),
  );
}

/// Select only the receiver returned by the completed NFC bootstrap. This
/// does not connect or write; the normal controller handles the explicit
/// connection and the driver reserves a durable login count before writing.
Future<DiscoveredSensor?> preparePlatformLibreGen1Connection() async {
  final receiver = _recorderFreeLibreReceiver;
  if (receiver != null && !kOgProtocolTrace) {
    return receiver.prepareConnection();
  }
  final driver = _protocolLibreDriver;
  if (!platformLibreGen1StreamingEnabled || driver == null) return null;
  if (!await driver.reloadBootstrap()) return null;
  return driver.bootstrappedSensor;
}

/// Suppresses the BLE plugin's native DEBUG default before any BLE operation.
/// Debug/profile development behavior remains available for local diagnosis;
/// distributable release builds fail closed if suppression cannot be applied.
Future<void> configurePlatformPrivacyDefaults() async {
  // Protocol-capture builds keep raw packets in the app-private trace sink.
  // Do not duplicate them into system logcat, where unrelated tooling can
  // retain or disclose them. The closed OGYW milestones remain available.
  if (kReleaseMode) {
    await disableFlutterBluePlusLogs();
  } else if (kOgProtocolTrace) {
    await disableFlutterBluePlusLogs();
  }
  _rejectIncompatibleDebugModes();
  if (!kOgProtocolTrace) return;
  if (!kDebugMode) {
    throw UnsupportedError('OG_PROTOCOL_TRACE requires a debug build.');
  }
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      'OG_PROTOCOL_TRACE currently supports Android debug builds only.',
    );
  }
  if (_protocolCaptureActive) {
    return;
  }
  // Resolve before starting native capture. An unknown profile must not leave
  // a partially initialized recorder behind.
  selectedProtocolCaptureProfile();
  _protocolCaptureStopFuture = null;
  final processSessionId = newProtocolCaptureProcessSessionId();
  await _protocolCaptureChannel.invokeMethod<void>(
    'startNfcCapture',
    <String, Object?>{'processSessionId': processSessionId},
  );
  _protocolCaptureProcessSessionId = processSessionId;
  _protocolCaptureActive = true;
  try {
    final transport = _sharedProtocolTransport();
    final status = _captureStatusPublisher();
    await status.start();
    await transport.start();
    _protocolCaptureLifecycle ??= AppLifecycleListener(
      onDetach: () {
        unawaited(
          stopPlatformProtocolCapture().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
      },
    );
  } catch (_) {
    await stopPlatformProtocolCapture();
    rethrow;
  }
}

/// Bind the same restricted history owner used by the controller before any
/// Libre driver is exposed. Privacy setup never creates a volatile receiver.
Future<void> configurePlatformSensorHistory(
  LibreGen1ObservationStore observationStore,
) async {
  _platformConfigurationStarted = true;
  if (_protocolLibreDriver != null || _recorderFreeLibreReceiver != null) {
    if (!identical(_libreObservationStore, observationStore)) {
      throw StateError('Sensor history is already bound to a driver.');
    }
    return;
  }
  _libreObservationStore = observationStore;
  if (!kOgProtocolTrace) {
    final receiver = await LibreGen1ReceiverComposition.tryCreate(
      transport: const FlutterBluePlusTransport(),
      validationEnabled: kDebugMode && Platform.isAndroid && !kOgDemo,
      observationStore: observationStore,
      decoderProvider: _privateRecorderFreeDecoder.provider,
      requireAvailable: _privateRecorderFreeDecoder.provider != null,
    );
    if (receiver != null) {
      // Suppress native logging before publishing a recorder-free RF path.
      await disableFlutterBluePlusLogs();
      _recorderFreeLibreReceiver = receiver;
    }
  }
}

CgmDriver buildPlatformDriver() {
  _platformConfigurationStarted = true;
  _rejectIncompatibleDebugModes();
  if (_privateRecorderFreeDecoder.provider != null &&
      _recorderFreeLibreReceiver == null) {
    throw StateError('Private Libre receiver must be configured before use.');
  }
  if (kOgDemo && kReleaseMode) {
    throw UnsupportedError('OG_DEMO is disabled in release builds.');
  }
  if (kOgDemo) {
    return DemoCgmDriver(initialScenario: MockScenario.fromId(kOgScenario));
  }
  if (kOgProtocolTrace) {
    if (!kDebugMode) {
      throw UnsupportedError('OG_PROTOCOL_TRACE requires a debug build.');
    }
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'OG_PROTOCOL_TRACE currently supports Android debug builds only.',
      );
    }
    if (!kOgProtocolCaptureLiveAidex &&
        !kOgProtocolCaptureLiveYuwell &&
        !kOgProtocolCaptureLiveLibre) {
      return const ProtocolCaptureObservationDriver();
    }
    return _buildCaptureRegistry(_sharedProtocolTransport());
  }
  return buildHardwareDriverRegistry(
    const FlutterBluePlusTransport(),
    libreReceiver: _recorderFreeLibreReceiver,
  );
}

/// One shared scan, with the optional separately gated receiver using its own
/// lifetime lease transport. This does not start NFC or enable a decoder.
CgmDriverRegistry buildHardwareDriverRegistry(
  BleTransport transport, {
  LibreGen1ReceiverComposition? libreReceiver,
}) {
  const aidexDiscovery = AidexDiscovery();
  return CgmDriverRegistry(
    transport: transport,
    registrations: <CgmDriverRegistration>[
      CgmDriverRegistration(
        driver: AidexSensorDriver(transport, discovery: aidexDiscovery),
        scanServiceUuids: AidexDiscovery.scanServiceUuids,
        discover: aidexDiscovery.mapScanResult,
        connectionPolicy: SensorConnectionPolicy.explicitConnect,
      ),
      if (libreReceiver != null) libreReceiver.registration,
    ],
  );
}

CgmDriver _buildCaptureRegistry(BleTransport transport) {
  final registrations = <CgmDriverRegistration>[];
  _protocolLibreDriver = null;
  if (kOgProtocolCaptureLiveLibre) {
    final store = LibreGen1SecureStore();
    final driver = LibreGen1Driver(
      transport: transport,
      bootstrapProvider: store,
      counterStore: store,
      glucoseDecoderProvider: _protocolLibreGlucoseDecoderProvider,
      observationStore: _libreObservationStore,
      requireDurableObservations: true,
    );
    _protocolLibreDriver = driver;
    registrations.add(
      CgmDriverRegistration(
        driver: driver,
        scanServiceUuids: LibreGen1Driver.scanServiceUuids,
        discover: driver.mapScanResult,
        connectionPolicy: SensorConnectionPolicy.externalSetupOnly,
        prepareDiscovery: () async {
          await driver.reloadBootstrap();
        },
      ),
    );
  }
  if (kOgProtocolCaptureLiveAidex) {
    const discovery = AidexDiscovery();
    registrations.add(
      CgmDriverRegistration(
        driver: AidexSensorDriver(transport, discovery: discovery),
        scanServiceUuids: AidexDiscovery.scanServiceUuids,
        discover: discovery.mapScanResult,
        connectionPolicy: SensorConnectionPolicy.explicitConnect,
      ),
    );
  }
  if (kOgProtocolCaptureLiveYuwell) {
    const discovery = YuwellAnytimeDiscovery();
    final secureStore = YuwellSecureSessionStore();
    registrations.add(
      CgmDriverRegistration(
        driver: YuwellAnytimeDriver(
          transport,
          credentialStore: secureStore,
          writeIntentStore: secureStore,
          glucoseOutputPolicy:
              YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
          discovery: discovery,
        ),
        scanServiceUuids: const <String>[yuwellCt5ServiceUuid],
        discover: discovery.mapScanResult,
        requiresUnfilteredScan: true,
        connectionPolicy: SensorConnectionPolicy.separateConfirmation,
      ),
    );
  }
  return CgmDriverRegistry(
    transport: transport,
    registrations: registrations,
  );
}

DebugSharedScanTransport _sharedProtocolTransport() {
  final profile = selectedProtocolCaptureProfile();
  return _protocolTraceTransport ??= DebugSharedScanTransport(
    delegate: _recordingDelegate(),
    physicalServiceUuids: protocolCapturePhysicalServices(
      profile,
      includeLiveAidex: kOgProtocolCaptureLiveAidex,
    ),
    unfilteredPhysicalScan: profile.usesUnfilteredScan,
    physicalScanStates: FlutterBluePlusTransport.scanStates,
    physicalScanIsActive: () => FlutterBluePlusTransport.isScanningNow,
    physicalScanStartAcknowledgements: _scanStartTracker().acknowledgements,
    physicalScanAttempt: () => _scanStartTracker().latestAttempt,
  );
}

/// Returns the fixed physical filter for one debug capture process.
///
/// The explicit parameter keeps all flag combinations directly testable. An
/// unfiltered profile stays unfiltered; adding a filtered service to it would
/// silently change the capture contract.
List<String> protocolCapturePhysicalServices(
  ProtocolCaptureProfile profile, {
  required bool includeLiveAidex,
}) {
  if (profile.usesUnfilteredScan || !includeLiveAidex) {
    return profile.physicalServiceUuids;
  }
  return <String>{
    ...profile.physicalServiceUuids,
    _canonicalAidexCgmServiceUuid,
  }.toList(growable: false);
}

void _rejectIncompatibleDebugModes() {
  if (kOgDemo && kOgProtocolTrace) {
    throw UnsupportedError(
      'OG_DEMO and OG_PROTOCOL_TRACE cannot be enabled together.',
    );
  }
  if ((kOgProtocolCaptureLiveAidex ||
          kOgProtocolCaptureLiveYuwell ||
          kOgProtocolCaptureLiveLibre) &&
      !kOgProtocolTrace) {
    throw UnsupportedError(
      'A live protocol-capture driver requires OG_PROTOCOL_TRACE.',
    );
  }
  if (kOgProtocolCaptureLiveLibre &&
      selectedProtocolCaptureProfile() != ProtocolCaptureProfile.libre) {
    throw UnsupportedError('Live Libre capture requires the libre profile.');
  }
  if (kOgProtocolCaptureLiveYuwell &&
      selectedProtocolCaptureProfile() !=
          ProtocolCaptureProfile.yuwellAnytimePassive) {
    throw UnsupportedError(
      'Live Yuwell capture requires the yuwell_anytime_passive profile.',
    );
  }
}

RecordingBleTransport _recordingDelegate() {
  return _recordingProtocolDelegate ??= RecordingBleTransport(
    delegate: FlutterBluePlusTransport(scanStartTracker: _scanStartTracker()),
    sink: _traceSink(),
  );
}

FlutterBluePlusScanStartTracker _scanStartTracker() {
  return _protocolScanStartTracker ??= FlutterBluePlusScanStartTracker();
}

LocalBleTraceSink _traceSink() {
  return _protocolTraceSink ??= LocalBleTraceSink();
}

ProtocolCaptureStatusPublisher _captureStatusPublisher() {
  final processSessionId = _protocolCaptureProcessSessionId;
  if (processSessionId == null) {
    throw StateError('Protocol capture has no process session identity.');
  }
  return _protocolCaptureStatus ??= ProtocolCaptureStatusPublisher(
    processSessionId: processSessionId,
    scanner: _sharedProtocolTransport(),
    sink: _traceSink(),
    writer: (status) async {
      await _protocolCaptureChannel.invokeMethod<void>(
        'setBleCaptureStatus',
        status,
      );
    },
    commitHeartbeat: _recordingDelegate().recordCaptureHeartbeat,
  );
}

Future<void> stopPlatformProtocolCapture() {
  if (!kOgProtocolTrace ||
      (!_protocolCaptureActive && _protocolCaptureStopFuture == null)) {
    return Future<void>.value();
  }
  final activeStop = _protocolCaptureStopFuture;
  if (activeStop != null) {
    return activeStop;
  }
  final stop = _stopPlatformProtocolCapture();
  _protocolCaptureStopFuture = stop;
  return stop.whenComplete(() {
    if (identical(_protocolCaptureStopFuture, stop)) {
      _protocolCaptureStopFuture = null;
    }
  });
}

Future<void> _stopPlatformProtocolCapture() async {
  _protocolCaptureLifecycle?.dispose();
  _protocolCaptureLifecycle = null;
  Object? firstError;
  StackTrace? firstStackTrace;

  Future<void> runStep(Future<void> Function() step) async {
    try {
      await step();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  final status = _protocolCaptureStatus;
  final transport = _protocolTraceTransport;
  final sink = _protocolTraceSink;
  if (status != null) {
    await runStep(status.markStopping);
  }
  if (transport != null) {
    await runStep(transport.stop);
  }
  if (sink != null) {
    await runStep(sink.close);
  }
  if (status != null) {
    await runStep(status.stop);
  }
  var nativeStopped = false;
  await runStep(() async {
    await _protocolCaptureChannel.invokeMethod<void>(
      'stopProtocolCapture',
    );
    nativeStopped = true;
  });

  if (nativeStopped) {
    _protocolCaptureActive = false;
    _protocolCaptureStatus = null;
    _protocolTraceTransport = null;
    _recordingProtocolDelegate = null;
    _protocolScanStartTracker = null;
    _protocolTraceSink = null;
    _protocolCaptureProcessSessionId = null;
  }

  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStackTrace!);
  }
}
