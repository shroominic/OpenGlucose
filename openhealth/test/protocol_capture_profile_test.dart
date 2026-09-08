import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/debug_shared_scan_transport.dart';
import 'package:openglucose/src/driver_factory_io.dart';
import 'package:openglucose/src/protocol_capture_profile.dart';

void main() {
  test('profile selector defaults to the existing Libre profile', () {
    expect(kOgProtocolCaptureProfile, 'libre');
    expect(
      selectedProtocolCaptureProfile(),
      ProtocolCaptureProfile.libre,
    );
    expect(
      ProtocolCaptureProfile.libre.physicalServiceUuids,
      const <String>['0000fde3-0000-1000-8000-00805f9b34fb'],
    );
    expect(ProtocolCaptureProfile.libre.usesUnfilteredScan, isFalse);
  });

  test('unknown profile fails closed', () {
    expect(
      () => ProtocolCaptureProfile.parse('unknown'),
      throwsUnsupportedError,
    );
  });

  test('Yuwell profile is passive and explicitly unfiltered', () {
    final profile = ProtocolCaptureProfile.parse('yuwell_anytime_passive');
    expect(profile, ProtocolCaptureProfile.yuwellAnytimePassive);
    expect(profile.usesUnfilteredScan, isTrue);
    expect(profile.physicalServiceUuids, isEmpty);
  });

  test('full UI adds only canonical AiDEX service to Libre capture', () {
    expect(
      protocolCapturePhysicalServices(
        ProtocolCaptureProfile.libre,
        includeLiveAidex: false,
      ),
      const <String>['0000fde3-0000-1000-8000-00805f9b34fb'],
    );
    expect(
      protocolCapturePhysicalServices(
        ProtocolCaptureProfile.libre,
        includeLiveAidex: true,
      ),
      const <String>[
        '0000fde3-0000-1000-8000-00805f9b34fb',
        '0000181f-0000-1000-8000-00805f9b34fb',
      ],
    );
  });

  test('live AiDEX cannot make an unfiltered profile filtered', () {
    expect(
      protocolCapturePhysicalServices(
        ProtocolCaptureProfile.yuwellAnytimePassive,
        includeLiveAidex: false,
      ),
      isEmpty,
    );
    expect(
      protocolCapturePhysicalServices(
        ProtocolCaptureProfile.yuwellAnytimePassive,
        includeLiveAidex: true,
      ),
      isEmpty,
    );
  });

  test('unfiltered physical scan passes null to the BLE delegate', () async {
    final delegate = _ProfileFakeTransport();
    final scanner = DebugSharedScanTransport(
      delegate: delegate,
      physicalServiceUuids: const <String>[],
      unfilteredPhysicalScan: true,
      physicalScanStates: delegate.scanStates,
      physicalScanIsActive: () => delegate.active,
      physicalScanStartAcknowledgements: delegate.acknowledgements,
      physicalScanAttempt: () => delegate.latestAttempt,
    );

    await scanner.start();
    await pumpEventQueue();

    expect(scanner.state, DebugSharedScanState.running);
    expect(delegate.requestedServices, <List<String>?>[null]);
    await scanner.stop();
  });

  test('scan mode and service list cannot conflict', () {
    final delegate = _ProfileFakeTransport();

    expect(
      () => DebugSharedScanTransport(
        delegate: delegate,
        physicalServiceUuids: const <String>[],
        physicalScanStates: delegate.scanStates,
        physicalScanIsActive: () => delegate.active,
        physicalScanStartAcknowledgements: delegate.acknowledgements,
        physicalScanAttempt: () => delegate.latestAttempt,
      ),
      throwsArgumentError,
    );
    expect(
      () => DebugSharedScanTransport(
        delegate: delegate,
        physicalServiceUuids: const <String>['181f'],
        unfilteredPhysicalScan: true,
        physicalScanStates: delegate.scanStates,
        physicalScanIsActive: () => delegate.active,
        physicalScanStartAcknowledgements: delegate.acknowledgements,
        physicalScanAttempt: () => delegate.latestAttempt,
      ),
      throwsArgumentError,
    );
  });
}

final class _ProfileFakeTransport implements BleTransport {
  final StreamController<bool> _states = StreamController<bool>.broadcast(
    sync: true,
  );
  final StreamController<int> _acknowledgements =
      StreamController<int>.broadcast(sync: true);
  final List<List<String>?> requestedServices = <List<String>?>[];
  int latestAttempt = 0;
  bool active = false;

  Stream<bool> get scanStates => _states.stream;
  Stream<int> get acknowledgements => _acknowledgements.stream;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    requestedServices.add(withServices);
    latestAttempt += 1;
    scheduleMicrotask(() {
      active = true;
      _states.add(true);
      _acknowledgements.add(latestAttempt);
    });
    final controller = StreamController<BleScanResult>();
    controller.onCancel = () {
      active = false;
      _states.add(false);
    };
    return controller.stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => Future<BleConnection>.error(
    UnsupportedError('The profile test transport does not connect.'),
  );
}
