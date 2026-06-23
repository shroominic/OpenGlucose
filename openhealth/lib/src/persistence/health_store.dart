import 'package:cgm_core/cgm_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sqflite_health_repository.dart';

export 'sqflite_health_repository.dart';

/// Default on-disk filename for the local health database.
const String kHealthDbFileName = 'openhealth_health.db';

/// Opens the app's local-first [HealthRepository], backed by sqflite in the
/// platform application-documents directory.
///
/// This is the production entry point the journaling / AI / HealthKit-import
/// features should use. Tests construct [SqfliteHealthRepository] directly with
/// an in-memory FFI factory instead, so they need no device or file system.
Future<HealthRepository> openHealthRepository({
  String fileName = kHealthDbFileName,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final repo = SqfliteHealthRepository(path: p.join(dir.path, fileName));
  await repo.init();
  return repo;
}
