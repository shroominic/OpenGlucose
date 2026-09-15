import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';

/// Read-only compatibility catalog for existing saved selections and archives.
///
/// A registered provider takes precedence. These declarations do not register
/// a live driver, enable NFC, import a decoder, or authorize a connection.
CgmSensorDataProfile builtInSensorDataProfileFor(String driverId) =>
    switch (driverId) {
      'aidex' => AidexSensorDriver.dataProfile,
      'libre2-gen1' => LibreGen1Driver.dataProfile,
      'yuwell-anytime' => YuwellAnytimeDriver.dataProfile,
      _ => CgmSensorDataProfile.legacy,
    };
