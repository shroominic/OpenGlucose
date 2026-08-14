import 'package:cgm_ble/cgm_ble.dart';
import 'package:test/test.dart';

void main() {
  test('failure metadata round-trips without native error text', () {
    final failure = BleFailure(
      kind: BleFailureKind.permissionRequired,
      operation: BleOperation.scan,
      diagnosticCode: 'platform.scan.permission-required',
    );

    final restored = BleFailure.fromMetadata(failure.toMetadata());

    expect(restored?.kind, BleFailureKind.permissionRequired);
    expect(restored?.operation, BleOperation.scan);
    expect(restored?.diagnosticCode, 'platform.scan.permission-required');
    expect(restored?.allowsAutomaticRetry, isFalse);
  });

  test('diagnostic codes cannot retain device identifiers', () {
    final failure = BleFailure(
      kind: BleFailureKind.unexpected,
      operation: BleOperation.connect,
      diagnosticCode: 'AA:BB:CC:DD:EE:FF failed',
    );

    expect(failure.diagnosticCode, 'ble.redacted');
    expect(failure.toString(), isNot(contains('AA:BB')));
  });

  test('only transient failures permit automatic retry', () {
    for (final kind in <BleFailureKind>[
      BleFailureKind.deviceDisconnected,
      BleFailureKind.operationTimedOut,
    ]) {
      expect(
        BleFailure(
          kind: kind,
          operation: BleOperation.connect,
          diagnosticCode: 'ble.connect.${kind.name}',
        ).allowsAutomaticRetry,
        isTrue,
      );
    }

    expect(
      BleFailure(
        kind: BleFailureKind.unexpected,
        operation: BleOperation.connect,
        diagnosticCode: 'ble.connect.unexpected',
      ).allowsAutomaticRetry,
      isFalse,
    );
  });
}
