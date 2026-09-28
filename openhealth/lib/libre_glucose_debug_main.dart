// SPDX-License-Identifier: MIT
// Combined debug executable includes GPL code; see ADR 0004 and package notices.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'main.dart' as app;
import 'src/driver_factory_io.dart';
import 'src/libre_gen1_glucose_adapter.dart';

/// Normal OpenGlucose UI with an explicitly selected private bench decoder.
/// No sensor is connected, activated or reset merely by starting this entry.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode || !platformLibreGen1StreamingEnabled) {
    throw UnsupportedError(
      'Libre glucose bench requires Android debug capture.',
    );
  }
  configurePrivateLibreGlucoseDecoder(PrivateLibreGlucoseDecoderProvider());
  await app.main();
}
