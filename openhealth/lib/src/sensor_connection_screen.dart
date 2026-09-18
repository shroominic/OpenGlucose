import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'driver_factory.dart';
import 'libre2_nfc_setup.dart';
import 'libre_gen1_streaming_setup.dart';
import 'session_presentation.dart';

/// Opens the sensor-neutral setup journey.
Future<void> showSensorConnectionFlow(
  BuildContext context,
  CgmAppController controller, {
  Libre2NfcSetupSession? libre2NfcSetupSession,
  LibreGen1StreamingSession? libreGen1StreamingSession,
  bool? libreGen1StreamingEnabled,
  Future<DiscoveredSensor?> Function()? prepareLibreGen1Connection,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFFF7F0E4),
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: SensorConnectionScreen(
        controller: controller,
        libre2NfcSetupSession: libre2NfcSetupSession,
        libreGen1StreamingSession: libreGen1StreamingSession,
        libreGen1StreamingEnabled: libreGen1StreamingEnabled,
        prepareLibreGen1Connection: prepareLibreGen1Connection,
      ),
    ),
  );
}

/// Searches Bluetooth first, with sensor-specific help available on request.
///
/// Scan results can expose Connect. A separately labelled, gated saved Libre 2
/// receiver can also expose Connect after a read-only bootstrap restore; its
/// driver must still find a fresh matching advertisement before connecting.
/// Libre 2 NFC uses a redacted bridge and a separately gated streaming setup.
class SensorConnectionScreen extends StatefulWidget {
  const SensorConnectionScreen({
    required this.controller,
    this.libre2NfcSetupSession,
    this.libreGen1StreamingSession,
    this.libreGen1StreamingEnabled,
    this.prepareLibreGen1Connection,
    this.inline = false,
    this.onClose,
    this.onConnected,
    super.key,
  });

  final CgmAppController controller;
  final Libre2NfcSetupSession? libre2NfcSetupSession;
  final LibreGen1StreamingSession? libreGen1StreamingSession;
  final bool? libreGen1StreamingEnabled;
  final Future<DiscoveredSensor?> Function()? prepareLibreGen1Connection;
  final bool inline;
  final VoidCallback? onClose;
  final VoidCallback? onConnected;

  @override
  State<SensorConnectionScreen> createState() => _SensorConnectionScreenState();
}

class _SensorConnectionScreenState extends State<SensorConnectionScreen> {
  bool _libre2Expanded = false;
  bool _sensorHelpExpanded = false;
  bool _aidexHelpExpanded = false;
  bool _scanRequested = false;
  bool _scanComplete = false;
  int _scanAttempt = 0;
  int _savedLibreRestoreGeneration = 0;
  DiscoveredSensor? _savedLibreReceiver;
  bool _savedLibreRestoreFailed = false;
  DiscoveredSensor? _connectingSensor;
  DiscoveredSensor? _yuwellActivationConfirmationSensor;
  bool _waitingForYuwellActivationRequirement = false;
  bool _connectionRoutePopScheduled = false;
  bool _actionInProgress = false;
  late final Libre2NfcSetupSession _libre2NfcSetupSession;
  StreamSubscription<Libre2NfcSetupState>? _libre2NfcSubscription;
  Libre2NfcSetupState _libre2NfcState = const Libre2NfcSetupState.idle();
  bool _libre2NfcActionInProgress = false;
  bool _libre2Closing = false;
  LibreGen1StreamingSession? _libreStreamingSession;
  StreamSubscription<LibreGen1StreamingState>? _libreStreamingSubscription;
  LibreGen1StreamingState? _libreStreamingState;
  LibreGen1StreamingState? _libreStreamingBlockedState;
  bool _libreStreamingTransition = false;
  bool _libreStreamingUsed = false;
  bool _libreStreamingHandedOff = false;
  bool _libreStreamingCleanupUncertain = false;
  int _libreStreamingGeneration = 0;

  CgmAppController get _controller => widget.controller;
  bool get _streamingEnabled =>
      widget.libreGen1StreamingEnabled ?? isPlatformLibreGen1StreamingEnabled;
  bool get _canStartLibreStreaming =>
      _streamingEnabled &&
      !_libreStreamingUsed &&
      !_libre2NfcState.isReadExpired &&
      !_libre2NfcState.isActivationVerified &&
      _libre2NfcState.phase == Libre2NfcSetupPhase.metadataRead &&
      _libre2NfcState.model == Libre2SensorModel.libre2 &&
      (_libre2NfcState.sensorStatus == Libre2SensorStatus.warmingUp ||
          _libre2NfcState.sensorStatus == Libre2SensorStatus.active);

  bool get _libreCaptureMode =>
      isPlatformProtocolCaptureEnabled ||
      _controller.supportsDriver('protocol_capture_observation');

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChange);
    _libre2NfcSetupSession =
        widget.libre2NfcSetupSession ??
        (_libreCaptureMode
            ? PlatformLibre2NfcSetupSession()
            : ListeningOnlyLibre2NfcSetupSession());
    _libre2NfcSubscription = _libre2NfcSetupSession.states.listen(
      _handleLibre2NfcState,
      onError: (Object _, StackTrace _) {
        _handleLibre2NfcState(
          const Libre2NfcSetupState.failed(Libre2NfcFailureKind.readFailed),
        );
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_startScan());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        _maybeCloseAfterConnection();
        final navigationLocked =
            _connectingSensor != null ||
            _yuwellActivationConfirmationSensor != null ||
            _actionInProgress ||
            _libre2Closing ||
            _libreStreamingTransition;
        if (widget.inline) {
          return PopScope<void>(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop || navigationLocked) return;
              _backFromInlineSetup();
            },
            child: Column(
              key: const ValueKey<String>('sensorConnectionScreen'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if ((_libre2Expanded || _sensorHelpExpanded) &&
                    !navigationLocked)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey<String>('sensorSetupBack'),
                      onPressed: _backFromInlineSetup,
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: Text(
                        _libre2Expanded || _aidexHelpExpanded
                            ? 'Sensor models'
                            : 'Nearby sensors',
                      ),
                    ),
                  ),
                _buildConnectionContent(context),
              ],
            ),
          );
        }
        return PopScope<void>(
          canPop: !_libre2Expanded && !_sensorHelpExpanded && !navigationLocked,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && !navigationLocked) {
              _backFromInlineSetup();
            }
          },
          child: Scaffold(
            key: const ValueKey<String>('sensorConnectionScreen'),
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: const Text('Connect a sensor'),
              leading: navigationLocked
                  ? null
                  : _libre2Expanded || _sensorHelpExpanded
                  ? IconButton(
                      tooltip: 'Back',
                      onPressed: _backFromInlineSetup,
                      icon: const Icon(Icons.arrow_back_rounded),
                    )
                  : IconButton(
                      tooltip: 'Close sensor setup',
                      onPressed: () => Navigator.of(context).maybePop<void>(),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
            body: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    Color(0xFFF7F0E4),
                    Color(0xFFE9F3EF),
                    Color(0xFFF7F5EE),
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: _buildConnectionContent(context),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectionContent(BuildContext context) {
    if (_yuwellActivationConfirmationSensor != null) {
      return _YuwellActivationConfirmation(
        actionInProgress: _actionInProgress,
        onConfirm: _actionInProgress
            ? null
            : () => unawaited(_confirmYuwellActivation()),
        onChooseAnother: _actionInProgress
            ? null
            : () => unawaited(_chooseAnother()),
      );
    }
    return switch (_connectionStage) {
      CgmSyncStage.ready => const SizedBox.shrink(),
      CgmSyncStage.error || CgmSyncStage.disconnected => _ConnectionFailure(
        title: _connectionFailureTitle,
        message: _connectionFailureMessage,
        onRetry: _connectingSensor == null || _actionInProgress
            ? null
            : () => unawaited(_connect(_connectingSensor!)),
        onChooseAnother: _actionInProgress
            ? null
            : () => unawaited(_chooseAnother()),
        actionInProgress: _actionInProgress,
      ),
      final stage? => _ConnectionProgress(
        stage: stage,
        statusText: _cbioProgressText,
        librePhase: _controller.snapshot?.metadata['cgm.libre2.phase'],
        libreDecoder: _controller.snapshot?.metadata['cgm.libre2.decoder'],
      ),
      null =>
        widget.inline ? _buildInlineChooser(context) : _buildChooser(context),
    };
  }

  /// The closed GS1 phase mapped to product copy. The driver's own status text
  /// is an internal, unbounded string and never reaches this card.
  String? get _cbioProgressText {
    final snapshot = _controller.snapshot;
    return snapshot == null ? null : cbioProgressTextForSnapshot(snapshot);
  }

  String get _connectionFailureMessage {
    if (_connectingSensor?.driverId == 'libre2-gen1') {
      final snapshot = _controller.snapshot;
      if (snapshot != null && libreConnectionWasLost(snapshot)) {
        return userMessageForLibreConnectionLoss(snapshot.lastError);
      }
      return userMessageForLibreConnectionFailure(
        _controller.snapshot?.lastError,
      );
    }
    return _controller.lastError ??
        'OpenGlucose could not connect to this sensor.';
  }

  String get _connectionFailureTitle {
    final snapshot = _controller.snapshot;
    if (snapshot != null && snapshotHasSyncStalled(snapshot)) {
      // The link came up, but the sensor never returned a readable reading.
      return 'No reading from this sensor';
    }
    return libreConnectionWasLost(snapshot)
        ? 'Connection lost'
        : 'Could not connect';
  }

  void _backFromInlineSetup() {
    if (_libre2Expanded) {
      _collapseLibre2Setup();
    } else if (_aidexHelpExpanded) {
      setState(() => _aidexHelpExpanded = false);
    } else if (_sensorHelpExpanded) {
      setState(() => _sensorHelpExpanded = false);
    } else {
      widget.onClose?.call();
    }
  }

  @override
  void dispose() {
    _scanAttempt += 1;
    _savedLibreRestoreGeneration += 1;
    _libreStreamingGeneration += 1;
    _controller.removeListener(_handleControllerChange);
    unawaited(_controller.cancelScan());
    unawaited(_disposeLibre2NfcSetup());
    unawaited(_disposeLibreStreaming());
    super.dispose();
  }

  Future<void> _disposeLibre2NfcSetup() async {
    try {
      await _libre2NfcSubscription?.cancel().timeout(
        const Duration(seconds: 30),
      );
      _libre2NfcSubscription = null;
    } catch (_) {
      // Owner is being removed. Never retry or surface private channel errors.
    } finally {
      try {
        await _libre2NfcSetupSession.dispose().timeout(
          const Duration(seconds: 30),
        );
      } catch (_) {
        // Native retains unresolved ownership. Disposing cannot authorize retry.
      }
    }
  }

  Future<void> _disposeLibreStreaming() async {
    try {
      await _libreStreamingSubscription?.cancel().timeout(
        const Duration(seconds: 30),
      );
      _libreStreamingSubscription = null;
      await _libreStreamingSession?.dispose();
    } catch (_) {
      // Native retains uncertain outcomes; disposing never retries a write.
    }
  }

  CgmSyncStage? get _connectionStage {
    if (_connectingSensor == null) {
      return null;
    }
    return _controller.snapshot?.stage ?? CgmSyncStage.connecting;
  }

  void _maybeCloseAfterConnection() {
    if (widget.inline) {
      if (_connectingSensor != null &&
          _controller.snapshot?.stage == CgmSyncStage.ready &&
          !_connectionRoutePopScheduled) {
        _connectionRoutePopScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controller.snapshot?.stage == CgmSyncStage.ready) {
            widget.onConnected?.call();
          } else {
            _connectionRoutePopScheduled = false;
          }
        });
      }
      return;
    }
    if (_connectingSensor == null ||
        _controller.snapshot?.stage != CgmSyncStage.ready ||
        _connectionRoutePopScheduled ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _connectionRoutePopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_controller.snapshot?.stage == CgmSyncStage.ready &&
          ModalRoute.of(context)?.isCurrent == true &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop<void>();
      } else {
        _connectionRoutePopScheduled = false;
      }
    });
  }

  _SensorFamilySupport _aidexSupportFor({
    required TargetPlatform platform,
    required bool isWeb,
  }) {
    final driverAvailable =
        _controller.supportsDriver('aidex') ||
        _controller.supportsDriver('demo-aidex');
    if (!driverAvailable) {
      return const _SensorFamilySupport(
        label: 'Unavailable',
        color: Color(0xFF7A4D28),
        description: 'Bluetooth setup is not supported on this device.',
        canOpen: false,
        canConnect: false,
      );
    }
    if (_controller.isMockDriver || isWeb) {
      return const _SensorFamilySupport(
        label: 'Demo only',
        color: Color(0xFF5A557A),
        description:
            'Try the setup screens with sample data. Demo mode cannot connect to a physical sensor.',
        canOpen: true,
        canConnect: true,
      );
    }
    return switch (platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS => const _SensorFamilySupport(
        label: 'Available',
        color: Color(0xFF0B6E69),
        description:
            'Find the sensor nearby, then complete Android or iPhone pairing.',
        canOpen: true,
        canConnect: true,
      ),
      TargetPlatform.macOS => const _SensorFamilySupport(
        label: 'Reviewer preview',
        color: Color(0xFF9A4D00),
        description:
            'The setup UI is available, but physical AiDEX use on macOS is not verified.',
        canOpen: true,
        canConnect: true,
      ),
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.fuchsia => const _SensorFamilySupport(
        label: 'Not supported',
        color: Color(0xFF7A4D28),
        description:
            'Physical AiDEX and LinX connection is not supported on this platform.',
        canOpen: false,
        canConnect: false,
      ),
    };
  }

  bool _canConnectSensorOnTarget(
    BuildContext context,
    DiscoveredSensor sensor,
  ) {
    if (!sensor.capabilities.supportsDirectBle ||
        !_controller.supportsDriver(sensor.driverId)) {
      return false;
    }
    if (sensor.driverId == 'aidex' || sensor.driverId == 'demo-aidex') {
      return _aidexSupportFor(
        platform: Theme.of(context).platform,
        isWeb: kIsWeb,
      ).canConnect;
    }
    if (_controller.isMockDriver) {
      return true;
    }
    if (kIsWeb) {
      return false;
    }
    return switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.fuchsia => false,
    };
  }

  Widget _buildChooser(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
    children: <Widget>[_buildInlineChooser(context)],
  );

  Widget _buildInlineChooser(BuildContext context) {
    if (_libre2Expanded) {
      return switch (_libreStreamingState) {
        final streaming? => _LibreStreamingGuide(
          state: streaming,
          stopping: _libreStreamingTransition,
          onClose: _collapseLibre2Setup,
          onReadAgain:
              streaming.canRepeatReadOnlyCheck &&
                  !_libreStreamingCleanupUncertain
              ? _retryLibreStreamingRead
              : null,
        ),
        null => _Libre2Guide(
          captureMode: _libreCaptureMode,
          state: _libre2NfcState,
          actionInProgress: _libre2NfcActionInProgress,
          onStart: _startLibre2NfcSetup,
          onRetry: _retryLibre2NfcSetup,
          onDone: _collapseLibre2Setup,
          onConnect: _canStartLibreStreaming ? _startLibreStreaming : null,
        ),
      };
    }
    final scanFinished = _scanComplete && !_controller.scanning;
    if (scanFinished && _sensorHelpExpanded) {
      return _buildSensorHelp(context);
    }
    return Column(
      key: const ValueKey<String>('sensorConnectionChooser'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_savedLibreReceiver case final saved?) ...<Widget>[
          _buildSavedLibreReceiver(context, saved),
          const SizedBox(height: 16),
        ],
        if (_savedLibreRestoreFailed) ...<Widget>[
          const Text(
            'Saved sensor setup could not be loaded. '
            'You can still search for nearby sensors.',
            key: ValueKey<String>('savedLibreRestoreUnavailable'),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Nearby sensors',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            if (widget.inline)
              IconButton(
                tooltip: 'Close sensor setup',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
        _NearbySensorPanel(
          scanRequested: _scanRequested,
          scanComplete: _scanComplete,
          scanning: _controller.scanning,
          sensors: _visibleSensors,
          scanFailure: _controller.scanFailure,
          scanFailureMessage: _controller.scanFailureMessage,
          onScan: _startScan,
          onConnect: _connect,
          canConnect: (sensor) => _canConnectSensorOnTarget(context, sensor),
          interrupted: _controller.sensorHasInterruptedTransfer,
          canReviewInterrupted:
              _controller.canAcknowledgeInterruptedSensorTransfer,
          onReviewInterrupted: _reviewInterruptedTransfer,
        ),
        if (scanFinished) ...<Widget>[
          const SizedBox(height: 12),
          TextButton(
            key: const ValueKey<String>('sensorHelpButton'),
            onPressed: () => setState(() => _sensorHelpExpanded = true),
            child: const Text("Can't find your sensor?"),
          ),
        ],
      ],
    );
  }

  Widget _buildSensorHelp(BuildContext context) {
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900);
    if (_aidexHelpExpanded) {
      final support = _aidexSupportFor(
        platform: Theme.of(context).platform,
        isWeb: kIsWeb,
      );
      return Column(
        key: const ValueKey<String>('aidexConnectionHelp'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('AiDEX / LinX', style: titleStyle),
          const SizedBox(height: 8),
          Text(
            support.canOpen && support.label == 'Available'
                ? 'Keep the sensor close. Turn on Bluetooth and allow nearby device access, then search again.'
                : support.description,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey<String>('aidexHelpScanAgain'),
            onPressed: support.canOpen ? () => unawaited(_startScan()) : null,
            icon: const Icon(Icons.bluetooth_searching_rounded),
            label: const Text('Search again'),
          ),
        ],
      );
    }
    return Column(
      key: const ValueKey<String>('sensorModelHelp'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Which sensor do you have?', style: titleStyle),
        const SizedBox(height: 8),
        const Text('Check the name on the sensor box.'),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey<String>('chooseAidexHelp'),
          onPressed: () => setState(() => _aidexHelpExpanded = true),
          child: const Text('AiDEX / LinX'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey<String>('chooseLibre2Help'),
          onPressed: _toggleLibre2Setup,
          child: const Text('FreeStyle Libre 2'),
        ),
        const SizedBox(height: 12),
        const Text('Not sure? Check the name on the box.'),
      ],
    );
  }

  Widget _buildSavedLibreReceiver(
    BuildContext context,
    DiscoveredSensor sensor,
  ) {
    return Card(
      key: const ValueKey<String>('savedLibreReceiver'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Saved Libre 2',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'Connection setup is saved on this phone. '
              'Connect to search for the sensor; this can take up to 2½ minutes.',
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const ValueKey<String>('connectSavedLibreReceiver'),
              onPressed:
                  _actionInProgress ||
                      _libre2Expanded ||
                      _libreStreamingState != null ||
                      !_canConnectSensorOnTarget(context, sensor) ||
                      _controller.sensorHasInterruptedTransfer(sensor)
                  ? null
                  : () => unawaited(_connect(sensor)),
              child: const Text('Connect saved sensor'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restoreSavedLibreReceiver() async {
    final generation = ++_savedLibreRestoreGeneration;
    setState(() {
      _savedLibreReceiver = null;
      _savedLibreRestoreFailed = false;
    });
    if (!_streamingEnabled || !_controller.supportsDriver('libre2-gen1')) {
      return;
    }
    DiscoveredSensor? restored;
    var failed = false;
    try {
      restored =
          await (widget.prepareLibreGen1Connection ??
                  preparePlatformLibreGen1Connection)()
              .timeout(const Duration(seconds: 10));
      if (restored != null && restored.driverId != 'libre2-gen1') {
        restored = null;
        failed = true;
      }
    } catch (_) {
      // This read is not connection authority. Never expose secure-store errors
      // or block other sensors when saved setup is absent or unavailable.
      failed = true;
    }
    if (!mounted || generation != _savedLibreRestoreGeneration) return;
    setState(() {
      _savedLibreReceiver = restored;
      _savedLibreRestoreFailed = failed;
    });
  }

  List<DiscoveredSensor> get _visibleSensors =>
      List<DiscoveredSensor>.unmodifiable(_controller.sensors);

  Future<void> _startScan() async {
    if (_libreStreamingState != null || _libreStreamingTransition) return;
    final attempt = ++_scanAttempt;
    setState(() {
      _scanRequested = true;
      _scanComplete = false;
      _sensorHelpExpanded = false;
      _aidexHelpExpanded = false;
    });
    unawaited(_restoreSavedLibreReceiver());
    await _controller.scan();
    if (!mounted || attempt != _scanAttempt) {
      return;
    }
    setState(() => _scanComplete = true);
  }

  Future<void> _connect(DiscoveredSensor sensor) async {
    if (_actionInProgress ||
        (_libreStreamingState != null && !_libreStreamingHandedOff) ||
        !_canConnectSensorOnTarget(context, sensor) ||
        _controller.sensorHasInterruptedTransfer(sensor)) {
      return;
    }
    setState(() {
      _actionInProgress = true;
      _connectingSensor = sensor;
      _yuwellActivationConfirmationSensor = null;
      _waitingForYuwellActivationRequirement =
          sensor.driverId == 'yuwell-anytime';
    });
    try {
      await _controller.connect(
        sensor,
        allowSessionActivation: sensor.driverId != 'yuwell-anytime',
      );
    } finally {
      if (mounted) {
        setState(() => _actionInProgress = false);
      }
    }
  }

  Future<void> _chooseAnother() async {
    if (_actionInProgress) {
      return;
    }
    setState(() => _actionInProgress = true);
    try {
      await _controller.chooseAnotherSensor();
      if (!mounted) {
        return;
      }
      if (_controller.snapshot != null) {
        setState(() {});
        return;
      }
      setState(() {
        _connectingSensor = null;
        _yuwellActivationConfirmationSensor = null;
        _waitingForYuwellActivationRequirement = false;
        _libre2Expanded = false;
        _scanRequested = false;
        _scanComplete = false;
      });
      unawaited(_startScan());
    } finally {
      if (mounted) {
        setState(() => _actionInProgress = false);
      }
    }
  }

  void _handleControllerChange() {
    if (!mounted || !_waitingForYuwellActivationRequirement) {
      return;
    }
    final connectingSensor = _connectingSensor;
    if (connectingSensor == null ||
        connectingSensor.driverId != 'yuwell-anytime') {
      return;
    }
    final activationRequiredSensor = _controller.activationRequiredSensor;
    if (activationRequiredSensor != null &&
        _sameSensorIdentity(connectingSensor, activationRequiredSensor)) {
      if (_yuwellActivationConfirmationSensor == null) {
        setState(() {
          _waitingForYuwellActivationRequirement = false;
          _yuwellActivationConfirmationSensor = connectingSensor;
          _actionInProgress = false;
        });
      }
      return;
    }
    if (_controller.snapshot?.stage == CgmSyncStage.ready) {
      _waitingForYuwellActivationRequirement = false;
    }
  }

  Future<void> _confirmYuwellActivation() async {
    final sensor = _yuwellActivationConfirmationSensor;
    if (_actionInProgress || sensor == null) {
      return;
    }
    setState(() {
      _actionInProgress = true;
      _yuwellActivationConfirmationSensor = null;
      _waitingForYuwellActivationRequirement = false;
    });
    try {
      await _controller.connect(sensor, allowSessionActivation: true);
    } finally {
      if (mounted) {
        setState(() => _actionInProgress = false);
      }
    }
  }

  Future<void> _reviewInterruptedTransfer(DiscoveredSensor sensor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review interrupted sensor move'),
        content: const Text(
          'Open Android Bluetooth settings. Confirm that this sensor is not '
          'listed as paired. If it is listed, choose Forget first. This only '
          'clears the app safety marker; it does not contact the sensor.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmInterruptedMoveRecovery'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('I checked Bluetooth'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await _controller.acknowledgeInterruptedSensorTransfer(sensor);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _controller.lastError ??
                  'The interrupted sensor move could not be cleared.',
            ),
          ),
        );
      }
    }
  }

  void _toggleLibre2Setup() {
    if (_libreStreamingTransition || _libre2Closing) return;
    if (_libre2Expanded) {
      _collapseLibre2Setup();
      return;
    }
    setState(() {
      _libre2Expanded = true;
      _libre2NfcState = const Libre2NfcSetupState.idle();
      _libreStreamingState = _libreStreamingBlockedState;
    });
    if (_libreCaptureMode &&
        _libreStreamingState == null &&
        !_libreStreamingCleanupUncertain) {
      unawaited(_startLibre2NfcSetup());
    }
  }

  void _handleLibre2NfcState(Libre2NfcSetupState state) {
    if (!mounted || !_libre2Expanded || _libreStreamingState != null) {
      return;
    }
    setState(() => _libre2NfcState = state);
  }

  Future<void> _startLibre2NfcSetup() =>
      _runLibre2NfcAction(_libre2NfcSetupSession.start);

  Future<void> _retryLibre2NfcSetup() =>
      _runLibre2NfcAction(_libre2NfcSetupSession.retry);

  Future<void> _runLibre2NfcAction(Future<void> Function() action) async {
    if (_libre2NfcActionInProgress ||
        !_libreCaptureMode ||
        _libreStreamingState != null ||
        _libreStreamingCleanupUncertain) {
      return;
    }
    setState(() => _libre2NfcActionInProgress = true);
    try {
      await action();
    } catch (_) {
      _handleLibre2NfcState(
        const Libre2NfcSetupState.failed(
          Libre2NfcFailureKind.cleanupUnconfirmed,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _libre2NfcActionInProgress = false);
      }
    }
  }

  void _collapseLibre2Setup() {
    if (_connectingSensor != null ||
        _libreStreamingTransition ||
        _libre2Closing) {
      return;
    }
    if (_libreStreamingState != null) {
      unawaited(_closeLibreStreaming());
      return;
    }
    if (_libre2Expanded) {
      unawaited(_closeLibre2Read());
      return;
    }
    setState(() {
      _libre2Expanded = false;
      _libre2NfcState = const Libre2NfcSetupState.idle();
    });
  }

  Future<void> _closeLibre2Read() async {
    setState(() => _libre2Closing = true);
    try {
      await _libre2NfcSetupSession.stop().timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _libre2Expanded = false;
        _libre2NfcState = const Libre2NfcSetupState.idle();
      });
    } catch (_) {
      _handleLibre2NfcState(
        const Libre2NfcSetupState.failed(
          Libre2NfcFailureKind.cleanupUnconfirmed,
        ),
      );
    } finally {
      if (mounted) setState(() => _libre2Closing = false);
    }
  }

  Future<void> _retryLibreStreamingRead() async {
    if (_libreStreamingTransition ||
        _libreStreamingCleanupUncertain ||
        _libreStreamingState?.canRepeatReadOnlyCheck != true) {
      return;
    }
    ++_libreStreamingGeneration;
    setState(() => _libreStreamingTransition = true);
    try {
      await _libreStreamingSubscription?.cancel().timeout(
        const Duration(seconds: 30),
      );
      _libreStreamingSubscription = null;
      await _libreStreamingSession?.stop().timeout(const Duration(seconds: 30));
      await _libreStreamingSession?.dispose().timeout(
        const Duration(seconds: 30),
      );
      if (!mounted) return;
      setState(() {
        _libreStreamingSession = null;
        _libreStreamingState = null;
        _libreStreamingUsed = false;
        _libreStreamingHandedOff = false;
        _libreStreamingTransition = false;
      });
      await _retryLibre2NfcSetup();
    } catch (_) {
      _libreStreamingCleanupUncertain = true;
      if (mounted) {
        setState(
          () => _libreStreamingState = const LibreGen1StreamingState(
            LibreGen1StreamingPhase.failed,
            failure: LibreGen1StreamingFailure.outcomeUnknown,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _libreStreamingTransition = false);
    }
  }

  Future<void> _startLibreStreaming() async {
    if (!_canStartLibreStreaming ||
        _libreStreamingTransition ||
        _libreStreamingCleanupUncertain) {
      return;
    }
    final generation = ++_libreStreamingGeneration;
    setState(() {
      _libreStreamingUsed = true;
      _libreStreamingTransition = true;
      _libreStreamingState = const LibreGen1StreamingState(
        LibreGen1StreamingPhase.idle,
      );
    });
    try {
      // The two native readers share one event channel. Release the read-only
      // subscription and native attempt before creating the streaming listener.
      final reader = _libre2NfcSetupSession;
      final sourceReadAttemptId =
          reader is Libre2NfcCompletedReadAttemptProvider
          ? (reader as Libre2NfcCompletedReadAttemptProvider)
                .completedReadAttemptId
          : null;
      await _libre2NfcSetupSession.stop().timeout(const Duration(seconds: 30));
      if (!mounted || generation != _libreStreamingGeneration) return;
      final session =
          widget.libreGen1StreamingSession ??
          PlatformLibreGen1StreamingSession(
            sourceReadAttemptId: sourceReadAttemptId,
          );
      _libreStreamingSession = session;
      _libreStreamingSubscription = session.states.listen(
        _handleLibreStreamingState,
        onError: (Object _, StackTrace _) => _handleLibreStreamingState(
          const LibreGen1StreamingState(
            LibreGen1StreamingPhase.failed,
            failure: LibreGen1StreamingFailure.outcomeUnknown,
          ),
        ),
      );
      await session.start();
    } catch (_) {
      _handleLibreStreamingState(
        const LibreGen1StreamingState(
          LibreGen1StreamingPhase.failed,
          failure: LibreGen1StreamingFailure.outcomeUnknown,
        ),
      );
    } finally {
      if (mounted &&
          generation == _libreStreamingGeneration &&
          !_libreStreamingHandedOff) {
        setState(() => _libreStreamingTransition = false);
      }
    }
  }

  void _handleLibreStreamingState(LibreGen1StreamingState state) {
    if (!mounted ||
        !_libre2Expanded ||
        _libreStreamingState?.isTerminal == true) {
      return;
    }
    setState(() => _libreStreamingState = state);
    if (state.phase == LibreGen1StreamingPhase.streamingEnabled &&
        !_libreStreamingHandedOff) {
      _libreStreamingHandedOff = true;
      unawaited(_connectPreparedLibreSensor());
    }
  }

  Future<void> _connectPreparedLibreSensor() async {
    final generation = _libreStreamingGeneration;
    setState(() => _libreStreamingTransition = true);
    try {
      await _libreStreamingSession?.stop().timeout(const Duration(seconds: 30));
      if (!mounted || generation != _libreStreamingGeneration) return;
      final sensor =
          await (widget.prepareLibreGen1Connection ??
                  preparePlatformLibreGen1Connection)()
              .timeout(const Duration(seconds: 30));
      if (!mounted || generation != _libreStreamingGeneration) return;
      if (sensor == null || !_canConnectSensorOnTarget(context, sensor)) {
        throw StateError('Bluetooth setup is unavailable.');
      }
      await _connect(sensor);
    } catch (_) {
      if (mounted && generation == _libreStreamingGeneration) {
        setState(
          () => _libreStreamingState = const LibreGen1StreamingState(
            LibreGen1StreamingPhase.failed,
            failure: LibreGen1StreamingFailure.outcomeUnknown,
          ),
        );
      }
    } finally {
      if (mounted && generation == _libreStreamingGeneration) {
        setState(() => _libreStreamingTransition = false);
      }
    }
  }

  Future<void> _closeLibreStreaming() async {
    if (_libreStreamingTransition) return;
    ++_libreStreamingGeneration;
    setState(() => _libreStreamingTransition = true);
    try {
      await _libreStreamingSession?.stop().timeout(const Duration(seconds: 30));
      await _libreStreamingSession?.dispose().timeout(
        const Duration(seconds: 30),
      );
      await _libreStreamingSubscription?.cancel().timeout(
        const Duration(seconds: 30),
      );
      _libreStreamingSubscription = null;
      if (mounted) {
        setState(() {
          if (_libreStreamingState?.canRepeatReadOnlyCheck == true) {
            _libreStreamingUsed = false;
          } else if (_libreStreamingState?.phase ==
              LibreGen1StreamingPhase.failed) {
            _libreStreamingBlockedState = _libreStreamingState;
          }
          _libreStreamingSession = null;
          _libre2Expanded = false;
          _libreStreamingState = null;
          _libre2NfcState = const Libre2NfcSetupState.idle();
        });
      }
    } catch (_) {
      _libreStreamingCleanupUncertain = true;
      if (mounted) {
        setState(
          () => _libreStreamingState = const LibreGen1StreamingState(
            LibreGen1StreamingPhase.failed,
            failure: LibreGen1StreamingFailure.outcomeUnknown,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _libreStreamingTransition = false);
    }
  }
}

class _NearbySensorPanel extends StatelessWidget {
  const _NearbySensorPanel({
    required this.scanRequested,
    required this.scanComplete,
    required this.scanning,
    required this.sensors,
    required this.scanFailure,
    required this.scanFailureMessage,
    required this.onScan,
    required this.onConnect,
    required this.canConnect,
    required this.interrupted,
    required this.canReviewInterrupted,
    required this.onReviewInterrupted,
  });

  final bool scanRequested;
  final bool scanComplete;
  final bool scanning;
  final List<DiscoveredSensor> sensors;
  final BleFailure? scanFailure;
  final String? scanFailureMessage;
  final Future<void> Function() onScan;
  final Future<void> Function(DiscoveredSensor sensor) onConnect;
  final bool Function(DiscoveredSensor sensor) canConnect;
  final bool Function(DiscoveredSensor sensor) interrupted;
  final bool Function(DiscoveredSensor sensor) canReviewInterrupted;
  final Future<void> Function(DiscoveredSensor sensor) onReviewInterrupted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = scanRequested && (!scanComplete || scanning);
    final scanFailed = scanFailure != null || scanFailureMessage != null;
    if (!scanRequested || waiting) {
      return Semantics(
        key: const ValueKey<String>('nearbyScanProgress'),
        liveRegion: true,
        label: 'Scanning for supported Bluetooth sensors',
        child: const _ScanningCard(),
      );
    }
    if (scanFailed && sensors.isEmpty) {
      return _ScanFailureCard(
        failure: scanFailure,
        message: scanFailureMessage,
        onRetry: onScan,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (scanFailed)
          _PartialScanFailure(
            failure: scanFailure,
            message: scanFailureMessage,
            onRetry: onScan,
          ),
        if (sensors.isEmpty)
          _NoSensorsCard(onRetry: onScan)
        else ...<Widget>[
          Semantics(
            liveRegion: true,
            label:
                '${sensors.length} supported ${sensors.length == 1 ? 'sensor' : 'sensors'} found',
            child: Text(
              '${sensors.length} ${sensors.length == 1 ? 'sensor' : 'sensors'} found',
              style: theme.textTheme.labelLarge?.copyWith(
                color: const Color(0xFF506763),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (sensors.length > 1) ...<Widget>[
            const _MultipleSensorsNotice(),
            const SizedBox(height: 8),
          ],
          for (var index = 0; index < sensors.length; index += 1) ...<Widget>[
            _DiscoveredSensorCard(
              sensor: sensors[index],
              resultNumber: index + 1,
              resultCount: sensors.length,
              connectable: canConnect(sensors[index]),
              interrupted: interrupted(sensors[index]),
              canReviewInterrupted: canReviewInterrupted(sensors[index]),
              onConnect: onConnect,
              onReviewInterrupted: onReviewInterrupted,
            ),
            if (index != sensors.length - 1) const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

class _ScanningCard extends StatelessWidget {
  const _ScanningCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Looking for supported sensors nearby…',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoSensorsCard extends StatelessWidget {
  const _NoSensorsCard({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        key: const ValueKey<String>('nearbyNoResults'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.sensors_off_rounded,
                size: 28,
                color: Color(0xFF0B6E69),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'No Bluetooth sensors found',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    SizedBox(height: 2),
                    Text('Keep the sensor close and try again.'),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Scan again',
                onPressed: () => unawaited(onRetry()),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanFailureCard extends StatelessWidget {
  const _ScanFailureCard({
    required this.failure,
    required this.message,
    required this.onRetry,
  });

  final BleFailure? failure;
  final String? message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            children: <Widget>[
              const Icon(
                Icons.bluetooth_disabled_rounded,
                size: 44,
                color: Color(0xFF9A4D00),
              ),
              const SizedBox(height: 12),
              Text(
                _scanFailureTitle(failure),
                key: const ValueKey<String>('sensorScanFailureTitle'),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                message ?? 'Check Bluetooth and try again.',
                key: const ValueKey<String>('sensorScanFailureMessage'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey<String>('retrySensorScanButton'),
                onPressed: () => unawaited(onRetry()),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PartialScanFailure extends StatelessWidget {
  const _PartialScanFailure({
    required this.failure,
    required this.message,
    required this.onRetry,
  });

  final BleFailure? failure;
  final String? message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        key: const ValueKey<String>('sensorScanInlineFailure'),
        color: const Color(0xFFFFF3E8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _scanFailureTitle(failure),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(message ?? 'Some scan results may be missing.'),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('retryPartialSensorScanButton'),
                onPressed: () => unawaited(onRetry()),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Scan again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultipleSensorsNotice extends StatelessWidget {
  const _MultipleSensorsNotice();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Card(
        color: const Color(0xFFFFF3E8),
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: Color(0xFF9A4D00)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'More than one sensor is nearby. Keep your sensor closest '
                  'and choose the strongest signal. Numbers are temporary.',
                  style: TextStyle(height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscoveredSensorCard extends StatelessWidget {
  const _DiscoveredSensorCard({
    required this.sensor,
    required this.resultNumber,
    required this.resultCount,
    required this.connectable,
    required this.interrupted,
    required this.canReviewInterrupted,
    required this.onConnect,
    required this.onReviewInterrupted,
  });

  final DiscoveredSensor sensor;
  final int resultNumber;
  final int resultCount;
  final bool connectable;
  final bool interrupted;
  final bool canReviewInterrupted;
  final Future<void> Function(DiscoveredSensor sensor) onConnect;
  final Future<void> Function(DiscoveredSensor sensor) onReviewInterrupted;

  @override
  Widget build(BuildContext context) {
    final connectionAvailable = connectable && !interrupted;
    final publicName = _publicSensorName(
      sensor,
      resultNumber: resultNumber,
      resultCount: resultCount,
    );
    return Semantics(
      container: true,
      label: '$publicName, Bluetooth, ${_signalLabel(sensor.rssi)} signal',
      child: Card(
        key: ValueKey<String>('sensorResult-$resultNumber'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const _RoundIcon(
                    icon: Icons.sensors_rounded,
                    background: Color(0xFFE2F0EC),
                    foreground: Color(0xFF0B6E69),
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          publicName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Bluetooth · ${_signalLabel(sensor.rssi)} signal',
                          style: const TextStyle(color: Color(0xFF5E726D)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (interrupted) ...<Widget>[
                const SizedBox(height: 14),
                const Text(
                  'A previous sensor move needs review before reconnecting. '
                  'OpenGlucose will not contact this sensor yet.',
                  style: TextStyle(color: Color(0xFF9A4D00), height: 1.35),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: ValueKey<String>('resolveInterruptedMove-$resultNumber'),
                  onPressed: canReviewInterrupted
                      ? () => unawaited(onReviewInterrupted(sensor))
                      : null,
                  child: Text(
                    canReviewInterrupted ? 'Review move' : 'Move needs support',
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  key: ValueKey<String>('connectButton-$resultNumber'),
                  onPressed: connectionAvailable
                      ? () => unawaited(onConnect(sensor))
                      : null,
                  child: Text(
                    connectionAvailable ? 'Connect' : 'Connection unavailable',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Libre2Guide extends StatelessWidget {
  const _Libre2Guide({
    required this.captureMode,
    required this.state,
    required this.actionInProgress,
    required this.onStart,
    required this.onRetry,
    required this.onDone,
    this.onConnect,
  });

  final bool captureMode;
  final Libre2NfcSetupState state;
  final bool actionInProgress;
  final Future<void> Function() onStart;
  final Future<void> Function() onRetry;
  final VoidCallback onDone;
  final Future<void> Function()? onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = _nfcPresentation(state, captureMode: captureMode);
    return Card(
      key: const ValueKey<String>('libre2NfcGuide'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(
          children: <Widget>[
            Semantics(
              key: const ValueKey<String>('libre2NfcSetupStatus'),
              liveRegion: true,
              container: true,
              label: '${presentation.title}. ${presentation.body}',
              excludeSemantics: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: presentation.background,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                  child: Column(
                    children: <Widget>[
                      _NfcScanAffordance(
                        state: state,
                        animate:
                            captureMode &&
                            (state.phase == Libre2NfcSetupPhase.listening ||
                                state.phase ==
                                    Libre2NfcSetupPhase.tagDetected ||
                                state.phase == Libre2NfcSetupPhase.reading),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        presentation.title,
                        key: const ValueKey<String>('libre2NfcSetupTitle'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        presentation.body,
                        key: const ValueKey<String>('libre2NfcSetupBody'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF365550),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (state.phase == Libre2NfcSetupPhase.metadataRead) ...<Widget>[
              const SizedBox(height: 10),
              _Libre2SafeResult(state: state),
            ],
            const SizedBox(height: 12),
            if (onConnect != null) ...<Widget>[
              FilledButton.icon(
                key: const ValueKey<String>('connectLibre2Sensor'),
                onPressed: actionInProgress
                    ? null
                    : () => unawaited(onConnect!()),
                icon: const Icon(Icons.bluetooth_rounded),
                label: const Text('Connect this sensor'),
              ),
              const SizedBox(height: 8),
            ],
            _Libre2NfcAction(
              captureMode: captureMode,
              state: state,
              actionInProgress: actionInProgress,
              onStart: onStart,
              onRetry: onRetry,
              onDone: onDone,
            ),
            if (state.phase == Libre2NfcSetupPhase.listening) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'Keep the phone unlocked and OpenGlucose in the foreground.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF5E726D)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibreStreamingGuide extends StatelessWidget {
  const _LibreStreamingGuide({
    required this.state,
    required this.stopping,
    required this.onClose,
    this.onReadAgain,
  });

  final LibreGen1StreamingState state;
  final bool stopping;
  final VoidCallback onClose;
  final Future<void> Function()? onReadAgain;

  @override
  Widget build(BuildContext context) {
    final title = switch (state.phase) {
      LibreGen1StreamingPhase.idle => 'Preparing NFC',
      LibreGen1StreamingPhase.listening => 'Tap your sensor again',
      LibreGen1StreamingPhase.tagDetected => 'Sensor detected',
      LibreGen1StreamingPhase.readingMetadata => 'Checking sensor',
      LibreGen1StreamingPhase.enablingStreaming => 'Setting up Bluetooth',
      LibreGen1StreamingPhase.streamingEnabled =>
        state.isSavedReceiver
            ? 'Using saved Bluetooth setup'
            : 'Bluetooth setup complete',
      LibreGen1StreamingPhase.failed =>
        state.canRepeatReadOnlyCheck
            ? 'Check the sensor again'
            : state.failure == LibreGen1StreamingFailure.outcomeUnknown
            ? 'Setup needs a check'
            : 'Setup stopped',
    };
    final body = switch (state.phase) {
      LibreGen1StreamingPhase.idle => 'Keep your sensor close.',
      LibreGen1StreamingPhase.listening =>
        'Hold the back of your phone against the sensor to set up Bluetooth.',
      LibreGen1StreamingPhase.tagDetected ||
      LibreGen1StreamingPhase.readingMetadata ||
      LibreGen1StreamingPhase.enablingStreaming =>
        'Keep the phone still against the sensor until setup finishes.',
      LibreGen1StreamingPhase.streamingEnabled =>
        'Connecting to the sensor over Bluetooth…',
      LibreGen1StreamingPhase.failed =>
        state.canRepeatReadOnlyCheck
            ? 'The last check could not be used. Scan the sensor again to continue. Bluetooth setup has not been changed.'
            : switch (state.failure) {
                LibreGen1StreamingFailure.outcomeUnknown =>
                  'The setup result could not be confirmed. Check the sensor state before another attempt.',
                LibreGen1StreamingFailure.tagMoved =>
                  'The phone moved away before setup finished.',
                LibreGen1StreamingFailure.expired => 'The NFC scan time ended.',
                LibreGen1StreamingFailure.cancelled =>
                  'NFC setup was cancelled.',
                _ => 'The sensor setup could not be completed.',
              },
    };
    final animationState = switch (state.phase) {
      LibreGen1StreamingPhase.streamingEnabled =>
        Libre2NfcSetupState.metadataRead(
          model: Libre2SensorModel.libre2,
          sensorStatus: state.lifecycle ?? Libre2SensorStatus.unknown,
        ),
      LibreGen1StreamingPhase.failed => const Libre2NfcSetupState.failed(
        Libre2NfcFailureKind.readFailed,
      ),
      _ => const Libre2NfcSetupState.listening(),
    };
    return Card(
      key: const ValueKey<String>('libreStreamingGuide'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            _NfcScanAffordance(
              state: animationState,
              animate: !state.isTerminal,
            ),
            Semantics(
              liveRegion: true,
              container: true,
              label: '$title. $body',
              excludeSemantics: true,
              child: Column(
                children: <Widget>[
                  Text(
                    title,
                    key: const ValueKey<String>('libreStreamingTitle'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(body, textAlign: TextAlign.center),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (onReadAgain != null)
              FilledButton.icon(
                key: const ValueKey<String>('retryLibreReadOnlyCheck'),
                onPressed: stopping ? null : () => unawaited(onReadAgain!()),
                icon: const Icon(Icons.nfc_rounded),
                label: const Text('Scan again'),
              ),
            TextButton(
              key: const ValueKey<String>('closeLibreStreaming'),
              onPressed: stopping ? null : onClose,
              child: Text(state.isTerminal ? 'Close' : 'Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NfcScanAffordance extends StatefulWidget {
  const _NfcScanAffordance({required this.state, required this.animate});

  final Libre2NfcSetupState state;
  final bool animate;

  @override
  State<_NfcScanAffordance> createState() => _NfcScanAffordanceState();
}

class _NfcScanAffordanceState extends State<_NfcScanAffordance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant _NfcScanAffordance oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  void _updateAnimation() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (widget.animate && !reduceMotion) {
      if (!_pulse.isAnimating) {
        unawaited(_pulse.repeat());
      }
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = _nfcIconAppearance(widget.state.phase);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const ValueKey<String>('libre2NfcScanAnimation'),
        dimension: 96,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) => Stack(
            alignment: Alignment.center,
            children: <Widget>[
              if (widget.animate)
                for (var index = 0; index < 3; index += 1)
                  _NfcPulseRing(progress: (_pulse.value + index / 3) % 1),
              AnimatedContainer(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: appearance.background,
                  shape: BoxShape.circle,
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x260B6E69),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Icon(
                  appearance.icon,
                  color: appearance.foreground,
                  size: 34,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }
}

class _NfcPulseRing extends StatelessWidget {
  const _NfcPulseRing({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.62 + (progress * 0.62),
      child: Opacity(
        opacity: (1 - progress) * 0.6,
        child: Container(
          width: 94,
          height: 94,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF0B6E69), width: 2),
          ),
        ),
      ),
    );
  }
}

class _Libre2SafeResult extends StatelessWidget {
  const _Libre2SafeResult({required this.state});

  final Libre2NfcSetupState state;

  @override
  Widget build(BuildContext context) {
    final model = state.model;
    if (model == null) {
      return const SizedBox.shrink();
    }
    final status = state.sensorStatus;
    if (status == null) {
      return const SizedBox.shrink();
    }
    return Card(
      key: const ValueKey<String>('libre2NfcSafeResult'),
      child: ListTile(
        leading: const Icon(Icons.sensors_rounded, color: Color(0xFF0B6E69)),
        title: Text(
          libre2SensorModelLabel(model),
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: Text(
          '${state.isActivationVerified
              ? 'At activation'
              : state.isReadExpired
              ? 'At last scan'
              : 'Sensor state'}: ${libre2SensorStatusLabel(status)}',
        ),
        trailing: Icon(
          _libre2StatusIcon(status),
          color: _libre2StatusColor(status),
        ),
      ),
    );
  }
}

class _Libre2NfcAction extends StatelessWidget {
  const _Libre2NfcAction({
    required this.captureMode,
    required this.state,
    required this.actionInProgress,
    required this.onStart,
    required this.onRetry,
    required this.onDone,
  });

  final bool captureMode;
  final Libre2NfcSetupState state;
  final bool actionInProgress;
  final Future<void> Function() onStart;
  final Future<void> Function() onRetry;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    if (!captureMode) {
      return _NfcActionWrap(
        primary: FilledButton.icon(
          key: const ValueKey<String>('libre2UnavailableButton'),
          onPressed: null,
          icon: const Icon(Icons.nfc_rounded),
          label: const Text('Check sensor'),
        ),
        onHide: onDone,
      );
    }
    return switch (state.phase) {
      Libre2NfcSetupPhase.idle => _NfcActionWrap(
        primary: FilledButton.icon(
          key: const ValueKey<String>('libre2CaptureButton'),
          onPressed: actionInProgress ? null : () => unawaited(onStart()),
          icon: const Icon(Icons.nfc_rounded),
          label: const Text('Check sensor'),
        ),
        onHide: onDone,
      ),
      Libre2NfcSetupPhase.failed => _NfcActionWrap(
        primary: FilledButton.icon(
          key: const ValueKey<String>('libre2NfcRetryButton'),
          onPressed:
              actionInProgress ||
                  state.failure == Libre2NfcFailureKind.cleanupUnconfirmed
              ? null
              : () => unawaited(onRetry()),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
        onHide: onDone,
      ),
      Libre2NfcSetupPhase.metadataRead => _NfcActionWrap(
        primary: OutlinedButton.icon(
          key: const ValueKey<String>('libre2NfcReadAgainButton'),
          onPressed: actionInProgress ? null : () => unawaited(onRetry()),
          icon: const Icon(Icons.nfc_rounded),
          label: const Text('Scan again'),
        ),
        onHide: onDone,
      ),
      Libre2NfcSetupPhase.listening ||
      Libre2NfcSetupPhase.tagDetected ||
      Libre2NfcSetupPhase.reading => OutlinedButton.icon(
        key: const ValueKey<String>('libre2NfcCollapseButton'),
        onPressed: onDone,
        icon: const Icon(Icons.expand_less_rounded),
        label: const Text('Hide NFC scan'),
      ),
    };
  }
}

class _NfcActionWrap extends StatelessWidget {
  const _NfcActionWrap({required this.primary, required this.onHide});

  final Widget primary;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        primary,
        OutlinedButton.icon(
          key: const ValueKey<String>('libre2NfcCollapseButton'),
          onPressed: onHide,
          icon: const Icon(Icons.expand_less_rounded),
          label: const Text('Hide NFC scan'),
        ),
      ],
    );
  }
}

_NfcPresentation _nfcPresentation(
  Libre2NfcSetupState state, {
  required bool captureMode,
}) => switch (state.phase) {
  Libre2NfcSetupPhase.idle => _NfcPresentation(
    title: 'Ready to check sensor',
    body: captureMode
        ? 'Select Check sensor, then hold the back of the phone near the sensor.'
        : 'NFC scanning requires a supported Android phone with NFC turned on.',
    background: const Color(0xFFE2F0EC),
  ),
  Libre2NfcSetupPhase.listening => const _NfcPresentation(
    title: 'Hold near the sensor',
    body:
        'Move the back of the phone slowly over the sensor and keep it there.',
    background: Color(0xFFE2F0EC),
  ),
  Libre2NfcSetupPhase.tagDetected => const _NfcPresentation(
    title: 'Sensor detected',
    body: 'Keep the phone still while OpenGlucose checks the sensor.',
    background: Color(0xFFE2F0EC),
  ),
  Libre2NfcSetupPhase.reading => const _NfcPresentation(
    title: 'Checking sensor',
    body: 'Keep the phone still while OpenGlucose checks the sensor state.',
    background: Color(0xFFE2F0EC),
  ),
  Libre2NfcSetupPhase.metadataRead => _verifiedNfcPresentation(state),
  Libre2NfcSetupPhase.failed => _NfcPresentation(
    title: state.failure == Libre2NfcFailureKind.cleanupUnconfirmed
        ? 'NFC needs a check'
        : 'Try the NFC tap again',
    body: _nfcFailureText(state.failure),
    background: const Color(0xFFFFF3E8),
  ),
};

String _nfcFailureText(Libre2NfcFailureKind? failure) => switch (failure) {
  Libre2NfcFailureKind.unavailable => 'NFC is not available on this phone.',
  Libre2NfcFailureKind.disabled => 'Turn on NFC, then try again.',
  Libre2NfcFailureKind.tagMoved =>
    'Hold the phone against the sensor until the check completes.',
  Libre2NfcFailureKind.cleanupUnconfirmed =>
    'NFC could not be stopped safely. Close and reopen OpenGlucose before another check.',
  Libre2NfcFailureKind.readFailed ||
  null => 'Move the phone back to the sensor and keep it still.',
};

_NfcPresentation _verifiedNfcPresentation(Libre2NfcSetupState state) {
  if (state.isReadExpired) {
    return const _NfcPresentation(
      title: 'Scan again to connect',
      body:
          'This check is no longer recent. Scan the sensor again before connecting.',
      background: Color(0xFFFFF3E8),
    );
  }
  if (state.isActivationVerified) {
    return const _NfcPresentation(
      title: 'Libre 2 activated',
      body:
          'Activation verified. Scan again to check the sensor before connecting over Bluetooth.',
      background: Color(0xFFE2F0EC),
    );
  }
  final status = state.sensorStatus;
  final statusText = status == null
      ? 'State unavailable'
      : libre2SensorStatusLabel(status);
  return _NfcPresentation(
    title: 'Libre 2 identified',
    body: 'Sensor data verified. Current state: $statusText.',
    background: const Color(0xFFE2F0EC),
  );
}

IconData _libre2StatusIcon(Libre2SensorStatus status) => switch (status) {
  Libre2SensorStatus.notActivated ||
  Libre2SensorStatus.warmingUp ||
  Libre2SensorStatus.active => Icons.check_circle_rounded,
  Libre2SensorStatus.expired ||
  Libre2SensorStatus.shutdown => Icons.info_rounded,
  Libre2SensorStatus.failure => Icons.error_rounded,
  Libre2SensorStatus.unknown => Icons.help_rounded,
};

Color _libre2StatusColor(Libre2SensorStatus status) => switch (status) {
  Libre2SensorStatus.notActivated ||
  Libre2SensorStatus.warmingUp ||
  Libre2SensorStatus.active => const Color(0xFF0B6E69),
  Libre2SensorStatus.expired ||
  Libre2SensorStatus.shutdown ||
  Libre2SensorStatus.unknown => const Color(0xFF7A4D28),
  Libre2SensorStatus.failure => const Color(0xFFC83F36),
};

_NfcIconAppearance _nfcIconAppearance(Libre2NfcSetupPhase phase) =>
    switch (phase) {
      Libre2NfcSetupPhase.idle ||
      Libre2NfcSetupPhase.listening => const _NfcIconAppearance(
        icon: Icons.nfc_rounded,
        foreground: Colors.white,
        background: Color(0xFF0B6E69),
      ),
      Libre2NfcSetupPhase.tagDetected => const _NfcIconAppearance(
        icon: Icons.sensors_rounded,
        foreground: Colors.white,
        background: Color(0xFF0B6E69),
      ),
      Libre2NfcSetupPhase.reading => const _NfcIconAppearance(
        icon: Icons.sync_rounded,
        foreground: Colors.white,
        background: Color(0xFF0B6E69),
      ),
      Libre2NfcSetupPhase.metadataRead => const _NfcIconAppearance(
        icon: Icons.check_rounded,
        foreground: Colors.white,
        background: Color(0xFF0B6E69),
      ),
      Libre2NfcSetupPhase.failed => const _NfcIconAppearance(
        icon: Icons.refresh_rounded,
        foreground: Color(0xFF7A4D28),
        background: Color(0xFFFFE0C7),
      ),
    };

class _NfcPresentation {
  const _NfcPresentation({
    required this.title,
    required this.body,
    required this.background,
  });

  final String title;
  final String body;
  final Color background;
}

class _NfcIconAppearance {
  const _NfcIconAppearance({
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final Color foreground;
  final Color background;
}

class _SensorFamilySupport {
  const _SensorFamilySupport({
    required this.label,
    required this.color,
    required this.description,
    required this.canOpen,
    required this.canConnect,
  });

  final String label;
  final Color color;
  final String description;
  final bool canOpen;
  final bool canConnect;
}

class _ConnectionProgress extends StatelessWidget {
  const _ConnectionProgress({
    required this.stage,
    this.statusText,
    this.librePhase,
    this.libreDecoder,
  });

  final CgmSyncStage stage;
  final String? statusText;
  final String? librePhase;
  final String? libreDecoder;

  @override
  Widget build(BuildContext context) {
    final phaseText = switch (librePhase) {
      'reconnecting' => 'Connection lost. Reconnecting once to your sensor.',
      'awaitingAdvertisement' => 'Looking for your Libre 2 sensor',
      'connecting' => 'Connecting to FreeStyle Libre 2',
      'discovering' => 'Checking the sensor connection',
      'reservingLogin' || 'loggingIn' => 'Signing in to the sensor',
      'subscribing' => 'Starting sensor updates',
      'awaitingPacket' => 'Connected. Waiting for sensor data.',
      'validatedPacket' => libreGlucoseWaitingDetail(libreDecoder),
      _ => _connectionStageText(stage),
    };
    final text = statusText ?? phaseText;
    final receiving =
        librePhase == 'awaitingPacket' || librePhase == 'validatedPacket';
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (receiving)
                    const Icon(
                      Icons.bluetooth_connected_rounded,
                      size: 40,
                      color: Color(0xFF0B6E69),
                    )
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 18),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    receiving
                        ? 'No glucose reading is available yet.'
                        : 'Keep the phone and sensor close while setup continues.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _YuwellActivationConfirmation extends StatelessWidget {
  const _YuwellActivationConfirmation({
    required this.onConfirm,
    required this.onChooseAnother,
    required this.actionInProgress,
  });

  final VoidCallback? onConfirm;
  final VoidCallback? onChooseAnother;
  final bool actionInProgress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Card(
            key: const ValueKey<String>('yuwellActivationConfirmation'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.sensors_rounded,
                    size: 44,
                    color: Color(0xFF0B6E69),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Start this Yuwell sensor?',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'OpenGlucose found a sensor that has not been started for '
                    'this app installation. Continuing will activate the '
                    'sensor and bind its connection credentials to this '
                    'installation.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Continue only on the phone and OpenGlucose installation '
                    'that will use this sensor.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey<String>(
                        'confirmYuwellActivationButton',
                      ),
                      onPressed: onConfirm,
                      child: const Text('Activate and connect'),
                    ),
                  ),
                  if (actionInProgress)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: LinearProgressIndicator(),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      key: const ValueKey<String>(
                        'cancelYuwellActivationButton',
                      ),
                      onPressed: onChooseAnother,
                      child: const Text('Choose another sensor'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionFailure extends StatelessWidget {
  const _ConnectionFailure({
    required this.title,
    required this.message,
    required this.onRetry,
    required this.onChooseAnother,
    required this.actionInProgress,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onChooseAnother;
  final bool actionInProgress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 44,
                    color: Color(0xFF9A4D00),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey<String>('connectionRetryButton'),
                      onPressed: onRetry,
                      child: const Text('Try again'),
                    ),
                  ),
                  if (actionInProgress)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Semantics(
                        liveRegion: true,
                        label: 'Connection action in progress',
                        child: const LinearProgressIndicator(),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      key: const ValueKey<String>('chooseAnotherSensorButton'),
                      onPressed: onChooseAnother,
                      child: const Text('Choose another sensor'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.icon,
    required this.background,
    required this.foreground,
    this.size = 46,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, color: foreground),
    );
  }
}

String _publicSensorName(
  DiscoveredSensor sensor, {
  required int resultNumber,
  required int resultCount,
}) {
  final family = switch (sensor.driverId) {
    'aidex' || 'demo-aidex' => 'AiDEX / LinX sensor',
    'yuwell-anytime' => 'Yuwell Anytime sensor',
    _ => 'Supported sensor',
  };
  return resultCount > 1 ? '$family $resultNumber' : family;
}

bool _sameSensorIdentity(DiscoveredSensor left, DiscoveredSensor right) =>
    left.driverId == right.driverId && left.deviceId == right.deviceId;

String _signalLabel(int rssi) {
  if (rssi >= -60) {
    return 'strong';
  }
  if (rssi >= -75) {
    return 'good';
  }
  return 'weak';
}

String _scanFailureTitle(BleFailure? failure) => switch (failure?.kind) {
  BleFailureKind.bluetoothOff => 'Bluetooth is off',
  BleFailureKind.permissionRequired => 'Bluetooth access needed',
  BleFailureKind.bluetoothUnavailable => 'Bluetooth is unavailable',
  _ => 'Could not scan for sensors',
};

String _connectionStageText(CgmSyncStage stage) => switch (stage) {
  CgmSyncStage.connecting => 'Connecting to sensor',
  CgmSyncStage.bonding => 'Preparing Bluetooth pairing',
  CgmSyncStage.pairing => 'Complete the pairing prompt',
  CgmSyncStage.activating => 'Starting sensor setup',
  CgmSyncStage.syncing => 'Syncing sensor history',
  CgmSyncStage.scanning => 'Finding sensor',
  CgmSyncStage.ready => 'Sensor connected',
  CgmSyncStage.disconnected => 'Sensor disconnected',
  CgmSyncStage.error => 'Connection failed',
};
