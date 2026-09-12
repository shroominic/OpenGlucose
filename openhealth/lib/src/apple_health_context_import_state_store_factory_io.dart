import 'apple_health_context_import_state.dart';
import 'apple_health_context_import_state_store_io.dart';

AppleHealthContextImportStateStore createAppleHealthContextImportStateStore() {
  return FileAppleHealthContextImportStateStore();
}
