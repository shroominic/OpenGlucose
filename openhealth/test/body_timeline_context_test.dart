import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/body_timeline_context.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);

  test('loads today context into a ready snapshot', () async {
    final repository = InMemoryHealthRepository();
    await repository.init();
    await repository.upsertActivitySamples(<ActivitySample>[
      ActivitySample(
        start: now.subtract(const Duration(minutes: 20)),
        end: now.subtract(const Duration(minutes: 5)),
        type: ActivityType.steps,
        source: DataSource.appleHealth,
        steps: 900,
      ),
    ]);

    final controller = BodyTimelineContextController(
      serviceFactory: () async => JournalService(repository: repository),
      now: () => now,
    );

    expect(controller.status, BodyTimelineContextStatus.idle);
    await controller.load();

    expect(controller.status, BodyTimelineContextStatus.ready);
    expect(controller.context?.activitySamples, hasLength(1));
    expect(controller.error, isNull);
    await repository.close();
  });

  test('reports empty when no local context is available', () async {
    final controller = BodyTimelineContextController(
      serviceFactory: () async =>
          JournalService(repository: InMemoryHealthRepository()),
      now: () => now,
    );

    await controller.load();

    expect(controller.status, BodyTimelineContextStatus.empty);
    expect(controller.context?.timeline, isEmpty);
    expect(controller.error, isNull);
  });

  test('fails closed with a safe, actionable error', () async {
    final controller = BodyTimelineContextController(
      serviceFactory: () async => throw StateError('private storage detail'),
      now: () => now,
    );

    await controller.load();

    expect(controller.status, BodyTimelineContextStatus.error);
    expect(controller.context, isNull);
    expect(controller.error, contains('local body context'));
    expect(controller.error, isNot(contains('private storage detail')));
  });

  test('coalesces concurrent loads and supports explicit refresh', () async {
    var factoryCalls = 0;
    final controller = BodyTimelineContextController(
      serviceFactory: () async {
        factoryCalls += 1;
        return JournalService(repository: InMemoryHealthRepository());
      },
      now: () => now,
    );

    await Future.wait(<Future<void>>[controller.load(), controller.load()]);
    expect(factoryCalls, 1);
    await controller.load();
    expect(factoryCalls, 1);
    await controller.load(force: true);
    expect(factoryCalls, 2);
  });
}
