import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/ios_export_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(IosExportShare.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('passes one prepared file and global origin to native iOS', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return 'dismissed';
        });

    await const IosExportShare(channel: channel).shareFile(
      filePath: '/tmp/openglucose-export-1/glucose.csv',
      subject: 'OpenGlucose sensor export',
      sharePositionOrigin: const Rect.fromLTWH(10, 20, 30, 40),
    );

    expect(receivedCall?.method, 'shareFile');
    expect(receivedCall?.arguments, <String, Object>{
      'filePath': '/tmp/openglucose-export-1/glucose.csv',
      'subject': 'OpenGlucose sensor export',
      'originX': 10.0,
      'originY': 20.0,
      'originWidth': 30.0,
      'originHeight': 40.0,
    });
  });

  test('fails closed when native iOS returns no result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    await expectLater(
      const IosExportShare(channel: channel).shareFile(
        filePath: '/tmp/openglucose-export-1/glucose.csv',
        subject: 'OpenGlucose sensor export',
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'export_share_failed',
        ),
      ),
    );
  });

  test('rejects an empty file path before invoking native iOS', () async {
    var invocationCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          invocationCount += 1;
          return 'dismissed';
        });

    await expectLater(
      const IosExportShare(
        channel: channel,
      ).shareFile(filePath: ' ', subject: 'OpenGlucose sensor export'),
      throwsArgumentError,
    );
    expect(invocationCount, 0);
  });
}
