import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'health_state_store.dart';
import 'libre_nfc_history.dart';
import 'sensor_archive.dart';
import 'sensor_archive_export_data.dart';

/// Existing restricted history identity. Do not use a BLE address as a key.
String sensorHistoryKey(DiscoveredSensor sensor) => _historyKey(
  sensor.driverId,
  sensor.storageKey,
);

String _historyKey(String driverId, String storageKey) => driverId == 'aidex'
    ? 'openHealth.history.$storageKey'
    : 'openHealth.history.v2.${base64Url.encode(utf8.encode(jsonEncode(<String>[driverId, storageKey]))).replaceAll('=', '')}';

/// The only owner of active history mutations in one app process.
///
/// Share this instance between the controller and Libre observation adapter.
/// The queue includes the authoritative read, merge, encoding and durable
/// write, not just setString. Display reads expose only committed state and
/// must never establish live freshness or authorize sensor operations.
final class SensorHistoryRepository {
  SensorHistoryRepository(
    this._store, {
    Duration Function()? monotonicNow,
    DateTime Function()? utcNow,
  }) : _monotonicNow = monotonicNow ?? _runningMonotonicClock(),
       _utcNow = utcNow ?? DateTime.now;

  final HealthStateStore _store;
  final Duration Function() _monotonicNow;
  final DateTime Function() _utcNow;
  final Object _ticketOwner = Object();
  final Set<_NfcImportTicket> _tickets = {};
  final Map<String, int> _clearRevisions = {};
  Future<void> _tail = Future<void>.value();
  final Set<String> _quarantinedKeys = {};
  final Map<String, _History> _confirmedRecords = {};
  final Set<String> _knownProvenanceArchives = {};

  /// Host-side read/transfer limits, not claims about sensor wire timing.
  static const maxNfcImportValidity = Duration(minutes: 3);
  static const maxNfcImportClockDrift = Duration(seconds: 5);

  /// Reads one immutable archive from its exact persisted manifest owner.
  /// This is an export boundary, not the permissive display/cache decoder.
  /// It neither joins active history nor reconstructs missing owner metadata.
  ArchivedSensorExportData readArchivedSensorExportData(
    ArchivedSensorSession requested,
  ) {
    try {
      final manifestRaw = _store.getString('openHealth.sensorArchive');
      if (manifestRaw == null) _unavailable();
      final manifest = jsonDecode(manifestRaw);
      if (manifest is! List) _unavailable();
      final matching = <Map<String, dynamic>>[];
      for (final value in manifest) {
        if (value is! Map<String, dynamic>) _unavailable();
        if (value['id'] == requested.id ||
            value['historyKey'] == requested.historyKey) {
          matching.add(value);
        }
      }
      if (matching.length != 1) _unavailable();
      final owner = _validatedExportOwner(matching.single);
      if (!_sameArchiveMetadata(owner.toJson(), requested.toJson())) {
        _unavailable();
      }
      final key = owner.historyKey;
      if (isQuarantined(key)) _unavailable();
      final raw = _store.getString(key);
      if (raw == null) {
        // Historical zero-count writers saved only a manifest. That manifest
        // has no encoding discriminator, so an absent empty archive cannot be
        // classified after restart. Real schema-two segments are nonempty;
        // reject all missing nonempty and any already-known provenance blob.
        if (owner.readingCount != 0 || _knownProvenanceArchives.contains(key)) {
          _unavailable();
        }
        return ArchivedSensorExportData.legacy(
          session: owner,
          readings: const [],
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        if (_knownProvenanceArchives.contains(key)) _unavailable();
        final readings = _readStrictReadings(
          decoded,
          legacy: true,
          libreBounds: owner.driverId == 'libre2-gen1',
        );
        if (readings.length != owner.readingCount) _unavailable();
        return ArchivedSensorExportData.legacy(
          session: owner,
          readings: readings,
        );
      }
      if (decoded is! Map<String, dynamic> || owner.driverId != 'libre2-gen1') {
        _unavailable();
      }
      final archive = _readArchiveEnvelope(
        key,
        decoded,
        storageKey: owner.storageKey,
        validateActiveBinding: false,
      );
      if (archive.entries.length != owner.readingCount) _unavailable();
      return ArchivedSensorExportData.libreHistory(
        session: owner,
        entries: archive.entries,
      );
    } catch (_) {
      _unavailable();
    }
  }

  ArchivedSensorSession _validatedExportOwner(Map<String, dynamic> value) {
    for (final field in ['id', 'historyKey', 'driverId', 'storageKey']) {
      if (value[field] is! String || (value[field] as String).isEmpty) {
        _unavailable();
      }
    }
    if (value['readingCount'] is! int || (value['readingCount'] as int) < 0) {
      _unavailable();
    }
    final owner = ArchivedSensorSession.fromJson(value);
    final normalized = owner.toJson();
    for (final entry in value.entries) {
      if (const {'startedAt', 'endedAt', 'lastReadingAt'}.contains(entry.key)) {
        if (entry.value != null &&
            (entry.value is! String ||
                DateTime.tryParse(entry.value as String) == null)) {
          _unavailable();
        }
      } else if ((entry.key == 'sensorVariant' ||
              entry.key == 'warmupMinutes') &&
          entry.value == null) {
        // Old optional metadata may be explicitly null.
      } else if (!normalized.containsKey(entry.key) ||
          !_sameArchiveMetadata(normalized[entry.key], entry.value)) {
        // Unknown fields/source values, trimmed variants, wrong types, and
        // permissive legacy defaults must not silently change export context.
        _unavailable();
      }
    }
    const prefix = 'openHealth.history.archive.';
    if (owner.historyKey.startsWith(prefix)) {
      if (owner.historyKey != '$prefix${owner.id}') _unavailable();
      if (owner.driverId == 'libre2-gen1') {
        _validateLibreStorageKey(owner.storageKey);
        _validatedArchiveReference(value, owner.storageKey);
      }
    } else if (owner.historyKey !=
            _historyKey(owner.driverId, owner.storageKey) &&
        owner.historyKey != 'openHealth.history.${owner.storageKey}') {
      _unavailable();
    }
    return owner;
  }

  bool _sameArchiveMetadata(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.entries.every(
            (entry) =>
                right.containsKey(entry.key) &&
                _sameArchiveMetadata(entry.value, right[entry.key]),
          );
    }
    return left == right;
  }

  List<LibreHistoryEntry> readLibreHistoryEntries(String key) {
    final record = _readForDisplay(key);
    return switch (record) {
      _LibreHistory() => List<LibreHistoryEntry>.unmodifiable(record.entries),
      _LibreArchiveHistory() => List<LibreHistoryEntry>.unmodifiable(
        record.entries,
      ),
      _ => throw StateError('Stored sensor history is unavailable.'),
    };
  }

  /// Presentation-only binding check. A quarantined write still permits the
  /// last confirmed envelope to be displayed; this grants no mutation/RF
  /// authority and must not replace retainOnDisconnect's strict storage read.
  bool hasConfirmedLibreHistory(String key) =>
      _readForDisplay(key) is _LibreHistory;

  /// Never replace a live reading with a same-minute historical observation.
  CgmReading? confirmedLibreLiveReading(String key, CgmReading incoming) {
    final record = _readForDisplay(key);
    if (record is! _LibreHistory) return null;
    for (final entry in record.entries) {
      if ((record.schemaVersion == 1 ||
              entry.origin == LibreHistoryOrigin.bleLive) &&
          _sameReading(entry.reading, incoming)) {
        return entry.reading;
      }
    }
    return null;
  }

  Future<LibreNfcHistoryImportTicket> beginNfcHistoryImport(
    LibreGen1ObservationBinding binding, {
    required Object connectionOwner,
    Duration validity = maxNfcImportValidity,
  }) => _serialize(() async {
    if (validity <= Duration.zero || validity > maxNfcImportValidity) {
      _unavailable();
    }
    final key = _historyKey(binding.driverId, binding.storageKey);
    final record = _read(key, binding: binding);
    // Real receiver load must already have established the exact binding.
    if (record is! _LibreHistory) _unavailable();
    final ticket = _NfcImportTicket(
      repositoryOwner: _ticketOwner,
      connectionOwner: connectionOwner,
      binding: binding,
      clearRevision: _clearRevisions[key] ?? record.clearRevision,
      minimumScanMinute: record.replayBarrierMinute,
      startedAt: _utcNow().toUtc(),
      startedMonotonic: _monotonicNow(),
      validity: validity,
    );
    _tickets.add(ticket);
    return ticket;
  });

  Future<void> cancelNfcHistoryImport(LibreNfcHistoryImportTicket ticket) {
    if (ticket is _NfcImportTicket &&
        identical(ticket.repositoryOwner, _ticketOwner)) {
      // Cancellation reaches queued work immediately. An already-dispatched
      // durable write is not reversible; clear is the ordered deletion path.
      ticket.cancelled = true;
    }
    return _serialize(() async => _tickets.remove(ticket));
  }

  Future<LibreNfcHistoryImportResult> importNfcHistory(
    LibreNfcHistoryImportTicket ticket, {
    required Object connectionOwner,
    required int scanMinute,
    required DateTime scanReceivedAt,
    required List<LibreNfcHistorySample> samples,
  }) {
    final retainedSamples = List<LibreNfcHistorySample>.unmodifiable(samples);
    return _serialize(() async {
      if (ticket is! _NfcImportTicket ||
          !identical(ticket.repositoryOwner, _ticketOwner) ||
          !_tickets.remove(ticket)) {
        _unavailable();
      }
      if (!identical(ticket.connectionOwner, connectionOwner) ||
          !_validMinute(scanMinute)) {
        _unavailable();
      }
      final key = _historyKey(
        ticket.binding.driverId,
        ticket.binding.storageKey,
      );
      final record = _read(key, binding: ticket.binding);
      if (record is! _LibreHistory ||
          ticket.clearRevision !=
              (_clearRevisions[key] ?? record.clearRevision)) {
        _unavailable();
      }
      _validateImportClock(ticket, scanReceivedAt);
      if ((ticket.minimumScanMinute != null &&
              scanMinute < ticket.minimumScanMinute!) ||
          (record.lastNfcScanMinute != null &&
              scanMinute < record.lastNfcScanMinute!) ||
          retainedSamples.length > 48 ||
          retainedSamples
                  .where(
                    (sample) => sample.origin == LibreHistoryOrigin.nfcTrend,
                  )
                  .length >
              16 ||
          retainedSamples
                  .where(
                    (sample) => sample.origin == LibreHistoryOrigin.nfcHistory,
                  )
                  .length >
              32) {
        _unavailable();
      }
      final entries = <String, LibreHistoryEntry>{
        for (final entry in record.entries)
          _readingIdentity(entry.reading): entry,
      };
      final incomingIdentities = <String>{};
      var imported = 0;
      for (final sample in retainedSamples) {
        final reading = sample.reading;
        _validateReading(reading);
        final minute = reading.sensorMinute;
        if (minute == null ||
            minute > scanMinute ||
            reading.recordedAt == null ||
            reading.source != CgmRecordSource.vendor ||
            !reading.isDisplayProvisional ||
            (sample.origin != LibreHistoryOrigin.nfcTrend &&
                sample.origin != LibreHistoryOrigin.nfcHistory) ||
            !sample.firstReceivedAt.isAtSameMomentAs(scanReceivedAt) ||
            !reading.recordedAt!.isAtSameMomentAs(
              scanReceivedAt.subtract(Duration(minutes: scanMinute - minute)),
            ) ||
            !incomingIdentities.add(_readingIdentity(reading))) {
          _unavailable();
        }
        if (record.clearedThroughMinute != null &&
            minute <= record.clearedThroughMinute!) {
          continue;
        }
        final identity = _readingIdentity(reading);
        if (entries.containsKey(identity)) continue;
        entries[identity] = LibreHistoryEntry(
          reading: reading.copyWith(recordedAt: reading.recordedAt!.toUtc()),
          origin: sample.origin,
          firstReceivedAt: scanReceivedAt.toUtc(),
          timestampBasis: LibreHistoryTimestampBasis.sensorRelative,
        );
        imported++;
      }
      final lastScan = record.lastNfcScanMinute;
      if (lastScan == scanMinute) {
        return LibreNfcHistoryImportResult(
          importedReadingCount: 0,
          state: record.state,
        );
      }
      final next = record.copyWith(
        schemaVersion: record.schemaVersion >= 3 ? 3 : 2,
        lastNfcScanMinute: lastScan == null || scanMinute > lastScan
            ? scanMinute
            : lastScan,
        clearRevision: ticket.clearRevision,
        entries: entries.values.toList(),
      );
      _validateImportClock(ticket, scanReceivedAt);
      await _writeLibre(key, next);
      return LibreNfcHistoryImportResult(
        importedReadingCount: imported,
        state: next.state,
      );
    });
  }

  void _validateImportClock(_NfcImportTicket ticket, DateTime receivedAt) {
    final elapsed = _monotonicNow() - ticket.startedMonotonic;
    final now = _utcNow().toUtc();
    final wallElapsed = now.difference(ticket.startedAt);
    final drift = (wallElapsed - elapsed).abs();
    if (ticket.cancelled ||
        elapsed < Duration.zero ||
        elapsed >= ticket.validity ||
        drift > maxNfcImportClockDrift ||
        receivedAt.isBefore(ticket.startedAt) ||
        receivedAt.isAfter(now)) {
      _unavailable();
    }
  }

  /// A lost/failed write can leave the backend cache behind its durable file.
  /// This owner cannot safely mutate that identity again. A real store/owner
  /// restart must reload disk; constructing a second owner is not recovery.
  bool isQuarantined(String key) => _quarantinedKeys.contains(key);

  List<CgmReading> readCommittedHistory(String key) =>
      List<CgmReading>.unmodifiable(_readForDisplay(key).history);

  _History _readForDisplay(String key) => isQuarantined(key)
      ? _confirmedRecords[key] ?? const _History([])
      : _read(key);

  /// Apply the same deletion/first-receipt policy to in-memory UI snapshots.
  ///
  /// Once bound, only the observation transaction can introduce a reading.
  /// A late snapshot or debounce cannot recreate a cleared observation, change
  /// its first receipt, or publish a point whose transaction did not complete.
  List<CgmReading> filterRetainedHistory(
    String key,
    Iterable<CgmReading> incoming,
  ) {
    final record = _readForDisplay(key);
    if (record is! _LibreHistory && !isQuarantined(key)) {
      return List<CgmReading>.unmodifiable(incoming);
    }
    final accepted = {
      for (final reading in record.history) _readingIdentity(reading): reading,
    };
    return List<CgmReading>.unmodifiable([
      for (final reading in incoming)
        if (accepted[_readingIdentity(reading)] case final retained?) retained,
    ]);
  }

  /// Strict display-only archive groups, deduplicated within each bootstrap.
  /// Unknown/malformed related metadata is not a trustworthy numeric count.
  /// This does not read or mutate the active envelope or migrate history.
  Map<String, List<CgmReading>> readLibreArchivedHistoryGroups() =>
      _readArchivedGroups();

  /// The retained observations not already present in this bootstrap's archive.
  /// A bound record is authoritative, including its clear tombstone. Legacy
  /// controller callers supply retained samples but gain no synthetic binding,
  /// replay frontier, or migration authority from this read-only operation.
  Future<List<CgmReading>> unarchivedLibreReadings({
    required DiscoveredSensor sensor,
    required Iterable<CgmReading> incoming,
  }) {
    final candidates = List<CgmReading>.unmodifiable(incoming);
    return _serialize(() async {
      if (sensor.driverId != 'libre2-gen1') _unavailable();
      _validateLibreStorageKey(sensor.storageKey);
      final key = sensorHistoryKey(sensor);
      final current = _read(key);
      final accepted = current is _LibreHistory
          ? current.schemaVersion >= 2
                ? current.history
                : filterRetainedHistory(key, candidates)
          : candidates;
      accepted.forEach(_validateReading);
      final archived =
          _readArchivedGroups(
            onlyStorageKey: sensor.storageKey,
          )[sensor.storageKey] ??
          const <CgmReading>[];
      final archivedIdentities = archived.map(_readingIdentity).toSet();
      return List<CgmReading>.unmodifiable(
        _keepFirst([], accepted).where(
          (reading) => !archivedIdentities.contains(_readingIdentity(reading)),
        ),
      );
    });
  }

  /// New Libre archive segments retain acquisition evidence after NFC import.
  /// Existing segments are immutable. Ordinary and schema-one list archives
  /// keep their old wire shape; this does not rewrite their bytes or manifest.
  Future<void> writeLibreArchive({
    required DiscoveredSensor sensor,
    required String archiveKey,
    required Iterable<CgmReading> incoming,
  }) {
    final candidates = List<CgmReading>.unmodifiable(incoming);
    return _serialize(() async {
      if (sensor.driverId != 'libre2-gen1') _unavailable();
      _validateArchiveKey(archiveKey, sensor.storageKey);
      final current = _read(sensorHistoryKey(sensor));
      final String encoded;
      if (current is _LibreHistory && current.schemaVersion >= 2) {
        final selected = <LibreHistoryEntry>[];
        for (final candidate in candidates) {
          final matches = current.entries
              .where((entry) => _sameReading(entry.reading, candidate))
              .toList();
          if (matches.length != 1) _unavailable();
          selected.add(matches.single);
        }
        if (selected
                .map((entry) => _readingIdentity(entry.reading))
                .toSet()
                .length !=
            selected.length) {
          _unavailable();
        }
        encoded = jsonEncode({
          'schemaVersion': current.schemaVersion,
          'kind': 'libreHistoryArchive',
          'driverId': current.binding.driverId,
          'storageKey': current.binding.storageKey,
          'sensorBindingDigest': current.binding.sensorBindingDigest,
          'readings': [for (final entry in selected) _entryJson(entry)],
        });
      } else {
        candidates.forEach(_validateReading);
        encoded = jsonEncode(
          candidates.map((reading) => reading.toJson()).toList(),
        );
      }
      if (isQuarantined(archiveKey)) _unavailable();
      final existing = _store.getString(archiveKey);
      if (existing != null) {
        if (existing != encoded) _unavailable();
        if (current is _LibreHistory && current.schemaVersion >= 2) {
          _knownProvenanceArchives.add(archiveKey);
        }
        return;
      }
      try {
        await _store.setString(archiveKey, encoded);
      } catch (_) {
        _quarantinedKeys.add(archiveKey);
        _unavailable();
      }
      if (current is _LibreHistory && current.schemaVersion >= 2) {
        _knownProvenanceArchives.add(archiveKey);
      }
    });
  }

  /// Ordinary histories remain JSON lists with their previous replacement
  /// semantics. Bound Libre history is already committed by its driver; stale
  /// controller copies can neither overwrite it nor extend its frontier.
  Future<void> merge(String key, List<CgmReading> incoming) {
    final snapshot = List<CgmReading>.unmodifiable(incoming);
    return _serialize(() async {
      final current = _read(key);
      if (current is _LibreHistory) return;
      if (current is _LibreArchiveHistory) _unavailable();
      final history = _isLibreKey(key)
          ? _keepFirst(current.history, snapshot)
          : snapshot;
      final encoded = jsonEncode(
        history.map((reading) => reading.toJson()).toList(),
      );
      try {
        await _store.setString(key, encoded);
      } catch (_) {
        if (_isLibreKey(key)) {
          _quarantinedKeys.add(key);
          _unavailable();
        }
        rethrow;
      }
      if (_isLibreKey(key)) _confirmedRecords[key] = _History(history);
    });
  }

  /// Explicit history deletion retains Libre's replay frontier in the same
  /// atomic record. Unknown/corrupt state is preserved, never silently removed.
  Future<void> clear(String key) => _serialize(() async {
    final current = _read(key);
    if (current is _LibreHistory) {
      final revision = (_clearRevisions[key] ?? current.clearRevision) + 1;
      if (revision > 0x1fffffffffffff) _unavailable();
      await _writeLibre(
        key,
        current.copyWith(
          history: const [],
          clearedThroughMinute: current.replayBarrierMinute,
          clearRevision: revision,
        ),
      );
      _clearRevisions[key] = revision;
    } else {
      // A legacy list needs the exact native bootstrap binding before it can
      // become a replay tombstone. Disconnect must retain such a list.
      if (_isLibreKey(key)) {
        if (current.history.isNotEmpty) _unavailable();
        final storageKey = _libreStorageKey(key);
        final archived = _readArchivedGroups(
          onlyStorageKey: storageKey,
        )[storageKey];
        // Missing active bytes are not proof of no history: older Disconnect
        // versions could leave accepted points only in matching archives. Do
        // not claim deletion before a real binding can establish a tombstone.
        if (archived?.isNotEmpty ?? false) _unavailable();
      }
      await _store.remove(key);
    }
  });

  /// A validated observation envelope is receiver state, not disposable cache.
  /// Callers also retain legacy Libre lists by their trusted driver identity.
  bool retainOnDisconnect(String key) => _read(key) is _LibreHistory;

  Future<LibreGen1ObservationState> loadLibre(
    LibreGen1ObservationBinding binding,
  ) => _serialize(() async {
    final key = _historyKey(binding.driverId, binding.storageKey);
    final record = _read(key, binding: binding);
    if (record is _LibreHistory) return record.state;
    final migrated = _fromLegacy(
      binding,
      _legacyMigrationHistory(binding, record.history),
    );
    await _writeLibre(key, migrated);
    return migrated.state;
  });

  Future<LibreGen1ObservationCommit> commitLibre(
    LibreGen1ObservationBinding binding, {
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings = const [],
  }) {
    final retained = List<LibreGen1HistoricalReading>.unmodifiable(
      historicalReadings,
    );
    return _serialize(() async {
      if (!_validMinute(sensorMinute)) {
        _unavailable();
      }
      if (reading != null) {
        _validateReading(reading);
        if (reading.sensorMinute != sensorMinute ||
            reading.recordedAt == null ||
            !reading.recordedAt!.isAtSameMomentAs(receivedAt)) {
          _unavailable();
        }
      }
      if (retained.length > 9) _unavailable();
      final positions = <String>{};
      for (final historical in retained) {
        final sample = historical.reading;
        _validateReading(sample);
        final minute = sample.sensorMinute;
        if (minute == null ||
            sample.recordedAt == null ||
            sample.source != CgmRecordSource.vendor ||
            !sample.isDisplayProvisional ||
            !_validBleHistoryPosition(historical.kind, sensorMinute, minute) ||
            !sample.recordedAt!.isAtSameMomentAs(
              receivedAt.subtract(Duration(minutes: sensorMinute - minute)),
            ) ||
            !positions.add('${historical.kind.name}:$minute')) {
          _unavailable();
        }
      }
      final key = _historyKey(binding.driverId, binding.storageKey);
      final existing = _read(key, binding: binding);
      final current = existing is _LibreHistory
          ? existing
          : _fromLegacy(
              binding,
              _legacyMigrationHistory(binding, existing.history),
            );
      final previousMinute = current.replayBarrierMinute;
      if (previousMinute != null && sensorMinute <= previousMinute) {
        if (existing is! _LibreHistory) await _writeLibre(key, current);
        return LibreGen1ObservationCommit(
          advanced: false,
          state: current.state,
        );
      }
      final next = current.copyWith(
        schemaVersion: retained.isNotEmpty ? 3 : current.schemaVersion,
        observedMinute: sensorMinute,
        provenance: 'observed',
        entries: [
          ...current.entries,
          if (reading != null)
            LibreHistoryEntry(
              reading: reading.copyWith(recordedAt: receivedAt.toUtc()),
              origin: LibreHistoryOrigin.bleLive,
              firstReceivedAt: receivedAt.toUtc(),
              timestampBasis: LibreHistoryTimestampBasis.phoneReceipt,
            ),
          for (final historical in retained)
            if (current.clearedThroughMinute == null ||
                historical.reading.sensorMinute! >
                    current.clearedThroughMinute!)
              LibreHistoryEntry(
                reading: historical.reading.copyWith(
                  recordedAt: historical.reading.recordedAt!.toUtc(),
                ),
                origin: historical.kind == LibreGen1BleHistoryKind.trend
                    ? LibreHistoryOrigin.bleTrend
                    : LibreHistoryOrigin.bleHistory,
                firstReceivedAt: receivedAt.toUtc(),
                timestampBasis: LibreHistoryTimestampBasis.sensorRelative,
              ),
        ],
      );
      await _writeLibre(key, next);
      return LibreGen1ObservationCommit(advanced: true, state: next.state);
    });
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  _History _read(String key, {LibreGen1ObservationBinding? binding}) {
    if (isQuarantined(key)) _unavailable();
    final record = _decode(key, binding: binding);
    if (_isLibreKey(key)) _confirmedRecords[key] = record;
    return record;
  }

  _History _decode(String key, {LibreGen1ObservationBinding? binding}) {
    try {
      final raw = _store.getString(key);
      if (raw == null) return const _History([]);
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        if (binding != null || _isLibreKey(key)) {
          return _History(_readStrictReadings(decoded, legacy: true));
        }
        // Preserve the existing ordinary-list decoder and serialized shape.
        return _History(
          decoded
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (value) =>
                    CgmReading.fromJson(Map<String, Object?>.from(value)),
              )
              .toList(growable: false),
        );
      }
      if (decoded is! Map<String, dynamic>) _unavailable();
      if (decoded['kind'] == 'libreHistoryArchive') {
        return _readArchiveEnvelope(key, decoded);
      }
      const fields = {
        'schemaVersion',
        'driverId',
        'storageKey',
        'sensorBindingDigest',
        'observedMinute',
        'frontierProvenance',
        'clearedThroughMinute',
        'readings',
      };
      final version = decoded['schemaVersion'];
      final expectedFields = version == 2 || version == 3
          ? {...fields, 'lastNfcScanMinute', 'clearRevision'}
          : fields;
      if (decoded.length != expectedFields.length ||
          !decoded.keys.every(expectedFields.contains) ||
          (version != 1 && version != 2 && version != 3) ||
          decoded['schemaVersion'] is! int ||
          decoded['driverId'] != 'libre2-gen1' ||
          decoded['storageKey'] is! String ||
          decoded['sensorBindingDigest'] is! String) {
        _unavailable();
      }
      final storageKey = decoded['storageKey'] as String;
      const prefix = 'libre2-gen1:';
      if (!storageKey.startsWith(prefix)) _unavailable();
      final storedBinding = LibreGen1ObservationBinding(
        bootstrapId: storageKey.substring(prefix.length),
        sensorBindingDigest: decoded['sensorBindingDigest'] as String,
      );
      if (key !=
              _historyKey(storedBinding.driverId, storedBinding.storageKey) ||
          (binding != null &&
              (binding.storageKey != storedBinding.storageKey ||
                  binding.sensorBindingDigest !=
                      storedBinding.sensorBindingDigest))) {
        _unavailable();
      }
      final minute = decoded['observedMinute'];
      final cleared = decoded['clearedThroughMinute'];
      final provenance = decoded['frontierProvenance'];
      final lastScan = version == 1 ? null : decoded['lastNfcScanMinute'];
      final clearRevision = version == 1 ? 0 : decoded['clearRevision'];
      final barrier = _maximumMinute([minute, lastScan]);
      if ((minute != null && !_validMinute(minute)) ||
          (cleared != null && !_validMinute(cleared)) ||
          (version == 2 && !_validMinute(lastScan)) ||
          (version == 3 && lastScan != null && !_validMinute(lastScan)) ||
          clearRevision is! int ||
          clearRevision < 0 ||
          clearRevision > 0x1fffffffffffff ||
          (minute == null
              ? provenance != 'none'
              : provenance != 'observed' && provenance != 'legacyLowerBound') ||
          (cleared != null &&
              (barrier == null || (cleared as int) > barrier)) ||
          decoded['readings'] is! List) {
        _unavailable();
      }
      final entries = version != 1
          ? [
              for (final value in decoded['readings'] as List)
                _readStrictHistoryEntry(
                  value,
                  minute as int?,
                  lastScan as int?,
                  schemaVersion: version as int,
                ),
            ]
          : [
              for (final reading in _readStrictReadings(
                decoded['readings'] as List,
              ))
                _legacyEntry(reading),
            ];
      final identities = <String>{};
      for (final entry in entries) {
        final reading = entry.reading;
        final atMinute = reading.sensorMinute;
        if (!identities.add(_readingIdentity(reading)) ||
            (atMinute != null && (barrier == null || atMinute > barrier)) ||
            (cleared != null &&
                (atMinute == null || atMinute <= (cleared as int)))) {
          _unavailable();
        }
      }
      return _LibreHistory(
        schemaVersion: version as int,
        binding: storedBinding,
        observedMinute: minute as int?,
        provenance: provenance as String,
        clearedThroughMinute: cleared as int?,
        lastNfcScanMinute: lastScan as int?,
        clearRevision: clearRevision,
        entries: entries,
      );
    } catch (_) {
      _unavailable();
    }
  }

  LibreHistoryEntry _readStrictHistoryEntry(
    Object? value,
    int? observedMinute,
    int? lastNfcScanMinute, {
    required int schemaVersion,
  }) {
    const fields = {'reading', 'origin', 'firstReceivedAt', 'timestampBasis'};
    if (value is! Map<String, dynamic> ||
        value.length != fields.length ||
        !value.keys.every(fields.contains)) {
      _unavailable();
    }
    final origin = LibreHistoryOrigin.values
        .where((entry) => entry.name == value['origin'])
        .singleOrNull;
    final basis = LibreHistoryTimestampBasis.values
        .where((entry) => entry.name == value['timestampBasis'])
        .singleOrNull;
    if (origin == null || basis == null) _unavailable();
    final reading = _readStrictReading(value['reading'], legacy: false);
    final rawReceipt = value['firstReceivedAt'];
    DateTime? receipt;
    if (rawReceipt != null) {
      if (rawReceipt is! String ||
          !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(rawReceipt)) {
        _unavailable();
      }
      receipt = DateTime.tryParse(rawReceipt);
      if (receipt == null) _unavailable();
    }
    if (origin == LibreHistoryOrigin.legacyUnknown) {
      if (basis != LibreHistoryTimestampBasis.legacyUnknown ||
          receipt != null ||
          (reading.sensorMinute != null &&
              (observedMinute == null ||
                  reading.sensorMinute! > observedMinute))) {
        _unavailable();
      }
    } else if (origin == LibreHistoryOrigin.bleLive) {
      if (basis != LibreHistoryTimestampBasis.phoneReceipt ||
          receipt == null ||
          reading.recordedAt == null ||
          !reading.recordedAt!.isAtSameMomentAs(receipt) ||
          reading.sensorMinute == null ||
          observedMinute == null ||
          reading.sensorMinute! > observedMinute) {
        _unavailable();
      }
    } else if (origin == LibreHistoryOrigin.bleTrend ||
        origin == LibreHistoryOrigin.bleHistory) {
      if (schemaVersion != 3 ||
          basis != LibreHistoryTimestampBasis.sensorRelative ||
          receipt == null ||
          reading.recordedAt == null ||
          reading.sensorMinute == null ||
          observedMinute == null ||
          reading.source != CgmRecordSource.vendor ||
          !reading.isDisplayProvisional) {
        _unavailable();
      }
      final offset = receipt.difference(reading.recordedAt!).inMicroseconds;
      if (offset <= 0 || offset % Duration.microsecondsPerMinute != 0) {
        _unavailable();
      }
      final packetMinute =
          reading.sensorMinute! + offset ~/ Duration.microsecondsPerMinute;
      if (packetMinute > observedMinute ||
          !_validBleHistoryPosition(
            origin == LibreHistoryOrigin.bleTrend
                ? LibreGen1BleHistoryKind.trend
                : LibreGen1BleHistoryKind.history,
            packetMinute,
            reading.sensorMinute!,
          )) {
        _unavailable();
      }
    } else {
      if (basis != LibreHistoryTimestampBasis.sensorRelative ||
          receipt == null ||
          reading.recordedAt == null ||
          reading.recordedAt!.isAfter(receipt) ||
          reading.sensorMinute == null ||
          lastNfcScanMinute == null ||
          reading.sensorMinute! > lastNfcScanMinute ||
          reading.source != CgmRecordSource.vendor ||
          !reading.isDisplayProvisional) {
        _unavailable();
      }
      final ageDifference = receipt
          .difference(reading.recordedAt!)
          .inMicroseconds;
      if (ageDifference % Duration.microsecondsPerMinute != 0 ||
          reading.sensorMinute! +
                  ageDifference ~/ Duration.microsecondsPerMinute >
              lastNfcScanMinute) {
        _unavailable();
      }
    }
    return LibreHistoryEntry(
      reading: reading,
      origin: origin,
      firstReceivedAt: receipt,
      timestampBasis: basis,
    );
  }

  List<CgmReading> _readStrictReadings(
    List<dynamic> values, {
    bool legacy = false,
    bool libreBounds = true,
  }) => [
    for (final value in values)
      _readStrictReading(value, legacy: legacy, libreBounds: libreBounds),
  ];

  CgmReading _readStrictReading(
    Object? value, {
    required bool legacy,
    bool libreBounds = true,
  }) {
    const fields = {
      'valueMgdl',
      'source',
      'sensorMinute',
      'recordedAt',
      'rawValue',
      'qualifier',
      'isDisplayProvisional',
    };
    if (value is! Map<String, dynamic> ||
        !value.keys.every(fields.contains) ||
        (!legacy &&
            (value.length != fields.length ||
                value['isDisplayProvisional'] is! bool)) ||
        value['valueMgdl'] is! num ||
        value['source'] is! String ||
        !CgmRecordSource.values.any(
          (source) => source.name == value['source'],
        ) ||
        (value['sensorMinute'] != null &&
            (libreBounds
                ? !_validMinute(value['sensorMinute'])
                : value['sensorMinute'] is! int)) ||
        (value['recordedAt'] != null && value['recordedAt'] is! String) ||
        (value['rawValue'] != null && value['rawValue'] is! int) ||
        (value['qualifier'] != null && value['qualifier'] is! int) ||
        (value['isDisplayProvisional'] != null &&
            value['isDisplayProvisional'] is! bool)) {
      _unavailable();
    }
    final at = value['recordedAt'];
    if (at != null &&
        (DateTime.tryParse(at as String) == null ||
            (!legacy && !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(at)))) {
      _unavailable();
    }
    final reading = CgmReading.fromJson(value);
    if (libreBounds) {
      _validateReading(reading);
    } else if (!reading.valueMgdl.isFinite) {
      // Generic archives preserve raw/untimed observations, including zero
      // and non-Libre integer minute ranges. Export is not glucose eligibility.
      _unavailable();
    }
    // Legacy CgmReading.toJson could omit a local offset. Preserve the instant
    // obtained by the previous DateTime.tryParse semantics at migration, then
    // encode UTC so subsequent timezone changes cannot reinterpret it.
    return legacy && reading.recordedAt != null
        ? reading.copyWith(recordedAt: reading.recordedAt!.toUtc())
        : reading;
  }

  void _validateReading(CgmReading reading) {
    if (!reading.valueMgdl.isFinite ||
        reading.valueMgdl <= 0 ||
        (reading.sensorMinute != null && !_validMinute(reading.sensorMinute))) {
      _unavailable();
    }
  }

  /// Older Disconnect code moved accepted samples to archive-only lists and
  /// removed the active key. Recover only manifest-referenced segments for the
  /// exact saved bootstrap, never by address, name, or a directory scan. This
  /// runs only before a bound envelope exists; a tombstone never reimports it.
  List<CgmReading> _legacyMigrationHistory(
    LibreGen1ObservationBinding binding,
    List<CgmReading> active,
  ) => _earliestReceipts([
    ...active,
    ...?_readArchivedGroups(
      onlyStorageKey: binding.storageKey,
      allowBoundArchives: false,
    )[binding.storageKey],
  ]);

  Map<String, List<CgmReading>> _readArchivedGroups({
    String? onlyStorageKey,
    bool allowBoundArchives = true,
  }) {
    try {
      final raw = _store.getString('openHealth.sensorArchive');
      if (raw == null) return const {};
      final manifest = jsonDecode(raw);
      if (manifest is! List) _unavailable();
      final candidates = <String, List<CgmReading>>{};
      final groupBindings = <String, String>{};
      final visited = <String>{};
      for (final value in manifest) {
        if (value is! Map<String, dynamic> ||
            value['driverId'] is! String ||
            value['storageKey'] is! String) {
          _unavailable();
        }
        final storageKey = value['storageKey'] as String;
        if (value['driverId'] != 'libre2-gen1' ||
            (onlyStorageKey != null && storageKey != onlyStorageKey)) {
          continue;
        }
        _validateLibreStorageKey(storageKey);
        final key = _validatedArchiveReference(value, storageKey);
        if (!visited.add(key)) _unavailable();
        if (isQuarantined(key)) _unavailable();
        final count = value['readingCount'] as int;
        final historyRaw = _store.getString(key);
        final group = candidates.putIfAbsent(storageKey, () => []);
        // The legacy archive writer deliberately creates no blob for a
        // zero-reading segment, while still saving its metadata reference.
        if (historyRaw == null && count == 0) continue;
        if (historyRaw == null) _unavailable();
        final decoded = jsonDecode(historyRaw);
        final List<CgmReading> history;
        if (decoded is List) {
          history = _readStrictReadings(decoded, legacy: true);
        } else if (decoded is Map<String, dynamic> && allowBoundArchives) {
          final archived = _readArchiveEnvelope(
            key,
            decoded,
            storageKey: storageKey,
          );
          final digest = archived.binding.sensorBindingDigest;
          final previousDigest = groupBindings[storageKey];
          if (previousDigest != null && previousDigest != digest) {
            _unavailable();
          }
          groupBindings[storageKey] = digest;
          history = archived.history;
        } else {
          // A missing active schema-two envelope cannot be reconstructed as
          // schema one from historical NFC samples and a fabricated BLE age.
          _unavailable();
        }
        if (history.length != count) _unavailable();
        group.addAll(history);
      }
      return Map<String, List<CgmReading>>.unmodifiable({
        for (final entry in candidates.entries)
          entry.key: List<CgmReading>.unmodifiable(
            _earliestReceipts(entry.value),
          ),
      });
    } catch (_) {
      _unavailable();
    }
  }

  _LibreArchiveHistory _readArchiveEnvelope(
    String key,
    Map<String, dynamic> value, {
    String? storageKey,
    bool validateActiveBinding = true,
  }) {
    const fields = {
      'schemaVersion',
      'kind',
      'driverId',
      'storageKey',
      'sensorBindingDigest',
      'readings',
    };
    if (value.length != fields.length ||
        !value.keys.every(fields.contains) ||
        value['schemaVersion'] is! int ||
        (value['schemaVersion'] != 2 && value['schemaVersion'] != 3) ||
        value['kind'] != 'libreHistoryArchive' ||
        value['driverId'] != 'libre2-gen1' ||
        value['storageKey'] is! String ||
        value['sensorBindingDigest'] is! String ||
        value['readings'] is! List ||
        (storageKey != null && value['storageKey'] != storageKey)) {
      _unavailable();
    }
    final storedKey = value['storageKey'] as String;
    _validateArchiveKey(key, storedKey);
    final binding = LibreGen1ObservationBinding(
      bootstrapId: storedKey.substring('libre2-gen1:'.length),
      sensorBindingDigest: value['sensorBindingDigest'] as String,
    );
    if (validateActiveBinding) {
      final active = _read(_historyKey(binding.driverId, binding.storageKey));
      if (active is _LibreHistory &&
          active.binding.sensorBindingDigest != binding.sensorBindingDigest) {
        _unavailable();
      }
    }
    final entries = [
      for (final entry in value['readings'] as List)
        _readStrictHistoryEntry(
          entry,
          0xffff,
          0xffff,
          schemaVersion: value['schemaVersion'] as int,
        ),
    ];
    if (entries
            .map((entry) => _readingIdentity(entry.reading))
            .toSet()
            .length !=
        entries.length) {
      _unavailable();
    }
    _knownProvenanceArchives.add(key);
    return _LibreArchiveHistory(binding: binding, entries: entries);
  }

  void _validateArchiveKey(String key, String storageKey) {
    try {
      _validateLibreStorageKey(storageKey);
      const prefix = 'openHealth.history.archive.';
      if (!key.startsWith(prefix)) _unavailable();
      _validatedArchiveReference({
        'id': key.substring(prefix.length),
        'historyKey': key,
        'readingCount': 0,
      }, storageKey);
    } catch (_) {
      // Parser diagnostics may include the opaque archive identity.
      _unavailable();
    }
  }

  List<CgmReading> _earliestReceipts(
    Iterable<CgmReading> candidates,
  ) {
    final firstReceipts = <String, CgmReading>{};
    for (final reading in candidates) {
      final identity = _readingIdentity(reading);
      final previous = firstReceipts[identity];
      final at = reading.recordedAt;
      if (previous == null ||
          (at != null &&
              (previous.recordedAt == null ||
                  at.isBefore(previous.recordedAt!)))) {
        firstReceipts[identity] = reading;
      }
    }
    return _keepFirst([], firstReceipts.values);
  }

  String _validatedArchiveReference(
    Map<String, dynamic> value,
    String storageKey,
  ) {
    const fields = {
      'id',
      'historyKey',
      'storageKey',
      'driverId',
      'deviceId',
      'displayName',
      'serial',
      'model',
      'firmware',
      'sensorVariant',
      'reason',
      'readingCount',
      'warmupMinutes',
      'startedAt',
      'endedAt',
      'lastReadingAt',
    };
    final id = value['id'];
    final key = value['historyKey'];
    final count = value['readingCount'];
    if (!value.keys.every(fields.contains) ||
        id is! String ||
        id.isEmpty ||
        key is! String ||
        key != 'openHealth.history.archive.$id' ||
        count is! int ||
        count < 0) {
      _unavailable();
    }
    final bytes = base64Url.decode(base64Url.normalize(id));
    if (base64Url.encode(bytes).replaceAll('=', '') != id) _unavailable();
    final identity = utf8.decode(bytes);
    final prefix = 'libre2-gen1|$storageKey|';
    if (!identity.startsWith(prefix) ||
        !RegExp(r'^-?\d+$').hasMatch(identity.substring(prefix.length)) ||
        int.tryParse(identity.substring(prefix.length)) == null) {
      _unavailable();
    }
    for (final field in [
      'deviceId',
      'displayName',
      'serial',
      'model',
      'firmware',
    ]) {
      if (value.containsKey(field) && value[field] is! String) _unavailable();
    }
    if (value.containsKey('reason') &&
        !{'expired', 'replaced', 'disconnected'}.contains(value['reason'])) {
      _unavailable();
    }
    final warmup = value['warmupMinutes'];
    if (warmup != null && (warmup is! int || warmup < 0)) _unavailable();
    final variant = value['sensorVariant'];
    if (variant != null) {
      if (variant is! Map<String, Object?> ||
          variant.values.any((field) => field is! String)) {
        _unavailable();
      }
      // The shared legacy parser is intentionally permissive. Archive startup
      // must prove a later typed manifest save will not trim or drop fields,
      // reinterpret a future source, or silently replace malformed metadata.
      final normalized = CgmSensorVariant.fromJson(variant).toJson();
      if (normalized.length != variant.length ||
          !variant.entries.every(
            (entry) =>
                normalized.containsKey(entry.key) &&
                normalized[entry.key] == entry.value,
          )) {
        _unavailable();
      }
    }
    for (final field in ['startedAt', 'endedAt', 'lastReadingAt']) {
      final timestamp = value[field];
      if (timestamp != null &&
          (timestamp is! String || DateTime.tryParse(timestamp) == null)) {
        _unavailable();
      }
    }
    return key;
  }

  _LibreHistory _fromLegacy(
    LibreGen1ObservationBinding binding,
    List<CgmReading> readings,
  ) {
    int? frontier;
    for (final reading in readings) {
      final minute = reading.sensorMinute;
      if (minute != null && (frontier == null || minute > frontier)) {
        frontier = minute;
      }
    }
    return _LibreHistory(
      binding: binding,
      observedMinute: frontier,
      provenance: frontier == null ? 'none' : 'legacyLowerBound',
      clearedThroughMinute: null,
      history: _keepFirst([], readings),
    );
  }

  Future<void> _writeLibre(String key, _LibreHistory record) async {
    final encoded = jsonEncode(record.toJson());
    try {
      await _store.setString(key, encoded);
    } catch (_) {
      // HealthStateStore has no definitely-rolled-back error. Even an ordinary
      // exception can follow a rename and failed rollback with stale cache.
      // Keep this queue alive for other keys, but never rewrite this frontier.
      _quarantinedKeys.add(key);
      _unavailable();
    }
    _confirmedRecords[key] = record;
  }

  static bool _validMinute(Object? value) =>
      value is int && value >= 0 && value <= 0xffff;

  static void _validateLibreStorageKey(String key) {
    const prefix = 'libre2-gen1:';
    if (!key.startsWith(prefix) ||
        key.length <= prefix.length ||
        key.length > prefix.length + 128) {
      _unavailable();
    }
  }

  static String _libreStorageKey(String key) {
    try {
      const prefix = 'openHealth.history.v2.';
      final identity = jsonDecode(
        utf8.decode(
          base64Url.decode(
            base64Url.normalize(key.substring(prefix.length)),
          ),
        ),
      );
      if (identity is! List ||
          identity.length != 2 ||
          identity[0] != 'libre2-gen1' ||
          identity[1] is! String) {
        _unavailable();
      }
      final storageKey = identity[1] as String;
      _validateLibreStorageKey(storageKey);
      if (_historyKey('libre2-gen1', storageKey) != key) _unavailable();
      return storageKey;
    } catch (_) {
      _unavailable();
    }
  }

  static bool _isLibreKey(String key) {
    const prefix = 'openHealth.history.v2.';
    if (!key.startsWith(prefix)) return false;
    try {
      final identity = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(key.substring(prefix.length))),
        ),
      );
      return identity is List &&
          identity.length == 2 &&
          identity.first == 'libre2-gen1';
    } catch (_) {
      return false;
    }
  }

  static Never _unavailable() =>
      throw StateError('Stored sensor history is unavailable.');
}

class _History {
  const _History(this.history);
  final List<CgmReading> history;
}

final class _LibreHistory extends _History {
  _LibreHistory({
    this.schemaVersion = 1,
    required this.binding,
    required this.observedMinute,
    required this.provenance,
    required this.clearedThroughMinute,
    this.lastNfcScanMinute,
    this.clearRevision = 0,
    List<CgmReading>? history,
    List<LibreHistoryEntry>? entries,
  }) : entries = _orderedEntries(
         entries ??
             [
               for (final reading in history ?? <CgmReading>[])
                 _legacyEntry(reading),
             ],
         legacy: schemaVersion == 1,
       ),
       super(
         _keepFirst(
           [],
           history ??
               [
                 for (final entry in entries ?? <LibreHistoryEntry>[])
                   entry.reading,
               ],
         ),
       );

  final int schemaVersion;
  final LibreGen1ObservationBinding binding;
  final int? observedMinute;
  final String provenance;
  final int? clearedThroughMinute;
  final int? lastNfcScanMinute;
  final int clearRevision;
  final List<LibreHistoryEntry> entries;

  int? get replayBarrierMinute => _maximumMinute([
    observedMinute,
    lastNfcScanMinute,
    clearedThroughMinute,
    for (final reading in history) reading.sensorMinute,
  ]);

  LibreGen1ObservationState get state => LibreGen1ObservationState(
    observedMinute: observedMinute,
    replayBarrierMinute: replayBarrierMinute,
    history: history,
  );

  _LibreHistory copyWith({
    int? schemaVersion,
    int? observedMinute,
    String? provenance,
    int? clearedThroughMinute,
    List<CgmReading>? history,
    List<LibreHistoryEntry>? entries,
    int? lastNfcScanMinute,
    int? clearRevision,
  }) => _LibreHistory(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    binding: binding,
    observedMinute: observedMinute ?? this.observedMinute,
    provenance: provenance ?? this.provenance,
    clearedThroughMinute: clearedThroughMinute ?? this.clearedThroughMinute,
    entries:
        entries ??
        (history == null
            ? this.entries
            : [for (final reading in history) _legacyEntry(reading)]),
    lastNfcScanMinute: lastNfcScanMinute ?? this.lastNfcScanMinute,
    clearRevision: clearRevision ?? this.clearRevision,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'driverId': binding.driverId,
    'storageKey': binding.storageKey,
    'sensorBindingDigest': binding.sensorBindingDigest,
    'observedMinute': observedMinute,
    'frontierProvenance': provenance,
    'clearedThroughMinute': clearedThroughMinute,
    if (schemaVersion >= 2) 'lastNfcScanMinute': lastNfcScanMinute,
    if (schemaVersion >= 2) 'clearRevision': clearRevision,
    'readings': schemaVersion == 1
        ? history.map((reading) => reading.toJson()).toList()
        : [
            for (final entry in entries) _entryJson(entry),
          ],
  };
}

final class _LibreArchiveHistory extends _History {
  _LibreArchiveHistory({
    required this.binding,
    required List<LibreHistoryEntry> entries,
  }) : entries = List<LibreHistoryEntry>.unmodifiable(entries),
       super(
         List<CgmReading>.unmodifiable(entries.map((entry) => entry.reading)),
       );
  final LibreGen1ObservationBinding binding;
  final List<LibreHistoryEntry> entries;
}

final class _NfcImportTicket implements LibreNfcHistoryImportTicket {
  _NfcImportTicket({
    required this.repositoryOwner,
    required this.connectionOwner,
    required this.binding,
    required this.clearRevision,
    required this.minimumScanMinute,
    required this.startedAt,
    required this.startedMonotonic,
    required this.validity,
  });

  final Object repositoryOwner;
  final Object connectionOwner;
  final LibreGen1ObservationBinding binding;
  final int clearRevision;
  final int? minimumScanMinute;
  final DateTime startedAt;
  final Duration startedMonotonic;
  final Duration validity;
  bool cancelled = false;

  @override
  String toString() => 'LibreNfcHistoryImportTicket(data: <redacted>)';
}

Duration Function() _runningMonotonicClock() {
  final clock = Stopwatch()..start();
  return () => clock.elapsed;
}

LibreHistoryEntry _legacyEntry(CgmReading reading) => LibreHistoryEntry(
  reading: reading,
  origin: LibreHistoryOrigin.legacyUnknown,
  firstReceivedAt: null,
  timestampBasis: LibreHistoryTimestampBasis.legacyUnknown,
);

Map<String, Object?> _entryJson(LibreHistoryEntry entry) => {
  'reading': entry.reading.toJson(),
  'origin': entry.origin.name,
  'firstReceivedAt': entry.firstReceivedAt?.toUtc().toIso8601String(),
  'timestampBasis': entry.timestampBasis.name,
};

List<LibreHistoryEntry> _orderedEntries(
  Iterable<LibreHistoryEntry> incoming, {
  required bool legacy,
}) {
  final entries = <String, LibreHistoryEntry>{};
  for (final entry in incoming) {
    entries.putIfAbsent(
      _readingIdentity(entry.reading),
      () => legacy ? _legacyEntry(entry.reading) : entry,
    );
  }
  return List<LibreHistoryEntry>.unmodifiable([
    for (final reading in _keepFirst(
      [],
      entries.values.map((entry) => entry.reading),
    ))
      entries[_readingIdentity(reading)]!,
  ]);
}

int? _maximumMinute(Iterable<Object?> values) {
  int? maximum;
  for (final value in values) {
    if (value == null) continue;
    if (value is! int || value < 0 || value > 0xffff) {
      SensorHistoryRepository._unavailable();
    }
    if (maximum == null || value > maximum) maximum = value;
  }
  return maximum;
}

/// Gen1's sparse BLE packet slots, not NFC ring positions. A historical
/// sample cannot acquire a live timestamp or extend the packet frontier.
bool _validBleHistoryPosition(
  LibreGen1BleHistoryKind kind,
  int packetMinute,
  int sampleMinute,
) {
  if (packetMinute < 0 ||
      packetMinute > 0xffff ||
      sampleMinute < 60 ||
      sampleMinute >= packetMinute) {
    return false;
  }
  if (kind == LibreGen1BleHistoryKind.trend) {
    return const {2, 4, 6, 7, 12, 15}.contains(packetMinute - sampleMinute);
  }
  final newest = ((packetMinute - 2) ~/ 15) * 15;
  return const {0, 15, 30}.contains(newest - sampleMinute);
}

bool _sameReading(CgmReading left, CgmReading right) =>
    left.valueMgdl == right.valueMgdl &&
    left.source == right.source &&
    left.sensorMinute == right.sensorMinute &&
    (left.recordedAt == null
        ? right.recordedAt == null
        : right.recordedAt != null &&
              left.recordedAt!.isAtSameMomentAs(right.recordedAt!)) &&
    left.rawValue == right.rawValue &&
    left.qualifier == right.qualifier &&
    left.isDisplayProvisional == right.isDisplayProvisional;

String _readingIdentity(CgmReading reading) => reading.sensorMinute == null
    ? 'time:${reading.recordedAt?.toUtc().toIso8601String()}:${reading.source.name}'
    : 'minute:${reading.sensorMinute}:${reading.source.name}';

List<CgmReading> _keepFirst(
  Iterable<CgmReading> existing,
  Iterable<CgmReading> incoming,
) {
  final readings = <String, CgmReading>{};
  for (final reading in [...existing, ...incoming]) {
    readings.putIfAbsent(_readingIdentity(reading), () => reading);
  }
  return readings.values.toList()..sort((left, right) {
    if (left.recordedAt != null && right.recordedAt != null) {
      return left.recordedAt!.compareTo(right.recordedAt!);
    }
    if (left.recordedAt != null) return 1;
    if (right.recordedAt != null) return -1;
    return (left.sensorMinute ?? -1).compareTo(right.sensorMinute ?? -1);
  });
}
