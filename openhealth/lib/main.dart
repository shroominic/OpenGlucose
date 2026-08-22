import 'dart:async';
import 'dart:ui';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/ai/ai_settings_pane.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/driver_factory.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/health_state_store_factory.dart';
import 'package:openglucose/src/integrations_settings_pane.dart';
import 'package:openglucose/src/macos_preview_notice.dart';
import 'package:openglucose/src/metrics_section.dart';
import 'package:openglucose/src/messaging/message_catalog.dart';
import 'package:openglucose/src/messaging/message_context_builder.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:openglucose/src/messaging/message_host.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/onboarding/onboarding_flow.dart';
import 'package:openglucose/src/onboarding/onboarding_store.dart';
import 'package:openglucose/src/sensor_lifecycle_card.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_archive_export.dart';
import 'package:openglucose/src/sensor_archive_share_file.dart';
import 'package:openglucose/src/sample_dashboard_screen.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:openglucose/src/weekly_recap/weekly_recap_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configurePlatformPrivacyDefaults();

  FlutterError.onError = (details) {
    if (kDebugMode) {
      debugPrint('FlutterError (${details.exception.runtimeType})');
    }
  };

  PlatformDispatcher.instance.onError = (error, _) {
    if (kDebugMode) {
      debugPrint('Unhandled error (${error.runtimeType})');
    }
    return true;
  };

  runApp(const _BootstrapApp());
}

Future<_BootstrapResult> _bootstrap() async {
  try {
    await clearStaleArchivedSensorShareFiles();
  } catch (_) {
    // Share-cache cleanup is privacy hygiene, never a reason to block launch.
  }
  final preferences = await SharedPreferences.getInstance();
  final healthStateStore = createHealthStateStore(preferences);
  final controller = CgmAppController(
    preferences: preferences,
    driver: buildDefaultDriver(),
    healthStateStore: healthStateStore,
  );
  await controller.initialize();
  final healthExport = HealthExportController(
    preferences: preferences,
    healthStateStore: healthStateStore,
    writesAllowed: !controller.isMockDriver,
  )..initialize();
  final messages = MessageController(
    preferences: preferences,
    messages: defaultMessageCatalog,
  );
  if (controller.isMockDriver) {
    // In demo mode (simulator/feature verification) the demo driver only
    // surfaces its sensor after a scan, so auto-scan and auto-connect to land
    // directly on the populated dashboard. Strictly gated behind OG_DEMO and
    // skipped when a previous session was already restored from preferences.
    unawaited(_autoConnectDemoSensor(controller));
  }
  return (
    controller: controller,
    preferences: preferences,
    healthExport: healthExport,
    messages: messages,
  );
}

typedef _BootstrapResult = ({
  CgmAppController controller,
  HealthExportController healthExport,
  MessageController messages,
  SharedPreferences preferences,
});

/// Scans with the demo driver and connects to the first discovered sensor so
/// OG_DEMO builds open straight onto the populated dashboard.
Future<void> _autoConnectDemoSensor(CgmAppController controller) async {
  if (controller.snapshot != null) {
    // A persisted session is already (re)connecting; don't interfere.
    return;
  }
  await controller.scan();
  final sensors = controller.sensors;
  if (sensors.isEmpty) {
    return;
  }
  await controller.connect(sensors.first);
}

class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  late final Future<_BootstrapResult> _future = _bootstrap();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BootstrapResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashApp();
        }
        if (snapshot.hasError) {
          return _SplashApp(
            error:
                'Secure local storage could not be initialized '
                '(${snapshot.error.runtimeType})',
          );
        }
        final result = snapshot.data!;
        return OpenGlucoseApp(
          controller: result.controller,
          healthExport: result.healthExport,
          preferences: result.preferences,
          messageController: result.messages,
        );
      },
    );
  }
}

class _SplashApp extends StatelessWidget {
  const _SplashApp({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const _SpinningLogo(),
              if (error != null) ...<Widget>[
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Failed to start: $error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFB24A3B)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SpinningLogo extends StatefulWidget {
  const _SpinningLogo();

  @override
  State<_SpinningLogo> createState() => _SpinningLogoState();
}

class _SpinningLogoState extends State<_SpinningLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Image.asset('assets/icon/logo.png', width: 140, height: 140),
    );
  }
}

/// Provides the [HealthExportController] to descendant widgets (notably the
/// settings sheet's Integrations tab) without threading it through every
/// constructor.
class HealthExportScope extends InheritedNotifier<HealthExportController> {
  const HealthExportScope({
    super.key,
    required HealthExportController controller,
    required super.child,
  }) : super(notifier: controller);

  static HealthExportController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<HealthExportScope>();
    assert(scope != null, 'No HealthExportScope found in context');
    return scope!.notifier!;
  }
}

/// Shares one prepared archived-sensor file through the platform share sheet.
///
/// The callback is injectable so tests can verify the exact native payload.
typedef ArchivedSensorShareAction = Future<void> Function(ShareParams params);

typedef _ArchivedSensorExportRequest = ({
  ArchivedSensorExportFormat format,
  ArchivedSensorSession session,
  List<CgmReading> readings,
});

Uint8List _buildArchivedSensorExportInBackground(
  _ArchivedSensorExportRequest request,
) => buildArchivedSensorExport(
  format: request.format,
  session: request.session,
  readings: request.readings,
);

class _ArchivedSensorShareScope extends InheritedWidget {
  const _ArchivedSensorShareScope({required this.share, required super.child});

  final ArchivedSensorShareAction share;

  static ArchivedSensorShareAction of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ArchivedSensorShareScope>();
    assert(scope != null, 'No archived-sensor share scope found in context');
    return scope!.share;
  }

  @override
  bool updateShouldNotify(_ArchivedSensorShareScope oldWidget) =>
      share != oldWidget.share;
}

Future<void> _shareArchivedSensorFile(ShareParams params) async {
  await SharePlus.instance.share(params);
}

/// Builds a one-attachment native share request.
///
/// In particular, this intentionally omits `text`: share_plus represents that
/// as a second iOS activity item, which Files can save as an extra text file.
ShareParams buildArchivedSensorShareParams({
  required XFile file,
  required String filename,
  Rect? sharePositionOrigin,
}) => ShareParams(
  title: 'OpenGlucose sensor export',
  subject: 'OpenGlucose sensor export',
  files: <XFile>[file],
  fileNameOverrides: <String>[filename],
  mailToFallbackEnabled: false,
  sharePositionOrigin: sharePositionOrigin,
);

class OpenGlucoseApp extends StatelessWidget {
  const OpenGlucoseApp({
    super.key,
    required this.controller,
    required this.healthExport,
    required this.preferences,
    this.messageController,
    this.archivedSensorShareAction,
  });

  final CgmAppController controller;
  final HealthExportController healthExport;
  final SharedPreferences preferences;

  /// Optional contextual-messaging engine. When null (e.g. in some tests) the
  /// dashboard simply renders no message host.
  final MessageController? messageController;

  /// Optional share-sheet seam used by export integration tests.
  final ArchivedSensorShareAction? archivedSensorShareAction;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0B6E69);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFFFF8F1),
    );
    return MaterialApp(
      title: 'OpenGlucose',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF6EFE6),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          color: Colors.white.withValues(alpha: 0.94),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF4F6F2),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFD8E3DE)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFD8E3DE)),
          ),
        ),
      ),
      // --- TASK-007 onboarding gate ---
      // First-run only: show the skippable onboarding flow, then hand off to
      // the existing scan/connect home. Persisted via OnboardingStore; once
      // completed/skipped the gate falls straight through on later launches.
      home: _ArchivedSensorShareScope(
        share: archivedSensorShareAction ?? _shareArchivedSensorFile,
        child: HealthExportScope(
          controller: healthExport,
          child: _OnboardingGate(
            store: OnboardingStore(preferences),
            controller: controller,
            unit: controller.displayPreferences.unit,
            home: CgmHomePage(
              controller: controller,
              messageController: messageController,
            ),
          ),
        ),
      ),
      // --- end TASK-007 onboarding gate ---
    );
  }
}

// --- TASK-007 onboarding gate ---
/// Chooses between first-run onboarding and the main app. Kept deliberately
/// small and self-contained so it merges cleanly with other `main.dart` edits.
class _OnboardingGate extends StatefulWidget {
  const _OnboardingGate({
    required this.store,
    required this.controller,
    required this.unit,
    required this.home,
  });

  final OnboardingStore store;
  final CgmAppController controller;
  final GlucoseUnit unit;
  final Widget home;

  @override
  State<_OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<_OnboardingGate> {
  late bool _showOnboarding = !widget.store.isCompleted;

  @override
  Widget build(BuildContext context) {
    if (!_showOnboarding) {
      return widget.home;
    }
    return OnboardingFlow(
      store: widget.store,
      unit: widget.unit,
      onFinished: () {
        widget.controller.updateDisplayPreferences(
          widget.controller.displayPreferences.copyWith(
            targetLowMgdl: widget.store.targetLowMgdl,
            targetHighMgdl: widget.store.targetHighMgdl,
          ),
        );
        setState(() => _showOnboarding = false);
      },
    );
  }
}
// --- end TASK-007 onboarding gate ---

class CgmHomePage extends StatefulWidget {
  const CgmHomePage({
    super.key,
    required this.controller,
    this.messageController,
  });

  final CgmAppController controller;
  final MessageController? messageController;

  @override
  State<CgmHomePage> createState() => _CgmHomePageState();
}

class _CgmHomePageState extends State<CgmHomePage> with WidgetsBindingObserver {
  static const _foregroundFreshnessInterval = Duration(seconds: 45);

  Timer? _freshnessTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _freshnessTimer = Timer.periodic(_foregroundFreshnessInterval, (_) {
      unawaited(widget.controller.ensureFreshData());
    });
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(widget.controller.ensureFreshData(force: true));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final snapshot = widget.controller.snapshot;
        // Contextual-messaging bridge: recompute which messages are relevant
        // from the latest app state on every controller change. Deferred to
        // post-frame so it never triggers a rebuild during this build pass.
        final messageController = widget.messageController;
        if (messageController != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            messageController.updateContext(
              buildMessageContext(widget.controller),
            );
          });
        }
        return Scaffold(
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
              child: snapshot == null
                  ? _ScanView(controller: widget.controller)
                  : _DashboardView(
                      controller: widget.controller,
                      snapshot: snapshot,
                      messageController: widget.messageController,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _ScanView extends StatelessWidget {
  const _ScanView({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final archivedSensors = controller.archivedSensors;
    final latestArchived = archivedSensors.isEmpty
        ? null
        : archivedSensors.first;
    final inactiveMessage = switch (latestArchived?.reason) {
      SensorArchiveReason.expired =>
        'Your last sensor expired. Your previous readings are still here—connect '
            'a new sensor to resume live glucose.',
      SensorArchiveReason.replaced =>
        'Your previous sensor was replaced. Its readings are still here—connect '
            'your new sensor to resume live glucose.',
      SensorArchiveReason.disconnected =>
        'No sensor is active. Your previous readings are still here—connect a '
            'sensor to resume live glucose.',
      null =>
        'Your glucose, on your terms. Connect your sensor to see live readings '
            'and trends.',
    };
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Card(
              color: const Color(0xFF103B3C),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'OpenGlucose',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          onPressed: () => _showSettings(context, controller),
                          color: Colors.white,
                          icon: const Icon(Icons.settings_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      inactiveMessage,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: const Color(0xFFD8EEE8),
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        FilledButton.icon(
                          key: const ValueKey<String>('scanSensorsButton'),
                          onPressed: controller.scanning
                              ? null
                              : () => unawaited(controller.scan()),
                          icon: controller.scanning
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.bluetooth_searching_rounded),
                          label: Text(
                            controller.scanning
                                ? 'Scanning...'
                                : 'Find my sensor',
                          ),
                        ),
                        if (controller.allHistoricalReadings.isEmpty)
                          OutlinedButton.icon(
                            key: const ValueKey<String>(
                              'sampleDashboardButton',
                            ),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SampleDashboardScreen(
                                  preferences: controller.displayPreferences,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.visibility_outlined),
                            label: const Text('Explore sample data'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Color(0xFF9CC9C1)),
                            ),
                          ),
                      ],
                    ),
                    if (controller.lastError != null &&
                        controller.scanFailure == null) ...<Widget>[
                      const SizedBox(height: 16),
                      Text(
                        controller.lastError!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFFFFC4AA),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        if (shouldShowMacosPreviewNotice(
          platform: defaultTargetPlatform,
          isWeb: kIsWeb,
        ))
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: MacosPreviewNotice(),
            ),
          ),
        if (controller.archivedSensors.isNotEmpty)
          SliverToBoxAdapter(
            child: _HistoricalOverviewCard(controller: controller),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Row(
              children: <Widget>[
                Text(
                  'Nearby sensors',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${controller.sensors.length} found',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF5E726D),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (controller.sensors.isNotEmpty &&
            !controller.scanning &&
            controller.scanFailure != null)
          SliverToBoxAdapter(child: _ScanFailureBanner(controller: controller)),
        if (controller.sensors.isEmpty &&
            !controller.scanning &&
            controller.scanFailure != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _ScanFailureState(controller: controller),
          )
        else if (controller.sensors.isEmpty && !controller.scanning)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No sensors found yet.\nHold your phone near your sensor and try again.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            sliver: SliverList.separated(
              itemCount: controller.sensors.length,
              itemBuilder: (context, index) {
                final sensor = controller.sensors[index];
                final advertisement = sensor.advertisement;
                final serial = sensor.metadata['serial'];
                final hasValue = advertisement?.displayValueMgdl != null;
                final hasInterruptedTransfer = controller
                    .sensorHasInterruptedTransfer(sensor);
                final canAcknowledgeInterruptedTransfer = controller
                    .canAcknowledgeInterruptedSensorTransfer(sensor);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    sensor.displayName,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    serial?.isNotEmpty == true
                                        ? serial!
                                        : sensor.deviceId,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF5E726D),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: <Widget>[
                                if (hasInterruptedTransfer)
                                  OutlinedButton(
                                    key: ValueKey<String>(
                                      'resolveInterruptedMove-'
                                      '${sensor.deviceId}',
                                    ),
                                    onPressed: canAcknowledgeInterruptedTransfer
                                        ? () => unawaited(
                                            _confirmInterruptedSensorTransferRecovery(
                                              context,
                                              controller,
                                              sensor,
                                            ),
                                          )
                                        : null,
                                    child: Text(
                                      canAcknowledgeInterruptedTransfer
                                          ? 'Review move'
                                          : 'Move needs support',
                                    ),
                                  ),
                                FilledButton(
                                  key: ValueKey<String>(
                                    'connectButton-${sensor.deviceId}',
                                  ),
                                  onPressed:
                                      sensor.capabilities.supportsDirectBle &&
                                          !hasInterruptedTransfer
                                      ? () => unawaited(
                                          controller.connect(sensor),
                                        )
                                      : null,
                                  child: const Text('Connect'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            _MetricChip(label: 'RSSI ${sensor.rssi} dBm'),
                            if (hasValue)
                              _MetricChip(
                                label:
                                    '${advertisement!.displayValueMgdl!.toStringAsFixed(0)} mg/dL',
                              ),
                            if (advertisement?.counter != null)
                              _MetricChip(
                                label: 'Counter ${advertisement!.counter}',
                              ),
                            if (sensor.metadata['mode'] == 'demo')
                              const _MetricChip(label: 'Demo transport'),
                          ],
                        ),
                        if (hasInterruptedTransfer &&
                            !canAcknowledgeInterruptedTransfer) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            'The sensor response is unknown. Do not reconnect '
                            'or forget the Android bond. Contact support for a '
                            'reviewed recovery.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF9A4D00),
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (sensor.notes?.isNotEmpty == true) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            sensor.notes!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.35,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(height: 12),
            ),
          ),
      ],
    );
  }
}

Future<void> _confirmInterruptedSensorTransferRecovery(
  BuildContext context,
  CgmAppController controller,
  DiscoveredSensor sensor,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Review interrupted sensor move'),
      content: const Text(
        'Open Android Bluetooth settings before you continue. Confirm that '
        'the sensor is not listed as paired. If it is listed, choose Forget '
        'first. This action only clears the app safety marker. It does not '
        'contact the sensor or change a Bluetooth bond.',
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
  if (confirmed != true || !context.mounted) {
    return;
  }
  try {
    await controller.acknowledgeInterruptedSensorTransfer(sensor);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.lastError ??
                'The interrupted sensor move could not be cleared.',
          ),
        ),
      );
    }
  }
}

class _ScanFailureState extends StatelessWidget {
  const _ScanFailureState({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final failure = controller.scanFailure!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.bluetooth_disabled_rounded,
              size: 48,
              color: Color(0xFF0B6E69),
            ),
            const SizedBox(height: 14),
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
              controller.scanFailureMessage ??
                  'Check Bluetooth, keep the sensor nearby, and try again.',
              key: const ValueKey<String>('sensorScanFailureMessage'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: const Color(0xFF5B6E6A),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey<String>('retrySensorScanButton'),
              onPressed: controller.scanning
                  ? null
                  : () => unawaited(controller.scan()),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanFailureBanner extends StatelessWidget {
  const _ScanFailureBanner({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final failure = controller.scanFailure!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Card(
        key: const ValueKey<String>('sensorScanInlineFailure'),
        color: const Color(0xFFFFF3E8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.bluetooth_disabled_rounded,
                    color: Color(0xFF9A4D00),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _scanFailureTitle(failure),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                controller.scanFailureMessage ??
                    'Check Bluetooth and try scanning again.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF6B5542),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('retryPartialSensorScanButton'),
                onPressed: () => unawaited(controller.scan()),
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

String _scanFailureTitle(BleFailure failure) => switch (failure.kind) {
  BleFailureKind.bluetoothOff => 'Bluetooth is off',
  BleFailureKind.permissionRequired => 'Bluetooth access needed',
  BleFailureKind.bluetoothUnavailable => 'Bluetooth is unavailable',
  _ => 'Could not scan for sensors',
};

class _HistoricalOverviewCard extends StatelessWidget {
  const _HistoricalOverviewCard({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readings = controller.allHistoricalReadings;
    final timestampedReadings = readings
        .where((reading) => reading.recordedAt != null)
        .toList(growable: false);
    final first = timestampedReadings.isEmpty
        ? null
        : timestampedReadings.first.recordedAt;
    final latest = timestampedReadings.isEmpty
        ? null
        : timestampedReadings.last.recordedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Card(
        key: const ValueKey<String>('historicalOverviewCard'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.history_rounded, color: Color(0xFF0B6E69)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Your glucose history',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${controller.archivedSensors.length} previous '
                '${controller.archivedSensors.length == 1 ? 'sensor' : 'sensors'} · '
                '${readings.length} readings'
                '${latest == null ? '' : ' · last ${DateFormat('MMM d, HH:mm').format(latest.toLocal())}'}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF5B6E6A),
                ),
              ),
              if (timestampedReadings.isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                Container(
                  key: const ValueKey<String>('historicalTimestampSummary'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F4),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: <Widget>[
                      _KeyValueRow(
                        label: 'First reading',
                        value: DateFormat(
                          'MMM d, y · HH:mm',
                        ).format(first!.toLocal()),
                      ),
                      _KeyValueRow(
                        label: 'Latest reading',
                        value: DateFormat(
                          'MMM d, y · HH:mm',
                        ).format(latest!.toLocal()),
                      ),
                      _KeyValueRow(
                        label: 'Stored sessions',
                        value: '${controller.archivedSensors.length}',
                      ),
                      const Text(
                        'Each sensor keeps its own chart in Sensor archive, so '
                        'separate sessions are never joined into one line.',
                        style: TextStyle(color: Color(0xFF5B6E6A)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WeeklyRecapScreen(
                          readings: readings,
                          preferences: controller.displayPreferences,
                          now: latest,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.insights_rounded),
                    label: const Text('View weekly recap'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardView extends StatelessWidget {
  const _DashboardView({
    required this.controller,
    required this.snapshot,
    this.messageController,
  });

  final CgmAppController controller;
  final CgmSessionSnapshot snapshot;
  final MessageController? messageController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preferences = controller.displayPreferences;
    final history = controller.visibleHistory;
    final warmup = computeWarmupStatus(
      snapshot,
      latestReading: controller.displayLatestReading,
    );
    final isWarmingUp = warmup?.phase == WarmupPhase.warming;
    final remainingLife = sensorLifeText(snapshot.sessionInfo.sessionStart);

    return RefreshIndicator(
      onRefresh: controller.sync,
      edgeOffset: 8,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: <Widget>[
          if (controller.isMockDriver)
            const SliverToBoxAdapter(
              child: ColoredBox(
                color: Color(0xFFFFD166),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Text(
                    'DEMO DATA — NOT REAL GLUCOSE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF4A2B00),
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'OpenGlucose',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          key: const ValueKey<String>('sensorExpiryIndicator'),
                          children: <Widget>[
                            const Icon(
                              Icons.event_outlined,
                              size: 16,
                              color: Color(0xFF5B6E6A),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                remainingLife,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: const Color(0xFF5B6E6A),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => _showSettings(context, controller),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
            ),
          ),
          // Contextual messaging host (TASK-004). Self-contained; renders the
          // current top tip/info/alert as a dismissible card, or nothing.
          if (messageController != null)
            SliverToBoxAdapter(
              child: MessageHost(controller: messageController!),
            ),
          SliverToBoxAdapter(
            child: _DashboardHeroCard(
              controller: controller,
              snapshot: snapshot,
            ),
          ),
          if (!isWarmingUp)
            SliverToBoxAdapter(
              key: const ValueKey<String>('dashboardHistorySection'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                'History',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Text(
                              '${history.length} readings',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF5B6E6A),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 336,
                          child: CgmDashboardChart(
                            readings: history,
                            preferences: preferences,
                            historySync: snapshot.historySync,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // History-derived UI stays hidden until the sensor finishes warmup;
          // early equilibration values are excluded from its shared input.
          if (!isWarmingUp)
            SliverToBoxAdapter(
              key: const ValueKey<String>('dashboardPatternsSection'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: MetricsSection(
                  readings: history,
                  preferences: preferences,
                ),
              ),
            ),
          if (!isWarmingUp)
            SliverToBoxAdapter(
              key: const ValueKey<String>('dashboardWeeklyRecapSection'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => WeeklyRecapScreen(
                        readings: history,
                        preferences: preferences,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.insights_rounded),
                  label: const Text('Weekly recap'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
            ),
          // --- end TASK-028 weekly recap entry point ---
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE6EFEA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            color: const Color(0xFF24443F),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _DashboardHeroCard extends StatefulWidget {
  const _DashboardHeroCard({required this.controller, required this.snapshot});

  final CgmAppController controller;
  final CgmSessionSnapshot snapshot;

  @override
  State<_DashboardHeroCard> createState() => _DashboardHeroCardState();
}

class _DashboardHeroCardState extends State<_DashboardHeroCard> {
  Timer? _ticker;

  Future<void> _copySupportCode(String supportCode) async {
    await Clipboard.setData(ClipboardData(text: supportCode));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Support code copied')));
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preferences = widget.controller.displayPreferences;
    final snapshot = widget.snapshot;
    final latest = widget.controller.displayLatestReading;
    final warmup = computeWarmupStatus(snapshot, latestReading: latest);
    final primaryError = primaryErrorTextForSnapshot(snapshot);
    final privateSupportCode =
        kOgPrivateSupport && shouldOfferPrivateBleSupportCode(snapshot)
        ? privateBleSupportCodeForSnapshot(snapshot)
        : null;

    final String bigValue;
    final String unitLabel;
    final String subtitle;
    final String stageLabel;
    if (warmup != null) {
      bigValue = warmupBigValueText(warmup);
      unitLabel = warmupUnitText(warmup);
      subtitle = warmupSubtext(warmup);
      stageLabel = warmupStageLabel(warmup);
    } else {
      final fallbackValue = snapshot.lastAdvertisement?.displayValueMgdl;
      final displayedValue =
          latest?.displayValue(preferences) ??
          (fallbackValue == null
              ? null
              : preferences.unit.convertFromMgdl(fallbackValue));
      bigValue = displayedValue == null
          ? '--'
          : displayedValue.toStringAsFixed(
              preferences.unit == GlucoseUnit.mgdl ? 0 : 1,
            );
      unitLabel = preferences.unit.label;
      subtitle = 'Latest reading at ${readingTimeText(latest)}';
      stageLabel = stageLabelForSnapshot(snapshot);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Card(
        color: const Color(0xFF113437),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            bigValue,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: theme.textTheme.displayMedium?.copyWith(
                              color: Colors.white,
                              height: 0.92,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            unitLabel,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: const Color(0xFFC7E4DD),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _StagePill(label: stageLabel),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFFD6ECE7),
                ),
              ),
              if (primaryError != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  primaryError,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFFFC4AA),
                  ),
                ),
                if (widget.controller.connectionRequiresUserAction) ...<Widget>[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      FilledButton.tonal(
                        key: const ValueKey<String>('retryBleSetupButton'),
                        onPressed: () =>
                            unawaited(widget.controller.retryConnection()),
                        child: const Text('Try again'),
                      ),
                      OutlinedButton(
                        key: const ValueKey<String>(
                          'chooseAnotherSensorButton',
                        ),
                        onPressed: () =>
                            unawaited(widget.controller.chooseAnotherSensor()),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFF9CC9C1)),
                        ),
                        child: const Text('Choose another sensor'),
                      ),
                    ],
                  ),
                ],
              ],
              if (privateSupportCode != null) ...<Widget>[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey<String>('copyBleSupportCodeButton'),
                  onPressed: () =>
                      unawaited(_copySupportCode(privateSupportCode)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD6ECE7),
                    side: const BorderSide(color: Color(0xFF9CC9C1)),
                  ),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy support code'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StagePill extends StatelessWidget {
  const _StagePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      'Connected' => const Color(0xFF2AB67D),
      'Error' => const Color(0xFFF26D5B),
      'Connecting' ||
      'Setting up' ||
      'Reconnecting' ||
      'Warmup' ||
      'Waiting' => const Color(0xFFF2A65A),
      _ => const Color(0xFF78A5A3),
    };
    return DecoratedBox(
      key: const ValueKey<String>('sessionStagePill'),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final effectiveValue = value.isEmpty ? '--' : value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(effectiveValue)),
        ],
      ),
    );
  }
}

Future<void> _showSettings(
  BuildContext context,
  CgmAppController controller,
) async {
  if (controller.snapshot != null) {
    unawaited(controller.refreshDiagnostics());
    unawaited(controller.loadCalibrations());
  }
  final healthExport = HealthExportScope.of(context);
  var working = controller.displayPreferences;
  final scaleController = TextEditingController(
    text: working.calibrationScale.toStringAsFixed(2),
  );
  final offsetController = TextEditingController(
    text: working.calibrationOffset.toStringAsFixed(1),
  );
  final cropController = TextEditingController(
    text: working.cropFirstSamples.toString(),
  );
  final targetLowController = TextEditingController(
    text: working.targetLowMgdl.toStringAsFixed(0),
  );
  final targetHighController = TextEditingController(
    text: working.targetHighMgdl.toStringAsFixed(0),
  );

  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final snapshot = controller.snapshot;
            final logs = controller.logs;
            final diagnostics =
                snapshot?.diagnostics ?? const <CgmDiagnosticItem>[];
            final calibrations =
                snapshot?.calibrations ?? const <CgmCalibrationEntry>[];

            final displayPane = _buildDisplaySettingsPane(
              context: context,
              controller: controller,
              working: working,
              targetLowController: targetLowController,
              targetHighController: targetHighController,
              setState: setState,
              onWorkingChanged: (next) => working = next,
            );

            return Scaffold(
              body: CustomScrollView(
                slivers: <Widget>[
                  const SliverAppBar.large(title: Text('Settings')),
                  SliverToBoxAdapter(
                    child: _SettingsOverview(
                      controller: controller,
                      healthExport: healthExport,
                      displayPane: displayPane,
                      hasActiveSensor: snapshot != null,
                      developerPane: snapshot == null
                          ? null
                          : _buildDeveloperSettingsPane(
                              context: context,
                              controller: controller,
                              snapshot: snapshot,
                              diagnostics: diagnostics,
                              calibrations: calibrations,
                              logs: logs,
                              scaleController: scaleController,
                              offsetController: offsetController,
                              cropController: cropController,
                              onScenarioChanged: (scenario) {
                                controller.applyMockScenario(scenario);
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
  scaleController.dispose();
  offsetController.dispose();
  cropController.dispose();
  targetLowController.dispose();
  targetHighController.dispose();
}

class _SettingsOverview extends StatelessWidget {
  const _SettingsOverview({
    required this.controller,
    required this.healthExport,
    required this.displayPane,
    required this.hasActiveSensor,
    this.developerPane,
  });

  final CgmAppController controller;
  final HealthExportController healthExport;
  final Widget displayPane;
  final bool hasActiveSensor;
  final Widget? developerPane;

  @override
  Widget build(BuildContext context) {
    final archivedCount = controller.archivedSensors.length;
    final macosSecureStorageDisabled = shouldDisableMacosSecureStorage(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    );
    return Column(
      key: const ValueKey<String>('settingsOverview'),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: _SettingsHero(controller: controller),
        ),
        const SizedBox(height: 22),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel('SENSOR'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              if (hasActiveSensor)
                _SettingsDestination(
                  icon: Icons.sensors_rounded,
                  title: 'Current sensor',
                  subtitle: 'Status, life, identity, and connection',
                  listenable: controller,
                  builder: (context) {
                    final snapshot = controller.snapshot;
                    if (snapshot == null) {
                      return const _InactiveSensorSettingsPane();
                    }
                    return _buildSensorSettingsPane(
                      context,
                      controller,
                      snapshot,
                    );
                  },
                )
              else
                _SettingsAction(
                  icon: Icons.add_circle_outline_rounded,
                  title: 'Connect a sensor',
                  subtitle: 'No sensor is active',
                  onTap: () => Navigator.of(context).pop(),
                ),
              _SettingsDestination(
                icon: Icons.archive_outlined,
                title: 'Sensor archive',
                subtitle:
                    '$archivedCount previous '
                    '${archivedCount == 1 ? 'sensor' : 'sensors'}',
                listenable: controller,
                builder: (_) => _SensorArchivePane(controller: controller),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel('PREFERENCES'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              _SettingsDestination(
                icon: Icons.monitor_heart_outlined,
                title: 'Glucose & display',
                subtitle:
                    '${controller.displayPreferences.unit.label} · '
                    '${controller.displayPreferences.targetLowMgdl.toStringAsFixed(0)}–'
                    '${controller.displayPreferences.targetHighMgdl.toStringAsFixed(0)}',
                child: displayPane,
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel('DATA & INTEGRATIONS'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              _SettingsDestination(
                icon: Icons.favorite_outline_rounded,
                title: 'Apple Health',
                subtitle: 'Glucose export and health data controls',
                child: IntegrationsSettingsPane(
                  healthExport: healthExport,
                  controller: controller,
                ),
              ),
              if (macosSecureStorageDisabled)
                const _SettingsDestination(
                  icon: Icons.auto_awesome_outlined,
                  title: 'AI & models',
                  subtitle: 'Unavailable in this reviewer preview',
                  child: MacosPreviewUnavailableAiPane(),
                )
              else
                _SettingsDestination(
                  icon: Icons.auto_awesome_outlined,
                  title: 'AI & models',
                  subtitle: 'Experimental · off until you enable it',
                  child: AiSettingsPane(
                    recentReadings: controller.allHistoricalReadings,
                    unit: controller.displayPreferences.unit,
                  ),
                ),
              const _SettingsDestination(
                icon: Icons.shield_outlined,
                title: 'Privacy & data',
                subtitle: 'Local storage and retention',
                child: _PrivacyDataPane(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel('APP'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              const _SettingsDestination(
                icon: Icons.info_outline_rounded,
                title: 'About OpenGlucose',
                subtitle: 'Version, purpose, and open-source project',
                child: _AboutPane(),
              ),
              if ((kDebugMode || controller.isMockDriver) &&
                  developerPane != null)
                _SettingsDestination(
                  icon: Icons.developer_mode_rounded,
                  title: 'Advanced',
                  subtitle: 'Diagnostics and developer tools',
                  child: developerPane,
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _SettingsHero extends StatelessWidget {
  const _SettingsHero({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = controller.snapshot;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF103B3C),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: Color(0xFF245756),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.water_drop_rounded, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  snapshot == null
                      ? 'No active sensor'
                      : snapshot.sensor.displayName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  snapshot == null
                      ? 'Your previous data stays on this iPhone.'
                      : sensorLifeText(snapshot.sessionInfo.sessionStart),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFD8EEE8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: const Color(0xFF5B6E6A),
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (var index = 0; index < children.length; index++) ...<Widget>[
            children[index],
            if (index != children.length - 1)
              const Divider(height: 1, indent: 64),
          ],
        ],
      ),
    );
  }
}

class _SettingsDestination extends StatelessWidget {
  const _SettingsDestination({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.child,
    this.builder,
    this.listenable,
  }) : assert(
         child != null || builder != null,
         'A settings destination needs either a child or a builder.',
       );

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? child;
  final WidgetBuilder? builder;
  final Listenable? listenable;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 68,
      leading: _SettingsIcon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (routeContext) {
            Widget buildBody(BuildContext context) =>
                builder?.call(context) ?? child!;
            return Scaffold(
              appBar: AppBar(title: Text(title)),
              body: listenable == null
                  ? buildBody(routeContext)
                  : AnimatedBuilder(
                      animation: listenable!,
                      builder: (context, _) => buildBody(context),
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsAction extends StatelessWidget {
  const _SettingsAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 68,
      leading: _SettingsIcon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFE6EFEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: const Color(0xFF0B6E69)),
    );
  }
}

class _InactiveSensorSettingsPane extends StatelessWidget {
  const _InactiveSensorSettingsPane();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.sensors_off_rounded,
              size: 42,
              color: Color(0xFF0B6E69),
            ),
            const SizedBox(height: 14),
            Text(
              'This sensor is no longer active',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            const Text(
              'Return to Settings to review Sensor archive or connect another '
              'sensor.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SensorArchivePane extends StatelessWidget {
  const _SensorArchivePane({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final sessions = controller.archivedSensors;
    if (sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Previous sensors will appear here after they expire or are replaced.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        final date = session.endedAt ?? session.lastReadingAt;
        final displayReadingCount = controller
            .displayReadingsForArchivedSensor(session)
            .length;
        return Card(
          child: ListTile(
            minTileHeight: 76,
            leading: const _SettingsIcon(Icons.sensors_off_rounded),
            title: Text(
              session.serial.isEmpty ? session.displayName : session.serial,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              '${_archiveReasonLabel(session.reason)} · '
              '$displayReadingCount readings'
              '${date == null ? '' : ' · ${DateFormat('MMM d, y').format(date)}'}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _ArchivedSensorDetail(
                  controller: controller,
                  session: session,
                ),
              ),
            ),
          ),
        );
      },
      separatorBuilder: (_, _) => const SizedBox(height: 8),
    );
  }
}

class _ArchivedSensorDetail extends StatelessWidget {
  const _ArchivedSensorDetail({
    required this.controller,
    required this.session,
  });

  final CgmAppController controller;
  final ArchivedSensorSession session;

  @override
  Widget build(BuildContext context) {
    final rawReadings = controller.readingsForArchivedSensor(session);
    final readings = controller.displayReadingsForArchivedSensor(session);
    final theme = Theme.of(context);
    var recapAnchor = session.lastReadingAt;
    for (final reading in readings) {
      final recordedAt = reading.recordedAt;
      if (recordedAt != null &&
          (recapAnchor == null || recordedAt.isAfter(recapAnchor))) {
        recapAnchor = recordedAt;
      }
    }
    recapAnchor ??= session.endedAt;
    return Scaffold(
      appBar: AppBar(title: const Text('Previous sensor')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: <Widget>[
          Text(
            session.serial.isEmpty ? session.displayName : session.serial,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_archiveReasonLabel(session.reason)} · history only, not connected',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF5B6E6A),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  _KeyValueRow(label: 'Readings', value: '${readings.length}'),
                  _KeyValueRow(
                    label: 'Started',
                    value: session.startedAt == null
                        ? '--'
                        : DateFormat(
                            'MMM d, y HH:mm',
                          ).format(session.startedAt!),
                  ),
                  _KeyValueRow(
                    label: 'Ended',
                    value: session.endedAt == null
                        ? '--'
                        : DateFormat('MMM d, y HH:mm').format(session.endedAt!),
                  ),
                  if (session.model.isNotEmpty)
                    _KeyValueRow(label: 'Model', value: session.model),
                ],
              ),
            ),
          ),
          if (readings.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  height: 300,
                  child: CgmDashboardChart(
                    readings: readings,
                    preferences: controller.displayPreferences,
                    historySync: const CgmHistorySyncState(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WeeklyRecapScreen(
                    readings: readings,
                    preferences: controller.displayPreferences,
                    now: recapAnchor,
                  ),
                ),
              ),
              icon: const Icon(Icons.insights_rounded),
              label: const Text('Recap this sensor'),
            ),
          ],
          if (rawReadings.isNotEmpty) ...<Widget>[
            SizedBox(height: readings.isNotEmpty ? 10 : 16),
            Builder(
              builder: (buttonContext) => SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey<String>('exportArchivedSensorData'),
                  onPressed: () async {
                    final format = await _chooseArchivedSensorExportFormat(
                      buttonContext,
                      session: session,
                      readings: rawReadings,
                      displayReadingCount: readings.length,
                    );
                    if (format == null || !buttonContext.mounted) {
                      return;
                    }
                    await _exportArchivedSensorData(
                      buttonContext,
                      format: format,
                      session: session,
                      readings: rawReadings,
                    );
                  },
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Export data'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<ArchivedSensorExportFormat?> _chooseArchivedSensorExportFormat(
  BuildContext context, {
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
  required int displayReadingCount,
}) async {
  final hiddenWarmupCount = readings.length - displayReadingCount;
  DateTime? firstReadingAt;
  DateTime? lastReadingAt;
  for (final reading in readings) {
    final recordedAt = reading.recordedAt;
    if (recordedAt == null) {
      continue;
    }
    if (firstReadingAt == null || recordedAt.isBefore(firstReadingAt)) {
      firstReadingAt = recordedAt;
    }
    if (lastReadingAt == null || recordedAt.isAfter(lastReadingAt)) {
      lastReadingAt = recordedAt;
    }
  }
  final rangeStart = firstReadingAt ?? session.startedAt;
  final rangeEnd = lastReadingAt ?? session.lastReadingAt ?? session.endedAt;
  final dateFormat = DateFormat('MMM d, y · HH:mm');
  final dateRange = rangeStart == null || rangeEnd == null
      ? 'Date range unavailable'
      : '${dateFormat.format(rangeStart.toLocal())} – '
            '${dateFormat.format(rangeEnd.toLocal())}';
  var selectedFormat = ArchivedSensorExportFormat.csv;
  return showDialog<ArchivedSensorExportFormat>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Export archived sensor data'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('${readings.length} stored glucose readings'),
              if (hiddenWarmupCount > 0) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  '$hiddenWarmupCount warmup '
                  '${hiddenWarmupCount == 1 ? 'reading is' : 'readings are'} '
                  'included for a complete export. These remain hidden from '
                  'charts, recaps, and Apple Health.',
                  key: const ValueKey<String>('archivedExportWarmupDisclosure'),
                ),
              ],
              const SizedBox(height: 4),
              Text(dateRange),
              const SizedBox(height: 18),
              const Text(
                'File format',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ArchivedSensorExportFormat>(
                  key: const ValueKey<String>(
                    'archivedSensorExportFormatPicker',
                  ),
                  segments: const <ButtonSegment<ArchivedSensorExportFormat>>[
                    ButtonSegment<ArchivedSensorExportFormat>(
                      value: ArchivedSensorExportFormat.csv,
                      label: Text(
                        'CSV',
                        key: ValueKey<String>('exportFormatCsv'),
                      ),
                    ),
                    ButtonSegment<ArchivedSensorExportFormat>(
                      value: ArchivedSensorExportFormat.txt,
                      label: Text(
                        'TXT',
                        key: ValueKey<String>('exportFormatTxt'),
                      ),
                    ),
                    ButtonSegment<ArchivedSensorExportFormat>(
                      value: ArchivedSensorExportFormat.xlsx,
                      label: Text(
                        'XLSX',
                        key: ValueKey<String>('exportFormatXlsx'),
                      ),
                    ),
                  ],
                  selected: <ArchivedSensorExportFormat>{selectedFormat},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setDialogState(() => selectedFormat = selection.single);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(_archivedSensorFormatDescription(selectedFormat)),
              const SizedBox(height: 18),
              const Text(
                'Included in the file',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text('• Glucose values in mg/dL and mmol/L'),
              const Text('• Reading times, source, and sensor minute'),
              const Text('• Raw quality fields and provisional state'),
              const Text('• Archive reason and session timing'),
              const SizedBox(height: 14),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.privacy_tip_outlined,
                    size: 20,
                    color: Color(0xFF0B6E69),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Sensor serials, device IDs, and storage identifiers '
                      'are not included.',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmArchivedSensorExport'),
            onPressed: () => Navigator.of(dialogContext).pop(selectedFormat),
            child: Text('Share ${selectedFormat.extension.toUpperCase()}'),
          ),
        ],
      ),
    ),
  );
}

String _archivedSensorFormatDescription(ArchivedSensorExportFormat format) =>
    switch (format) {
      ArchivedSensorExportFormat.csv =>
        'Best for importing into most spreadsheet and analysis apps.',
      ArchivedSensorExportFormat.txt =>
        'A tab-separated plain-text file that is easy to inspect anywhere.',
      ArchivedSensorExportFormat.xlsx =>
        'A real Excel workbook with glucose measurements stored as numbers.',
    };

Future<void> _exportArchivedSensorData(
  BuildContext context, {
  required ArchivedSensorExportFormat format,
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
}) async {
  final share = _ArchivedSensorShareScope.of(context);
  final renderBox = context.findRenderObject() as RenderBox?;
  final shareOrigin = renderBox == null
      ? null
      : renderBox.localToGlobal(Offset.zero) & renderBox.size;
  String? preparedFilePath;
  try {
    final bytes = await compute(_buildArchivedSensorExportInBackground, (
      format: format,
      session: session,
      readings: List<CgmReading>.of(readings, growable: false),
    ));
    final filename = archivedSensorExportFilename(format);
    preparedFilePath = await prepareArchivedSensorShareFileBytes(
      filename: filename,
      bytes: bytes,
    );
    final exportFile = preparedFilePath == null
        ? XFile.fromData(bytes, mimeType: format.mimeType)
        : XFile(preparedFilePath, mimeType: format.mimeType);
    await share(
      buildArchivedSensorShareParams(
        file: exportFile,
        filename: filename,
        sharePositionOrigin: shareOrigin,
      ),
    );
  } catch (_) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('The archived sensor data could not be exported.'),
      ),
    );
  } finally {
    await disposeArchivedSensorShareFile(preparedFilePath);
  }
}

String _archiveReasonLabel(SensorArchiveReason reason) => switch (reason) {
  SensorArchiveReason.expired => 'Expired',
  SensorArchiveReason.replaced => 'Replaced',
  SensorArchiveReason.disconnected => 'Disconnected',
};

class _PrivacyDataPane extends StatelessWidget {
  const _PrivacyDataPane();

  @override
  Widget build(BuildContext context) {
    final isMacosPreview =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final storageTitle = isMacosPreview
        ? 'Stored in this Mac app container'
        : 'Stored on this iPhone';
    final storageDescription = isMacosPreview
        ? 'Sensor identity and glucose history remain local. Backup exclusion '
              "is not verified for this preview; check this Mac's backup policy."
        : 'Sensor identity and glucose history remain local and are excluded '
              'from device backups.';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            isMacosPreview
                ? Icons.desktop_mac_outlined
                : Icons.phone_iphone_rounded,
          ),
          title: Text(storageTitle),
          subtitle: Text(storageDescription),
        ),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.cloud_off_rounded),
          title: Text('No OpenGlucose cloud'),
          subtitle: Text(
            'Data leaves the app only when you explicitly enable an integration.',
          ),
        ),
      ],
    );
  }
}

class _AboutPane extends StatelessWidget {
  const _AboutPane();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        const Icon(
          Icons.water_drop_rounded,
          size: 56,
          color: Color(0xFF0B6E69),
        ),
        const SizedBox(height: 12),
        Text(
          'OpenGlucose',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        const Text('Version 0.0.1', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        const Text(
          'A local-first, open-source wellness app for viewing your own glucose '
          'data. OpenGlucose is not a medical device and does not provide '
          'diagnosis or treatment advice.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

Widget _buildDisplaySettingsPane({
  required BuildContext context,
  required CgmAppController controller,
  required DisplayPreferences working,
  required TextEditingController targetLowController,
  required TextEditingController targetHighController,
  required void Function(void Function()) setState,
  required void Function(DisplayPreferences) onWorkingChanged,
}) {
  return ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
    children: <Widget>[
      Text(
        'Display settings',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<GlucoseUnit>(
        initialValue: working.unit,
        decoration: const InputDecoration(labelText: 'Unit'),
        items: GlucoseUnit.values
            .map(
              (value) => DropdownMenuItem<GlucoseUnit>(
                value: value,
                child: Text(value.label),
              ),
            )
            .toList(growable: false),
        onChanged: (value) =>
            setState(() => onWorkingChanged(working.copyWith(unit: value))),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<ChartStyle>(
        initialValue: working.chartStyle,
        decoration: const InputDecoration(labelText: 'Chart style'),
        items: ChartStyle.values
            .map(
              (value) => DropdownMenuItem<ChartStyle>(
                value: value,
                child: Text(value.name),
              ),
            )
            .toList(growable: false),
        onChanged: (value) => setState(
          () => onWorkingChanged(working.copyWith(chartStyle: value)),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: targetLowController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Target low (mg/dL)',
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: targetHighController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Target high (mg/dL)',
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          FilledButton(
            onPressed: () {
              final targetLow = double.tryParse(targetLowController.text);
              final targetHigh = double.tryParse(targetHighController.text);
              if (targetLow == null ||
                  targetHigh == null ||
                  !targetLow.isFinite ||
                  !targetHigh.isFinite ||
                  targetLow <= 0 ||
                  targetHigh <= targetLow) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter an increasing target glucose range.'),
                  ),
                );
                return;
              }
              controller.updateDisplayPreferences(
                working.copyWith(
                  targetLowMgdl: targetLow,
                  targetHighMgdl: targetHigh,
                ),
              );
              Navigator.of(context).pop();
            },
            child: const Text('Save settings'),
          ),
        ],
      ),
    ],
  );
}

Widget _buildSensorSettingsPane(
  BuildContext context,
  CgmAppController controller,
  CgmSessionSnapshot snapshot,
) {
  final sessionStart = snapshot.sessionInfo.sessionStart;
  final interruptedTransferState =
      snapshot.metadata[cgmBondTransferStateMetadataKey];
  final hasInterruptedTransfer = interruptedTransferState != null;
  final canAcknowledgeInterruptedTransfer =
      interruptedTransferState == 'sensor-accepted';
  final supportsAndroidSensorTransfer =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final supportsLiveGlucoseConsent =
      !kIsWeb &&
      !controller.isMockDriver &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  return ListView(
    padding: const EdgeInsets.all(20),
    children: <Widget>[
      SensorLifecycleCard(
        snapshot: snapshot,
        latestReading: controller.displayLatestReading,
        onReplaceSensor: () => unawaited(controller.replaceCurrentSensor()),
        outerPadding: EdgeInsets.zero,
      ),
      if (supportsLiveGlucoseConsent) ...<Widget>[
        const SizedBox(height: 18),
        Card(
          child: SwitchListTile.adaptive(
            key: const ValueKey<String>('sensitiveLiveActivityContentToggle'),
            title: const Text('Show glucose in live notification'),
            subtitle: const Text(
              'Allows glucose values, trends, and update times to appear in '
              'the Android live notification or iOS Live Activity. Anyone '
              'who can view your lock screen may see this health data.',
            ),
            value: controller.sensitiveLiveActivityContentEnabled,
            onChanged: controller.liveActivityPrivacyUpdateInFlight
                ? null
                : (enabled) => unawaited(
                    controller.updateSensitiveLiveActivityContent(
                      enabled: enabled,
                    ),
                  ),
          ),
        ),
      ],
      const SizedBox(height: 18),
      Text(
        'Sensor details',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      _KeyValueRow(label: 'Serial', value: snapshot.sessionInfo.serial),
      _KeyValueRow(label: 'Model', value: snapshot.sessionInfo.model),
      _KeyValueRow(label: 'Firmware', value: snapshot.sessionInfo.firmware),
      _KeyValueRow(
        label: 'Sensor start',
        value: sessionStart == null
            ? '--'
            : DateFormat('MMM d, HH:mm').format(sessionStart.toLocal()),
      ),
      _KeyValueRow(
        label: 'History',
        value: '${snapshot.history.length} reading(s)',
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          FilledButton(
            key: ValueKey<String>(
              hasInterruptedTransfer
                  ? 'reviewSelectedInterruptedMoveButton'
                  : 'disconnectSensorButton',
            ),
            onPressed:
                controller.bondTransferInFlight ||
                    (hasInterruptedTransfer &&
                        !canAcknowledgeInterruptedTransfer)
                ? null
                : canAcknowledgeInterruptedTransfer
                ? () => unawaited(
                    _confirmInterruptedSelectedSensorTransferRecovery(
                      context,
                      controller,
                    ),
                  )
                : () async {
                    await controller.disconnect();
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
            child: Text(
              hasInterruptedTransfer
                  ? canAcknowledgeInterruptedTransfer
                        ? 'Review interrupted move'
                        : 'Move needs support'
                  : 'Disconnect',
            ),
          ),
          if (supportsAndroidSensorTransfer &&
              (controller.canMoveSensorToAnotherPhone ||
                  controller.bondTransferInFlight))
            OutlinedButton.icon(
              key: const ValueKey<String>('moveSensorToAnotherPhoneButton'),
              onPressed: controller.canMoveSensorToAnotherPhone
                  ? () => unawaited(
                      _confirmAndMoveSensorToAnotherPhone(context, controller),
                    )
                  : null,
              icon: const Icon(Icons.phonelink_erase_rounded),
              label: const Text('Move sensor to another phone'),
            ),
        ],
      ),
      if (hasInterruptedTransfer &&
          !canAcknowledgeInterruptedTransfer) ...<Widget>[
        const SizedBox(height: 12),
        const Text(
          'The sensor response is unknown. Do not reconnect, forget the '
          'Android bond, disconnect, or retry. Contact support for a reviewed '
          'recovery.',
          style: TextStyle(color: Color(0xFF9A4D00), height: 1.35),
        ),
      ],
    ],
  );
}

Future<void> _confirmInterruptedSelectedSensorTransferRecovery(
  BuildContext context,
  CgmAppController controller,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Review interrupted sensor move'),
      content: const Text(
        'Open Android Bluetooth settings. Confirm that the sensor is not '
        'listed as paired. If it is listed, choose Forget first. Continuing '
        'clears the app safety marker and archives this selection. It does '
        'not contact the sensor or change a Bluetooth bond.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('confirmSelectedInterruptedMoveRecovery'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('I checked Bluetooth'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }
  try {
    await controller.acknowledgeInterruptedSelectedSensorTransfer();
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.lastError ??
                'The interrupted sensor move could not be cleared.',
          ),
        ),
      );
    }
  }
}

Future<void> _confirmAndMoveSensorToAnotherPhone(
  BuildContext context,
  CgmAppController controller,
) async {
  CgmBondTransferPlan plan;
  try {
    plan = await controller.inspectSensorTransfer();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.lastError ?? 'The sensor cannot be moved safely.',
          ),
        ),
      );
    }
    return;
  }
  if (!context.mounted) {
    return;
  }

  final removesAllBonds = plan.removesAllLeBonds;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        removesAllBonds
            ? 'Remove all sensor phone bonds?'
            : 'Move sensor to another phone?',
      ),
      content: Text(
        removesAllBonds
            ? 'This sensor only supports removing every phone bond stored by '
                  'the transmitter. It will disconnect from this phone and '
                  'all other phones. The sensor session is not reset. Keep '
                  'the sensor close and do not retry if an error appears.'
            : "This removes this phone's bond from the sensor and Android, "
                  'then disconnects. The sensor session is not reset. Keep '
                  'the sensor close and do not retry if an error appears.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('confirmMoveSensorButton'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Move sensor'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }

  try {
    await controller.moveSensorToAnotherPhone(plan);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sensor is ready to pair with another phone.'),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.lastError ??
                'Sensor transfer stopped. Do not retry automatically.',
          ),
        ),
      );
    }
  }
}

Widget _buildDeveloperSettingsPane({
  required BuildContext context,
  required CgmAppController controller,
  required CgmSessionSnapshot snapshot,
  required List<CgmDiagnosticItem> diagnostics,
  required List<CgmCalibrationEntry> calibrations,
  required List<CgmLogEntry> logs,
  required TextEditingController scaleController,
  required TextEditingController offsetController,
  required TextEditingController cropController,
  required ValueChanged<MockScenario> onScenarioChanged,
}) {
  final metadataEntries = <MapEntry<String, String>>[
    MapEntry('deviceId', snapshot.sensor.deviceId),
    MapEntry('driverId', snapshot.sensor.driverId),
    MapEntry('serial', snapshot.sessionInfo.serial),
    MapEntry('firmware', snapshot.sessionInfo.firmware),
    MapEntry('history', '${snapshot.history.length} records'),
    MapEntry('rawHistory', '${snapshot.rawHistory.length} records'),
    ...snapshot.metadata.entries,
  ];

  return ListView(
    padding: const EdgeInsets.all(20),
    children: <Widget>[
      Text(
        'Developer',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 16),
      if (controller.isMockDriver) ...<Widget>[
        Text(
          'Mock scenario',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<MockScenario>(
          key: const ValueKey<String>('mockScenarioPicker'),
          initialValue: controller.mockScenario ?? MockScenario.activeNormal,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Simulated sensor state',
          ),
          items: MockScenario.values
              .map(
                (scenario) => DropdownMenuItem<MockScenario>(
                  value: scenario,
                  child: Text(scenario.label),
                ),
              )
              .toList(growable: false),
          onChanged: (scenario) {
            if (scenario != null) {
              onScenarioChanged(scenario);
            }
          },
        ),
        const SizedBox(height: 6),
        Text(
          (controller.mockScenario ?? MockScenario.activeNormal).description,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF5B6E6A)),
        ),
        const Divider(height: 28),
      ],
      Text(
        'Engineering controls',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 6),
      const Text(
        'Advanced corrections for diagnostics and sensor-data troubleshooting.',
        style: TextStyle(color: Color(0xFF5B6E6A)),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey<String>('advancedCalibrationScale'),
        controller: scaleController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Calibration scale'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: offsetController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Calibration offset'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: cropController,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Crop first N samples'),
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          FilledButton(
            onPressed: () {
              final scale = double.tryParse(scaleController.text);
              final offset = double.tryParse(offsetController.text);
              final crop = int.tryParse(cropController.text);
              if (scale == null ||
                  offset == null ||
                  crop == null ||
                  !scale.isFinite ||
                  !offset.isFinite ||
                  scale <= 0 ||
                  crop < 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter valid engineering correction values.'),
                  ),
                );
                return;
              }
              controller.updateDisplayPreferences(
                controller.displayPreferences.copyWith(
                  calibrationScale: scale,
                  calibrationOffset: offset,
                  cropFirstSamples: crop,
                ),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Engineering settings saved.')),
              );
            },
            child: const Text('Save engineering settings'),
          ),
          if (!controller.isMockDriver)
            OutlinedButton(
              key: const ValueKey<String>('clearActiveSensorCache'),
              onPressed: () => unawaited(
                _confirmClearActiveSensorCache(context, controller),
              ),
              child: const Text('Clear active sensor cache'),
            ),
        ],
      ),
      if (!controller.isMockDriver) ...<Widget>[
        const SizedBox(height: 8),
        const Text(
          'Clears only the active sensor’s local cache. Sensor archive is not '
          'deleted, and available readings may download again from the sensor.',
          style: TextStyle(color: Color(0xFF5B6E6A)),
        ),
      ],
      const Divider(height: 28),
      Text(
        'Metadata',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      for (final entry in metadataEntries) _MetadataRow(entry: entry),
      const SizedBox(height: 16),
      Text(
        'Diagnostics',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      if (diagnostics.isEmpty)
        const Text('No diagnostics loaded yet.')
      else
        for (final item in diagnostics) ...<Widget>[
          Text(item.title, style: const TextStyle(fontWeight: FontWeight.w800)),
          if (item.summary.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(item.summary),
          ],
          if (item.rawHex.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            SelectableText(
              item.rawHex,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
          if (item.fields.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            for (final field in item.fields.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${field.key}: ${field.value}'),
              ),
          ],
          const Divider(height: 28),
        ],
      Text(
        'Calibrations',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      if (calibrations.isEmpty)
        const Text('No calibration entries loaded.')
      else
        for (final entry in calibrations)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '#${entry.index}  ${entry.glucoseMgdl ?? '--'} mg/dL  ${entry.recordedAt == null ? '' : DateFormat('MMM d, HH:mm').format(entry.recordedAt!.toLocal())}',
            ),
          ),
      const SizedBox(height: 16),
      Text(
        'Logs',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      if (logs.isEmpty)
        const Text('No logs yet.')
      else
        for (final entry in logs) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 92,
                child: Text(
                  DateFormat('HH:mm:ss').format(entry.timestamp.toLocal()),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  entry.level.name.toUpperCase(),
                  style: const TextStyle(color: Color(0xFF5B6E6A)),
                ),
              ),
              Expanded(child: Text(entry.message)),
            ],
          ),
          const Divider(height: 20),
        ],
    ],
  );
}

Future<void> _confirmClearActiveSensorCache(
  BuildContext context,
  CgmAppController controller,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Clear active sensor cache?'),
      content: const Text(
        'This removes only the locally cached history for the active sensor. '
        'Archived sensors are kept, and available readings may download again.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Clear cache'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }
  final cleared = await controller.clearPersistedHistory();
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        cleared
            ? 'Active sensor cache cleared.'
            : 'No active sensor cache was cleared.',
      ),
    ),
  );
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.entry});

  final MapEntry<String, String> entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              entry.key,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(entry.value)),
        ],
      ),
    );
  }
}
