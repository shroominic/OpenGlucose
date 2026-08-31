import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/archived_sensor_export_diagnostics.dart';

void main() {
  test('support code keeps the failing stage and omits private messages', () {
    const privatePath = '/private/cache/openglucose-export-1/glucose.csv';
    final code = archivedSensorExportSupportCode(
      stage: ArchivedSensorExportStage.sharing,
      error: PlatformException(
        code: 'export_share_failed',
        message: 'Could not share $privatePath',
        details: <String, Object>{'filePath': privatePath},
      ),
    );

    expect(
      code,
      'OGEXP1 phase=P03 op=export kind=platform '
      'code=export_share_failed',
    );
    expect(code, isNot(contains('private')));
    expect(code, isNot(contains('glucose.csv')));
  });

  test('support code normalizes untrusted platform codes', () {
    final code = archivedSensorExportSupportCode(
      stage: ArchivedSensorExportStage.storing,
      error: PlatformException(
        code: '../../CACHE/SENSOR 42/WRITE FAILED',
      ),
    );

    expect(code, contains('phase=P02'));
    expect(code, contains('code=unexpected'));
    expect(code, isNot(contains('sensor-42')));
    expect(code, isNot(contains('/')));
  });
}
