/// Bounded live polling and history backfill over the vendor glucose read.
///
/// This is pure planning and decoding logic: it owns no transport, no timer,
/// and no radio. A caller supplies [CbioGlucoseBatchReader], which is expected
/// to send exactly one `06 0A` read and return the raw notification bytes.
/// Every path is fail-closed: a transport error, an undecodable reply, or an
/// exhausted budget leaves the recorded state untouched and returns a status
/// instead of a measurement.
library;

import 'cbio_frames.dart';
import 'cbio_queries.dart';

/// Reads one glucose page. Implementations send one query and never retry
/// inside this call.
typedef CbioGlucoseBatchReader = Future<List<int>> Function(int index);

/// Outcome of a bounded sync step.
enum CbioGlucoseSyncStatus {
  /// A complete batch was decoded.
  ok,

  /// The sensor returned a valid batch with no records.
  noRecords,

  /// The reply did not satisfy the plaintext frame contract.
  decodeFailed,

  /// The read threw or timed out.
  queryFailed,

  /// The caller's query budget for this window is exhausted.
  budgetReached,

  /// History paging stopped on a gap instead of guessing.
  historyNotFullyAvailable,
}

/// Result of one live poll.
final class CbioGlucoseLiveResult {
  const CbioGlucoseLiveResult({
    required this.status,
    required this.nextPollIn,
    this.queriedIndex,
    this.batch,
    this.newRecords = const <CbioGlucoseRecord>[],
    this.errorType,
  });

  final CbioGlucoseSyncStatus status;

  /// How long the caller should wait before the next poll.
  final Duration nextPollIn;

  /// Index the query asked for, when a query was actually sent.
  final int? queriedIndex;

  final CbioGlucoseBatch? batch;

  /// Records newer than the previous high-water mark.
  final List<CbioGlucoseRecord> newRecords;

  /// Runtime type name of the failure, never the error payload.
  final String? errorType;
}

/// Result of a bounded history backfill.
final class CbioHistoryResult {
  CbioHistoryResult({
    required this.status,
    required this.complete,
    required this.queriesUsed,
    required this.indexContiguous,
    required this.reindexContiguous,
    required List<CbioGlucoseBatch> pages,
    required List<CbioGlucoseRecord> records,
  }) : pages = List.unmodifiable(pages),
       records = List.unmodifiable(records);

  final CbioGlucoseSyncStatus status;

  /// True only when the walk reached the live edge without a gap or a budget
  /// cut-off, or when the sensor holds no records at all.
  final bool complete;

  final int queriesUsed;

  /// Whether every page began exactly where the previous page ended.
  final bool indexContiguous;

  /// Whether the vendor reindex counters run continuously across pages.
  final bool reindexContiguous;

  /// Pages in fetch order, oldest first. The final page may be empty.
  final List<CbioGlucoseBatch> pages;

  /// Records across every accepted page, oldest first.
  final List<CbioGlucoseRecord> records;

  int? get oldestIndex => records.isEmpty ? null : records.first.index;
  int? get newestIndex => records.isEmpty ? null : records.last.index;
}

/// Bounded live polling and history paging for one sensor session.
final class CbioGlucoseSyncSession {
  CbioGlucoseSyncSession({
    required this.read,
    this.pollInterval = const Duration(seconds: 60),
    this.maxQueriesPerWindow = 12,
  });

  final CbioGlucoseBatchReader read;

  /// Vendor records are 60 raw seconds apart in the examined layout, so one
  /// poll per minute matches the sensor's own production rate.
  final Duration pollInterval;

  /// Hard cap on reads inside one sync window.
  final int maxQueriesPerWindow;

  int _queriesUsed = 0;
  int? _lastIndex;

  /// Highest sensor index already accepted by this session.
  int? get lastIndex => _lastIndex;

  /// Reads spent by this session, across live polls and history pages.
  int get queriesUsed => _queriesUsed;

  /// One bounded live poll at the newest index.
  ///
  /// The first poll asks for index 0, the documented practical query, and
  /// treats that page as the baseline. Later polls ask for the index after the
  /// newest record already seen.
  Future<CbioGlucoseLiveResult> pollLive() async {
    if (_queriesUsed >= maxQueriesPerWindow) {
      return CbioGlucoseLiveResult(
        status: CbioGlucoseSyncStatus.budgetReached,
        nextPollIn: pollInterval,
      );
    }
    final index = _lastIndex == null ? 0 : _lastIndex! + 1;
    final previousLast = _lastIndex;

    final _ReadOutcome outcome = await _readBatch(index);
    if (outcome.status != CbioGlucoseSyncStatus.ok) {
      return CbioGlucoseLiveResult(
        status: outcome.status,
        queriedIndex: index,
        nextPollIn: pollInterval,
        errorType: outcome.errorType,
        batch: outcome.batch,
      );
    }
    final batch = outcome.batch!;
    if (batch.count == 0) {
      return CbioGlucoseLiveResult(
        status: CbioGlucoseSyncStatus.noRecords,
        queriedIndex: index,
        batch: batch,
        nextPollIn: pollInterval,
      );
    }
    _lastIndex = batch.lastIndex;
    return CbioGlucoseLiveResult(
      status: CbioGlucoseSyncStatus.ok,
      queriedIndex: index,
      batch: batch,
      nextPollIn: pollInterval,
      newRecords: [
        for (final record in batch.records)
          if (previousLast == null || record.index > previousLast) record,
      ],
    );
  }

  /// Walks stored history upward from the oldest record under a page budget.
  ///
  /// Pages must begin exactly where the previous page ended; the vendor
  /// reindex counter is checked as well. A gap, an empty page, or the budget
  /// produces an explicit state rather than a guessed range.
  Future<CbioHistoryResult> backfillHistory({int maxPages = 8}) async {
    if (maxPages < 1) {
      throw ArgumentError.value(maxPages, 'maxPages', 'must be at least 1');
    }
    final pages = <CbioGlucoseBatch>[];
    final records = <CbioGlucoseRecord>[];
    var start = 0;
    var queries = 0;
    var status = CbioGlucoseSyncStatus.ok;
    var indexContiguous = true;
    var reindexContiguous = true;

    while (queries < maxPages) {
      if (_queriesUsed >= maxQueriesPerWindow) {
        status = CbioGlucoseSyncStatus.budgetReached;
        break;
      }
      final outcome = await _readBatch(start);
      queries += 1;
      if (outcome.status != CbioGlucoseSyncStatus.ok) {
        status = outcome.status;
        break;
      }
      final batch = outcome.batch!;
      pages.add(batch);
      if (batch.count == 0) {
        status = records.isEmpty
            ? CbioGlucoseSyncStatus.noRecords
            : CbioGlucoseSyncStatus.ok;
        return CbioHistoryResult(
          status: status,
          complete: true,
          queriesUsed: queries,
          indexContiguous: indexContiguous,
          reindexContiguous: reindexContiguous,
          pages: pages,
          records: records,
        );
      }
      if (batch.initialIndex != start) {
        indexContiguous = false;
        status = CbioGlucoseSyncStatus.historyNotFullyAvailable;
        break;
      }
      if (records.isNotEmpty) {
        final previous = records.last;
        if (batch.records.first.reindex + 1 != previous.reindex) {
          reindexContiguous = false;
        }
      }
      records.addAll(batch.records);
      start = batch.lastIndex + 1;
    }
    if (queries >= maxPages && status == CbioGlucoseSyncStatus.ok) {
      status = CbioGlucoseSyncStatus.budgetReached;
    }
    return CbioHistoryResult(
      status: status,
      complete: false,
      queriesUsed: queries,
      indexContiguous: indexContiguous,
      reindexContiguous: reindexContiguous,
      pages: pages,
      records: records,
    );
  }

  Future<_ReadOutcome> _readBatch(int index) async {
    _queriesUsed += 1;
    final List<int> bytes;
    try {
      bytes = await read(index);
    } on Object catch (error) {
      return _ReadOutcome(
        status: CbioGlucoseSyncStatus.queryFailed,
        errorType: error.runtimeType.toString(),
      );
    }
    try {
      return _ReadOutcome(
        status: CbioGlucoseSyncStatus.ok,
        batch: parseCbioGlucoseBatch(bytes),
      );
    } on CbioFrameException {
      return const _ReadOutcome(status: CbioGlucoseSyncStatus.decodeFailed);
    }
  }
}

final class _ReadOutcome {
  const _ReadOutcome({required this.status, this.batch, this.errorType});

  final CbioGlucoseSyncStatus status;
  final CbioGlucoseBatch? batch;
  final String? errorType;
}
