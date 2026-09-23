import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:test/test.dart';

void main() {
  group('CT5 constants', () {
    test('keep the audited GATT roles distinct', () {
      expect(yuwellCt5ServiceUuid, '00001000-1212-efde-1523-785feabcd123');
      expect(
        yuwellCt5NotifyCharacteristicUuid,
        '00001001-1212-efde-1523-785feabcd123',
      );
      expect(
        yuwellCt5WriteCharacteristicUuid,
        '00001002-1212-efde-1523-785feabcd123',
      );
      expect(<String>{
        yuwellCt5ServiceUuid,
        yuwellCt5NotifyCharacteristicUuid,
        yuwellCt5WriteCharacteristicUuid,
      }, hasLength(3));
    });

    test('exposes 5P lifecycle values as model metadata', () {
      expect(YuwellAnytime5PMetadata.warmup, const Duration(minutes: 45));
      expect(YuwellAnytime5PMetadata.wearPeriod, const Duration(days: 16));
      expect(
        YuwellAnytime5PMetadata.sampleInterval,
        const Duration(minutes: 3),
      );
      expect(YuwellAnytime5PMetadata.expectedWearSamples, 7680);
      expect(YuwellAnytime5PMetadata.warmupSlots, 15);
      expect(YuwellAnytime5PMetadata.totalSlots, 7695);
      expect(
        YuwellAnytime5PMetadata.totalSessionDuration,
        const Duration(days: 16, minutes: 45),
      );
    });
  });

  group('device-name classifier', () {
    test('accepts only exact Anytime plus ten decimal digits', () {
      expect(
        classifyYuwellAnytimeDeviceName('Anytime0123456789'),
        YuwellAnytimeNameKind.anytimeFamily,
      );
    });

    test('maps a candidate without persisting its name suffix or address', () {
      const discovery = YuwellAnytimeDiscovery();
      const scan = BleScanResult(
        deviceId: 'synthetic-address',
        deviceName: 'Anytime0123456789',
        rssi: -50,
      );

      final first = discovery.mapScanResult(scan)!;
      final second = discovery.mapScanResult(scan)!;

      expect(first.displayName, 'Yuwell Anytime 5P');
      expect(first.storageKey, second.storageKey);
      expect(first.storageKey, isNot(contains(scan.deviceId)));
      expect(first.storageKey, isNot(contains('0123456789')));
      expect(
        first.metadata[yuwellValidationStateMetadataKey],
        'target-unverified',
      );
    });

    test('mapper accepts the canonical exact candidate name', () {
      const discovery = YuwellAnytimeDiscovery();

      final candidate = discovery.mapScanResult(
        const BleScanResult(
          deviceId: 'synthetic-address',
          deviceName: 'Anytime0123456789',
          rssi: -50,
        ),
      );

      expect(candidate, isNotNull);
    });

    test('mapper rejects a candidate with leading whitespace', () {
      const discovery = YuwellAnytimeDiscovery();

      final candidate = discovery.mapScanResult(
        const BleScanResult(
          deviceId: 'synthetic-address',
          deviceName: ' Anytime0123456789',
          rssi: -50,
        ),
      );

      expect(candidate, isNull);
    });

    test('mapper rejects a candidate with trailing whitespace', () {
      const discovery = YuwellAnytimeDiscovery();

      final candidate = discovery.mapScanResult(
        const BleScanResult(
          deviceId: 'synthetic-address',
          deviceName: 'Anytime0123456789 ',
          rssi: -50,
        ),
      );

      expect(candidate, isNull);
    });

    test('rejects substring, case, whitespace, and word false positives', () {
      for (final name in <String?>[
        null,
        '',
        'zy_watch',
        ' ZY_WATCH',
        'ZY_WATCHER',
        'ZY_WATCH_A?',
        'Anytime012345678',
        'Anytime01234567890',
        'AnytimeA123456789',
        'Anytime012345678_',
        'NotAnytime5P',
        'Anytime',
        'AnytimeSoon',
        'Anytime 5P',
        'anytime5P',
      ]) {
        expect(
          classifyYuwellAnytimeDeviceName(name),
          YuwellAnytimeNameKind.none,
          reason: 'unexpected match for $name',
        );
      }
    });
  });
}
