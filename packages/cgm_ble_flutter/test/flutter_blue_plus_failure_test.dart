import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/src/flutter_blue_plus_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies denied Android scan permissions', () {
    final failure = classifyFlutterBluePlusFailure(
      PlatformException(
        code: 'startScan',
        message:
            'Permission android.permission.BLUETOOTH_SCAN required to scan',
      ),
      operation: BleOperation.scan,
    );

    expect(failure.kind, BleFailureKind.permissionRequired);
    expect(failure.operation, BleOperation.scan);
    expect(failure.allowsAutomaticRetry, isFalse);
  });

  test('classifies Bluetooth powered off', () {
    final failure = classifyFlutterBluePlusFailure(
      fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.fbp,
        'connect',
        fbp.FbpErrorCode.adapterIsOff.index,
        'Bluetooth adapter is off',
      ),
      operation: BleOperation.connect,
    );

    expect(failure.kind, BleFailureKind.bluetoothOff);
  });

  test('classifies bond timeout separately from rejection', () {
    final timeout = classifyFlutterBluePlusFailure(
      fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.fbp,
        'createBond',
        fbp.FbpErrorCode.timeout.index,
        'Timed out after 90s',
      ),
      operation: BleOperation.bond,
    );
    final rejected = classifyFlutterBluePlusFailure(
      fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.fbp,
        'createBond',
        fbp.FbpErrorCode.createBondFailed.index,
        'Failed to create bond. bond-none',
      ),
      operation: BleOperation.bond,
    );

    expect(timeout.kind, BleFailureKind.bondTimedOut);
    expect(rejected.kind, BleFailureKind.bondRejected);
    expect(timeout.allowsAutomaticRetry, isFalse);
    expect(rejected.allowsAutomaticRetry, isFalse);
  });

  test('classifies bond start failure as possible sensor contention', () {
    final failure = classifyFlutterBluePlusFailure(
      PlatformException(
        code: 'createBond',
        message: 'device.createBond() returned false',
      ),
      operation: BleOperation.bond,
    );

    expect(failure.kind, BleFailureKind.sensorPossiblyInUse);
    expect(failure.allowsAutomaticRetry, isFalse);
  });

  test(
    'protected subscribe authentication errors require pairing recovery',
    () {
      for (final testCase in <({int code, String description})>[
        (code: 5, description: 'GATT_INSUFFICIENT_AUTHENTICATION'),
        (code: 15, description: 'GATT_INSUFFICIENT_ENCRYPTION'),
      ]) {
        final failure = classifyFlutterBluePlusFailure(
          fbp.FlutterBluePlusException(
            fbp.ErrorPlatform.android,
            'setNotifyValue',
            testCase.code,
            testCase.description,
          ),
          operation: BleOperation.subscribe,
        );

        expect(failure.kind, BleFailureKind.bondRejected);
        expect(failure.operation, BleOperation.subscribe);
        expect(failure.allowsAutomaticRetry, isFalse);
      }
    },
  );

  test('classifies repeated Android GATT 133 without exposing native text', () {
    const privateAddress = 'AA:BB:CC:DD:EE:FF';
    final failure = classifyFlutterBluePlusFailure(
      fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.android,
        'connect',
        133,
        'ANDROID_SPECIFIC_ERROR for $privateAddress GATT_ERROR (133)',
      ),
      operation: BleOperation.connect,
    );

    expect(failure.kind, BleFailureKind.sensorPossiblyInUse);
    expect(failure.diagnosticCode, isNot(contains(privateAddress)));
    expect(failure.toString(), isNot(contains(privateAddress)));
  });
}
