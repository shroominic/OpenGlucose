import 'package:flutter/services.dart';

/// Opens the native iOS activity sheet for one prepared export file.
///
/// OpenGlucose owns this narrow bridge because `share_plus` 12.x and 13.3.0
/// configure a popover presentation on iPhones. On iOS 26 that can leave the
/// activity controller stuck and prevent later share sheets from opening.
class IosExportShare {
  const IosExportShare({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  static const channelName = 'com.openglucose.app/export_share';

  final MethodChannel _channel;

  Future<void> shareFile({
    required String filePath,
    required String subject,
    Rect? sharePositionOrigin,
  }) async {
    if (filePath.trim().isEmpty) {
      throw ArgumentError.value(filePath, 'filePath', 'must not be empty');
    }

    final result = await _channel.invokeMethod<String>(
      'shareFile',
      <String, Object>{
        'filePath': filePath,
        'subject': subject,
        if (sharePositionOrigin case final origin?) ...<String, double>{
          'originX': origin.left,
          'originY': origin.top,
          'originWidth': origin.width,
          'originHeight': origin.height,
        },
      },
    );
    if (result == null) {
      throw PlatformException(
        code: 'export_share_failed',
        message: 'The iOS export share request returned no result.',
      );
    }
  }
}
