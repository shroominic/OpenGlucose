/// Fail-closed, dry-run-first coordination for complete local health-data
/// erasure.
///
/// This package only defines the contract and deterministic orchestration. A
/// Flutter adapter must connect each domain to its real store (SQLite,
/// restricted sensor state, secure keychain, native background surfaces, and
/// export cache). No existing UI calls this coordinator implicitly.
library;

/// Local data domains that must be considered by a complete erase operation.
enum LocalDataDomain {
  journalEvents,
  activitySamples,
  sleepSamples,
  heartRateSamples,
  aiInsights,
  aiApiKey,
  alertHistory,
  activeSensorState,
  sensorArchive,
  backgroundSurfaces,
  derivedCaches,
  temporaryExports;

  String get key => name;

  static LocalDataDomain fromKey(String? key) {
    for (final domain in values) {
      if (domain.name == key) return domain;
    }
    throw FormatException('Unsupported local-data domain: $key');
  }
}

/// A point-in-time, non-sensitive count inventory of local data.
class LocalDataInventory {
  LocalDataInventory(Map<LocalDataDomain, int> counts)
    : counts = Map<LocalDataDomain, int>.unmodifiable(<LocalDataDomain, int>{
        for (final domain in LocalDataDomain.values)
          domain: _validateCount(counts[domain] ?? 0, domain),
      });

  final Map<LocalDataDomain, int> counts;

  int count(LocalDataDomain domain) => counts[domain] ?? 0;

  bool get isEmpty => counts.values.every((count) => count == 0);

  /// Stable comparison token for detecting a changed store between planning
  /// and execution. It contains domain names and counts only, never records or
  /// identifiers.
  String get fingerprint => LocalDataDomain.values
      .map((domain) => '${domain.key}:${count(domain)}')
      .join('|');

  Map<String, Object> toJson() => <String, Object>{
    for (final domain in LocalDataDomain.values) domain.key: count(domain),
  };

  factory LocalDataInventory.fromJson(Map<String, Object?> json) {
    return LocalDataInventory(<LocalDataDomain, int>{
      for (final entry in json.entries)
        LocalDataDomain.fromKey(entry.key): _readCount(entry.value, entry.key),
    });
  }
}

/// An explicit, reviewable dry-run plan. Creating a plan never mutates data.
class LocalDataDeletionPlan {
  const LocalDataDeletionPlan({
    required this.id,
    required this.createdAt,
    required this.domains,
    required this.inventory,
  });

  final String id;
  final DateTime createdAt;
  final List<LocalDataDomain> domains;
  final LocalDataInventory inventory;

  String get inventoryFingerprint => inventory.fingerprint;

  /// A phrase a UI may ask the user to confirm. The coordinator never treats
  /// a generic `true` value as consent; callers must pass this exact phrase.
  String get confirmationPhrase => 'DELETE LOCAL DATA ${id.toUpperCase()}';

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': 1,
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'domains': domains.map((domain) => domain.key).toList(growable: false),
    'inventory': inventory.toJson(),
    'inventoryFingerprint': inventoryFingerprint,
    'confirmationPhrase': confirmationPhrase,
  };
}

/// Outcome status of an attempted deletion.
enum LocalDataDeletionStatus {
  /// A plan was produced without mutation.
  dryRun,

  /// Execution was refused because explicit confirmation was missing.
  confirmationRequired,

  /// Execution was refused because the store changed after planning.
  stalePlan,

  /// All requested domains were deleted and verified empty.
  completed,

  /// A delete or verification failed; callers must not claim complete erasure.
  partialFailure;

  String get key => name;
}

/// Machine- and UI-readable result of a dry-run or execution attempt.
class LocalDataDeletionResult {
  const LocalDataDeletionResult({
    required this.status,
    required this.plan,
    required this.requested,
    required this.deleted,
    required this.remaining,
    required this.errors,
    required this.dryRun,
  });

  final LocalDataDeletionStatus status;
  final LocalDataDeletionPlan plan;
  final List<LocalDataDomain> requested;
  final List<LocalDataDomain> deleted;
  final List<LocalDataDomain> remaining;
  final Map<LocalDataDomain, String> errors;
  final bool dryRun;

  bool get isComplete => status == LocalDataDeletionStatus.completed;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.key,
    'plan': plan.toJson(),
    'requested': requested.map((domain) => domain.key).toList(growable: false),
    'deleted': deleted.map((domain) => domain.key).toList(growable: false),
    'remaining': remaining.map((domain) => domain.key).toList(growable: false),
    'errors': <String, String>{
      for (final entry in errors.entries) entry.key.key: entry.value,
    },
    'dryRun': dryRun,
  };
}

/// Store adapter required by [LocalDataDeletionCoordinator].
///
/// Implementations must make [inspect] report counts from durable stores and
/// must fail closed when they cannot initialize or verify a domain. Deleting a
/// domain means removing every record and derived copy in that domain, not
/// merely hiding it from the current screen.
abstract interface class LocalHealthDataDeletionBackend {
  Future<LocalDataInventory> inspect();

  Future<void> deleteDomain(LocalDataDomain domain);

  Future<bool> verifyDomainEmpty(LocalDataDomain domain);
}

/// Coordinates explicit complete/local-domain deletion without UI side effects.
class LocalDataDeletionCoordinator {
  LocalDataDeletionCoordinator({
    required LocalHealthDataDeletionBackend backend,
    DateTime Function()? clock,
    String Function()? idFactory,
  }) : _backend = backend,
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? _defaultIdFactory;

  final LocalHealthDataDeletionBackend _backend;
  final DateTime Function() _clock;
  final String Function() _idFactory;

  /// Inspects all domains and returns a plan. This is always a dry run.
  Future<LocalDataDeletionPlan> createPlan({
    Set<LocalDataDomain>? domains,
  }) async {
    final inventory = await _backend.inspect();
    final selected = (domains ?? LocalDataDomain.values.toSet()).toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final id = _idFactory().trim();
    if (id.isEmpty) throw StateError('Deletion plan id must not be empty.');
    return LocalDataDeletionPlan(
      id: id,
      createdAt: _clock().toUtc(),
      domains: List<LocalDataDomain>.unmodifiable(selected),
      inventory: inventory,
    );
  }

  /// Returns a dry-run report for [plan] without mutating any store.
  Future<LocalDataDeletionResult> dryRun(LocalDataDeletionPlan plan) async {
    final current = await _backend.inspect();
    if (current.fingerprint != plan.inventoryFingerprint) {
      return _result(
        plan: plan,
        status: LocalDataDeletionStatus.stalePlan,
        errors: <LocalDataDomain, String>{
          _firstDomain(plan): 'Store changed since this plan was created.',
        },
        dryRun: true,
        inventory: current,
      );
    }
    return _result(
      plan: plan,
      status: LocalDataDeletionStatus.dryRun,
      dryRun: true,
      inventory: current,
    );
  }

  /// Executes [plan] only after exact phrase confirmation.
  ///
  /// A missing/incorrect confirmation, stale plan, delete failure, or failed
  /// post-delete verification performs no further destructive work and returns
  /// a truthful non-complete result. Existing UI is not wired to this method.
  Future<LocalDataDeletionResult> execute(
    LocalDataDeletionPlan plan, {
    required String confirmation,
  }) async {
    if (confirmation != plan.confirmationPhrase) {
      return _result(
        plan: plan,
        status: LocalDataDeletionStatus.confirmationRequired,
        errors: <LocalDataDomain, String>{
          _firstDomain(plan): 'Exact deletion confirmation was not provided.',
        },
        dryRun: false,
      );
    }

    final current = await _backend.inspect();
    if (current.fingerprint != plan.inventoryFingerprint) {
      return _result(
        plan: plan,
        status: LocalDataDeletionStatus.stalePlan,
        errors: <LocalDataDomain, String>{
          _firstDomain(plan): 'Store changed since this plan was created.',
        },
        dryRun: false,
        inventory: current,
      );
    }

    final deleted = <LocalDataDomain>[];
    final errors = <LocalDataDomain, String>{};
    for (final domain in plan.domains) {
      if (current.count(domain) == 0) {
        continue;
      }
      try {
        await _backend.deleteDomain(domain);
        if (!await _backend.verifyDomainEmpty(domain)) {
          errors[domain] = 'Domain did not verify empty after deletion.';
          break;
        }
        deleted.add(domain);
      } catch (error) {
        errors[domain] = 'Deletion failed: $error';
        break;
      }
    }
    final remainingInventory = await _backend.inspect();
    final remaining = plan.domains
        .where((domain) => remainingInventory.count(domain) > 0)
        .toList(growable: false);
    final status = errors.isEmpty && remaining.isEmpty
        ? LocalDataDeletionStatus.completed
        : LocalDataDeletionStatus.partialFailure;
    return LocalDataDeletionResult(
      status: status,
      plan: plan,
      requested: plan.domains,
      deleted: List<LocalDataDomain>.unmodifiable(deleted),
      remaining: remaining,
      errors: Map<LocalDataDomain, String>.unmodifiable(errors),
      dryRun: false,
    );
  }

  LocalDataDeletionResult _result({
    required LocalDataDeletionPlan plan,
    required LocalDataDeletionStatus status,
    required bool dryRun,
    Map<LocalDataDomain, String> errors = const <LocalDataDomain, String>{},
    LocalDataInventory? inventory,
  }) {
    final current = inventory ?? plan.inventory;
    final remaining = plan.domains
        .where((domain) => current.count(domain) > 0)
        .toList(growable: false);
    return LocalDataDeletionResult(
      status: status,
      plan: plan,
      requested: plan.domains,
      deleted: const <LocalDataDomain>[],
      remaining: remaining,
      errors: Map<LocalDataDomain, String>.unmodifiable(errors),
      dryRun: dryRun,
    );
  }

  static LocalDataDomain _firstDomain(LocalDataDeletionPlan plan) =>
      plan.domains.isEmpty ? LocalDataDomain.journalEvents : plan.domains.first;

  static String _defaultIdFactory() =>
      'erase-${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

/// Deterministic backend for contract tests and previews.
class InMemoryLocalHealthDataDeletionBackend
    implements LocalHealthDataDeletionBackend {
  InMemoryLocalHealthDataDeletionBackend({
    Map<LocalDataDomain, int>? counts,
    Set<LocalDataDomain>? failingDeletes,
    Set<LocalDataDomain>? failingVerifications,
  }) : _counts = <LocalDataDomain, int>{
         for (final domain in LocalDataDomain.values)
           domain: _validateCount(counts?[domain] ?? 0, domain),
       },
       failingDeletes = Set<LocalDataDomain>.of(failingDeletes ?? const {}),
       failingVerifications = Set<LocalDataDomain>.of(
         failingVerifications ?? const {},
       );

  final Map<LocalDataDomain, int> _counts;
  final Set<LocalDataDomain> failingDeletes;
  final Set<LocalDataDomain> failingVerifications;

  @override
  Future<LocalDataInventory> inspect() async => LocalDataInventory(_counts);

  @override
  Future<void> deleteDomain(LocalDataDomain domain) async {
    if (failingDeletes.contains(domain)) {
      throw StateError('Injected deletion failure for ${domain.key}.');
    }
    _counts[domain] = 0;
  }

  @override
  Future<bool> verifyDomainEmpty(LocalDataDomain domain) async {
    if (failingVerifications.contains(domain)) return false;
    return _counts[domain] == 0;
  }
}

int _validateCount(int count, LocalDataDomain domain) {
  if (count < 0) {
    throw ArgumentError.value(
      count,
      'count',
      '${domain.key} must be non-negative',
    );
  }
  return count;
}

int _readCount(Object? value, String key) {
  if (value is! int || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value;
}
