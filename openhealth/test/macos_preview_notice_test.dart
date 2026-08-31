import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
import 'package:openglucose/src/macos_preview_notice.dart';

Widget _localizedApp(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

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
      shouldShowMacosPreviewNotice(platform: TargetPlatform.macOS, isWeb: true),
      isFalse,
    );
  });

  testWidgets('notice discloses unverified BLE and transfer limits', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localizedApp(const Scaffold(body: MacosPreviewNotice())),
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
      _localizedApp(const Scaffold(body: MacosPreviewUnavailableAiPane())),
    );

    expect(find.text('AI unavailable in macOS preview'), findsOneWidget);
    expect(find.textContaining('Cloud AI remains disabled'), findsOneWidget);
    expect(find.textContaining('Do not paste a key'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('renders macOS safety limits in Simplified Chinese', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localizedApp(
        const Scaffold(body: MacosPreviewNotice()),
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('macOS 传输预览'), findsOneWidget);
    expect(find.textContaining('尚未在 Mac 硬件上验证'), findsOneWidget);
    expect(find.textContaining('无法移除系统蓝牙绑定'), findsOneWidget);
  });
}
