import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/persistence/health_repository_lifecycle.dart';

class _ClosableRepository extends InMemoryHealthRepository {
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls += 1;
  }
}

void main() {
  test(
    'the app-owned repository is opened once and never reused after teardown',
    () async {
      final repository = _ClosableRepository();
      var openCalls = 0;
      final lifecycle = AppHealthRepositoryLifecycle(() async {
        openCalls += 1;
        return repository;
      });

      expect(await lifecycle.acquire(), same(repository));
      expect(await lifecycle.acquire(), same(repository));
      expect(openCalls, 1);

      await lifecycle.dispose();
      await lifecycle.dispose();

      expect(repository.closeCalls, 1);
      await expectLater(lifecycle.acquire(), throwsA(isA<StateError>()));
      expect(openCalls, 1);
    },
  );
}
