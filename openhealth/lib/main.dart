import 'dart:async';
import 'dart:ui';

import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/driver_factory.dart';
import 'package:openglucose/src/health_state_store_factory.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

Future<CgmAppController> _bootstrap() async {
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: buildDefaultDriver(),
    healthStateStore: createHealthStateStore(preferences),
  );
  await controller.initialize();
  return controller;
}

class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  late final Future<CgmAppController> _future = _bootstrap();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CgmAppController>(
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
        return OpenGlucoseApp(controller: snapshot.data!);
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

class OpenGlucoseApp extends StatelessWidget {
  const OpenGlucoseApp({super.key, required this.controller});

  final CgmAppController controller;

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
      home: CgmHomePage(controller: controller),
    );
  }
}

class CgmHomePage extends StatefulWidget {
  const CgmHomePage({super.key, required this.controller});

  final CgmAppController controller;

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
                    Text(
                      'OpenGlucose',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Your glucose, on your terms. Connect your sensor to see live readings and trends.',
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
                      ],
                    ),
                    if (controller.lastError != null) ...<Widget>[
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
        if (controller.sensors.isEmpty && !controller.scanning)
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
                            FilledButton(
                              key: ValueKey<String>(
                                'connectButton-${sensor.deviceId}',
                              ),
                              onPressed: sensor.capabilities.supportsDirectBle
                                  ? () => unawaited(controller.connect(sensor))
                                  : null,
                              child: const Text('Connect'),
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

class _DashboardView extends StatelessWidget {
  const _DashboardView({required this.controller, required this.snapshot});

  final CgmAppController controller;
  final CgmSessionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preferences = controller.displayPreferences;
    final history = controller.visibleHistory;
    final remainingLife = sensorLifeText(snapshot.sessionInfo.sessionStart);
    final totalReadingCount =
        snapshot.historySync.totalAvailable > history.length
        ? snapshot.historySync.totalAvailable
        : history.length;
    final totalReadingsText =
        snapshot.historySync.inProgress && totalReadingCount > history.length
        ? '${history.length} / $totalReadingCount'
        : '$totalReadingCount';

    return RefreshIndicator(
      onRefresh: controller.sync,
      edgeOffset: 8,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: <Widget>[
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
                          snapshot.sensor.displayName,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          remainingLife,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF5B6E6A),
                          ),
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
          SliverToBoxAdapter(
            child: _DashboardHeroCard(
              controller: controller,
              snapshot: snapshot,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'History',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
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
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Recent readings',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (history.isEmpty)
                        Text(
                          'Waiting for readings.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF5B6E6A),
                          ),
                        )
                      else
                        for (final reading in history.reversed.take(8))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    reading.recordedAt == null
                                        ? 'Minute ${reading.sensorMinute ?? '--'}'
                                        : DateFormat('MMM d  HH:mm').format(
                                            reading.recordedAt!.toLocal(),
                                          ),
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${reading.displayValue(preferences).toStringAsFixed(preferences.unit == GlucoseUnit.mgdl ? 0 : 1)} ${preferences.unit.label}',
                                  style: theme.textTheme.bodyLarge,
                                ),
                              ],
                            ),
                          ),
                      const SizedBox(height: 6),
                      const Divider(height: 20),
                      _KeyValueRow(
                        label: 'Total readings',
                        value: totalReadingsText,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
    final latest = widget.controller.latestReading;
    final warmup = computeWarmupStatus(snapshot, latestReading: latest);

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
              if (shouldShowPrimaryError(snapshot)) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  snapshot.lastError!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFFFC4AA),
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

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
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
            scaleController: scaleController,
            offsetController: offsetController,
            cropController: cropController,
            setState: setState,
            onWorkingChanged: (next) => working = next,
          );

          if (snapshot == null) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.62,
                child: displayPane,
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.84,
              child: DefaultTabController(
                length: 3,
                child: Column(
                  children: <Widget>[
                    const TabBar(
                      tabs: <Widget>[
                        Tab(text: 'Display'),
                        Tab(text: 'Sensor'),
                        Tab(text: 'Developer'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: <Widget>[
                          displayPane,
                          _buildSensorSettingsPane(
                            context,
                            controller,
                            snapshot,
                          ),
                          _buildDeveloperSettingsPane(
                            context: context,
                            snapshot: snapshot,
                            diagnostics: diagnostics,
                            calibrations: calibrations,
                            logs: logs,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Widget _buildDisplaySettingsPane({
  required BuildContext context,
  required CgmAppController controller,
  required DisplayPreferences working,
  required TextEditingController scaleController,
  required TextEditingController offsetController,
  required TextEditingController cropController,
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
      TextField(
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
      const SizedBox(height: 18),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          FilledButton(
            onPressed: () {
              controller.updateDisplayPreferences(
                working.copyWith(
                  calibrationScale:
                      double.tryParse(scaleController.text) ??
                      working.calibrationScale,
                  calibrationOffset:
                      double.tryParse(offsetController.text) ??
                      working.calibrationOffset,
                  cropFirstSamples:
                      int.tryParse(cropController.text) ??
                      working.cropFirstSamples,
                ),
              );
              Navigator.of(context).pop();
            },
            child: const Text('Save settings'),
          ),
          OutlinedButton(
            onPressed: () => unawaited(controller.clearPersistedHistory()),
            child: const Text('Clear cache'),
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
  final warmup = computeWarmupStatus(
    snapshot,
    latestReading: controller.latestReading,
  );
  return ListView(
    padding: const EdgeInsets.all(20),
    children: <Widget>[
      Text(
        'Sensor',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 16),
      if (warmup != null)
        _KeyValueRow(label: 'Warmup', value: warmupSubtext(warmup)),
      _KeyValueRow(label: 'Life', value: sensorLifeText(sessionStart)),
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
            onPressed: () {
              unawaited(controller.disconnect());
              Navigator.of(context).pop();
            },
            child: const Text('Disconnect'),
          ),
        ],
      ),
    ],
  );
}

Widget _buildDeveloperSettingsPane({
  required BuildContext context,
  required CgmSessionSnapshot snapshot,
  required List<CgmDiagnosticItem> diagnostics,
  required List<CgmCalibrationEntry> calibrations,
  required List<CgmLogEntry> logs,
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
