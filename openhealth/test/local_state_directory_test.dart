import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/local_state_directory.dart';

void main() {
  test('Windows restricted state selects non-roaming LocalAppData', () async {
    var localCalls = 0;
    var supportCalls = 0;

    final result = await resolveLocalStateBaseDirectory(
      isWindows: true,
      localAppDataProvider: () async {
        localCalls += 1;
        return Directory(r'C:\Users\tester\AppData\Local\OpenGlucose');
      },
      applicationSupportProvider: () async {
        supportCalls += 1;
        return Directory(r'C:\Users\tester\AppData\Roaming\OpenGlucose');
      },
    );

    expect(result.path, contains(r'AppData\Local'));
    expect(localCalls, 1);
    expect(supportCalls, 0);
  });

  test('mobile restricted state keeps application-support behavior', () async {
    var localCalls = 0;
    var supportCalls = 0;

    final result = await resolveLocalStateBaseDirectory(
      isWindows: false,
      localAppDataProvider: () async {
        localCalls += 1;
        return Directory('/local');
      },
      applicationSupportProvider: () async {
        supportCalls += 1;
        return Directory('/support');
      },
    );

    expect(result.path, '/support');
    expect(localCalls, 0);
    expect(supportCalls, 1);
  });
}
