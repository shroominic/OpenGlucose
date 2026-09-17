# Cbio GS1: authenticated query key source and runtime call sequence

## Scope and status

Read-only forensics against the vendor artifacts of the SiSensing GS1 Android
application. No radio was used, no sensor write occurred, and no vendor binary,
decompiled source, or unverified credential was added to this package. This
document records the source of the two 16-byte secrets the vendor protocol
needs, the derivation procedure, synthetic test vectors, and the vendor call
sequence for setup, live glucose, and history backfill.

This pass answers the question left open by `docs/testing/cbio-gs1-offline.md`:
where the 16-byte request key and the 16-byte authentication material come from
at runtime. Both are **application-embedded constants**. Neither is fetched
from a cloud account, stored in SharedPreferences, read from `BuildConfig`, nor
derived from the sensor serial or Bluetooth address.

## Artifact provenance

Re-acquired on 2026-09-18 from a public mirror at the documented version
(`01.20.01.00`, versionCode `33`) and verified byte-identical to the hashes in
the previous record before any analysis.

| Artifact | SHA-256 |
| --- | --- |
| Extracted base APK | `fce9313f255c356cf5afe75f705f57d3a4568f4ca2bf84856198d0b2a8ab2b07` |
| `config.arm64_v8a.apk` | `055f7de79e01c3137b9a97004615c462ebd0c899af3344dfb8f48af46596b1e3` |
| `assets/nedata.db` | `7eee004dbb6015843b46b4f78c3076c9feeee14cd8f55b463244795e5b2ad1b2` |
| ARM64 `libnesec.so` | `d652636504cf8ba2085a3c5741066defd9ac65e71b2aae5075845834cc35987d` |
| ARM64 `libdata-handle-lib.so` | `761f0aab72b35010839e90620c348ee71b888b25682252360a7af16f150bd1d7` |

All analysis copies live under a private mode-`0700` scratch directory outside
the repository. Only summaries and synthetic vectors appear here.

## Key source 1: the per-frame RC4 key is a static library constant

Every request the vendor sends is RC4-masked at stream offset zero with one
16-byte key. That key is a plain `.rodata` constant inside the hash-verified
`libdata-handle-lib.so`, at virtual address and file offset `0x11164`
(`.rodata + 0xe4`, followed immediately by unrelated log format strings).

Static evidence in the same library:

| Address | What it establishes |
| --- | --- |
| `0x11164` | The 16-byte `.rodata` RC4 key, referenced directly by the builders and by key registration |
| `0x93c8` | `register_key` entry point |
| `0x9568` | `register_key` loads the `0x11164` constant and passes it to the RC4 setup/stream routines (`0x4b60`, `0x4b80`) |
| `0x18170` | `.bss` registered-block slot (`0x38` bytes) that `register_key` fills |

The frame builders reached through `com.no.sisense.enanddecryption.CGMDataHandle130`
each build a fixed plaintext frame and, when the low bit of the first argument is
set, pass it through the same RC4 routine with a 16-byte key length and zero
stream offset. This is the secret that masks both directions of the traffic; the
sensor address is never an input to it.

## Key source 2: the auth material is a static, package-bound app constant

The 26-byte authentication frame carries a second 16-byte value at frame
offsets `9..24`. It is not a nonce, not the serial, and not the Bluetooth
address. It comes from the `.bss` registered block at `0x18170`:

1. The vendor application calls native `register_key` with a hex-encoded token
   string. That token is a **string constant embedded in the protected
   application DEX** (previous record: exactly one binding-matching token at
   file offset `0x3214a5` of recovered DEX section 2), not a network response.
2. `register_key` at `0x93c8` hex-decodes its input and RC4-decodes it with the
   same `.rodata` key from `0x11164`.
3. The decoded buffer is checked against the caller's package name, so a token
   only registers for the package it was minted for.
4. Clear bytes `6..21` of the decoded buffer are copied into the `.bss` block at
   `0x18170` (`0x95a4`-`0x95b4` in `register_key`).
5. The authentication builder reads those 16 bytes back out of `0x18170` and
   places them at frame offsets `9..24`.

Consequences for our own driver:

- The material is a fixed per-package credential. It does not roll per session,
  per sensor, or per account, and no cloud round trip is required to obtain it.
- The six sensor-address bytes are a separate, caller-supplied field
  (`frame[3..8]`, reversed address octets). They authenticate the link, not the
  secret.
- Because the material is static and package-bound, our driver can embed it the
  same way the vendor does instead of re-implementing the token registration.
  The literal token bytes were not re-extracted in this pass (see limits).

## Independent cross-checks

Two unrelated open-source implementations of this protocol, neither derived
from this repository, independently carry the identical 16-byte RC4 key and a
static per-package authentication credential: the Sibionics module of the
Juggluco reader (BSD/GPL project, `Common/src/main/cpp/sibionics/`), and a
Home Assistant direct-BLE GS1 integration. Both use the same frame layouts and
the same zero-offset RC4 masking described above.

The repository's own guarded bench reinforces this: a single encrypted `01`
request built with the DEX-recovered material was accepted on hardware with an
echoed opcode `01` and result `1` (`cbio-gs1-offline.md`, second authorized Mac
attempt). Authentication success is therefore live evidence for the material,
independent of the two third-party implementations.

## Runtime call sequence

Vendor-side references are to the decompiled `q/b.java`, `q/a.java`, and
`jo4.java` cited in `cbio-gs1-offline.md`; frame bytes are the derived plaintexts
that must be RC4-masked before the write.

1. Discovery and notify. Filter on service `FF30`, resolve receive `FF31` and
   command-write `FF32`, then attach the receive callback and enable
   notifications on `FF31` (`q.b.h.v2()`, `q/b.java:300`-`314`; UUID constants
   `q/b.java:39`).
2. Device information. `q.b.P1()` (`q/b.java:952`) writes the encrypted 4-byte
   `03 F0 x C` selector frame built by `v120_device_information`.
3. Authentication. `jo4.o()` (`jo4.java:451`-`459`) selects the encrypted path
   for this software revision, then `ProximityService.c.a()` posts a delayed
   call to `q.b.n1()` (`q/b.java:1404`). `n1()` reverses the six Bluetooth
   address octets and calls `v120_apply_authentication`, which builds the
   26-byte `19 01 x <6 reversed address octets> <16-byte registered material> C`.
   Success is an ACK with opcode `01` and result `1`. The separate
   `03 02 x C` switch-authentication builder (`v120_switch_authentication`) is
   not part of the recovered initial sequence.
4. Clock and live read. The read path `jo4.s()` -> `ProximityService.c.d()`
   first calls `q.b.J1()` (`q/b.java:837`) to send the 7-byte clock frame
   `06 03 LE32(epoch) C`, then `q.b.O1(index)` for records. For this software
   revision `O1()` selects the `08` raw-read family.
5. History backfill. Index paging uses `q.b.U1()`/`v120_glouse` for the packed
   `06 0A LE16(index) LE16(0) C` query (7 bytes; `q/b.java:989`) and the `08`
   raw-read request `06 08 LE16(index) 00 00 C` for bulk history. A working
   third-party client requests index `0` on first connection, then pages forward
   from the last received index; the sensor answers with `08` batches carrying a
   count, little-endian start index, base timestamp, and per-record payload, and
   then continues pushing live records on the same characteristic.
6. Sensor-initiated authentication trigger. At least one independent client
   treats the 5-byte notification `23 F7 6F D9 F4` as the "start authentication
   now" trigger and answers with the `19 01` frame. Subscribing and sending the
   authentication frame immediately is the equivalent, already-validated path.
7. Acknowledgement handling. ACKs are 5-byte frames; the observed opcodes are
   `01` (authentication), `03` (clock), `07` (activation), `08` (data request).
   A result field of `1` is success for authentication; ATT write completion is
   not protocol acceptance.

Not in scope of the recovered initial sequence: activation (`0A 07 LE32(epoch)
LE32(1234) C`) and the clock update are state-changing sensor writes and were
not performed by this lane.

## Synthetic test vectors

Every frame is summed to zero modulo 256 by its trailing `C` byte and then
RC4-masked with the `0x11164` key at stream offset zero. Inputs below are
synthetic: the address is `66:55:44:33:22:11` (reversed to `66 55 44 33 22 11`
in the frame) and the timestamp is `1700000000`.

| Purpose | Plaintext frame | Expected masked bytes |
| --- | --- | --- |
| Authentication (synthetic address) | `1901006655443322115448453534345530545949544534363154` | `3ef66fbf5d376bfeacd5ce463a8332d9b2e7bd0576c155804f5e` |
| Device information `F0`/`02` | `03f0020b` | `24076dd2` |
| Glucose query, index 1 | `060a01000000ef` | `21fd6ed90873b7` |
| Raw read, index 1 | `060801000000f1` | `21ff6ed90873a9` |
| Clock update | `060300f153654e` | `21f46f285b1616` |
| Activation (state-changing) | `0a0700f15365d204000070` | `2df06f285b168ad8bd81f6` |

The raw-read row independently reproduces the `06 08 01 00 00 00 F1` plaintext
derived in `cbio-gs1-offline.md` from the native builders, which is a useful
self-check that the plaintext construction and the masking are consistent.

## Limits

- The protected DEX was not re-unpacked in this pass, so the literal hex token
  string behind the registered block is still not reproduced. Its decoded
  output (the material) is established by static analysis of `register_key`, by
  two independent implementations, and by the live authentication success.
- The `16`-byte material and the `.rodata` RC4 key are recorded only in the
  private scratch directory and in the issue that tracks this work; they are
  deliberately not reproduced as bare constants in this document beyond the
  test vectors above.
- Glucose scaling, validity flags, and the exact epoch convention remain open
  and are unchanged by this pass.
