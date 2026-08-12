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
      expect((roundTrip(event).payload as NotePayload).text, 'felt great today');
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
    test('unknown type falls back to custom', () {
      final out = HealthEvent.fromJson({
        'id': 'x',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'type': 'something-new',
      });
      expect(out.type, HealthEventType.custom);
    });

    test('missing / malformed fields deserialize without throwing', () {
      final out = HealthEvent.fromJson(const <String, Object?>{});
      expect(out.id, '');
      expect(out.type, HealthEventType.custom);
      expect(out.payload, isNull);
      expect(out.tags, isEmpty);
      expect(out.source, DataSource.manual);
      expect(
        out.timestamp,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    });

    test('unknown payload kind deserializes to null payload', () {
      final out = HealthEvent.fromJson({
        'id': 'x',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'type': 'custom',
        'payload': {'kind': 'future-thing', 'foo': 1},
      });
      expect(out.payload, isNull);
    });

    test('partial meal payload keeps nulls', () {
      final out = MealPayload.fromJson(const {'kind': 'meal', 'carbsGrams': 12});
      expect(out.carbsGrams, 12);
      expect(out.proteinGrams, isNull);
      expect(out.description, isNull);
    });

    test('exercise payload with no duration round-trips as null', () {
      final out = ExercisePayload.fromJson(const {'kind': 'exercise'});
      expect(out.duration, isNull);
      expect(out.intensity, isNull);
    });
  });
}
