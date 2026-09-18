/// Vendor V120 stream masking for the GS1 sensor link.
///
/// Both directions of the vendor protocol are RC4-masked with one 16-byte
/// application constant at stream offset zero. The key is not derived from the
/// sensor address, the serial, the account, or the session, and it does not
/// roll: every frame restarts the keystream.
///
/// The key itself is **not in this repository**. It is extracted from a vendor
/// artifact and injected at run time; the extraction procedure and the artifact
/// digests are recorded in `docs/testing/cbio-gs1-auth-material.md`, and that
/// record deliberately does not restate the bytes. Every function here takes
/// the key as an explicit argument, so a caller that has not resolved vendor
/// material cannot compile a call to it.
library;

/// RC4 keystream bytes for [length] bytes from offset zero.
///
/// [key] is the injected 16-byte vendor stream key. It has no default.
List<int> cbioRc4Keystream(int length, {required List<int> key}) {
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

/// Masks one plaintext vendor frame with the injected key at offset zero.
List<int> maskCbioFrame(List<int> plaintext, {required List<int> key}) =>
    _xorWithStream(plaintext, key);

/// Removes the vendor mask from one inbound payload.
///
/// Masking is symmetric and restarts at offset zero for every frame, so this
/// also answers "what was the sensor actually saying" for a captured payload.
List<int> unmaskCbioFrame(List<int> masked, {required List<int> key}) =>
    _xorWithStream(masked, key);

List<int> _xorWithStream(List<int> bytes, List<int> key) {
  final keystream = cbioRc4Keystream(bytes.length, key: key);
  return [
    for (var i = 0; i < bytes.length; i++) (bytes[i] ^ keystream[i]) & 0xff,
  ];
}
