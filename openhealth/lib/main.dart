import 'dart:async';
import 'dart:ui';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
import 'package:openglucose/src/ai/ai_settings_pane.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:openglucose/src/app_localizations_extension.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/archived_sensor_export_diagnostics.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/driver_factory.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/health_state_store_factory.dart';
import 'package:openglucose/src/integrations_settings_pane.dart';
import 'package:openglucose/src/ios_export_share.dart';
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
  final languageController = AppLanguageController(preferences: preferences);
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
    languageController: languageController,
    preferences: preferences,
    healthExport: healthExport,
    messages: messages,
  );
}

typedef _BootstrapResult = ({
  CgmAppController controller,
  HealthExportController healthExport,
  AppLanguageController languageController,
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
          return _SplashApp(error: snapshot.error);
        }
        final result = snapshot.data!;
        return OpenGlucoseApp(
          controller: result.controller,
          healthExport: result.healthExport,
          preferences: result.preferences,
          languageController: result.languageController,
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
      locale: AppLanguageController.resolveDeviceLocales(
        WidgetsBinding.instance.platformDispatcher.locales,
      ).locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Scaffold(
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
                      context.l10n.failedToStart(error.runtimeType.toString()),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFB24A3B)),
                    ),
                  ),
                ],
              ],
            ),
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
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    final files = params.files;
    final subject = params.subject ?? params.title;
    if (files == null || files.length != 1 || files.single.path.isEmpty) {
      throw ArgumentError(
        'iOS archived-sensor export requires one prepared file.',
      );
    }
    if (subject == null || subject.isEmpty) {
      throw ArgumentError('iOS archived-sensor export requires a share title.');
    }
    await const IosExportShare().shareFile(
      filePath: files.single.path,
      subject: subject,
      sharePositionOrigin: params.sharePositionOrigin,
    );
    return;
  }
  await SharePlus.instance.share(params);
}

/// Builds a one-attachment native share request.
///
/// In particular, this intentionally omits `text`: share_plus represents that
/// as a second iOS activity item, which Files can save as an extra text file.
ShareParams buildArchivedSensorShareParams({
  required XFile file,
  required String filename,
  required String localizedTitle,
  Rect? sharePositionOrigin,
}) => ShareParams(
  title: localizedTitle,
  subject: localizedTitle,
  files: <XFile>[file],
  fileNameOverrides: <String>[filename],
  mailToFallbackEnabled: false,
  sharePositionOrigin: sharePositionOrigin,
);

class OpenGlucoseApp extends StatefulWidget {
  const OpenGlucoseApp({
    super.key,
    required this.controller,
    required this.healthExport,
    required this.preferences,
    this.languageController,
    this.messageController,
    this.archivedSensorShareAction,
  });

  final CgmAppController controller;
  final HealthExportController healthExport;
  final SharedPreferences preferences;
  final AppLanguageController? languageController;

  /// Optional contextual-messaging engine. When null (e.g. in some tests) the
  /// dashboard simply renders no message host.
  final MessageController? messageController;

  /// Optional share-sheet seam used by export integration tests.
  final ArchivedSensorShareAction? archivedSensorShareAction;

  @override
  State<OpenGlucoseApp> createState() => _OpenGlucoseAppState();
}

class _OpenGlucoseAppState extends State<OpenGlucoseApp> {
  late final AppLanguageController _languageController =
      widget.languageController ??
      AppLanguageController(preferences: widget.preferences);
  late final bool _ownsLanguageController = widget.languageController == null;

  @override
  void initState() {
    super.initState();
    _languageController.addListener(_syncLiveSurfaceLanguage);
    _syncLiveSurfaceLanguage();
  }

  void _syncLiveSurfaceLanguage() {
    unawaited(
      widget.controller.updateAppLanguage(_languageController.resolvedLanguage),
    );
  }

  @override
  void dispose() {
    _languageController.removeListener(_syncLiveSurfaceLanguage);
    if (_ownsLanguageController) {
      _languageController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0B6E69);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFFFF8F1),
    );
    return AnimatedBuilder(
      animation: _languageController,
      builder: (context, _) => AppLanguageScope(
        controller: _languageController,
        child: _ArchivedSensorShareScope(
          share: widget.archivedSensorShareAction ?? _shareArchivedSensorFile,
          child: HealthExportScope(
            controller: widget.healthExport,
            child: MaterialApp(
              title: 'OpenGlucose',
              locale: _languageController.resolvedLocale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
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
              // First-run only: show the skippable onboarding flow, then hand
              // off to the existing scan/connect home. Persisted via
              // OnboardingStore; once completed/skipped the gate falls straight
              // through on later launches.
              home: _OnboardingGate(
                store: OnboardingStore(widget.preferences),
                controller: widget.controller,
                unit: widget.controller.displayPreferences.unit,
                home: CgmHomePage(
                  controller: widget.controller,
                  messageController: widget.messageController,
                ),
              ),
              // --- end TASK-007 onboarding gate ---
            ),
          ),
        ),
      ),
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
    final l10n = context.l10n;
    final archivedSensors = controller.archivedSensors;
    final latestArchived = archivedSensors.isEmpty
        ? null
        : archivedSensors.first;
    final inactiveMessage = switch (latestArchived?.reason) {
      SensorArchiveReason.expired => l10n.inactiveSensorExpired,
      SensorArchiveReason.replaced => l10n.inactiveSensorReplaced,
      SensorArchiveReason.disconnected => l10n.inactiveSensorDisconnected,
      null => l10n.inactiveSensorWelcome,
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
                            l10n.appTitle,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: l10n.settings,
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
                                ? l10n.scanning
                                : l10n.findMySensor,
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
                            label: Text(l10n.exploreSampleData),
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
                  l10n.nearbySensors,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  l10n.sensorsFound(controller.sensors.length),
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
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(l10n.noSensorsFound, textAlign: TextAlign.center),
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
                                          ? l10n.reviewMove
                                          : l10n.moveNeedsSupport,
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
                                  child: Text(l10n.connect),
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
                                label: l10n.counter(advertisement!.counter!),
                              ),
                            if (sensor.metadata['mode'] == 'demo')
                              _MetricChip(label: l10n.demoTransport),
                          ],
                        ),
                        if (hasInterruptedTransfer &&
                            !canAcknowledgeInterruptedTransfer) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            l10n.unknownSensorResponse,
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
      title: Text(context.l10n.reviewInterruptedSensorMove),
      content: Text(context.l10n.interruptedSensorMoveReview),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey<String>('confirmInterruptedMoveRecovery'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.checkedBluetooth),
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
                context.l10n.interruptedSensorMoveCouldNotClear,
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
              _scanFailureTitle(context, failure),
              key: const ValueKey<String>('sensorScanFailureTitle'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              controller.scanFailureMessage ?? context.l10n.scanSensorHelp,
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
              label: Text(context.l10n.tryAgain),
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
                      _scanFailureTitle(context, failure),
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
                    context.l10n.scanSensorHelpShort,
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
                label: Text(context.l10n.scanAgain),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _scanFailureTitle(
  BuildContext context,
  BleFailure failure,
) => switch (failure.kind) {
  BleFailureKind.bluetoothOff => context.l10n.bluetoothOffTitle,
  BleFailureKind.permissionRequired => context.l10n.bluetoothPermissionTitle,
  BleFailureKind.bluetoothUnavailable => context.l10n.bluetoothUnavailableTitle,
  _ => context.l10n.scanSensorsFailedTitle,
};

class _HistoricalOverviewCard extends StatelessWidget {
  const _HistoricalOverviewCard({required this.controller});

  final CgmAppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
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
                      l10n.yourGlucoseHistory,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                <String>[
                  l10n.archivedSensorsCount(controller.archivedSensors.length),
                  l10n.readingCount(readings.length),
                  if (latest != null)
                    l10n.lastAt(_localizedShortDateTime(context, latest)),
                ].join(' · '),
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
                        label: l10n.firstReading,
                        value: _localizedDateTime(context, first!),
                      ),
                      _KeyValueRow(
                        label: l10n.latestReading,
                        value: _localizedDateTime(context, latest!),
                      ),
                      _KeyValueRow(
                        label: l10n.storedSessions,
                        value: '${controller.archivedSensors.length}',
                      ),
                      Text(
                        l10n.historySessionSeparation,
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
                    label: Text(l10n.viewWeeklyRecap),
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
    final l10n = context.l10n;
    final preferences = controller.displayPreferences;
    final history = controller.visibleHistory;
    final warmup = computeWarmupStatus(
      snapshot,
      latestReading: controller.displayLatestReading,
    );
    final isWarmingUp = warmup?.phase == WarmupPhase.warming;
    final remainingLife = sensorLifeText(
      snapshot.sessionInfo.sessionStart,
      language: context.appLanguage,
    );

    return RefreshIndicator(
      onRefresh: controller.sync,
      edgeOffset: 8,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: <Widget>[
          if (controller.isMockDriver)
            SliverToBoxAdapter(
              child: ColoredBox(
                color: Color(0xFFFFD166),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Text(
                    l10n.demoDataWarning,
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
              child: MessageHost(
                controller: messageController!,
                messageTextResolver: localizedCatalogMessageText,
              ),
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
                                l10n.history,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Text(
                              l10n.readingCount(history.length),
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
                  label: Text(l10n.weeklyRecap),
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
    ).showSnackBar(SnackBar(content: Text(context.l10n.supportCodeCopied)));
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
    final primaryError = primaryErrorTextForSnapshot(
      snapshot,
      language: context.appLanguage,
    );
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
      unitLabel = warmupUnitText(warmup, language: context.appLanguage);
      subtitle = warmupSubtext(warmup, language: context.appLanguage);
      stageLabel = warmupStageLabel(warmup, language: context.appLanguage);
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
      subtitle = context.l10n.latestReadingAt(
        readingTimeText(latest, language: context.appLanguage),
      );
      stageLabel = stageLabelForSnapshot(
        snapshot,
        language: context.appLanguage,
      );
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
                    child: _StagePill(
                      label: stageLabel,
                      stageCode: warmup != null
                          ? 'progress'
                          : stageCodeForSnapshot(snapshot),
                    ),
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
                        child: Text(context.l10n.tryAgain),
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
                        child: Text(context.l10n.chooseAnotherSensor),
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
                  label: Text(context.l10n.copySupportCode),
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
  const _StagePill({required this.label, required this.stageCode});

  final String label;
  final String stageCode;

  @override
  Widget build(BuildContext context) {
    final color = switch (stageCode) {
      'live' => const Color(0xFF2AB67D),
      'error' => const Color(0xFFF26D5B),
      'progress' => const Color(0xFFF2A65A),
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

String _localizedDateTime(BuildContext context, DateTime value) {
  final locale = context.appLanguage == AppLanguage.simplifiedChinese
      ? 'zh'
      : 'en';
  return DateFormat.yMMMd(locale).add_Hm().format(value.toLocal());
}

String _localizedShortDateTime(BuildContext context, DateTime? value) {
  if (value == null) {
    return '--';
  }
  final locale = context.appLanguage == AppLanguage.simplifiedChinese
      ? 'zh'
      : 'en';
  return DateFormat.MMMd(locale).add_Hm().format(value.toLocal());
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
                  SliverAppBar.large(title: Text(context.l10n.settings)),
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
    final l10n = context.l10n;
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel(l10n.sensor.toUpperCase()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              if (hasActiveSensor)
                _SettingsDestination(
                  icon: Icons.sensors_rounded,
                  title: l10n.currentSensor,
                  subtitle: l10n.sensorStatusSubtitle,
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
                  title: l10n.connectSensor,
                  subtitle: l10n.noSensorActive,
                  onTap: () => Navigator.of(context).pop(),
                ),
              _SettingsDestination(
                icon: Icons.archive_outlined,
                title: l10n.sensorArchive,
                subtitle: l10n.archivedSensorsCount(archivedCount),
                listenable: controller,
                builder: (_) => _SensorArchivePane(controller: controller),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel(l10n.preferencesSection.toUpperCase()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              _SettingsDestination(
                icon: Icons.language_rounded,
                title: l10n.language,
                subtitle: _appLanguageSummary(context),
                builder: (_) => const _AppLanguagePane(),
              ),
              _SettingsDestination(
                icon: Icons.monitor_heart_outlined,
                title: l10n.glucoseAndDisplay,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel(
            l10n.dataAndIntegrationsSection.toUpperCase(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              _SettingsDestination(
                icon: Icons.favorite_outline_rounded,
                title: l10n.appleHealth,
                subtitle: l10n.appleHealthSubtitle,
                child: IntegrationsSettingsPane(
                  healthExport: healthExport,
                  controller: controller,
                ),
              ),
              if (macosSecureStorageDisabled)
                _SettingsDestination(
                  icon: Icons.auto_awesome_outlined,
                  title: l10n.aiAndModels,
                  subtitle: l10n.aiUnavailableInMacosPreview,
                  child: MacosPreviewUnavailableAiPane(),
                )
              else
                _SettingsDestination(
                  icon: Icons.auto_awesome_outlined,
                  title: l10n.aiAndModels,
                  subtitle: l10n.cloudAiDisabledByDefault,
                  child: AiSettingsPane(
                    recentReadings: controller.allHistoricalReadings,
                    unit: controller.displayPreferences.unit,
                  ),
                ),
              _SettingsDestination(
                icon: Icons.shield_outlined,
                title: l10n.privacyAndData,
                subtitle: l10n.privacySubtitle,
                child: _PrivacyDataPane(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsSectionLabel(l10n.appSection.toUpperCase()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _SettingsGroup(
            children: <Widget>[
              _SettingsDestination(
                icon: Icons.info_outline_rounded,
                title: l10n.aboutOpenGlucose,
                subtitle: l10n.aboutSubtitle,
                child: const _AboutPane(),
              ),
              if ((kDebugMode || controller.isMockDriver) &&
                  developerPane != null)
                _SettingsDestination(
                  icon: Icons.developer_mode_rounded,
                  title: l10n.advanced,
                  subtitle: l10n.advancedSubtitle,
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
                      ? context.l10n.noActiveSensor
                      : snapshot.sensor.displayName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  snapshot == null
                      ? context.l10n.previousDataStaysOnThisPhone
                      : sensorLifeText(
                          snapshot.sessionInfo.sessionStart,
                          language: context.appLanguage,
                        ),
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

String _appLanguageName(BuildContext context, AppLanguage language) {
  return switch (language) {
    AppLanguage.english => context.l10n.languageEnglish,
    AppLanguage.simplifiedChinese => context.l10n.languageSimplifiedChinese,
  };
}

String _appLanguageSummary(BuildContext context) {
  final controller = AppLanguageScope.of(context);
  final current = context.l10n.languageCurrent(
    _appLanguageName(context, controller.resolvedLanguage),
  );
  return controller.preference == AppLanguagePreference.system
      ? '${context.l10n.languageSystem} · $current'
      : current;
}

class _AppLanguagePane extends StatelessWidget {
  const _AppLanguagePane();

  @override
  Widget build(BuildContext context) {
    final controller = AppLanguageScope.of(context);
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: <Widget>[
          Text(
            l10n.appLanguage,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.languageChangeDescription,
            style: const TextStyle(color: Color(0xFF5B6E6A), height: 1.35),
          ),
          const SizedBox(height: 16),
          Card(
            child: RadioGroup<AppLanguagePreference>(
              groupValue: controller.preference,
              onChanged: (value) {
                if (value != null) {
                  unawaited(controller.setPreference(value));
                }
              },
              child: Column(
                children: <Widget>[
                  RadioListTile<AppLanguagePreference>(
                    key: const ValueKey<String>('appLanguageSystem'),
                    value: AppLanguagePreference.system,
                    title: Text(l10n.languageSystem),
                    subtitle: Text(
                      '${l10n.languageSystemDescription}\n'
                      '${l10n.languageCurrent(_appLanguageName(context, controller.resolvedLanguage))}',
                    ),
                  ),
                  const Divider(height: 1),
                  RadioListTile<AppLanguagePreference>(
                    key: const ValueKey<String>('appLanguageEnglish'),
                    value: AppLanguagePreference.english,
                    title: Text(l10n.languageEnglish),
                  ),
                  const Divider(height: 1),
                  RadioListTile<AppLanguagePreference>(
                    key: const ValueKey<String>('appLanguageChinese'),
                    value: AppLanguagePreference.simplifiedChinese,
                    title: Text(l10n.languageSimplifiedChineseNative),
                    subtitle: Text(l10n.languageSimplifiedChinese),
                  ),
                ],
              ),
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
              context.l10n.sensorNoLongerActive,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.inactiveSensorSettingsDescription,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.backToSettings),
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            context.l10n.sensorArchiveEmpty,
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
              context.l10n.archiveSessionSummary(
                _archiveReasonLabel(context, session.reason),
                context.l10n.readingCount(displayReadingCount),
                date == null
                    ? ''
                    : ' · ${_localizedShortDateTime(context, date)}',
              ),
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

class _ArchivedSensorDetail extends StatefulWidget {
  const _ArchivedSensorDetail({
    required this.controller,
    required this.session,
  });

  final CgmAppController controller;
  final ArchivedSensorSession session;

  @override
  State<_ArchivedSensorDetail> createState() => _ArchivedSensorDetailState();
}

class _ArchivedSensorDetailState extends State<_ArchivedSensorDetail> {
  ArchivedSensorExportStage? _exportStage;

  Future<void> _chooseAndExport(
    BuildContext buttonContext, {
    required List<CgmReading> rawReadings,
    required int displayReadingCount,
  }) async {
    if (_exportStage != null) {
      return;
    }
    final format = await _chooseArchivedSensorExportFormat(
      buttonContext,
      session: widget.session,
      readings: rawReadings,
      displayReadingCount: displayReadingCount,
    );
    if (format == null ||
        !mounted ||
        !buttonContext.mounted ||
        _exportStage != null) {
      return;
    }
    setState(() => _exportStage = ArchivedSensorExportStage.preparing);
    try {
      await _exportArchivedSensorData(
        buttonContext,
        format: format,
        session: widget.session,
        readings: rawReadings,
        onStageChanged: (stage) {
          if (mounted && stage != _exportStage) {
            setState(() => _exportStage = stage);
          }
        },
      );
    } finally {
      if (mounted) {
        setState(() => _exportStage = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final session = widget.session;
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
      appBar: AppBar(title: Text(context.l10n.previousSensor)),
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
            context.l10n.archiveHistoryOnly(
              _archiveReasonLabel(context, session.reason),
            ),
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
                  _KeyValueRow(
                    label: context.l10n.readings,
                    value: context.l10n.readingCount(readings.length),
                  ),
                  _KeyValueRow(
                    label: context.l10n.started,
                    value: session.startedAt == null
                        ? '--'
                        : _localizedDateTime(context, session.startedAt!),
                  ),
                  _KeyValueRow(
                    label: context.l10n.ended,
                    value: session.endedAt == null
                        ? '--'
                        : _localizedDateTime(context, session.endedAt!),
                  ),
                  if (session.model.isNotEmpty)
                    _KeyValueRow(
                      label: context.l10n.model,
                      value: session.model,
                    ),
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
              label: Text(context.l10n.recapThisSensor),
            ),
          ],
          if (rawReadings.isNotEmpty) ...<Widget>[
            SizedBox(height: readings.isNotEmpty ? 10 : 16),
            Builder(
              builder: (buttonContext) => SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey<String>('exportArchivedSensorData'),
                  onPressed: _exportStage == null
                      ? () => _chooseAndExport(
                          buttonContext,
                          rawReadings: rawReadings,
                          displayReadingCount: readings.length,
                        )
                      : null,
                  icon: _exportStage == null
                      ? const Icon(Icons.ios_share_rounded)
                      : const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                  label: Text(switch (_exportStage) {
                    ArchivedSensorExportStage.preparing ||
                    ArchivedSensorExportStage.storing =>
                      context.l10n.archivedSensorExportPreparing,
                    ArchivedSensorExportStage.sharing =>
                      context.l10n.archivedSensorExportSharing,
                    ArchivedSensorExportStage.cleanup =>
                      context.l10n.archivedSensorExportFinishing,
                    null => context.l10n.exportData,
                  }, key: const ValueKey<String>('archivedSensorExportStatus')),
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
  final dateRange = rangeStart == null || rangeEnd == null
      ? context.l10n.dateRangeUnavailable
      : '${_localizedDateTime(context, rangeStart)} – '
            '${_localizedDateTime(context, rangeEnd)}';
  var selectedFormat = ArchivedSensorExportFormat.csv;
  return showDialog<ArchivedSensorExportFormat>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(context.l10n.exportArchivedSensorData),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(context.l10n.storedGlucoseReadings(readings.length)),
              if (hiddenWarmupCount > 0) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  context.l10n.hiddenWarmupDisclosure(hiddenWarmupCount),
                  key: const ValueKey<String>('archivedExportWarmupDisclosure'),
                ),
              ],
              const SizedBox(height: 4),
              Text(dateRange),
              const SizedBox(height: 18),
              Text(
                context.l10n.fileFormat,
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
              Text(_archivedSensorFormatDescription(context, selectedFormat)),
              const SizedBox(height: 18),
              Text(
                context.l10n.includedInFile,
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(context.l10n.exportIncludesGlucose),
              Text(context.l10n.exportIncludesTiming),
              Text(context.l10n.exportIncludesQuality),
              Text(context.l10n.exportIncludesArchive),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.privacy_tip_outlined,
                    size: 20,
                    color: Color(0xFF0B6E69),
                  ),
                  SizedBox(width: 8),
                  Expanded(child: Text(context.l10n.exportExcludesIdentity)),
                ],
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmArchivedSensorExport'),
            onPressed: () => Navigator.of(dialogContext).pop(selectedFormat),
            child: Text(
              context.l10n.shareFormat(selectedFormat.extension.toUpperCase()),
            ),
          ),
        ],
      ),
    ),
  );
}

String _archivedSensorFormatDescription(
  BuildContext context,
  ArchivedSensorExportFormat format,
) => switch (format) {
  ArchivedSensorExportFormat.csv => context.l10n.csvExportDescription,
  ArchivedSensorExportFormat.txt => context.l10n.txtExportDescription,
  ArchivedSensorExportFormat.xlsx => context.l10n.xlsxExportDescription,
};

Future<void> _exportArchivedSensorData(
  BuildContext context, {
  required ArchivedSensorExportFormat format,
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
  required ValueChanged<ArchivedSensorExportStage> onStageChanged,
}) async {
  String? preparedFilePath;
  var stage = ArchivedSensorExportStage.preparing;
  try {
    final share = _ArchivedSensorShareScope.of(context);
    final localizedTitle = context.l10n.exportArchivedSensorData;
    final renderBox = context.findRenderObject() as RenderBox?;
    final shareOrigin = renderBox == null
        ? null
        : renderBox.localToGlobal(Offset.zero) & renderBox.size;
    final bytes = await compute(_buildArchivedSensorExportInBackground, (
      format: format,
      session: session,
      readings: List<CgmReading>.of(readings, growable: false),
    ));
    stage = ArchivedSensorExportStage.storing;
    onStageChanged(stage);
    final filename = archivedSensorExportFilename(format);
    preparedFilePath = await prepareArchivedSensorShareFileBytes(
      filename: filename,
      bytes: bytes,
    );
    final exportFile = preparedFilePath == null
        ? XFile.fromData(bytes, mimeType: format.mimeType)
        : XFile(preparedFilePath, mimeType: format.mimeType);
    if (!context.mounted) {
      return;
    }
    stage = ArchivedSensorExportStage.sharing;
    onStageChanged(stage);
    await share(
      buildArchivedSensorShareParams(
        file: exportFile,
        filename: filename,
        localizedTitle: localizedTitle,
        sharePositionOrigin: shareOrigin,
      ),
    );
  } catch (error) {
    final supportCode = archivedSensorExportSupportCode(
      stage: stage,
      error: error,
    );
    debugPrint(supportCode);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${context.l10n.archivedSensorExportFailed}\n$supportCode',
        ),
        action: SnackBarAction(
          label: context.l10n.copySupportCode,
          onPressed: () =>
              unawaited(Clipboard.setData(ClipboardData(text: supportCode))),
        ),
      ),
    );
  } finally {
    try {
      onStageChanged(ArchivedSensorExportStage.cleanup);
      await disposeArchivedSensorShareFile(preparedFilePath);
    } catch (error) {
      debugPrint(
        archivedSensorExportSupportCode(
          stage: ArchivedSensorExportStage.cleanup,
          error: error,
        ),
      );
    }
  }
}

String _archiveReasonLabel(BuildContext context, SensorArchiveReason reason) =>
    switch (reason) {
      SensorArchiveReason.expired => context.l10n.archiveReasonExpired,
      SensorArchiveReason.replaced => context.l10n.archiveReasonReplaced,
      SensorArchiveReason.disconnected =>
        context.l10n.archiveReasonDisconnected,
    };

class _PrivacyDataPane extends StatelessWidget {
  const _PrivacyDataPane();

  @override
  Widget build(BuildContext context) {
    final isMacosPreview =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final storageTitle = isMacosPreview
        ? context.l10n.storedInMacAppContainer
        : context.l10n.storedOnIphone;
    final storageDescription = isMacosPreview
        ? context.l10n.localDataMacDescription
        : context.l10n.localDataIphoneDescription;
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_off_rounded),
          title: Text(context.l10n.noOpenGlucoseCloud),
          subtitle: Text(context.l10n.noOpenGlucoseCloudDescription),
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
        Text(
          context.l10n.appVersion('0.1.5 (27)'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Text(context.l10n.aboutAppDescription, textAlign: TextAlign.center),
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
        context.l10n.displaySettings,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<GlucoseUnit>(
        initialValue: working.unit,
        decoration: InputDecoration(labelText: context.l10n.unit),
        items: GlucoseUnit.values
            .map(
              (value) => DropdownMenuItem<GlucoseUnit>(
                value: value,
                child: Text(_glucoseUnitLabel(context, value)),
              ),
            )
            .toList(growable: false),
        onChanged: (value) =>
            setState(() => onWorkingChanged(working.copyWith(unit: value))),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<ChartStyle>(
        initialValue: working.chartStyle,
        decoration: InputDecoration(labelText: context.l10n.chartStyle),
        items: ChartStyle.values
            .map(
              (value) => DropdownMenuItem<ChartStyle>(
                value: value,
                child: Text(_chartStyleLabel(context, value)),
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
              decoration: InputDecoration(
                labelText: context.l10n.targetLowMgdl,
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
              decoration: InputDecoration(
                labelText: context.l10n.targetHighMgdl,
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
                  SnackBar(content: Text(context.l10n.targetRangeInvalid)),
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
            child: Text(context.l10n.saveSettings),
          ),
        ],
      ),
    ],
  );
}

String _glucoseUnitLabel(BuildContext _, GlucoseUnit unit) => unit.label;

String _chartStyleLabel(BuildContext context, ChartStyle style) =>
    switch (style) {
      ChartStyle.line => context.l10n.line,
      ChartStyle.dots => context.l10n.dots,
      ChartStyle.candles => context.l10n.candles,
    };

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
            title: Text(context.l10n.showGlucoseInLiveNotification),
            subtitle: Text(
              context.l10n.showGlucoseInLiveNotificationDescription,
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
        context.l10n.sensorDetails,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      _KeyValueRow(
        label: context.l10n.serial,
        value: snapshot.sessionInfo.serial,
      ),
      _KeyValueRow(
        label: context.l10n.model,
        value: snapshot.sessionInfo.model,
      ),
      _KeyValueRow(
        label: context.l10n.firmware,
        value: snapshot.sessionInfo.firmware,
      ),
      _KeyValueRow(
        label: context.l10n.sensorStart,
        value: sessionStart == null
            ? '--'
            : _localizedShortDateTime(context, sessionStart),
      ),
      _KeyValueRow(
        label: context.l10n.history,
        value: context.l10n.readingCount(snapshot.history.length),
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
                        ? context.l10n.reviewSelectedInterruptedMove
                        : context.l10n.moveNeedsSupport
                  : context.l10n.disconnect,
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
              label: Text(context.l10n.moveSensorToAnotherPhone),
            ),
        ],
      ),
      if (hasInterruptedTransfer &&
          !canAcknowledgeInterruptedTransfer) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          context.l10n.unknownSensorResponse,
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
      title: Text(context.l10n.reviewInterruptedSensorMove),
      content: Text(context.l10n.interruptedSelectedSensorMoveReview),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey<String>('confirmSelectedInterruptedMoveRecovery'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(context.l10n.checkedBluetooth),
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
                context.l10n.interruptedSensorMoveCouldNotClear,
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
            controller.lastError ?? context.l10n.sensorCannotMoveSafely,
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
            ? context.l10n.removeAllSensorPhoneBonds
            : context.l10n.moveSensorToAnotherPhoneQuestion,
      ),
      content: Text(
        removesAllBonds
            ? context.l10n.removeAllSensorPhoneBondsDescription
            : context.l10n.moveSensorToAnotherPhoneDescription,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey<String>('confirmMoveSensorButton'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(context.l10n.moveSensor),
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
        SnackBar(content: Text(context.l10n.sensorReadyToPairAnotherPhone)),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.lastError ?? context.l10n.sensorTransferStopped,
          ),
        ),
      );
    }
  }
}

String _mockScenarioLabel(BuildContext context, MockScenario scenario) {
  final l10n = context.l10n;
  return switch (scenario) {
    MockScenario.warmup => l10n.scenarioWarmup,
    MockScenario.activeNormal => l10n.scenarioActiveNormal,
    MockScenario.activeHigh => l10n.scenarioActiveHigh,
    MockScenario.activeLow => l10n.scenarioActiveLow,
    MockScenario.rapidRise => l10n.scenarioRapidRise,
    MockScenario.rapidFall => l10n.scenarioRapidFall,
    MockScenario.expiringSoon => l10n.scenarioExpiringSoon,
    MockScenario.expired => l10n.scenarioExpired,
    MockScenario.signalLoss => l10n.scenarioSignalLoss,
    MockScenario.disconnected => l10n.scenarioDisconnected,
    MockScenario.multiSensorHistory => l10n.scenarioMultiSensorHistory,
    MockScenario.error => l10n.scenarioError,
  };
}

String _mockScenarioDescription(BuildContext context, MockScenario scenario) {
  final l10n = context.l10n;
  return switch (scenario) {
    MockScenario.warmup => l10n.scenarioWarmupDescription,
    MockScenario.activeNormal => l10n.scenarioActiveNormalDescription,
    MockScenario.activeHigh => l10n.scenarioActiveHighDescription,
    MockScenario.activeLow => l10n.scenarioActiveLowDescription,
    MockScenario.rapidRise => l10n.scenarioRapidRiseDescription,
    MockScenario.rapidFall => l10n.scenarioRapidFallDescription,
    MockScenario.expiringSoon => l10n.scenarioExpiringSoonDescription,
    MockScenario.expired => l10n.scenarioExpiredDescription,
    MockScenario.signalLoss => l10n.scenarioSignalLossDescription,
    MockScenario.disconnected => l10n.scenarioDisconnectedDescription,
    MockScenario.multiSensorHistory =>
      l10n.scenarioMultiSensorHistoryDescription,
    MockScenario.error => l10n.scenarioErrorDescription,
  };
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
        context.l10n.developer,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 16),
      if (controller.isMockDriver) ...<Widget>[
        Text(
          context.l10n.mockScenario,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<MockScenario>(
          key: const ValueKey<String>('mockScenarioPicker'),
          initialValue: controller.mockScenario ?? MockScenario.activeNormal,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.l10n.simulatedSensorState,
          ),
          items: MockScenario.values
              .map(
                (scenario) => DropdownMenuItem<MockScenario>(
                  value: scenario,
                  child: Text(_mockScenarioLabel(context, scenario)),
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
          _mockScenarioDescription(
            context,
            controller.mockScenario ?? MockScenario.activeNormal,
          ),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF5B6E6A)),
        ),
        const Divider(height: 28),
      ],
      Text(
        context.l10n.engineeringControls,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 6),
      Text(
        context.l10n.engineeringControlsDescription,
        style: TextStyle(color: Color(0xFF5B6E6A)),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey<String>('advancedCalibrationScale'),
        controller: scaleController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: context.l10n.calibrationScale),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: offsetController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: context.l10n.calibrationOffset),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: cropController,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: context.l10n.cropFirstSamples),
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
                  SnackBar(
                    content: Text(context.l10n.engineeringValuesInvalid),
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
                SnackBar(content: Text(context.l10n.engineeringSettingsSaved)),
              );
            },
            child: Text(context.l10n.saveEngineeringSettings),
          ),
          if (!controller.isMockDriver)
            OutlinedButton(
              key: const ValueKey<String>('clearActiveSensorCache'),
              onPressed: () => unawaited(
                _confirmClearActiveSensorCache(context, controller),
              ),
              child: Text(context.l10n.clearActiveSensorCache),
            ),
        ],
      ),
      if (!controller.isMockDriver) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          context.l10n.clearActiveSensorCacheDescription,
          style: TextStyle(color: Color(0xFF5B6E6A)),
        ),
      ],
      const Divider(height: 28),
      Text(
        context.l10n.metadata,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      for (final entry in metadataEntries) _MetadataRow(entry: entry),
      const SizedBox(height: 16),
      Text(
        context.l10n.diagnostics,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      if (diagnostics.isEmpty)
        Text(context.l10n.noDiagnosticsLoaded)
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
        context.l10n.calibrations,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      if (calibrations.isEmpty)
        Text(context.l10n.noCalibrationEntries)
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
        context.l10n.logs,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      if (logs.isEmpty)
        Text(context.l10n.noLogs)
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
      title: Text(context.l10n.clearActiveSensorCacheQuestion),
      content: Text(context.l10n.clearActiveSensorCacheReview),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.clearCache),
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
            ? context.l10n.activeSensorCacheCleared
            : context.l10n.noActiveSensorCacheCleared,
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
