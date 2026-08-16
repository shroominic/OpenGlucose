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

  test('discovery uses the plugin-owned 30 second timeout', () async {
    bool? subscribeToServicesChanged;
    int? timeoutSeconds;
    final source = Completer<List<String>>();

    const transport = FlutterBluePlusTransport();
    expect(transport.discoveryTimeout, const Duration(seconds: 30));

    final discovery = discoverServicesWithoutServiceChanged<List<String>>((
      subscribe,
      timeout,
    ) {
      subscribeToServicesChanged = subscribe;
      timeoutSeconds = timeout;
      return source.future;
    }, timeout: transport.discoveryTimeout);

    expect(subscribeToServicesChanged, isFalse);
    expect(timeoutSeconds, 30);
    // Returning the plugin Future directly ensures that a shorter Dart
    // Future.timeout cannot complete while FlutterBluePlus still owns its
    // operation mutex.
    expect(identical(discovery, source.future), isTrue);

    source.complete(<String>['service']);
    final services = await discovery;
    expect(services, <String>['service']);
  });

  test('discovery timeout rounds up to whole plugin seconds', () async {
    int? timeoutSeconds;

    await discoverServicesWithoutServiceChanged<void>((
      subscribe,
      timeout,
    ) async {
      timeoutSeconds = timeout;
    }, timeout: const Duration(milliseconds: 12501));

    expect(timeoutSeconds, 13);
  });

  test('notification setup uses the plugin-owned operation timeout', () async {
    int? timeoutSeconds;
    final source = Completer<void>();

    final notification = setNotifyWithPluginTimeout<void>((timeout) {
      timeoutSeconds = timeout;
      return source.future;
    }, timeout: const Duration(milliseconds: 12501));

    expect(timeoutSeconds, 13);
    // An outer Future.timeout would return a different Future and could allow
    // recovery to start while FlutterBluePlus still owns its operation mutex.
    expect(identical(notification, source.future), isTrue);

    source.complete();
    await notification;
  });

  test('write with response uses the plugin-owned operation timeout', () async {
    bool? withoutResponse;
    int? timeoutSeconds;
    final source = Completer<void>();

    final write = writeWithPluginTimeout<void>(
      (writeMode, timeout) {
        withoutResponse = writeMode;
        timeoutSeconds = timeout;
        return source.future;
      },
      withoutResponse: false,
      timeout: const Duration(milliseconds: 12501),
    );

    expect(withoutResponse, isFalse);
    expect(timeoutSeconds, 13);
    // The exact plugin Future owns both the ATT response and timeout. An
    // irreversible control-point write cannot complete after our caller has
    // already started recovery.
    expect(identical(write, source.future), isTrue);

    source.complete();
    await write;
  });

  test('disconnect and remove-bond retain plugin timeout ownership', () async {
    int? disconnectTimeout;
    int? removeBondTimeout;
    final disconnectSource = Completer<void>();
    final removeBondSource = Completer<void>();

    final disconnect = disconnectWithPluginTimeout<void>((timeout) {
      disconnectTimeout = timeout;
      return disconnectSource.future;
    }, timeout: const Duration(milliseconds: 12001));
    final removeBond = removeBondWithPluginTimeout<void>((timeout) {
      removeBondTimeout = timeout;
      return removeBondSource.future;
    }, timeout: const Duration(milliseconds: 12001));

    expect(disconnectTimeout, 13);
    expect(removeBondTimeout, 13);
    expect(identical(disconnect, disconnectSource.future), isTrue);
    expect(identical(removeBond, removeBondSource.future), isTrue);

    disconnectSource.complete();
    removeBondSource.complete();
    await Future.wait(<Future<void>>[disconnect, removeBond]);
  });

  test('plugin discovery timeout remains a retryable BLE timeout', () {
    final failure = classifyFlutterBluePlusFailure(
      fbp.FlutterBluePlusException(
        fbp.ErrorPlatform.fbp,
        'discoverServices',
        fbp.FbpErrorCode.timeout.index,
        'Timed out after 30s',
      ),
      operation: BleOperation.discoverServices,
    );

    expect(failure.kind, BleFailureKind.operationTimedOut);
    expect(failure.operation, BleOperation.discoverServices);
    expect(failure.allowsAutomaticRetry, isTrue);
    expect(
      failure.diagnosticCode,
      'fbp.fbp.discover-services.1.operationtimedout',
    );
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
        final observations =
            StreamController<AndroidBondStateObservation>.broadcast(sync: true);

        await ensureAndroidBond(
          currentState: () async => BleBondState.unbonded,
          bondStates: observations.stream,
          createBond: () async {
            createBondCalls += 1;
            observations.add((
              state: BleBondState.bonding,
              previousState: BleBondState.unbonded,
            ));
            observations.add((
              state: BleBondState.bonded,
              previousState: BleBondState.bonding,
            ));
            throw disconnect;
          },
          reconciliationTimeout: const Duration(milliseconds: 50),
        );

        expect(createBondCalls, 1);
        expect(observations.hasListener, isFalse);
        await observations.close();
      },
    );

    test(
      'buffers immediate BONDING to NONE before createBond code 6',
      () async {
        final disconnect = fbp.FlutterBluePlusException(
          fbp.ErrorPlatform.fbp,
          'createBond',
          fbp.FbpErrorCode.deviceIsDisconnected.index,
          'Device is disconnected',
        );
        final observations =
            StreamController<AndroidBondStateObservation>.broadcast(sync: true);

        await expectLater(
          ensureAndroidBond(
            currentState: () async => BleBondState.unbonded,
            bondStates: observations.stream,
            createBond: () async {
              observations.add((
                state: BleBondState.bonding,
                previousState: BleBondState.unbonded,
              ));
              observations.add((
                state: BleBondState.unbonded,
                previousState: BleBondState.bonding,
              ));
              throw disconnect;
            },
            reconciliationTimeout: const Duration(seconds: 1),
          ).timeout(const Duration(milliseconds: 50)),
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

        expect(observations.hasListener, isFalse);
        await observations.close();
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

  group('Windows bond verification', () {
    test('keeps an existing bond without opening a pairing prompt', () async {
      var createBondCalls = 0;

      await ensureWindowsBond(
        currentState: () async => BleBondState.bonded,
        createBond: () async {
          createBondCalls += 1;
          return true;
        },
      );

      expect(createBondCalls, 0);
    });

    test('creates and verifies a missing Windows bond', () async {
      var state = BleBondState.unbonded;
      var createBondCalls = 0;

      await ensureWindowsBond(
        currentState: () async => state,
        createBond: () async {
          createBondCalls += 1;
          state = BleBondState.bonded;
          return true;
        },
      );

      expect(createBondCalls, 1);
      expect(state, BleBondState.bonded);
    });

    test('trusts the verified postcondition if the native result races', () {
      var stateReads = 0;

      return ensureWindowsBond(
        currentState: () async {
          stateReads += 1;
          return stateReads == 1 ? BleBondState.unbonded : BleBondState.bonded;
        },
        createBond: () async => false,
      );
    });

    test('reports rejection without exposing a device identifier', () async {
      const privateAddress = 'AA:BB:CC:DD:EE:FF';

      await expectLater(
        ensureWindowsBond(
          currentState: () async => BleBondState.unbonded,
          createBond: () async => false,
        ),
        throwsA(
          isA<BleFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                BleFailureKind.bondRejected,
              )
              .having(
                (failure) => failure.operation,
                'operation',
                BleOperation.bond,
              )
              .having(
                (failure) => failure.toString(),
                'safe string',
                isNot(contains(privateAddress)),
              ),
        ),
      );
    });

    test('removes a bond only after its final state is verified', () async {
      var state = BleBondState.bonded;

      await removeWindowsBond(
        removeBond: () async {
          state = BleBondState.unbonded;
          return true;
        },
        currentState: () async => state,
      );

      expect(state, BleBondState.unbonded);
    });

    test('fails closed when Windows still reports a bond', () async {
      await expectLater(
        removeWindowsBond(
          removeBond: () async => false,
          currentState: () async => BleBondState.bonded,
        ),
        throwsA(
          isA<BleFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                BleFailureKind.unexpected,
              )
              .having(
                (failure) => failure.operation,
                'operation',
                BleOperation.removeBond,
              ),
        ),
      );
    });
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
