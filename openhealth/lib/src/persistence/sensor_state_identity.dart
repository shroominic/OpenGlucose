import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';

String encodedSensorStateIdentity(DiscoveredSensor sensor) => base64Url
    .encode(
      utf8.encode(jsonEncode(<String>[sensor.driverId, sensor.storageKey])),
    )
    .replaceAll('=', '');
