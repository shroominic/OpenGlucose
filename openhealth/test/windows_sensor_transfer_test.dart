import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/windows_sensor_transfer.dart';

void main() {
  test('only real Windows sensor connections require the transfer warning', () {
    for (final platform in TargetPlatform.values) {
      expect(
        requiresWindowsSensorTransferWarning(
          platform: platform,
          isMockDriver: false,
        ),
        platform == TargetPlatform.windows,
      );
      expect(
        requiresWindowsSensorTransferWarning(
          platform: platform,
          isMockDriver: true,
        ),
        isFalse,
      );
    }
  });

  test('confirmed transfer action is available only on verified adapters', () {
    for (final platform in TargetPlatform.values) {
      expect(
        supportsConfirmedSensorTransfer(platform),
        platform == TargetPlatform.android ||
            platform == TargetPlatform.windows,
      );
    }
    expect(
      confirmedSensorTransferLabel(TargetPlatform.android),
      'Move sensor to another phone',
    );
    expect(
      confirmedSensorTransferLabel(TargetPlatform.windows),
      'Move sensor to another device',
    );
  });

  testWidgets('transfer warning states the single-bond and no-reset rules', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WindowsSensorTransferDialog())),
    );

    expect(find.text('Move sensor to this computer?'), findsOneWidget);
    expect(find.textContaining('one Bluetooth bond'), findsOneWidget);
    expect(
      find.textContaining('ordinary Disconnect does not move'),
      findsOneWidget,
    );
    expect(find.textContaining('does not reset or restart'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('confirmWindowsSensorTransfer')),
      findsOneWidget,
    );
  });

  testWidgets('transfer confirmation returns the explicit user choice', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await confirmWindowsSensorTransfer(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('confirmWindowsSensorTransfer')),
    );
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
