// SPDX-License-Identifier: MIT
// Combined debug executable includes GPL code; see ADR 0004 and package notices.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'main.dart' as app;
import 'src/driver_factory_io.dart';
import 'src/libre_gen1_glucose_adapter.dart';
import 'src/libre_gen1_receiver_store.dart';

/// Normal OpenGlucose UI with an explicitly selected private bench decoder.
/// Normal app restoration can reconnect a saved receiver. Launch does not
/// authorize NFC activation, streaming enablement, or sensor reset.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode) {
    throw UnsupportedError(
      'Private Libre glucose requires an Android debug build.',
    );
  }
  if (kOgProtocolTrace) {
    configurePrivateLibreGlucoseDecoder(PrivateLibreGlucoseDecoderProvider());
  } else {
    configurePrivateRecorderFreeLibreGlucoseDecoder(
      PrivateLibreGlucoseDecoderProvider(
        readEvidence: LibreGen1ReceiverStore().readCalibrationEvidence,
      ),
    );
  }
  await app.main();
}
