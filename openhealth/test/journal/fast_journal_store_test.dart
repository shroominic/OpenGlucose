import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';

void main() {
  test('persists only base-compatible fast-journal kind keys', () {
    expect(
      FastJournalKind.values.map((kind) => kind.name),
      <String>['meal', 'activity', 'sleep'],
    );
  });

  test('fast-journal entry round-trips its isolated manual protocol', () {
    final entry = FastJournalEntry(
      id: 'journal-1',
      kind: FastJournalKind.sleep,
      occurredAt: DateTime.utc(2026, 8, 24, 22),
      label: 'Early night',
      duration: const Duration(hours: 7),
      riseReference: FastJournalRiseReference(
        startedAt: DateTime.utc(2026, 8, 24, 20),
        lastObservedAt: DateTime.utc(2026, 8, 24, 20, 20),
      ),
    );

    final decoded = FastJournalEntry.fromJson(entry.toJson());

    expect(decoded.id, 'journal-1');
    expect(decoded.kind, FastJournalKind.sleep);
    expect(decoded.occurredAt, DateTime.utc(2026, 8, 24, 22));
    expect(decoded.duration, const Duration(hours: 7));
    expect(decoded.riseReference?.startedAt, DateTime.utc(2026, 8, 24, 20));
    expect(decoded.source.name, 'manual');
  });

  test(
    'fast-journal protocol fails closed on future or non-manual records',
    () {
      final valid = FastJournalEntry(
        id: 'journal-1',
        kind: FastJournalKind.meal,
        occurredAt: DateTime.utc(2026, 8, 24, 12),
      ).toJson();

      for (final json in <Map<String, Object?>>[
        <String, Object?>{...valid, 'formatVersion': 2},
        <String, Object?>{...valid, 'source': 'appleHealth'},
        <String, Object?>{...valid, 'futureField': true},
        <String, Object?>{...valid}..remove('label'),
      ]) {
        expect(
          () => FastJournalEntry.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
}
