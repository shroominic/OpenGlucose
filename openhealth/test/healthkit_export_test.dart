import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory exporter so the opt-in / sync-state logic can be exercised on the
/// test host (HealthKit itself is iOS-only).
class _FakeExporter implements GlucoseExporter {
  _FakeExporter({this.supported = true, this.authorized = true});

  bool supported;
  bool authorized;
  int authorizationCalls = 0;
  final List<CgmReading> exported = <CgmReading>[];
  DateTime? lastSince;

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
    if (!supported) {
      return const HealthExportResult(status: HealthExportStatus.notSupported);
    }
    if (!authorized) {
      return const HealthExportResult(status: HealthExportStatus.notAuthorized);
    }
    lastSince = since;
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
    await controller.setEnabled(true);

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

    await controller.setEnabled(true);

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

    await controller.setEnabled(true);
    expect(controller.enabled, isFalse);

    final result = await controller.syncNow(<CgmReading>[
      _reading(100, DateTime(2026, 6, 22, 12)),
    ]);
    expect(result.status, HealthExportStatus.notSupported);
  });
}
