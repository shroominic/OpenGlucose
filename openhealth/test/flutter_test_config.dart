import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Makes existing English assertions deterministic.
///
/// Production resolves the device language at runtime. Tests that exercise
/// automatic Chinese selection pass an explicit Chinese locale to the
/// language controller, while the general suite remains independent of the
/// host computer's current locale.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.localesTestValue = const <Locale>[Locale('en')];
  await testMain();
}
