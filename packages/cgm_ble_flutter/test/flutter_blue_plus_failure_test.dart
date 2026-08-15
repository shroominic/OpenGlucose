import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/src/flutter_blue_plus_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android connection sequencing', () {
    test('awaits scan shutdown before the initial connect and retry', () async {
      final events = <String>[];
      final firstScanStopped = Completer<void>();
      final retryScanStopped = Completer<void>();
      var stopCalls = 0;
      var connectCalls = 0;

      final result = connectWithScanStoppedRetry<String>(
        stopScan: () {
          stopCalls += 1;
          events.add('stop-scan-$stopCalls');
          return stopCalls == 1
              ? firstScanStopped.future
              : retryScanStopped.future;
        },
        connect: () async {
          connectCalls += 1;
          events.add('connect-$connectCalls');
          if (connectCalls == 1) {
            throw StateError('retryable connect failure');
          }
          return 'connected';
        },
        shouldRetry: (error) => error is StateError,
        waitBeforeRetry: () async {
          events.add('retry-delay');
        },
      );

      expect(events, <String>['stop-scan-1']);
      expect(connectCalls, 0);

      firstScanStopped.complete();
      await Future<void>.delayed(Duration.zero);

      expect(events, <String>[
        'stop-scan-1',
        'connect-1',
        'retry-delay',
        'stop-scan-2',
      ]);
      expect(connectCalls, 1);

      retryScanStopped.complete();

      await expectLater(result, completion('connected'));
      expect(events, <String>[
        'stop-scan-1',
        'connect-1',
        'retry-delay',
        'stop-scan-2',
        'connect-2',
      ]);
    });
  });

  test('discovery disables the Service Changed subscription', () async {
    bool? subscribeToServicesChanged;

    final services = await discoverServicesWithoutServiceChanged<List<String>>((
      subscribe,
    ) async {
      subscribeToServicesChanged = subscribe;
      return <String>['service'];
    });

    expect(subscribeToServicesChanged, isFalse);
    expect(services, <String>['service']);
  });

  group('Android bond reconciliation', () {
    test(
      'accepts an OS bond persisted across a createBond disconnect',
      () async {
        final disconnect = fbp.FlutterBluePlusException(
          fbp.ErrorPlatform.fbp,
          'createBond',
          fbp.FbpErrorCode.deviceIsDisconnected.index,
          'Device is disconnected',
        );
        var createBondCalls = 0;

        await ensureAndroidBond(
          currentState: () async => BleBondState.unbonded,
          bondStates: Stream<AndroidBondStateObservation>.fromIterable(
            const <AndroidBondStateObservation>[
              (state: BleBondState.unbonded, previousState: null),
              (state: BleBondState.bonded, previousState: BleBondState.bonding),
            ],
          ),
          createBond: () async {
            createBondCalls += 1;
            throw disconnect;
          },
          reconciliationTimeout: const Duration(milliseconds: 50),
        );

        expect(createBondCalls, 1);
      },
    );

    test('ignores stale none then preserves a real bond rejection', () async {
      final disconnect = fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.fbp,
        'createBond',
        fbp.FbpErrorCode.deviceIsDisconnected.index,
        'Device is disconnected',
      );

      await expectLater(
        ensureAndroidBond(
          currentState: () async => BleBondState.unbonded,
          bondStates: Stream<AndroidBondStateObservation>.fromIterable(const <
            AndroidBondStateObservation
          >[
            (state: BleBondState.unbonded, previousState: null),
            (state: BleBondState.unbonded, previousState: BleBondState.bonding),
          ]),
          createBond: () async => throw disconnect,
          reconciliationTimeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<BleFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                BleFailureKind.bondRejected,
              )
              .having(
                (failure) => failure.diagnosticCode,
                'diagnosticCode',
                'fbp.bond.not-completed',
              ),
        ),
      );
    });

    test('bounds reconciliation and reports a bond timeout', () async {
      final disconnect = fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.fbp,
        'createBond',
        fbp.FbpErrorCode.deviceIsDisconnected.index,
        'Device is disconnected',
      );
      final observations = StreamController<AndroidBondStateObservation>();

      await expectLater(
        ensureAndroidBond(
          currentState: () async => BleBondState.unbonded,
          bondStates: observations.stream,
          createBond: () async => throw disconnect,
          reconciliationTimeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<BleFailure>().having(
            (failure) => failure.kind,
            'kind',
            BleFailureKind.bondTimedOut,
          ),
        ),
      );
      await observations.close();
    });

    test(
      'does not reconcile rejection, timeout, or unrelated failures',
      () async {
        final failures = <fbp.FlutterBluePlusException>[
          fbp.FlutterBluePlusException(
            fbp.ErrorPlatform.fbp,
            'createBond',
            fbp.FbpErrorCode.userRejected.index,
            'User rejected pairing',
          ),
          fbp.FlutterBluePlusException(
            fbp.ErrorPlatform.fbp,
            'createBond',
            fbp.FbpErrorCode.timeout.index,
            'Timed out after 90s',
          ),
          fbp.FlutterBluePlusException(
            fbp.ErrorPlatform.android,
            'createBond',
            133,
            'ANDROID_SPECIFIC_ERROR',
          ),
        ];

        for (final failure in failures) {
          await expectLater(
            ensureAndroidBond(
              currentState: () async => BleBondState.unbonded,
              bondStates: const Stream<AndroidBondStateObservation>.empty(),
              createBond: () async => throw failure,
              reconciliationTimeout: const Duration(milliseconds: 10),
            ),
            throwsA(same(failure)),
          );
        }
      },
    );
  });

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
