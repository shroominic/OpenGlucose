# Cbio GS1: offline registry map and SiSensing evidence

## Scope and status

- Task: OpenGlucose Competition, Cbio GS1; requested on 2026-09-09.
- Owner: `@shroominic`; implementation: Codex.
- Base: `02140e72ef553bee4035777862ce601cdc1d9ae6`.
- Worktree/branch: `feature/codex-cbio-gs1`.
- Risk: R2, sensor protocol research. Initial work was offline; the later
  explicitly authorized Mac bench attempt is recorded separately below.
- Acceptance: map the composition points, inventory local GS1/GS3 evidence,
  add a pure Dart `cgm_cbio` scaffold, and verify its offline boundary.
- Initial exclusions: BLE, network access, phone deployment, other contestants'
  work, sensor writes, activation, authentication, glucose publication, and release.
  The user later authorized a 15-minute BLE GRAB for scan/connect and read
  queries. Activation, reset, and other sensor administration remain excluded.

All inspection used shell tools. The initial static work used local files;
no app, vendor binary, or radio was started during that phase. Before radio
operation, the competition requires `BLE GRAB @Codex — Cbio GS1` to be posted
in OpenGlucose Competition, then `BLE RELEASE @Codex` when done (15 minutes
maximum unless extended). The user subsequently confirmed the posted GRAB at
approximately 17:56 BKK on 2026-09-09, expiring at 18:11 BKK. This document
does not itself grant or acquire the radio.

The scaffold reserves `cbio` and declares no capabilities. Its pure discovery
mapper now returns an unverified candidate for `FF30` advertisements; it still
fails scan/connect with an identifier-free error. It has no transport reference,
decoder, session, or app registration. Tests use only synthetic input. The
separate Mac bench connection does not establish glucose compatibility.

**UUID dig status, 2026-09-09: candidates recovered and compared on Mac.** Static
unpacking recovered five checksum-valid DEX files. Both apps use service
`0000ff30-0000-1000-8000-00805f9b34fb`, receive characteristic `FF31`, and
command-write characteristic `FF32` with the same Bluetooth UUID suffix.
GS1 Java also places `FF30` in a scan-filter path. See the exact call sites
below. A later authorized probe confirmed all three on one GS1-model candidate.
The frame layouts are research findings, not commands to send or a validated
glucose decoder. `cgm_cbio` has pure candidate mapping and no transport access.
The offline dig stopped at UUID readiness, before the user's later BLE GRAB.

## Initial offline registry and macOS composition map

This table records the initial scaffold constraints. The later pure discovery
change supplies a nonempty `FF30` filter, but does not register a live driver.

| Location | Existing contract | Cbio integration consequence |
| --- | --- | --- |
| `openhealth/lib/src/driver_factory.dart` | Selects IO or stub factory | macOS uses `driver_factory_io.dart` |
| `driver_factory_io.dart: buildPlatformDriver` | Handles demo/debug modes before the normal registry | Future GS1 bench selection needs an explicit macOS path; Android trace mode is not a Mac path |
| `driver_factory_io.dart: _buildPlatformRegistry` | Constructs AiDEX registration and one `FlutterBluePlusTransport` | Future Cbio registration must share that transport and registry |
| `openhealth/lib/src/cgm_driver_registry.dart: CgmDriverRegistration` | Requires a nonempty service list and pure discovery mapper | No registration is valid while GS1 services are unknown; do not invent a UUID |
| `CgmDriverRegistry.scan` | One physical scan, normalized service union, pure vendor mapping; rejects ambiguous matches | Do not start a separate Cbio scan or claim a shared standard service as vendor proof |
| `CgmDriverRegistry.connect` | Stops scan, routes by `driverId`, serializes lifecycle operations | Reserve `cbio`; implement and test transport/session behavior before enabling routing |
| `packages/cgm_aidex/lib/src/aidex_driver.dart` | Separates `AidexDiscovery` from `AidexSensorDriver` | Reuse the separation and contracts, not vendor names, keys, UUIDs, or packet assumptions |
| `packages/cgm_ble/lib/src/ble_transport.dart` | Pure transport and optional single-attempt connection contracts | Protocol code remains independent of Flutter and native plugins |
| `packages/cgm_core/lib/src/cgm_session.dart` | Neutral driver/session API | No GS-specific additions to core are needed for this scaffold |

The registry's `requiresUnfilteredScan` changes the whole physical scan. An
empty Cbio UUID list is evidence of missing knowledge, not permission to use
that option. The normal app registry and its tests remain unchanged.

## Local evidence and provenance

Reference root used read-only:
`/Users/fungus/dev/OpenHealth/other-apps-to-take-inspiration`.

| Artifact under that root | Observed identity |
| --- | --- |
| `apks/com.sisensing.sijoy.xapk` | GS1, version `01.20.01.00`, code `33`; base + ARM64 + hdpi split |
| `apks/com.sisensing.gs3.xapk` | GS3, version `01.08.01.00`, code `25`; base + ARM64 + xxhdpi split |
| `docs/apk-analysis/com.sisensing.sijoy.md` | Prior product-surface analysis, not a wire protocol specification |
| `docs/apk-analysis/com.sisensing.gs3.md` | Prior product-surface analysis, not GS1 compatibility evidence |
| `apks/analysis/apk-re/jadx/com.sisensing.sijoy/resources/res/values/strings.xml:101` | `app_name` is `SIBIONICS GS1` |
| `apks/analysis/apk-re/jadx/com.sisensing.sijoy/resources/AndroidManifest.xml:491` | Registers `com.sisensing.common.ble.LocalBleServiceProxy` |

Both decoded apps expose the NetEase `com.netease.nis.wrapper` shell instead
of the sensor implementation. Their base APKs each contain one small
`classes.dex` (GS1: 58,224 bytes; GS3: 58,976 bytes) and `assets/nedata.db`
(GS1: 6,260,999 bytes; GS3: 7,535,724 bytes). This explains why a Java-source
search does not recover the manifest's BLE implementation. No protocol DEX
was unpacked or executed in this slice.

Each XAPK's `config.arm64_v8a.apk` contains the native libraries. Inspecting
only `extracted/<package>.apk` misses these libraries. ZIP members were read
in memory during the initial inventory. The follow-up extracted selected
members into the protected temporary directory described below. No vendor
executable was added to the repository or executed.

SHA-256 provenance (build artifacts, not sensor identifiers):

| Artifact | SHA-256 |
| --- | --- |
| GS1 extracted base APK | `fce9313f255c356cf5afe75f705f57d3a4568f4ca2bf84856198d0b2a8ab2b07` |
| GS3 extracted base APK | `8a1ee3d974ed9dd0439997ebf18c2824d405237f1c27819a17424de4b7332d7e` |
| GS1 `libdata-handle-lib.so` | `761f0aab72b35010839e90620c348ee71b888b25682252360a7af16f150bd1d7` |
| GS3 `libdata-handle-lib2.so` | `a270661f0dcea2630bd142d37178a62ae6ed28b023298a6136c63157ed8f754b` |
| Both `libnative-encrypy-decrypt-v110.so` | `7deca2302bee4aff557c261de89565cf43744f7e6430e8d6bbd3c6823b7a92d4` |
| GS1 `libnative-algorithm-jni-v116A.so` | `1ceab2ffa14528ba84c01b831f9e04f202a84dd7ee94d9e15e678917685e4b5e` |

## Native RE map

ELF dynamic symbols were read statically, without loading the libraries.
GS1 exports JNI methods under
`Java_com_no_sisense_enanddecryption_CGMDataHandle130_`; GS3 uses
`Java_com_sisensing_cgmble_processor_CgmDataHandle_`.

| GS1 symbol suffix | ELF virtual address / size | What it establishes |
| --- | --- | --- |
| `V110RawData` | `0x514c` / 232 | Candidate raw-data wrapper exists |
| `V110SpiltData` | `0x5234` / 332 | Candidate V110 framing entry point exists; spelling is from the binary |
| `V120RawData` | `0x5538` / 228 | Separate V120 raw-data path exists |
| `V120Glouse` | `0x561c` / 160 | Candidate glucose wrapper exists; no units or field semantics established |
| `V120DeviceInformation` | `0x5790` / 212 | Candidate device-information operation exists |
| `V120SpiltData` | `0x5864` / 352 | Separate V120 framing entry point exists |
| `V120ApplyAuthentication` | `0x59c4` / 216 | Authentication operation exists; handshake unknown |
| `V120SwitchAuthentication` | `0x5a9c` / 144 | A second authentication operation exists; side effects unknown |
| `AES_1ENCRYPT` / `AES_1DECRYPT` | `0x6228` / 192; `0x62e8` / 192 | Crypto wrappers exist; mode, keys, and inputs unverified |

GS1 also exports sensitivity decryption, key registration, activation, reset,
interval, and threshold operations. These names are investigation leads, not
authorized commands. No credentials or vendor implementation were copied into
the package. The follow-up records derived frame layouts below, without keys
or authentication material. The encryption library exports `global_app_encrypt`,
`global_app_decrypt`, and `global_encrypt_control_cmd`.

The GS1 ARM64 split contains algorithm families V110, V111, V112, V112F, and
V116A. The V116A JNI surface includes `initAlgorithmContext`,
`processAlgorithmContext`, binary context get/set, sensitivity routines, and
release. That is evidence of a separate stateful algorithm path. It does not
justify converting an arbitrary raw field into glucose. GS3 adds explicitly
named GS3/GKS2/GK5 data paths; shared wrapper suffixes do not prove equivalent
wire protocols or firmware behavior.

## Follow-up: extraction and UUID search

Source XAPKs were opened with Python `zipfile`; only their base APK and
`config.arm64_v8a.apk` were opened as nested archives. Selected members were
`lib/`, `assets/`, `res/`, `classes.dex`, `resources.arsc`, and
`AndroidManifest.xml`. Paths were checked for traversal before extraction.
The output root is `/private/tmp/cbio-re-20260909` (mode `0700`); extracted
files have mode `0600`. There is one subdirectory per package name. The
original reference directory was read-only. No Android runtime was started.

| Scope | GS1 / `sijoy` | GS3 |
| --- | --- | --- |
| Extracted files | 2,088 | 2,441 |
| ARM64 `.so` files | 27 | 26 |
| Files with textual full-UUID matches | 1 image | 4 images |
| Non-image files with textual full-UUID matches | 0 | 0 |
| Binary Bluetooth-base suffix matches | 0 | 0 |
| Single-byte-XOR Bluetooth-base text suffix matches in `.so`, DEX, or `nedata.db` | 0 | 0 |

The full-UUID search covered ASCII and UTF-16LE/BE at both byte alignments.
Binary suffix checks covered canonical and reversed Bluetooth-base tails.
The limited XOR search covered all 255 nonzero one-byte masks of the
uppercase/lowercase standard UUID suffix. This does not rule out encrypted,
compressed, fragmented, or numerically constructed UUIDs.

All textual hits were in bundled graphics with Adobe XMP document/instance
metadata: `assets/graphics/skies.jpg` in both apps, plus GS3's
`anim_ble_connecting.gif`, `gif_scan_code_guide.gif`, and
`ic_how_scan_sensor_step_2.gif`. XMP markers included `stRef:documentID`,
`stRef:instanceID`, and `xmpMM:InstanceID`. These hits provide no BLE evidence,
even when the filename contains `ble`. They were rejected as scan candidates.

Both data-handler libraries have only `0000` as an exact four-hex-digit ASCII
string. That is not a service UUID candidate. Searches of decoded string
resources found BLE UI text and a `BleBluetoothTool` version message, but no
service/characteristic value. No standard CGM UUID was substituted by guess.

Additional split provenance:

| Artifact | SHA-256 |
| --- | --- |
| GS1 `config.arm64_v8a.apk` | `055f7de79e01c3137b9a97004615c462ebd0c899af3344dfb8f48af46596b1e3` |
| GS3 `config.arm64_v8a.apk` | `db8e5be06a91c2998857a5cf71d832eb51a5dbfa7124bcb0d93f276387c9b1e3` |

### Initial protected-payload limit (resolved below)

The 365 wrapper string calls in each decompiled app were decoded statically
using the wrapper's Base64/XOR routine. Relevant decoded names referred to
the NetEase loader libraries; no UUID or GATT definition appeared.

`assets/nedata.db` in both apps contains no plain DEX or ZIP local-header
signature. Its measured byte entropy is 7.99997 bits/byte for GS1 and 7.99998
for GS3. Those observations are consistent with a protected/compressed
payload; they do not establish a specific cipher or unpacking method.

The ARM64 `libnesec.so` itself has nonstandard `.gnu.fragment`, `.gnu.draft`,
and `.gnu.stub` sections. Its nominal `.text` is only 16 bytes and does not
disassemble as an ordinary loader entry point. A normal `objdump` of this
section cannot recover the hidden BLE classes. The initial pass recovered no
protected protocol DEX. The static loader and RC4 recovery below now resolve
that extraction limit without a runtime, app launch, or scan.

## Follow-up: static DEX recovery and scan-ready UUIDs

After the reboot removed scratch files, the two local XAPKs were extracted
again into `/private/tmp/cbio-re-20260909` (`/tmp` resolves to `/private/tmp`
on this Mac). The directory is private, mode `0700`; recovered binary files
are mode `0600`. Vendor payloads, unpacking keys, and decompiler logs stay
outside the repository. Only this evidence document changed in this pass.

### Recovery and integrity evidence

The GS1 ARM64 `libnesec.so` init path leads to the protected body through
metadata at virtual address `0x103778`. A Python reconstruction of the loader
byte transform decoded its 63,968-byte auxiliary region and 849,488-byte body.
The body declares a 374,916-byte zlib stream and an 872,450-byte clear result;
decompression produced exactly that length. Six recovered program headers
map the original file, including writable segments with virtual/file offsets
that differ by `0x4000` and `0x8000`. Restoring 2,113 relative relocations made
the loader's data references readable. This is an analysis image, not a
loadable or executed vendor library; erased dynamic metadata is not complete.

Recovered loader routines `0xb0bf0` and `0xb0c64` implement ordinary RC4
setup and stream XOR. `0xb0d14` decodes loader literals; `0xb0e04` combines
two 16-byte literals for the outer archive key. Applying that derived key
to each `assets/nedata.db` yields a valid ZIP. Every entry passes ZIP CRC.
Each ZIP contains `patch` and `addition.data`; `patch` was retained privately
but was not applied or decoded in this pass.

In `addition.data`, the little-endian word at byte 4 gives a metadata length
of 218 (GS1) or 216 (GS3). RC4 with the first loader literal decodes that
many bytes from byte 8. The next table starts at the following 4-byte boundary:
`0xe4` for GS1, `0xe0` for GS3. It contains a count and 20-byte entries with
five LE32 fields: flags, file offset, clear length, stored length, and index.
Entry 0 is zlib metadata: 7,756 bytes for GS1, 6,696 for GS3. The remaining
entries have flags 5 and equal clear/stored lengths.

Loader `0xa1d60` parses the decoded metadata; field `d` supplies the per-app
DEX key at object offset `0x118`. Routine `0xa2f4c`, specifically
`0xa30fc`–`0xa3148`, resets RC4 with that key and transforms only the first
`min(stored_length, 4096)` bytes of each DEX entry. The remaining bytes are
already clear. All five results have `dex\n035\0` magic, exact declared file
length, valid DEX Adler-32, and valid DEX SHA-1. No key value is reproduced.

| Recovered DEX | Bytes | SHA-256 |
| --- | ---: | --- |
| GS1 section 1 | 8,361,784 | `6825d472700cd60ed16f3927f61cc5457d14140a9926e2fe089e630737675eaf` |
| GS1 section 2 | 5,285,224 | `d99eef8e0238e3fab929ee9feac8429673b496fd5966548587fd9a967e29a8ed` |
| GS3 section 1 | 8,743,700 | `be2f764f3db6539f516178612f9066da06f9522cdda2819e701c45a3ab9ed2b2` |
| GS3 section 2 | 4,468,984 | `0440e046de969ebb1ce132bd506641f604c8a4f28d773c2ac5e7f445ac072780` |
| GS3 section 3 | 3,581,236 | `ead3f1d7983c43f31686a93e1e85cd692be8c63c94f9ab0702f543849e5541d1` |

Input SHA-256 values for reproduction:

| Input | SHA-256 |
| --- | --- |
| GS1 `assets/nedata.db` | `7eee004dbb6015843b46b4f78c3076c9feeee14cd8f55b463244795e5b2ad1b2` |
| GS3 `assets/nedata.db` | `ed108663596e73d4a7175fb655a5d9de34dcef70030861b3567c488ccf4e01a3` |
| GS1 ARM64 `libnesec.so` | `d652636504cf8ba2085a3c5741066defd9ac65e71b2aae5075845834cc35987d` |

The private reconstruction script is `recover.py` in the scratch directory.
Local JADX 1.5.4 processed the DEX files with resources disabled and checksum
verification enabled. Both full decompilations returned exit 3 with errors;
this is not a claim of complete Java recovery. The specific UUID and builder
methods cited below are readable. Protected/missing methods and the unapplied
`patch` remain limits on complete control-flow and response analysis.

### UUID roles and stop point

All three candidate UUIDs are full strings in GS1 section 2 and GS3 section 2.
Paths below are relative to each private `jadx-<app>/sources` directory.

| Role | Full UUID | Static evidence |
| --- | --- | --- |
| Primary service; scan-filter candidate | `0000ff30-0000-1000-8000-00805f9b34fb` | GS1 `q/b.java:39` (`P`), `q.b.h.w1()` line 410; `defpackage/ck4.java:7`, used by `q.a.V()` at `q/a.java:590` |
| Receive/notification characteristic | `0000ff31-0000-1000-8000-00805f9b34fb` | GS1 `q.b.Q` → field `y` in `w1()`; `q.b.h.v2()` lines 300–314 attaches the receive callback and enables notifications |
| Command-write characteristic | `0000ff32-0000-1000-8000-00805f9b34fb` | GS1 `q.b.R` → field `z` in `w1()`; `P1()`, `U1()`, and `n1()` send native builder output through `e(this.z, ...)` |

GS3 independently corroborates this layout: `defpackage/ze5.java:486`–489,
method `p()`, gets `FF30`, then `FF31` and `FF32`. `rl0.a0()` stores `FF31`
in `t`, used by receive setup in `rl0.D()`; `rl0.e0()` stores `FF32` in `u`,
used by command sends such as `rl0.H()`.

GS1 `q.a.V()` selects the `FF30` scan filter when `ko4.j(...) == 2`; other
branches use name conditions. This proves a service-filter code path, not
that every firmware advertises that service. A separate GS1 `T0()` path looks
up `FF31` as a service and `FF32` as its characteristic; its purpose remains
unclassified and it is not promoted over the primary `w1()` path. Standard
device-information/battery UUIDs and the WebSocket GUID also occur in the DEX
and are not GS1 discovery identifiers.

**Stop condition met.** These candidates are ready for a later user-authorized
BLE GRAB comparison. No scan, connection, service discovery, notification
subscription, or write was attempted. No registry or driver constant changed.

### Java links to the native frames

GS1 `com.no.sisense.enanddecryption.CGMDataHandle130` declares the JNI methods.
The recovered Java makes these links to the plaintext layouts below:

| Frame | GS1 Java call site | New evidence |
| --- | --- | --- |
| `03 F0 x C` (4 bytes) | `q.b.P1()`, `q/b.java:952` | Requires protocol string `V120`; passes its integer selector to `V120DeviceInformation`; copies exactly the native returned length to the `FF32` write buffer |
| `06 0A LE16(a) LE16(b) C` (7 bytes) | `q.b.U1()`, `q/b.java:989` | Passes the caller's index as the `long` argument and zero as the next integer to `V120Glouse`; the adjacent log labels the caller argument `index`; JNI at `0x561c` confirms this order, with the builder retaining the low 16 bits |
| `19 01 x [6 bytes] [16 bytes] C` (26 bytes) | `q.b.n1()`, `q/b.java:1404` | Builds the six-byte input by reversing the Bluetooth address octets, then passes it to `V120ApplyAuthentication`; sends exactly the native returned length on `FF32` |

The 1,024-byte temporary buffers and the glucose builder's capacity argument
30 are not packet lengths. Java copies the returned byte count before the
write. The native sum-to-zero integrity result below still applies to the
examined plaintext builders; no new wire checksum or response-correlation
rule is claimed. Java write-completion callbacks do not establish protocol
acceptance. Exact authentication selector meaning, success responses,
transaction correlation, fragmentation, and the complete notification-to-
`V120SpiltData` path remain unresolved at this stop point. No real address,
authentication material, packet, or glucose value was recorded in this file.

## Follow-up: native frame layouts

Disassembly used the locally installed
`/opt/homebrew/opt/llvm/bin/llvm-objdump`. Addresses below are ELF virtual
addresses in the exact hashed libraries, not raw file offsets. This is static
data-flow analysis; no vendor function was called and no packet was sent.

The GS1 `v120_device_information`, `v120_apply_authentication`,
`v120_switch_authentication`, and `v120_glouse` functions are **request
builders**. The last function is not a glucose decoder. Each examined builder
checks its output buffer/capacity, builds a fixed-length frame, and either
copies it or passes it through `Rc4XorWithKey` when the low bit of its first
argument is set. The calls supply a 16-byte key length and zero stream offset.
Key bytes and global authentication material are not reproduced here. The
presence of other AES exports does not make these request paths AES.

Notation: all bytes below are hexadecimal; `x` is the low byte of an
unresolved caller argument, `LE16(a)` is an unresolved 16-bit caller argument
in little-endian order, and `C` is the additive checksum byte. The final sum
of every byte, including `C`, is zero modulo 256. These are plaintext
templates before the optional transform, not send-ready handshake packets.

| Builder | GS1 address | Length | Derived plaintext layout |
| --- | --- | --- | --- |
| `v120_device_information` | `0x6808` | 4 | `03 F0 x C`, with `C = (0x0D - x) & 0xFF` |
| `v120_apply_authentication` | `0x68bc` | 26 | `19 01 x [6 bytes from caller] [16 bytes from global state] C` |
| `v120_switch_authentication` | `0x6a48` | 4 | `03 02 x C`, with `C = (0xFB - x) & 0xFF` |
| `v120_glouse` | `0x6c44` | 7 | `06 0A LE16(a) LE16(b) C` |

The checksum helper at GS1 `0x6528` accumulates bytes and negates the sum;
callers use the low byte. In these builders, byte zero equals total frame
length minus one. The authentication builder copies the caller's six bytes
unchanged; their meaning is not established. Do not label them a device
address, serial, or nonce without the Java call site. The role and valid values
of `x`, initialization of the global state, required handshake order, choice
of plaintext/transformed mode, and success/rejection semantics remain unknown.

Cross-check: GS3's `v120_apply_authentication` at `0xad54`,
`v120_switch_authentication` at `0xaee0`, and `v120_glouse` at `0xb0dc`
use the same examined frame lengths, header bytes, checksum arithmetic, and
optional RC4 call shape. This establishes shared builder structure in these
two app versions, not GS1/GS3 sensor interchangeability.

## Follow-up: candidate glucose response fields

GS1 `v120_spilt_data` starts at `0x7060`. After its optional transform, it
dispatches on byte 1. Its jump table at `0x11080` routes opcode `0x0A` to
`0x7434`; a byte-zero value of 4 takes the short acknowledgement path, while
the other path reaches `0x7960` and produces `cgmv120_only_glouse_info_t`.
Opcode `0x08` reaches a different, eight-byte-per-record path; it must not be
parsed as the two-byte layout below.

For the `0x0A` data path, the code treats byte 0 as `L`, copies `L + 1` bytes,
and compares byte `L` with the negated sum of the preceding `L` bytes. The
following layout is derived from load offsets and loop strides. A future
parser must independently validate actual input length, count, and bounds;
the native routine is not a safe parser specification by itself.

| Offset in transformed/plain frame | Derived role |
| --- | --- |
| 0 | `L`, the checksum offset; total length is `L + 1` |
| 1 | Opcode `0x0A` |
| 2 | Record count `n` |
| 3–4 | Little-endian initial `index` |
| 5–8 | Little-endian initial `itime` |
| 9 onward | `n` packed records, two bytes each |
| `L - 2`, `L - 1` | Little-endian base used to derive `reindex` |
| `L` | Additive checksum byte |

The nonoverlapping layout implies total length `12 + 2*n`. This length/count
relationship is a derived validation requirement, not a claim that the native
routine enforces it or that every sensor firmware uses it.

For record `i`, let `p = frame[9 + 2*i]` and `q = frame[10 + 2*i]`:

| JSON field | Extraction in the examined GS1 code |
| --- | --- |
| `glouse` | `(p >> 6) | (q << 2)`; an unsigned 10-bit integer |
| `trend` | `(p >> 3) & 7` |
| `gwarn` | `(p >> 1) & 3` |
| `twarn` | `p & 1` |
| `cwarn` | `p & 1`, the same source bit in this build |
| `index` | Initial index plus `i`, stored as 16 bits |
| `reindex` | Trailer base plus `n - 1 - i`, stored as 16 bits |
| `itime` | Initial time plus `60*i`, stored as 32 bits |

Evidence: the packed-field loop is `0x7a00`–`0x7a58`; the JSON conversion
call is at `0x7ad0`; `struct_to_json_cgmv120_only_glouse_info_t` is at
`0x97a4`. Its string references resolve to `index`, `reindex`, `glouse`,
`trend`, `gwarn`, `twarn`, `cwarn`, and `itime`. No unit conversion occurs in
this conversion function. A step of 60 is consistent with seconds but does
not establish the time unit or epoch without the caller.

**No valid glucose reading can yet be published.** The 10-bit field's scale
and units, warning meanings, trend mapping, special values, firmware/model
selection, and timestamp origin remain unresolved. The separate stateful
native algorithm libraries are still present. This path may carry a computed
value for some firmware; that does not establish that the target Cbio GS1
uses it, or justify treating the integer as mg/dL or mmol/L.

### Reproduction points

These read-only commands reproduce the key disassembly from the local
extraction. They do not load the library or access Bluetooth:

```sh
cbio_objdump=/opt/homebrew/opt/llvm/bin/llvm-objdump
cbio_gs1=/private/tmp/cbio-re-20260909/com.sisensing.sijoy/lib/arm64-v8a/libdata-handle-lib.so
cbio_gs3=/private/tmp/cbio-re-20260909/com.sisensing.gs3/lib/arm64-v8a/libdata-handle-lib2.so
"$cbio_objdump" -d --no-show-raw-insn --start-address=0x6808 --stop-address=0x6afc "$cbio_gs1"
"$cbio_objdump" -d --no-show-raw-insn --start-address=0x6c44 --stop-address=0x6d24 "$cbio_gs1"
"$cbio_objdump" -d --no-show-raw-insn --start-address=0x7960 --stop-address=0x7b20 "$cbio_gs1"
"$cbio_objdump" -d --no-show-raw-insn --start-address=0x97a4 --stop-address=0x9868 "$cbio_gs1"
"$cbio_objdump" -d --no-show-raw-insn --start-address=0xad54 --stop-address=0xaf94 "$cbio_gs3"
"$cbio_objdump" -d --no-show-raw-insn --start-address=0xb0dc --stop-address=0xb1bc "$cbio_gs3"
```

The static follow-up changed only this evidence document in the repository. Earlier
scaffold tests remain the last code-test evidence; no new protocol code or
test fixture was added. `git diff --check` was rerun for the document update.

## Authorized Mac BLE follow-up, 2026-09-09

The user confirmed `BLE GRAB` for Codex Cbio GS1 at approximately 17:56 BKK,
with a 15-minute maximum. The hard deadline used by the private probes was
18:11 BKK. The final connection closed at **18:06:38 BKK**, and **BLE RELEASE**
was reported in this conversation. No message was sent to the competition
group through a connector. Further radio work requires a new GRAB.

### Package discovery change

`CbioUuids` records the full `FF30` service, `FF31` receive, and `FF32` command
UUIDs. `CbioDiscovery.scanServiceUuids` now contains only `FF30`. The pure mapper
accepts that full UUID (case-insensitive), `FF30`, or `0000FF30`, with a nonempty
device ID. It returns a generic Cbio / SiSensing candidate, without a glucose
advertisement or enabled capabilities. Names alone, characteristic UUIDs,
near-match service UUIDs, and empty IDs do not match. GS1 and GS3 share the
service, so this mapping does not claim model identity.

The driver still has no transport and rejects direct scan/connect calls,
including calls with newly mapped candidate metadata. The app registry is
unchanged. The live probe used the locally installed Python Bleak/CoreBluetooth
stack in a private scratch script; it did not add a runtime dependency or a
live implementation to `cgm_cbio`.

### Redacted bench evidence

| Step | Result |
| --- | --- |
| Sandbox probe | CoreBluetooth reported `Bluetooth is unsupported`; no scan result. The same authorized probe was retried with host Bluetooth access |
| 25-second `FF30`-filtered scan | One candidate; connected successfully, then disconnected at 17:59:51 BKK |
| Service discovery | `FF30` present; `FF31` supports `notify`; `FF32` supports `write` and `write-without-response` |
| Passive subscription | No notification in 20 seconds |
| Generic device-information reads | Model field reports `GS1`; model, firmware, hardware, software, and manufacturer fields read. No serial-number characteristic read |
| Plaintext information and glucose queries | One four-byte `F0` request and one seven-byte `0A` request, with zero selectors/index; both ATT writes completed. Each was followed by a five-byte notification |
| Offline reply check | Both plaintext-attempt replies decode with the native RC4 routine/key into length-valid, sum-to-zero opcode-`00` control frames; no glucose record |
| First encrypted connection attempt | Target lookup failed with `BleakDeviceNotFoundError`; no command sent. A new bounded, explicitly `FF30`-filtered lookup reacquired the same target |
| Encrypted queries | One `F0` information request and one `0A` index-zero query, RC4-transformed with the native 16-byte key, stream offset zero. Both ATT writes completed |
| Encrypted replies | One five-byte acknowledgement per query; after RC4, length and checksum both pass. Reply opcodes echo `F0` and `0A`; both carry control/status bytes `00 03` |
| Final cleanup | Notification subscription stopped and client disconnected at 18:06:38 BKK; probe process exited. No further radio operation |

The plaintext-attempt connection ended during notification cleanup with
`BleakError: Service Discovery has not been performed yet`; its client context
exited. The later encrypted attempt completed normal unsubscribe/disconnect.
All probes had a deadline guard and bounded waits. The reconnect by stored
CoreBluetooth identifier used Bleak's internal target lookup; the final
reacquisition used an explicit service filter and a `BLEDevice` object.

The request templates were `03 F0 00 0D` and `06 0A 00 00 00 00 F0` before
optional encryption. These are generic query templates, not device secrets.
JNI at `0x561c` and `0x5790` confirms that the Java boolean selects RC4 and
that the glucose index and following integer feed the first and second LE16
fields. This establishes a working encrypted query/acknowledgement path on
the observed candidate. It does not establish authentication success or a
complete request/response transaction model.

The native `0x0A` handler at `0x7434` treats length byte 4 as an acknowledgement;
the data-record path is separate at `0x7960`. The follow-up below maps `00 03`
to result zero and raw status three, with unresolved meaning. It is not glucose or successful data
delivery, or proof of a particular authentication failure. No data-record frame
arrived. **No valid glucose read was obtained or published.** No activation,
authentication, reset, calibration, clock setting, or administrative write
was attempted. No pairing or bond change was requested.

Raw names, CoreBluetooth identifiers, advertisements, device-information values,
notification bytes, and keys remain private in `/private/tmp/cbio-re-20260909`.
The capture files are `mac-probe-private.json`, `mac-read-private.json`,
`mac-read-encrypted-lookup-private.json`, and `mac-read-encrypted-private.json`.
They are mode `0600` under the mode-`0700` directory and are not repository
fixtures. This scratch evidence will not survive another reboot.

### Discovery verification

Using the pinned Dart executable from `packages/cgm_cbio`, without dependency
resolution or network access:

| Command | Result |
| --- | --- |
| `dart --suppress-analytics format lib test` | Passed; test formatting updated |
| `env CI=true dart --suppress-analytics format --output=none --set-exit-if-changed lib test` | Passed; 3 files, 0 changed |
| `env CI=true dart --suppress-analytics analyze --fatal-infos` | Passed; no issues |
| `env CI=true dart --suppress-analytics test --reporter expanded` | Passed; 7 synthetic tests |

`dart` above is `/Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart`.
Root `git diff --check` passed. Because the new evidence/package files remain
untracked, `git diff --no-index --check /dev/null <file>` also passed for this
document, the discovery implementation, and its tests. A local comparison
confirmed that captured target names and CoreBluetooth identifiers do not
occur in the document, package source, or tests.

Tests cover normalized `FF30` candidates, false matches, missing identity,
disabled capabilities, and rejection of a live session for mapped/restored
metadata. Package and compatibility documentation were updated. No manifest,
lockfile, app, native project, or unrelated sensor package changed. Full
workspace/native validation is not claimed. Roll back this discovery increment
by restoring the empty scan filter and null mapper; the app has no registration.

## Offline ACK/authentication follow-up after BLE RELEASE

The radio remained free throughout this pass. No probe was run, no sensor was
connected, and no credential was sent. The package retains pure discovery and
has no transport access. This work prepares the next physical attempt; a real
glucose read and live registry integration remain unfinished.

### What `00 03` establishes

The native five-byte ACK layout is `04 opcode result raw_status checksum`.
`struct_to_json_cgmv120_cmd_ack_t` at `0x95ec` names the result
`u8reply_ack_resule` and the mapped error `u8error_code`. The command type in
that JSON is `0xc001 + opcode`, while the parser's outer result type is
`0xc00d`. Thus the `0A` acknowledgement becomes command type `0xc00b`, and an
authentication `01` acknowledgement becomes `0xc002`. These two IDs must not
be confused with the outer ACK type or with a glucose record type.

For result zero, `0x7498` calls `get_errocode` (`0x7e88`). Its table sends
`0xc00b` to `0x7eb8`, where raw statuses 4, 5, and 6 map to 2, 5, and 13.
Raw status 3 takes the fallback `0xff`. Therefore the observed `00 03` is
**result zero / raw status three / unmapped native error**, not a verified
label for “authentication required.” The offline parser retains both raw
fields and does not convert an ACK or ATT completion into a glucose reading.

GS3 corroboration is separate: `og5.w()` routes command `0xc002` to its
authentication event; `da0.java:387` treats result 1 as authentication success.
GS1 native uses the same ACK layout and command arithmetic. The next bench
gate requires a new checksum-valid `01` reply with result 1 after the one
authentication write; an opcode match alone cannot establish freshness,
transaction identity, or success.

### Authentication prerequisites recovered offline

The GS1 `jo4.o()` method was re-decompiled in JADX simple mode to recover its
device-information branch. The private output is `jo4-simple.java`. After
model/software checks, lines 451–459 set encryption true and call
`k(device, this.s, true, 0)`. That method posts a one-second delayed call through
`ProximityService.c.a()` to `q.b.n1()`. `jo4.e()` selects V120 for GS1 software
whose final version component has major at least 2; `jo4.w()` additionally
tests major at least 2 and minor at least 1 before that encrypted auth path.
The privately captured model/software values satisfy both conditions. This
supports trying the app's initial authentication sequence without assigning a
meaning to status 3.

`q.b.n1()` reverses the six Android Bluetooth address octets and calls
`V120ApplyAuthentication(..., encrypted, 0, address_bytes, output, capacity)`.
Native `0x68bc` builds exactly 26 bytes:

`19 01 00 [six reversed address octets] [16-byte registered material] C`

`C` makes the plaintext sum zero modulo 256. RC4 then transforms the entire
frame with the same native 16-byte stream key and zero stream offset that
validated the captured ACKs. This is application authentication, distinct from
BLE bonding. The separate `02` authentication-switch builder is not part of
the recovered initial sequence and is excluded from the next attempt.

The 16-byte auth material at native virtual address `0x18170` is **BSS**, not
a static constant or a valid all-zero substitute. `register_key` at `0x93c8`
hex-decodes its input, applies RC4, compares the decoded package field with
the caller package, then copies clear bytes 6–21 into that BSS slot at
`0x95a4`–`0x95b4`. Exactly one token in GS1 section 2 (file offset `0x3214a5`)
passed that package binding check for `com.sisensing.sijoy`. Its 47-byte clear
result and all key/material values remain private. No native function was
executed, and no registration/authentication token was added to the package.

The unresolved live input is the six-byte sensor address. CoreBluetooth's
device UUID is not a MAC address and must never be substituted. GS1
`q.b`'s serial callback reads characteristic `2A25` and calls `ko4.k()`, which
formats its bytes in reverse order as a colon-separated address. This is a
candidate source on Mac, but the prior bench did not read that characteristic.
The next attempt must read it on the same target, require exactly six bytes,
and validate its address correspondence before sending auth. A malformed,
absent, or inconsistent value stops the attempt; no invented address is used.

The private `prepare_next_auth.py` has no Bluetooth/network imports. It verifies
package binding, builds the auth frame with a synthetic six-byte address, and
checks 26-byte length, field order, checksum, and RC4 roundtrip. It also checks
the two query templates. It writes `next-auth-preflight-private.json` with
private material and the bench gates, but no authorization to run the radio.
The script passed. Both files remain under the private scratch directory.

### Packed glucose inspection and limits

`parseCbioPlaintextFrame` now validates a complete, already-decrypted frame.
It accepts the examined five-byte ACK opcodes and the `0A` packed layout,
requires exact `L + 1` and `12 + 2*n` lengths, checks all byte ranges and the
sum-to-zero checksum, and rejects unsupported opcodes. ACKs never enter the
data path. It exposes immutable raw record fields and rejects index, time,
or reindex overflow instead of guessing wrap behavior. It neither assembles
BLE fragments nor attempts to decrypt an unverified partial notification.

GS3 `rf5.h()` (`rf5.java:162`) divides `V120GlucoseBean.glouse` by 10.0 when
making its public record. That is useful scale evidence for GS3, not proof of
GS1 units. In the recovered GS1 path, `q.a.A()` copies the integer from
`CGMRecordV120.getGlouse()` through `NewRecord.k()` unchanged. Its downstream
app conversion still includes protected methods. Epoch, exact-model scale,
warning meanings, special values, and calibrated/current validity remain
unresolved. No normalization or medical reading API was added.

The pinned Dart commands in the previous section passed again: format and
analysis were clean, and **14 tests passed**. Seven new frame tests cover raw
ACK correlation, endian/field values, all 65,536 packed bit combinations,
empty/maximum batches, every truncated prefix, trailing bytes, checksum/byte
errors, wrong opcodes/counts, immutable results, and unknown counter wrap.
All fixtures are synthetic; none is copied from the live notification capture.

Commit preparation exposed missing generated dependency metadata in the other
workspace packages. The first pre-commit format/tooling checks passed, but the
workspace analyzer could not resolve those imports. Metadata was restored from
the existing Pub cache with `pub get --offline` (and `--enforce-lockfile` for
the app). No manifest, tracked native file, or app lockfile changed. The pinned
ShellCheck/actionlint binaries were already installed through Homebrew; private
workspace cache links let the native tooling bootstrap use those versions
without downloading tools. `env CI=true FLUTTER_SUPPRESS_ANALYTICS=true
DART_SUPPRESS_ANALYTICS=true make lint` then passed across the workspace with
no issues. Hooks remain enabled for the commit retry.

### Next physical attempt: prepared; awaiting a new BLE GRAB

1. Start only after a newly posted GRAB, with a hard 15-minute deadline and one
   target. Use `FF30` filtering and verify the known model/characteristic layout.
2. Read/validate `2A25` as described above. Subscribe to `FF31`. Confirm a single
   26-byte ATT write is supported; do not invent fragmentation.
3. Send one encrypted `01` authentication request with selector zero and the
   verified material. Stop on timeout, malformed response, wrong opcode, or
   any result other than 1. Do not retry or switch authentication mode.
4. Only after that gate, send one encrypted `F0` information query and one `0A`
   index-zero query. Preserve ACKs separately from full packed data frames.
   Decode valid records to raw fields privately; do not publish scaled glucose
   until exact-model unit/time/validity evidence is established.
5. Unsubscribe, disconnect, and report BLE RELEASE on completion or expiry.
   Do not send activation, clock-setting, reset, key-setting, calibration,
   threshold, binding-change, or other administrative commands.

**Offline preparation stop point reached.** No new airtime was used. The next
bench can resolve the address/auth/data gates; transport-only success is not
treated as completion of live glucose or registry integration.

## Unknowns and next work

1. Extend the one-candidate `FF30`/`FF31`/`FF32` evidence to exact firmware and
   advertisement rules before general compatibility claims. The wrapper-only
   DEX search is superseded by protected DEX recovery and the Mac GATT probe.
   Radio is released; any further physical work needs a new BLE GRAB.
2. Complete the live auth/data gates above and extend opcode-only correlation
   to exact response semantics, fragmentation, and freshness before live parsers
   or writes are integrated into a driver.
3. Establish firmware selection, authentication prerequisites, and side
   effects. Do not infer GS1 secrets or activation semantics from GS3 symbols.
4. Separate raw records from computed glucose. Establish time base, units,
   algorithm version, sensitivity/context requirements, validity, and stale
   data rules before publishing any value.
5. Extend the synthetic parser tests with validated exact-model interpretation,
   then an explicit Mac bench composition. Use one shared registry; prevent automatic writes and retries
   until their semantics and authorization are established.
6. Obtain the required posted BLE GRAB before radio work. Keep raw evidence,
   names, addresses, sensor identifiers, and readings in protected local
   artifacts. Commit only redacted conclusions and synthetic fixtures.

No vendor implementation was ported. Review provenance and license terms
before a future port or binary use. Native algorithm availability is not
permission to bundle it.

## Verification and integration readiness

The pinned SDK reports Dart 3.11.4. The Flutter launcher could not update its
SDK cache stamp inside the filesystem sandbox, so package checks used its
existing Dart executable directly. Initial Pub resolution hit a cache-metadata
write restriction; the offline retry with cache-write permission passed.
`--offline` remained set. No packages were fetched from the network.

From `packages/cgm_cbio`, with
`dart_bin=/Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart`:

| Exact command | Result |
| --- | --- |
| `env CI=true "$dart_bin" --suppress-analytics pub get --offline` | Passed using local cache |
| `env CI=true "$dart_bin" --suppress-analytics format --output=none --set-exit-if-changed lib test` | Passed; 3 files, 0 changed |
| `env CI=true "$dart_bin" --suppress-analytics analyze --fatal-infos` | Passed; no issues |
| `env CI=true "$dart_bin" --suppress-analytics test --reporter expanded` | Passed; 4 tests |

At the repository root, `sh -n scripts/flutter-workspace.sh`,
`shellcheck scripts/flutter-workspace.sh`, and `git diff --check` passed.
The native workspace runner now includes `packages/cgm_cbio`. No application
manifest, app lockfile, native project, or other sensor package was changed.

`make check` was not run: its tool bootstrap can download missing tools and its
build lanes can resolve native dependencies. This offline slice uses the
existing package-check commands above and does not claim full workspace or
native-build validation. The app was not launched.

Full workspace `make check`, independent review, physical GS1 evidence, and
macOS BLE validation are required before a live integration or compatibility
claim. No release or PR publication was performed in this offline slice.

Rollback: remove `packages/cgm_cbio` and its workspace enumeration. The app
has no dependency on it, and no sensor, stored data, or platform configuration
has changed.
