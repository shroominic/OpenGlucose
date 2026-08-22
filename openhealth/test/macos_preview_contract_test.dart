import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('macOS release target is sandboxed and preview-scoped', () {
    final info = _read('macos/Runner/Info.plist');
    final podfile = _read('macos/Podfile');
    final appInfo = _read('macos/Runner/Configs/AppInfo.xcconfig');
    final releaseConfig = _read('macos/Runner/Configs/Release.xcconfig');
    final releaseEntitlements = _read(
      'macos/Runner/Release.entitlements',
    );

    expect(info, contains('NSBluetoothAlwaysUsageDescription'));
    expect(podfile, contains("platform :osx, '11.0'"));
    expect(
      appInfo,
      contains('PRODUCT_BUNDLE_IDENTIFIER = com.openglucose.app.macos.preview'),
    );
    expect(appInfo, contains('PRODUCT_NAME = OpenGlucose Preview'));
    expect(releaseConfig, contains('CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO'));
    expect(releaseConfig, contains('ARCHS = arm64'));
    expect(releaseEntitlements, contains('com.apple.security.app-sandbox'));
    expect(
      releaseEntitlements,
      contains('com.apple.security.device.bluetooth'),
    );
    expect(
      releaseEntitlements,
      isNot(contains('com.apple.security.network.client')),
    );
    expect(releaseEntitlements, isNot(contains('keychain-access-groups')));
    expect(
      releaseEntitlements,
      isNot(contains('com.apple.security.get-task-allow')),
    );
  });

  test('macOS transport cannot expose confirmed sensor transfer', () {
    final transport = _read(
      '../packages/cgm_ble_flutter/lib/src/flutter_blue_plus_transport.dart',
    );
    final app = _read('lib/main.dart');
    final documentation = _read('../docs/macos-preview.md');

    expect(
      transport,
      contains(
        'bool get supportsBondLifecycle => !kIsWeb && Platform.isAndroid',
      ),
    );
    expect(
      app,
      contains('defaultTargetPlatform == TargetPlatform.android'),
    );
    expect(documentation, contains('does not expose bond state'));
    expect(documentation, contains('hides **Move sensor** on macOS'));
    expect(
      documentation,
      contains('No redacted physical Mac/AiDEX evidence'),
    );
  });

  test('macOS preview does not expose API-key storage', () {
    final app = _read('lib/main.dart');
    final documentation = _read('../docs/macos-preview.md');

    expect(app, contains('macosSecureStorageDisabled'));
    expect(app, contains('MacosPreviewUnavailableAiPane'));
    expect(documentation, contains('Do not paste an API key'));
  });
}
