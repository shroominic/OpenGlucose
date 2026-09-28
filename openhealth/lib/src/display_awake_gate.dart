import 'package:flutter/services.dart';

/// Keep the display interactive for the window a discovery scan needs it.
///
/// Android does not run an *unfiltered* (opportunistic) BLE scan while the
/// display is off: `ScanManager` refuses it with "Cannot start unfiltered scan
/// in screen-off. This scan will be resumed later". The sensor this app pairs
/// with does not always advertise the service UUID Android has to filter on, so
/// the unfiltered pass is the one discovery depends on - which means a sleeping
/// phone reports "no sensor nearby" for a sensor sitting right there.
///
/// The platform's rule is about the display, so the fix is to keep the display
/// interactive for the scan window rather than to retry harder. The same
/// channel answers whether the display is interactive, so a scan that could not
/// run is reported as such instead of as an absent sensor.
abstract interface class DisplayAwakeGate {
  /// Hold the display interactive until [release] is called.
  Future<void> hold();

  /// Release a hold taken by [hold]. Safe to call without a matching hold.
  Future<void> release();

  /// Whether the platform would run an unfiltered scan right now.
  ///
  /// Platforms with no implementation answer `true`: this app never claims a
  /// scan was declined when it cannot tell.
  Future<bool> isInteractive();
}

/// The gate used where no platform bridge exists, and in tests.
///
/// It never holds anything and always reports an interactive display, so a
/// build without the bridge keeps pairing exactly as it did before: it can
/// never invent a declined scan.
final class NoopDisplayAwakeGate implements DisplayAwakeGate {
  const NoopDisplayAwakeGate();

  @override
  Future<void> hold() async {}

  @override
  Future<void> release() async {}

  @override
  Future<bool> isInteractive() async => true;
}

/// The device implementation, backed by the app's own Android channel.
///
/// Every failure resolves to the safe value instead of escaping: a missing
/// bridge must never break a scan or invent a declined one.
final class PlatformDisplayAwakeGate implements DisplayAwakeGate {
  const PlatformDisplayAwakeGate();

  static const String _channelName = 'com.aidex.cgm/display';

  @override
  Future<void> hold() => _invoke('hold');

  @override
  Future<void> release() => _invoke('release');

  @override
  Future<bool> isInteractive() async {
    try {
      final interactive = await MethodChannel(
        _channelName,
      ).invokeMethod<bool>('isInteractive');
      return interactive ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  Future<void> _invoke(String method) async {
    try {
      await MethodChannel(_channelName).invokeMethod<void>(method);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
