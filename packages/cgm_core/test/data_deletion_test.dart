import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  final counts = <LocalDataDomain, int>{
    for (final domain in LocalDataDomain.values) domain: 1,
  };

  test('plan and dry-run report every domain without mutation', () async {
    final backend = InMemoryLocalHealthDataDeletionBackend(counts: counts);
    final coordinator = LocalDataDeletionCoordinator(
      backend: backend,
      clock: () => DateTime.utc(2026, 8, 15, 12),
      idFactory: () => 'fixed-plan',
    );
    final plan = await coordinator.createPlan();
    expect(plan.domains, LocalDataDomain.values);
    expect(plan.inventory.isEmpty, isFalse);
    expect(plan.confirmationPhrase, 'DELETE LOCAL DATA FIXED-PLAN');

    final result = await coordinator.dryRun(plan);
    expect(result.status, LocalDataDeletionStatus.dryRun);
    expect(result.dryRun, isTrue);
    expect(result.deleted, isEmpty);
    expect(result.remaining, LocalDataDomain.values);
    expect((await backend.inspect()).isEmpty, isFalse);
  });

  test('missing confirmation performs no mutation', () async {
    final backend = InMemoryLocalHealthDataDeletionBackend(counts: counts);
    final coordinator = LocalDataDeletionCoordinator(
      backend: backend,
      idFactory: () => 'confirm-plan',
    );
    final plan = await coordinator.createPlan();
    final result = await coordinator.execute(plan, confirmation: 'yes');
    expect(result.status, LocalDataDeletionStatus.confirmationRequired);
    expect(result.deleted, isEmpty);
    expect((await backend.inspect()).isEmpty, isFalse);
  });

  test('exact confirmation deletes and verifies every domain', () async {
    final backend = InMemoryLocalHealthDataDeletionBackend(counts: counts);
    final coordinator = LocalDataDeletionCoordinator(
      backend: backend,
      idFactory: () => 'execute-plan',
    );
    final plan = await coordinator.createPlan();
    final result = await coordinator.execute(
      plan,
      confirmation: plan.confirmationPhrase,
    );
    expect(result.status, LocalDataDeletionStatus.completed);
    expect(result.isComplete, isTrue);
    expect(result.remaining, isEmpty);
    expect((await backend.inspect()).isEmpty, isTrue);
  });

  test('stale plan is refused before mutation', () async {
    final backend = InMemoryLocalHealthDataDeletionBackend(counts: counts);
    final coordinator = LocalDataDeletionCoordinator(
      backend: backend,
      idFactory: () => 'stale-plan',
    );
    final plan = await coordinator.createPlan();
    await backend.deleteDomain(LocalDataDomain.aiInsights);
    final result = await coordinator.execute(
      plan,
      confirmation: plan.confirmationPhrase,
    );
    expect(result.status, LocalDataDeletionStatus.stalePlan);
    expect(result.deleted, isEmpty);
  });

  test(
    'failure is reported as incomplete and stops subsequent domains',
    () async {
      final backend = InMemoryLocalHealthDataDeletionBackend(
        counts: counts,
        failingDeletes: <LocalDataDomain>{LocalDataDomain.aiApiKey},
      );
      final coordinator = LocalDataDeletionCoordinator(
        backend: backend,
        idFactory: () => 'failure-plan',
      );
      final plan = await coordinator.createPlan();
      final result = await coordinator.execute(
        plan,
        confirmation: plan.confirmationPhrase,
      );
      expect(result.status, LocalDataDeletionStatus.partialFailure);
      expect(result.isComplete, isFalse);
      expect(result.errors, contains(LocalDataDomain.aiApiKey));
      expect(result.remaining, contains(LocalDataDomain.aiApiKey));
      expect(result.remaining, contains(LocalDataDomain.alertHistory));
    },
  );

  test('failed verification never claims complete erasure', () async {
    final backend = InMemoryLocalHealthDataDeletionBackend(
      counts: counts,
      failingVerifications: <LocalDataDomain>{LocalDataDomain.sensorArchive},
    );
    final coordinator = LocalDataDeletionCoordinator(
      backend: backend,
      idFactory: () => 'verify-plan',
    );
    final plan = await coordinator.createPlan();
    final result = await coordinator.execute(
      plan,
      confirmation: plan.confirmationPhrase,
    );
    expect(result.status, LocalDataDeletionStatus.partialFailure);
    expect(result.isComplete, isFalse);
    expect(result.errors, contains(LocalDataDomain.sensorArchive));
  });
}
