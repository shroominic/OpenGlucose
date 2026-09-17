/// Vendor V120 stream masking for the GS1 sensor link.
///
/// Both directions of the vendor protocol are RC4-masked with one 16-byte
/// application constant at stream offset zero. The key is not derived from the
/// sensor address, the serial, the account, or the session, and it does not
/// roll: every frame restarts the keystream.
///
/// Provenance of [cbioVendorStreamKey]: extracted from virtual and file offset
/// `0x11164` (`.rodata + 0xe4`) of the hash-verified
/// `libdata-handle-lib.so` shipped in the SiSensing GS1 application
/// (`01.20.01.00`, SHA-256 `761f0aab72b35010839e90620c348ee71b888b25682252360a7af16f150bd1d7`).
/// It is loaded directly by the frame builders and by `register_key`, and it
/// was cross-checked against an independent open-source client of the same
/// protocol. See `docs/testing/cbio-gs1-auth-material.md` for the derivation;
/// the derivation record deliberately does not restate the bytes.
///
/// Provenance of [cbioVendorAuthMaterial]: the 16 clear bytes the vendor's
/// `register_key` copies into its `.bss` block at `0x18170`, which the
/// authentication builder then reads back into frame offsets 9..24. The value
/// is the package-bound EU credential; the same constant appears in the
/// independent open-source client. It is a link credential, not an encryption
/// key, and it is not a sensor secret.
library;

/// The 16-byte per-frame stream key. Never log or transmit this value.
const List<int> cbioVendorStreamKey = <int>[
  0x01,
  0x38,
  0x0b,
  0x9a,
  0x00,
  0x5b,
  0x02,
  0x5d,
  0xcd,
  0x9e,
  0xc3,
  0x99,
  0x09,
  0x37,
  0xaa,
  0xe8,
];

/// The 16-byte EU link credential carried inside the authentication frame.
const List<int> cbioVendorAuthMaterial = <int>[
  0x54,
  0x48,
  0x45,
  0x35,
  0x34,
  0x34,
  0x55,
  0x30,
  0x54,
  0x59,
  0x49,
  0x54,
  0x45,
  0x34,
  0x36,
  0x31,
];

/// The five bytes the sensor sends when it wants authentication.
///
/// `23 F7 6F D9 F4` unmasks to the valid control frame `04 00 00 00 FC`, an
/// acknowledgement with opcode, result, and raw status all zero.
const List<int> cbioAuthenticationTrigger = <int>[0x23, 0xf7, 0x6f, 0xd9, 0xf4];

/// RC4 keystream bytes for [length] bytes from offset zero.
List<int> cbioRc4Keystream(int length, {List<int> key = cbioVendorStreamKey}) {
  if (length < 0) {
    throw ArgumentError.value(length, 'length', 'must not be negative');
  }
  if (key.isEmpty || key.length > 256) {
    throw ArgumentError.value(key, 'key', 'must be 1..256 bytes');
  }
  final state = List<int>.generate(256, (index) => index);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + state[i] + key[i % key.length]) & 0xff;
    final swap = state[i];
    state[i] = state[j];
    state[j] = swap;
  }
  final keystream = <int>[];
  var i = 0;
  j = 0;
  for (var n = 0; n < length; n++) {
    i = (i + 1) & 0xff;
    j = (j + state[i]) & 0xff;
    final swap = state[i];
    state[i] = state[j];
    state[j] = swap;
    keystream.add(state[(state[i] + state[j]) & 0xff]);
  }
  return keystream;
}

/// Masks one plaintext vendor frame with the static key at offset zero.
List<int> maskCbioFrame(List<int> plaintext) =>
    _xorWithStream(plaintext, cbioVendorStreamKey);

/// Removes the vendor mask from one inbound payload.
///
/// Masking is symmetric and restarts at offset zero for every frame, so this
/// also answers "what was the sensor actually saying" for a captured payload.
List<int> unmaskCbioFrame(List<int> masked) =>
    _xorWithStream(masked, cbioVendorStreamKey);

List<int> _xorWithStream(List<int> bytes, List<int> key) {
  final keystream = cbioRc4Keystream(bytes.length, key: key);
  return [
    for (var i = 0; i < bytes.length; i++) (bytes[i] ^ keystream[i]) & 0xff,
  ];
}
