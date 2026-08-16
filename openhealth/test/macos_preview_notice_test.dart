import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/macos_preview_notice.dart';

void main() {
  test('notice is limited to native macOS', () {
    expect(
      shouldShowMacosPreviewNotice(
        platform: TargetPlatform.macOS,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      shouldShowMacosPreviewNotice(
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      shouldDisableMacosSecureStorage(
        platform: TargetPlatform.macOS,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      shouldDisableMacosSecureStorage(
        platform: TargetPlatform.iOS,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      shouldShowMacosPreviewNotice(
        platform: TargetPlatform.macOS,
        isWeb: true,
      ),
      isFalse,
    );
  });

  testWidgets('notice discloses unverified BLE and transfer limits', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MacosPreviewNotice())),
    );

    expect(find.text('macOS transport preview'), findsOneWidget);
    expect(find.textContaining('not verified on Mac hardware'), findsOneWidget);
    expect(
      find.textContaining('cannot remove a system Bluetooth bond'),
      findsOneWidget,
    );
    expect(find.textContaining('Move sensor action'), findsOneWidget);
  });

  testWidgets('unavailable AI pane does not request an API key', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MacosPreviewUnavailableAiPane()),
      ),
    );

    expect(find.text('AI unavailable in macOS preview'), findsOneWidget);
    expect(find.textContaining('Cloud AI remains disabled'), findsOneWidget);
    expect(find.textContaining('Do not paste a key'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
