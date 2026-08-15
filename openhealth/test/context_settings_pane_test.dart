import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openglucose/src/health_context_import.dart';
import 'package:openglucose/src/integrations_settings_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cgm_core/cgm_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('context card exposes explicit categories without auto-sync', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    var factoryCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HealthContextSettingsCard(
            importerFactory: () async {
              factoryCalls += 1;
              return _importer();
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Health context'), findsOneWidget);
    expect(find.text('Steps'), findsOneWidget);
    expect(find.text('Workouts'), findsOneWidget);
    expect(find.text('Sleep'), findsOneWidget);
    expect(find.text('Heart rate'), findsOneWidget);
    expect(find.text('Active energy'), findsOneWidget);
    expect(find.text('Walking distance'), findsOneWidget);
    expect(find.text('Sync context'), findsOneWidget);
    expect(factoryCalls, 0);
  });

  testWidgets(
    'sync passes selected categories and a bounded seven-day window',
    (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final reader = _RecordingReader();
      var factoryCalls = 0;
      final now = DateTime.utc(2026, 8, 15, 12);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HealthContextSettingsCard(
              now: () => now,
              importerFactory: () async {
                factoryCalls += 1;
                return HealthContextImporter(
                  reader: reader,
                  repository: InMemoryHealthRepository(),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('contextStepsSwitch')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('contextActiveEnergySwitch')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('healthContextSyncButton')),
      );
      await tester.pumpAndSettle();

      expect(factoryCalls, 1);
      expect(reader.start, now.subtract(const Duration(days: 7)));
      expect(reader.end, now);
      expect(reader.lastRequestedTypes, <HealthDataType>[
        HealthDataType.WORKOUT,
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.SLEEP_AWAKE_IN_BED,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.SLEEP_IN_BED,
        HealthDataType.SLEEP_UNKNOWN,
        HealthDataType.HEART_RATE,
        HealthDataType.DISTANCE_WALKING_RUNNING,
      ]);
      expect(find.textContaining('No context data found'), findsOneWidget);
    },
  );

  testWidgets('permission failure gives actionable guidance', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final reader = _RecordingReader(authorized: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HealthContextSettingsCard(
            importerFactory: () async => HealthContextImporter(
              reader: reader,
              repository: InMemoryHealthRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('healthContextSyncButton')),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Health-data access was not granted'),
      findsOneWidget,
    );
    expect(find.textContaining('Allow health access'), findsOneWidget);
  });
}

HealthContextImporter _importer() => HealthContextImporter(
  reader: _RecordingReader(),
  repository: InMemoryHealthRepository(),
);

class _RecordingReader implements HealthContextReader {
  _RecordingReader({this.authorized = true});

  final bool authorized;
  DateTime? start;
  DateTime? end;
  List<HealthDataType>? lastRequestedTypes;

  @override
  DataSource get source => DataSource.appleHealth;

  @override
  bool get isSupported => true;

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async {
    lastRequestedTypes = List<HealthDataType>.of(types);
    return authorized;
  }

  @override
  Future<List<HealthDataPoint>> read({
    required List<HealthDataType> types,
    required DateTime start,
    required DateTime end,
  }) async {
    this.start = start;
    this.end = end;
    return const <HealthDataPoint>[];
  }
}
