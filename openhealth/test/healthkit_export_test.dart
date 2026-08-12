import 'dart:collection';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/integrations_settings_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory exporter so the opt-in / sync-state logic can be exercised on the
/// test host (HealthKit itself is iOS-only).
class _FakeExporter implements GlucoseExporter {
  _FakeExporter({this.supported = true, this.authorized = true});

  bool supported;
  bool authorized;
  int authorizationCalls = 0;
  int exportCalls = 0;
  final List<CgmReading> exported = <CgmReading>[];
  final List<DateTime?> sinceValues = <DateTime?>[];
  final Queue<HealthExportResult> scriptedResults = Queue<HealthExportResult>();

  @override
  bool get isSupported => supported;

  @override
  Future<bool> requestAuthorization() async {
    authorizationCalls += 1;
    return authorized;
  }

  @override
  Future<HealthExportResult> export(
    List<CgmReading> readings, {
    DateTime? since,
  }) async {
    exportCalls += 1;
    sinceValues.add(since);
    if (scriptedResults.isNotEmpty) {
      return scriptedResults.removeFirst();
    }
    if (!supported) {
      return const HealthExportResult(status: HealthExportStatus.notSupported);
    }
    if (!authorized) {
      return const HealthExportResult(status: HealthExportStatus.notAuthorized);
    }
    final pending = readings
        .where(
          (r) =>
              r.recordedAt != null &&
              (since == null || r.recordedAt!.isAfter(since)),
        )
        .toList();
    if (pending.isEmpty) {
      return const HealthExportResult(status: HealthExportStatus.noData);
    }
    exported.addAll(pending);
    DateTime? latest;
    for (final r in pending) {
      final at = r.recordedAt!;
      if (latest == null || at.isAfter(latest)) {
        latest = at;
      }
    }
    return HealthExportResult(
      status: HealthExportStatus.ok,
      written: pending.length,
      latestReadingAt: latest,
    );
  }
}

class _FakeHealth extends Health {
  _FakeHealth({required List<bool> writeOutcomes})
    : _writeOutcomes = Queue<bool>.of(writeOutcomes);

  final Queue<bool> _writeOutcomes;
  final List<DateTime> writtenAt = <DateTime>[];

  @override
  Future<void> configure() async {}

  @override
  Future<bool?> hasPermissions(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async => true;

  @override
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async => true;

  @override
  Future<bool> writeHealthData({
    required double value,
    HealthDataUnit? unit,
    required HealthDataType type,
    required DateTime startTime,
    String? clientRecordId,
    double? clientRecordVersion,
    DateTime? endTime,
    RecordingMethod recordingMethod = RecordingMethod.automatic,
  }) async {
    writtenAt.add(startTime);
    if (_writeOutcomes.isEmpty) {
      return true;
    }
    return _writeOutcomes.removeFirst();
  }
}

CgmReading _reading(double value, DateTime at) => CgmReading(
  valueMgdl: value,
  source: CgmRecordSource.vendor,
  recordedAt: at,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  test('enabling triggers authorization and persists opt-in', () async {
    final exporter = _FakeExporter();
    final controller = HealthExportController(
      preferences: await prefs(),
      service: exporter,
    )..initialize();

    expect(controller.enabled, isFalse);
    await controller.setEnabled(enabled: true);

    expect(exporter.authorizationCalls, 1);
    expect(controller.enabled, isTrue);

    // A fresh controller over the same prefs restores the opt-in.
    final restored = HealthExportController(
      preferences: await prefs(),
      service: _FakeExporter(),
    )..initialize();
    expect(restored.enabled, isTrue);
  });

  test('declined authorization leaves opt-in off', () async {
    final controller = HealthExportController(
      preferences: await prefs(),
      service: _FakeExporter(authorized: false),
    )..initialize();

    await controller.setEnabled(enabled: true);

    expect(controller.enabled, isFalse);
    expect(controller.statusMessage, isNotNull);
  });

  test('syncNow writes readings and records last-synced time', () async {
    final exporter = _FakeExporter();
    final controller = HealthExportController(
      preferences: await prefs(),
      service: exporter,
    )..initialize();

    final now = DateTime(2026, 6, 22, 12);
    final readings = <CgmReading>[
      _reading(100, now.subtract(const Duration(minutes: 2))),
      _reading(110, now.subtract(const Duration(minutes: 1))),
    ];

    await controller.setEnabled(enabled: true);
    final result = await controller.syncNow(readings);

    expect(result.status, HealthExportStatus.ok);
    expect(result.written, 2);
    expect(exporter.exported, hasLength(2));
    expect(controller.lastSyncedAt, isNotNull);
    expect(controller.enabled, isTrue);
  });

  test('syncNow only exports readings newer than the last sync', () async {
    final exporter = _FakeExporter();
    final controller = HealthExportController(
      preferences: await prefs(),
      service: exporter,
    )..initialize();

    final base = DateTime(2026, 6, 22, 12);
    await controller.setEnabled(enabled: true);
    await controller.syncNow(<CgmReading>[_reading(100, base)]);
    expect(exporter.exported, hasLength(1));

    // Older / equal readings are not re-sent; only the strictly newer one is.
    final second = await controller.syncNow(<CgmReading>[
      _reading(100, base),
      _reading(120, base.add(const Duration(minutes: 1))),
    ]);

    expect(second.status, HealthExportStatus.ok);
    expect(second.written, 1);
    expect(exporter.exported, hasLength(2));
  });

  test('unsupported platform reports gracefully and stays off', () async {
    final controller = HealthExportController(
      preferences: await prefs(),
      service: _FakeExporter(supported: false),
    )..initialize();

    await controller.setEnabled(enabled: true);
    expect(controller.enabled, isFalse);

    final result = await controller.syncNow(<CgmReading>[
      _reading(100, DateTime(2026, 6, 22, 12)),
    ]);
    expect(result.status, HealthExportStatus.notSupported);
  });

  test('syncNow requires opt-in and performs no export while off', () async {
    final exporter = _FakeExporter();
    final controller = HealthExportController(
      preferences: await prefs(),
      service: exporter,
    )..initialize();

    final result = await controller.syncNow(<CgmReading>[
      _reading(100, DateTime(2026, 6, 22, 12)),
    ]);

    expect(result.status, HealthExportStatus.notAuthorized);
    expect(exporter.authorizationCalls, 0);
    expect(exporter.exportCalls, 0);
    expect(controller.enabled, isFalse);
  });

  test('writesAllowed false prevents authorization and export', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.healthExport.enabled': true,
    });
    final exporter = _FakeExporter();
    final controller = HealthExportController(
      preferences: await prefs(),
      service: exporter,
      writesAllowed: false,
    )..initialize();

    expect(controller.enabled, isFalse);
    await controller.setEnabled(enabled: true);
    final result = await controller.syncNow(<CgmReading>[
      _reading(100, DateTime(2026, 6, 22, 12)),
    ]);

    expect(result.status, HealthExportStatus.notAuthorized);
    expect(exporter.authorizationCalls, 0);
    expect(exporter.exportCalls, 0);
    expect(controller.enabled, isFalse);
  });

  test('partial sync persists only the contiguous watermark', () async {
    final first = DateTime.utc(2026, 6, 22, 12);
    final second = first.add(const Duration(minutes: 1));
    final exporter = _FakeExporter()
      ..scriptedResults.add(
        HealthExportResult(
          status: HealthExportStatus.partial,
          written: 1,
          latestReadingAt: first,
        ),
      );
    final controller = HealthExportController(
      preferences: await prefs(),
      service: exporter,
    )..initialize();
    await controller.setEnabled(enabled: true);

    final partial = await controller.syncNow(<CgmReading>[
      _reading(100, first),
      _reading(110, second),
    ]);
    final retry = await controller.syncNow(<CgmReading>[
      _reading(100, first),
      _reading(110, second),
    ]);

    expect(partial.status, HealthExportStatus.partial);
    expect(exporter.sinceValues, <DateTime?>[null, first]);
    expect(retry.status, HealthExportStatus.ok);
    expect(retry.written, 1);
  });

  test(
    'service sorts writes and stops at the first failed timestamp',
    () async {
      final first = DateTime.utc(2026, 6, 22, 12);
      final second = first.add(const Duration(minutes: 1));
      final third = second.add(const Duration(minutes: 1));
      final health = _FakeHealth(writeOutcomes: <bool>[true, false]);
      final service = HealthKitExportService(
        health: health,
        supportCheck: () => true,
      );

      final result = await service.export(<CgmReading>[
        _reading(120, third),
        _reading(100, first),
        _reading(110, second),
      ]);

      expect(result.status, HealthExportStatus.partial);
      expect(result.written, 1);
      expect(result.latestReadingAt, first);
      expect(health.writtenAt, <DateTime>[first.toLocal(), second.toLocal()]);
    },
  );

  test('service does not advance midway through a timestamp group', () async {
    final first = DateTime.utc(2026, 6, 22, 12);
    final second = first.add(const Duration(minutes: 1));
    final health = _FakeHealth(writeOutcomes: <bool>[true, false]);
    final service = HealthKitExportService(
      health: health,
      supportCheck: () => true,
    );

    final result = await service.export(<CgmReading>[
      _reading(100, first),
      _reading(101, first),
      _reading(110, second),
    ]);

    expect(result.status, HealthExportStatus.partial);
    expect(result.written, 1);
    expect(result.latestReadingAt, isNull);
    expect(health.writtenAt, <DateTime>[first.toLocal(), first.toLocal()]);
  });

  testWidgets('sync button stays disabled until the user opts in', (
    tester,
  ) async {
    final preferences = await prefs();
    final healthExport = HealthExportController(
      preferences: preferences,
      service: _FakeExporter(),
    )..initialize();
    final appController = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: IntegrationsSettingsPane(
          healthExport: healthExport,
          controller: appController,
        ),
      ),
    );

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sync now'),
          )
          .onPressed,
      isNull,
    );

    await healthExport.setEnabled(enabled: true);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sync now'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('simulated data explains and disables Apple Health writes', (
    tester,
  ) async {
    final preferences = await prefs();
    final healthExport = HealthExportController(
      preferences: preferences,
      service: _FakeExporter(),
      writesAllowed: false,
    )..initialize();
    final appController = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: IntegrationsSettingsPane(
          healthExport: healthExport,
          controller: appController,
        ),
      ),
    );

    expect(
      find.textContaining('disabled while using simulated or mock sensor data'),
      findsOneWidget,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sync now'),
          )
          .onPressed,
      isNull,
    );
  });
}
