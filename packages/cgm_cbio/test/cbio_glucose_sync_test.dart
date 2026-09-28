import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

List<int> checked(List<int> prefix) => [
  ...prefix,
  (-prefix.fold<int>(0, (sum, byte) => sum + byte)) & 255,
];

/// One synthetic `0A` page holding the records [first..last].
///
/// The trailer carries the vendor's reindex base, chosen so that
/// `reindex = 1000 - index` across every page.
List<int> page({required int first, required int last}) {
  final count = last - first + 1;
  final trailer = 1000 - last;
  return checked([
    11 + 2 * count,
    0x0a,
    count,
    first & 255,
    (first >> 8) & 255,
    1000 & 255,
    (1000 >> 8) & 255,
    0,
    0,
    for (var i = 0; i < count; i++) ...[0xd5, 0x12],
    trailer & 255,
    (trailer >> 8) & 255,
  ]);
}

List<int> emptyPage() => checked([
  11,
  0x0a,
  0,
  0,
  0,
  1000 & 255,
  1000 >> 8,
  0,
  0,
  996 & 255,
  996 >> 8,
]);

/// A sensor whose replies begin at the requested index and hold at most
/// `pageSize` records, matching the documented `06 0A <index>` semantics.
CbioGlucoseBatchReader fakeSensor({
  required int newestIndex,
  int pageSize = 10,
  Map<int, List<int>>? overrides,
  bool throwAt = false,
}) {
  return (index) async {
    if (throwAt) throw StateError('link lost');
    final override = overrides?[index];
    if (override != null) return override;
    if (index > newestIndex) return emptyPage();
    final last = index + pageSize - 1 > newestIndex
        ? newestIndex
        : index + pageSize - 1;
    return page(first: index, last: last);
  };
}

void main() {
  group('live polling', () {
    test('baseline poll reports the whole first page as new', () async {
      final session = CbioGlucoseSyncSession(read: fakeSensor(newestIndex: 24));
      final result = await session.pollLive();
      expect(result.status, CbioGlucoseSyncStatus.ok);
      expect(result.queriedIndex, 0);
      expect(result.newRecords.length, 10);
      expect(result.newRecords.last.index, 9);
      expect(session.lastIndex, 9);
      expect(result.nextPollIn, const Duration(seconds: 60));
    });

    test('the next poll asks for the index after the newest seen', () async {
      final session = CbioGlucoseSyncSession(read: fakeSensor(newestIndex: 24));
      await session.pollLive();
      final second = await session.pollLive();
      expect(second.queriedIndex, 10);
      expect(second.newRecords.length, 10);
      expect(second.newRecords.first.index, 10);
      expect(session.lastIndex, 19);
    });

    test(
      'an empty reply is noRecords and does not advance the index',
      () async {
        final session = CbioGlucoseSyncSession(
          read: fakeSensor(newestIndex: 24, overrides: {10: emptyPage()}),
        );
        await session.pollLive();
        final second = await session.pollLive();
        expect(second.status, CbioGlucoseSyncStatus.noRecords);
        expect(second.newRecords, isEmpty);
        expect(session.lastIndex, 9);
      },
    );

    test('a transport error fails closed without advancing', () async {
      final failing = CbioGlucoseSyncSession(
        read: fakeSensor(newestIndex: 24, throwAt: true),
      );
      final result = await failing.pollLive();
      expect(result.status, CbioGlucoseSyncStatus.queryFailed);
      expect(result.errorType, 'StateError');
      expect(failing.lastIndex, isNull);
      expect(result.newRecords, isEmpty);
    });

    test('undecodable bytes are a decode failure, not a reading', () async {
      final session = CbioGlucoseSyncSession(
        read: (index) async => [0x23, 0xf7, 0x6f, 0xd9, 0xf4],
      );
      final result = await session.pollLive();
      expect(result.status, CbioGlucoseSyncStatus.decodeFailed);
      expect(result.batch, isNull);
      expect(result.newRecords, isEmpty);
      expect(session.lastIndex, isNull);
    });

    test('the query budget stops further polling', () async {
      final session = CbioGlucoseSyncSession(
        read: fakeSensor(newestIndex: 24),
        maxQueriesPerWindow: 1,
      );
      expect((await session.pollLive()).status, CbioGlucoseSyncStatus.ok);
      final blocked = await session.pollLive();
      expect(blocked.status, CbioGlucoseSyncStatus.budgetReached);
      expect(blocked.queriedIndex, isNull);
      expect(blocked.newRecords, isEmpty);
    });
  });

  group('history backfill', () {
    test('pages from the oldest record and reports completeness', () async {
      final session = CbioGlucoseSyncSession(read: fakeSensor(newestIndex: 24));
      final result = await session.backfillHistory();
      expect(result.complete, isTrue);
      expect(result.status, CbioGlucoseSyncStatus.ok);
      expect(result.queriesUsed, 4);
      expect(result.records.length, 25);
      expect(result.records.first.index, 0);
      expect(result.records.last.index, 24);
      expect(result.indexContiguous, isTrue);
      expect(result.reindexContiguous, isTrue);
      expect(result.pages.last.count, 0);
    });

    test('a bounded budget returns an explicit incomplete state', () async {
      final session = CbioGlucoseSyncSession(read: fakeSensor(newestIndex: 24));
      final result = await session.backfillHistory(maxPages: 2);
      expect(result.complete, isFalse);
      expect(result.status, CbioGlucoseSyncStatus.budgetReached);
      expect(result.queriesUsed, 2);
      expect(result.records.length, 20);
      expect(result.records.last.index, 19);
    });

    test(
      'a page that does not begin at the request is a history gap',
      () async {
        final session = CbioGlucoseSyncSession(
          read: fakeSensor(
            newestIndex: 24,
            overrides: {10: page(first: 0, last: 4)},
          ),
        );
        final result = await session.backfillHistory();
        expect(result.complete, isFalse);
        expect(result.status, CbioGlucoseSyncStatus.historyNotFullyAvailable);
        expect(result.indexContiguous, isFalse);
        expect(result.records.length, 10);
      },
    );

    test('an empty first page means the sensor holds no history', () async {
      final session = CbioGlucoseSyncSession(
        read: fakeSensor(newestIndex: 0, overrides: {0: emptyPage()}),
      );
      final result = await session.backfillHistory();
      expect(result.status, CbioGlucoseSyncStatus.noRecords);
      expect(result.records, isEmpty);
      expect(result.complete, isTrue);
    });

    test(
      'the backfill budget is independent of the live query count',
      () async {
        final session = CbioGlucoseSyncSession(
          read: fakeSensor(newestIndex: 24),
        );
        await session.pollLive();
        final result = await session.backfillHistory(maxPages: 2);
        expect(result.queriesUsed, 2);
        expect(session.queriesUsed, 3);
      },
    );
  });
}
