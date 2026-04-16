import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:cgm_core/cgm_core.dart';

CgmDriver buildPlatformDriver() {
  return AidexSensorDriver(const FlutterBluePlusTransport());
}
