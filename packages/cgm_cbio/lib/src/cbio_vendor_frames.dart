/// Masked vendor V120 frames for the authenticated GS1 link.
///
/// Every frame is built in plaintext with the vendor's zero-sum checksum and
/// then masked with [cbioVendorStreamKey]. These are the exact shapes the
/// SiSensing application sends; the plaintext builders in `cbio_queries.dart`
/// describe the same layouts and are useful for reading and testing, but the
/// sensor only accepts the masked forms.
///
/// Allowed frames here are the authorised link setup and read commands: device
/// information, authentication, the vendor clock frame, glucose reads, and raw
/// history reads. Activation, reset, threshold, and key-registration frames are
/// deliberately absent.
library;

import 'cbio_crypto.dart';

/// Masked `03 F0 selector C` device-information read.
List<int> buildMaskedCbioDeviceInformation(int selector) =>
    maskCbioFrame(_informationFrame(selector));

/// Masked `19 01 00 <6 reversed address octets> <16 auth material> C`.
///
/// [reversedAddressOctets] is the sensor Bluetooth address in reverse order,
/// exactly as the vendor's `n1()` builds it.
List<int> buildMaskedCbioAuthentication(
  List<int> reversedAddressOctets, {
  List<int> material = cbioVendorAuthMaterial,
}) {
  if (reversedAddressOctets.length != 6) {
    throw ArgumentError.value(
      reversedAddressOctets,
      'reversedAddressOctets',
      'must be exactly 6 octets',
    );
  }
  if (material.length != 16) {
    throw ArgumentError.value(material, 'material', 'must be exactly 16 bytes');
  }
  final head = <int>[0x19, 0x01, 0x00, ...reversedAddressOctets, ...material];
  return maskCbioFrame([...head, _checksum(head)]);
}

/// Masked `06 03 LE32(epoch) C` vendor clock frame.
///
/// This changes the sensor clock. Callers must log the write and send it only
/// when the record timestamps need it.
List<int> buildMaskedCbioClock(int epochSeconds) {
  if (epochSeconds < 0 || epochSeconds > 0xffffffff) {
    throw ArgumentError.value(epochSeconds, 'epochSeconds', 'must be uint32');
  }
  final head = <int>[
    0x06,
    0x03,
    epochSeconds & 0xff,
    (epochSeconds >> 8) & 0xff,
    (epochSeconds >> 16) & 0xff,
    (epochSeconds >> 24) & 0xff,
  ];
  return maskCbioFrame([...head, _checksum(head)]);
}

/// Masked `06 0A LE16(index) 00 00 C` packed glucose read.
List<int> buildMaskedCbioGlucoseQuery(int index) =>
    maskCbioFrame(_readFrame(0x0a, index));

/// Masked `06 08 LE16(index) 00 00 C` raw history read.
List<int> buildMaskedCbioRawQuery(int index) =>
    maskCbioFrame(_readFrame(0x08, index));

List<int> _informationFrame(int selector) {
  if (selector < 1 || selector > 255) {
    throw ArgumentError.value(selector, 'selector', 'must be 1..255');
  }
  final head = <int>[0x03, 0xf0, selector];
  return [...head, _checksum(head)];
}

List<int> _readFrame(int opcode, int index) {
  if (index < 0 || index > 0xffff) {
    throw ArgumentError.value(index, 'index', 'must fit in 16 bits');
  }
  final head = <int>[
    0x06,
    opcode,
    index & 0xff,
    (index >> 8) & 0xff,
    0x00,
    0x00,
  ];
  return [...head, _checksum(head)];
}

int _checksum(List<int> head) =>
    (-head.fold<int>(0, (sum, byte) => sum + byte)) & 0xff;
