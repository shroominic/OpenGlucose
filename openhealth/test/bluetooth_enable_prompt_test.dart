import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/bluetooth_enable_prompt.dart';

void main() {
  const channel = MethodChannel('com.openglucose/bluetooth');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late int requests;
  late int retries;
  late Future<String> Function() response;
  setUp(() {
    requests = 0;
    retries = 0;
    response = () async => 'enabled';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'requestEnable');
      expect(call.arguments, isNull);
      requests++;
      return response();
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BluetoothEnablePrompt(
          onEnabled: () async {
            retries++;
          },
        ),
      ),
    ),
  );

  testWidgets('showing Bluetooth guidance never changes the radio', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Turn on Bluetooth'), findsOneWidget);
    expect(find.text('Error'), findsNothing);
    expect(requests, 0);
    await tester.tap(find.byKey(const ValueKey('enableBluetoothButton')));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(retries, 1);
  });

  for (final result in [
    'cancelled',
    'permissionRequired',
    'unavailable',
    'unexpected',
  ]) {
    testWidgets('$result does not retry a sensor connection', (tester) async {
      response = () async => result;
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('enableBluetoothButton')));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(retries, 0);
      expect(find.text('Error'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pending consent is single-flight and ignores a removed target', (
    tester,
  ) async {
    final gate = Completer<String>();
    response = () => gate.future;
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('enableBluetoothButton')));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
    gate.complete('enabled');
    await tester.pump();
    expect(retries, 0);
  });

  testWidgets('consent waits for foreground before reconnecting once', (
    tester,
  ) async {
    final gate = Completer<String>();
    response = () => gate.future;
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('enableBluetoothButton')));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    gate.complete('enabled');
    await tester.pump();
    expect(retries, 0);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(retries, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(retries, 1);
  });
}
