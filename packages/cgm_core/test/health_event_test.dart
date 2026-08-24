import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  group('HealthEvent construction & timeline', () {
    test('exposes timeline contract', () {
      final event = HealthEvent(
        id: 'e1',
        timestamp: DateTime.utc(2026, 1, 1, 8),
        type: HealthEventType.note,
      );
      expect(event.timelineTimestamp, DateTime.utc(2026, 1, 1, 8));
      expect(event.timelineKind, TimelineEntryKind.event);
      expect(event.source, DataSource.manual);
      expect(event.tags, isEmpty);
      expect(event.payload, isNull);
    });

    test('copyWith updates fields and can clear payload', () {
      final event = HealthEvent(
        id: 'e1',
        timestamp: DateTime.utc(2026, 1, 1),
        type: HealthEventType.meal,
        payload: const MealPayload(carbsGrams: 30),
      );

      final updated = event.copyWith(
        type: HealthEventType.custom,
        tags: const ['a'],
      );
      expect(updated.type, HealthEventType.custom);
      expect(updated.tags, ['a']);
      expect((updated.payload as MealPayload).carbsGrams, 30);

      final cleared = event.copyWith(clearPayload: true);
      expect(cleared.payload, isNull);
      expect(cleared.id, 'e1');
    });
  });

  group('HealthEvent JSON round-trip', () {
    HealthEvent roundTrip(HealthEvent event) =>
        HealthEvent.fromJson(event.toJson());

    test('meal payload round-trips', () {
      final event = HealthEvent(
        id: 'meal-1',
        timestamp: DateTime.utc(2026, 2, 3, 12, 30),
        type: HealthEventType.meal,
        payload: const MealPayload(
          carbsGrams: 45.5,
          proteinGrams: 20,
          fatGrams: 10,
          caloriesKcal: 400,
          description: 'lunch',
        ),
        tags: const ['home', 'lunch'],
        source: DataSource.appleHealth,
      );

      final out = roundTrip(event);
      expect(out.id, 'meal-1');
      expect(out.timestamp, event.timestamp);
      expect(out.type, HealthEventType.meal);
      expect(out.tags, ['home', 'lunch']);
      expect(out.source, DataSource.appleHealth);
      final payload = out.payload as MealPayload;
      expect(payload.carbsGrams, 45.5);
      expect(payload.proteinGrams, 20);
      expect(payload.fatGrams, 10);
      expect(payload.caloriesKcal, 400);
      expect(payload.description, 'lunch');
      expect(event.toJson()['formatVersion'], 1);
      expect(event.toJson()['timestamp'], '2026-02-03T12:30:00.000Z');
    });

    test('exercise payload round-trips with duration & intensity', () {
      final event = HealthEvent(
        id: 'ex-1',
        timestamp: DateTime.utc(2026, 2, 3, 18),
        type: HealthEventType.exercise,
        payload: const ExercisePayload(
          activity: 'running',
          duration: Duration(minutes: 42),
          intensity: ExerciseIntensity.vigorous,
          energyKcal: 510,
        ),
      );

      final payload = roundTrip(event).payload as ExercisePayload;
      expect(payload.activity, 'running');
      expect(payload.duration, const Duration(minutes: 42));
      expect(payload.intensity, ExerciseIntensity.vigorous);
      expect(payload.energyKcal, 510);
    });

    test('note payload round-trips', () {
      final event = HealthEvent(
        id: 'n1',
        timestamp: DateTime.utc(2026, 2, 3),
        type: HealthEventType.note,
        payload: const NotePayload(text: 'felt great today'),
      );
      expect(
        (roundTrip(event).payload as NotePayload).text,
        'felt great today',
      );
    });

    test('dose payload round-trips for insulin and medication', () {
      final insulin = HealthEvent(
        id: 'i1',
        timestamp: DateTime.utc(2026, 2, 3),
        type: HealthEventType.insulin,
        payload: const DosePayload(name: 'rapid', amount: 4.5, unit: 'U'),
      );
      final out = roundTrip(insulin).payload as DosePayload;
      expect(out.name, 'rapid');
      expect(out.amount, 4.5);
      expect(out.unit, 'U');
    });
  });

  group('HealthEvent edge cases', () {
    Map<String, Object?> validJson({int? formatVersion = 1}) =>
        <String, Object?>{
          'formatVersion': ?formatVersion,
          'id': 'event-1',
          'timestamp': '2026-01-01T00:00:00.000Z',
          'type': 'meal',
          'payload': <String, Object?>{'kind': 'meal', 'carbsGrams': 12},
          'tags': <String>['breakfast'],
          'source': 'manual',
        };

    test('accepts unversioned and explicit v0 legacy records', () {
      for (final formatVersion in <int?>[null, 0]) {
        final out = HealthEvent.fromJson(
          validJson(formatVersion: formatVersion),
        );
        expect(out.id, 'event-1');
        expect(out.timestamp, DateTime.utc(2026));
      }
    });

    test('normalizes offset timestamps to UTC', () {
      final out = HealthEvent.fromJson(<String, Object?>{
        ...validJson(),
        'timestamp': '2026-01-01T07:30:00.000+07:00',
      });
      expect(out.timestamp, DateTime.utc(2026, 1, 1, 0, 30));
      expect(out.timestamp.isUtc, isTrue);
      expect(out.toJson()['timestamp'], '2026-01-01T00:30:00.000Z');
    });

    test('v1 requires an explicit timestamp timezone', () {
      expect(
        () => HealthEvent.fromJson(<String, Object?>{
          ...validJson(),
          'timestamp': '2026-01-01T00:00:00.000',
        }),
        throwsA(isA<FormatException>()),
      );

      final legacy = HealthEvent.fromJson(<String, Object?>{
        ...validJson(formatVersion: 0),
        'timestamp': '2026-01-01T00:00:00.000',
      });
      expect(legacy.timestamp.isUtc, isTrue);
    });

    test('rejects unsupported format versions', () {
      for (final version in <Object?>[-1, 2, 1.0, '1', null]) {
        expect(
          () => HealthEvent.fromJson(<String, Object?>{
            ...validJson(),
            'formatVersion': version,
          }),
          throwsA(isA<FormatException>()),
          reason: 'version $version',
        );
      }
    });

    test('rejects malformed required fields instead of fabricating data', () {
      final cases = <({String name, Map<String, Object?> json})>[
        (
          name: 'missing id',
          json: <String, Object?>{...validJson()}..remove('id'),
        ),
        (name: 'empty id', json: <String, Object?>{...validJson(), 'id': ''}),
        (name: 'id type', json: <String, Object?>{...validJson(), 'id': 7}),
        (
          name: 'missing timestamp',
          json: <String, Object?>{...validJson()}..remove('timestamp'),
        ),
        (
          name: 'timestamp type',
          json: <String, Object?>{...validJson(), 'timestamp': 7},
        ),
        (
          name: 'timestamp text',
          json: <String, Object?>{...validJson(), 'timestamp': 'not-a-date'},
        ),
        (
          name: 'timestamp range',
          json: <String, Object?>{
            ...validJson(),
            'timestamp': '2026-02-31T00:00:00.000Z',
          },
        ),
        (
          name: 'unknown event type',
          json: <String, Object?>{...validJson(), 'type': 'something-new'},
        ),
        (
          name: 'unknown source',
          json: <String, Object?>{...validJson(), 'source': 'mystery'},
        ),
        (
          name: 'missing source',
          json: <String, Object?>{...validJson()}..remove('source'),
        ),
        (
          name: 'non-string tag',
          json: <String, Object?>{
            ...validJson(),
            'tags': <Object?>['valid', 3],
          },
        ),
        (
          name: 'payload type',
          json: <String, Object?>{...validJson(), 'payload': 'meal'},
        ),
        (
          name: 'unknown payload',
          json: <String, Object?>{
            ...validJson(),
            'payload': <String, Object?>{'kind': 'future-thing'},
          },
        ),
      ];

      for (final testCase in cases) {
        expect(
          () => HealthEvent.fromJson(testCase.json),
          throwsA(isA<FormatException>()),
          reason: testCase.name,
        );
      }
    });

    test('partial meal payload keeps nulls', () {
      final out = MealPayload.fromJson(const {
        'kind': 'meal',
        'carbsGrams': 12,
      });
      expect(out.carbsGrams, 12);
      expect(out.proteinGrams, isNull);
      expect(out.description, isNull);
    });

    test('exercise payload with no duration round-trips as null', () {
      final out = ExercisePayload.fromJson(const {'kind': 'exercise'});
      expect(out.duration, isNull);
      expect(out.intensity, isNull);
    });

    test('rejects malformed and invalid payload values', () {
      final cases = <({String name, void Function() decode})>[
        (
          name: 'negative carbs',
          decode: () =>
              MealPayload.fromJson(const <String, Object?>{'carbsGrams': -0.1}),
        ),
        (
          name: 'non-finite calories',
          decode: () => MealPayload.fromJson(const <String, Object?>{
            'caloriesKcal': double.infinity,
          }),
        ),
        (
          name: 'numeric type',
          decode: () => MealPayload.fromJson(const <String, Object?>{
            'proteinGrams': '12',
          }),
        ),
        (
          name: 'fractional duration',
          decode: () => ExercisePayload.fromJson(const <String, Object?>{
            'durationMs': 2.5,
          }),
        ),
        (
          name: 'negative duration',
          decode: () => ExercisePayload.fromJson(const <String, Object?>{
            'durationMs': -1,
          }),
        ),
        (
          name: 'unknown intensity',
          decode: () => ExercisePayload.fromJson(const <String, Object?>{
            'intensity': 'extreme',
          }),
        ),
        (
          name: 'missing note text',
          decode: () => NotePayload.fromJson(const <String, Object?>{}),
        ),
        (
          name: 'negative dose',
          decode: () =>
              DosePayload.fromJson(const <String, Object?>{'amount': -1}),
        ),
      ];

      for (final testCase in cases) {
        expect(
          testCase.decode,
          throwsA(isA<FormatException>()),
          reason: testCase.name,
        );
      }
    });

    test('rejects event/payload mismatches on decode and encode', () {
      final mismatches = <({String type, String kind})>[
        (type: 'meal', kind: 'exercise'),
        (type: 'exercise', kind: 'note'),
        (type: 'note', kind: 'dose'),
        (type: 'insulin', kind: 'meal'),
        (type: 'medication', kind: 'exercise'),
        (type: 'custom', kind: 'note'),
      ];
      for (final mismatch in mismatches) {
        final payload = switch (mismatch.kind) {
          'meal' => <String, Object?>{'kind': 'meal'},
          'exercise' => <String, Object?>{'kind': 'exercise'},
          'note' => <String, Object?>{'kind': 'note', 'text': 'x'},
          _ => <String, Object?>{'kind': 'dose'},
        };
        expect(
          () => HealthEvent.fromJson(<String, Object?>{
            ...validJson(),
            'type': mismatch.type,
            'payload': payload,
          }),
          throwsA(isA<FormatException>()),
          reason: '${mismatch.type}/${mismatch.kind}',
        );
      }

      final event = HealthEvent(
        id: 'bad',
        timestamp: DateTime.utc(2026),
        type: HealthEventType.note,
        payload: const MealPayload(carbsGrams: 5),
      );
      expect(event.toJson, throwsA(isA<FormatException>()));
    });
  });
}
