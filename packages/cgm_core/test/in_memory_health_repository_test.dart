import 'package:cgm_core/cgm_core.dart';

import 'health_repository_contract.dart';

void main() {
  runHealthRepositoryContractTests(InMemoryHealthRepository.new);
}
