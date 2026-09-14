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
  queries, then a second GRAB for one encrypted authentication and gated reads.
  Later GRABs on 2026-09-10 authorized one guarded activation and its prepared
  clock/readback path, with no retries. The 12:12 attempt stopped before
  connection; the 16:07 attempt authenticated but stopped at the inactive-state
  gate. Neither sent activation. Reset and other sensor administration remain
  excluded.

All inspection used shell tools. The initial static work used local files;
no app, vendor binary, or radio was started during that phase. Before radio
operation, the competition requires `BLE GRAB @Codex — Cbio GS1` to be posted
in OpenGlucose Competition, then `BLE RELEASE @Codex` when done (15 minutes
maximum unless extended). The user subsequently confirmed the posted GRAB at
approximately 17:56 BKK on 2026-09-09, expiring at 18:11 BKK. This document
does not itself grant or acquire the radio.

**Current activation status, 2026-09-11: one activation confirmed; radio released.**
The 02:55 BKK lease reached the known GS1. One journaled `07` and one clock
`03` returned success ACKs; time information echoed the activation epoch.
The activation journal is retained: **never send another `07` for this attempt**.
Storage grew while `last_index` stayed zero. An `08` success ACK is not a
glucose record. The later read-only 03:04 lease ended at 03:14:05 BKK with
another `08` success ACK and no record frames. It sent no activation or clock
write. Further physical work requires a new posted GRAB.

**2026-09-11 continuous read result: 542 raw records; radio released.**
The bridge confirmed the next Competition GRAB and that the other contender
yielded. One `08` delivered 538 replay records and four fresh minute records
on one connection. The connection ended at 11:58:19 BKK, before the observation
limit and lease deadline. No activation or clock write was sent. The packed
glucose fields are all zero; the app uses a separate algorithm on current and
temperature. **No validated mg/dL result yet.**

**State interpretation remains unresolved.** The
16:07 lease returned `F0/02 = FF`; the offline trace below proves unsigned
transport of that value but does not establish its state meaning. The old
activation plan remains historical and blocked. Dom's explicit lease override
authorized the one completed activation; it did not establish a state enum.
The recovered app receive path now has a bounded no-consumer proof: both
concrete listeners use the callback that discards `ActivationResult`. No
exact-firmware state definition has been identified in the local material.

The scaffold reserves `cbio` and declares no capabilities. Its pure discovery
mapper now returns an unverified candidate for `FF30` advertisements; it still
fails scan/connect with an identifier-free error. It has no transport reference,
decryption, live session, or app registration. Tests use only synthetic input. The
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

### Prepared physical attempt (executed in the second GRAB below)

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

## Second authorized Mac attempt: authentication passed; reads failed

The user confirmed a new BLE GRAB at approximately **19:34 BKK on
2026-09-09**, with a hard expiry at **19:49 BKK**. The private probe started
at **19:43:24**, connected at **19:43:28**, and unsubscribed/disconnected at
**19:44:22 BKK**. The process then exited, and BLE RELEASE was reported.
This used about 58 seconds of the lease, including filtered reacquisition.
No further radio operation ran during the following offline inspection.

The bench reacquired only the previous CoreBluetooth target through the `FF30`
filter. It confirmed model `GS1`, `FF31` notification support, and `FF32` write
support. Two reads of the same target's `2A25` returned the same six-byte,
nonzero/non-all-ones value. The Java reverse-to-address/reverse-to-auth roundtrip
preserved those bytes. This validates a stable same-target address source and,
with the subsequent successful auth, supports this address order on the tested
unit. It does not independently establish an advertisement MAC layout.

CoreBluetooth reported ATT MTU **247** and a with-response write limit of
**512** bytes. The 26-byte auth request therefore fit one ATT payload; no
application fragmentation was used. After subscribing and a two-second passive
interval, the probe sent exactly one encrypted `01` request with selector zero.
The gate required a newly received, complete five-byte reply, correct length
and checksum, echoed opcode `01`, and result `1`. It passed before either read
query was sent. RC4 restarted at offset zero for each request and notification.

| Request | Wire length | Reply length | Result / raw status | Outcome |
| --- | --- | --- | --- | --- |
| Encrypted `01`, selector 0 | 26 | 5 | `01 00` | Authentication success ACK |
| Encrypted `F0`, selector 0 | 4 | 5 | `00 02` | Failure ACK; no information payload |
| Encrypted `0A`, index 0, second argument 0 | 7 | 5 | `00 04` | Failure ACK; no glucose payload |

All three notifications passed exact `L + 1` length and sum-to-zero integrity
checks. Each query had a 25-second listening interval. There were exactly three
notifications, all ACKs; **zero packed data frames and zero glucose records**.
No retry, auth-mode switch, activation, clock update, reset, key change,
calibration, or binding command was sent. A successful authentication and ATT
write do not establish a successful read or live glucose support.

The script and raw capture remain in the private scratch directory as
`mac_auth_probe_1934.py` and `mac-auth-1934-private.json`. The capture was created
with umask `077`; its checked mode is `0600` under the `0700` directory. It holds
raw address/auth/request/notification evidence and must not be committed or
copied into public fixtures. Console output contained only redacted protocol
metadata. This temporary directory remains vulnerable to reboot cleanup.

### Offline consequence and next gates

The `0A` failure changed from pre-auth raw status `3` to post-auth raw status
`4`. Reinspection of native `get_errocode` at `0x7e88` confirms that command
`0xc00b` maps raw `4` to error `2` through `0x7eb8`. A semantic label for error
`2` is still unverified: it must not be called an invalid index, empty history,
inactive sensor, or permission failure without more evidence. The `F0` raw
status `2` likewise remains an unlabelled failure.

Two concrete offline leads now precede another physical attempt:

1. Trace the information selector from `ProximityService.c.c()`
   (`ProximityService.java:313`) through `q.b.P1()` (`q/b.java:946`). The native
   builder `v120_device_information` at `0x6808` emits `03 F0 selector C` but
   does not validate the selector. The information data branch checks a
   selector-derived range of 1–10 at `0x7530`–`0x753c`; this makes selector zero
   suspect, but does not yet prove which requested selector is appropriate.
2. Trace firmware/mode and initial-index selection before another `0A` query.
   The version dispatch immediately before `q.b.P1()` selects `a2(index)`
   (`V120RawData`) for version 2.0/2.1 and, for later versions, when `X0() == 0`.
   It selects `U1(index)` (`V120Glouse`) for the other later-version mode.
   `X0()` returns static `e0` (`q/b.java:1057`). Thus the existence of a packed
   glucose builder does not prove that this firmware/mode uses it. Establish
   the mode, index origin, raw-query frame, and its decode path from GS1 evidence
   before preparing a replacement read. Do not parse raw records as packed
   `0A` records or infer their units from GS3.

The package remains unchanged: pure discovery and offline plaintext inspection,
with no BLE transport, credentials, live session, or glucose publication. The
existing scoped package work is committed as `3c47637`. This follow-up changes
only this redacted evidence document. The private probe passed
`python3 -m py_compile /tmp/cbio-re-20260909/mac_auth_probe_1934.py`; the recorded
physical result is the evidence above, not a simulated glucose success.

**Radio released; live glucose and registry integration remain unfinished.**
At this stop point the revised read path was not yet ready for another GRAB.
The following offline pass completes its selector, firmware/mode, and index
preparation; it does not claim a successful physical read.

## Offline read correction after the second GRAB

**Next read attempt prepared; awaiting a new BLE GRAB.** No scan, connection,
BLE import, or sensor command ran in this pass. The two concrete corrections
are a supported information selector and a firmware-selected raw-data query
starting at index 1. Live glucose and app registry integration remain unfinished.

### Information selectors and control replies

The Java information argument is passed unchanged through
`q.a.g0(device, selector)` (`q/a.java:790`), `jo4.t()` (`jo4.java:336`),
`ProximityService.c.c()` (`ProximityService.java:313`), and `q.b.P1()`
(`q/b.java:946`) to `V120DeviceInformation`. Native `0x6808` builds
`03 F0 selector C`. There is no builder-side selector validation. The upper
app's `LocalBleServiceV3.CGMSystemMessage()` remains protected/native, so this
does not establish the app's complete preferred order of information reads.

On receive, `0x723c` routes `F0` to `0x74dc`; the checked byte at frame offset
2 is the information selector. Table `0x110fe` dispatches selectors 1–10 to:

| Selector | Native destination | Native information type |
| --- | --- | --- |
| 1 | `0x7558` | Sensitivity, `0xc01b` |
| 2 | `0x7b7c` | Activation state, `0xc02b` |
| 3 | `0x7bbc` | Device time and last index, `0xc03b` |
| 4 | `0x7c18` | Storage state, `0xc04b` |
| 5 | `0x7c6c` | Calibration information, `0xc05b` |
| 6 | `0x7cbc` | Secret-key information, `0xc06b` |
| 7 | `0x7d0c` | Reset information, `0xc07b` |
| 8 | `0x7d68` | Glucose thresholds, `0xc08b` |
| 9 | `0x7db0` | Oscillator information, `0xc09b` |
| 10 | `0x7df0` | Watchdog information, `0xc0ab` |

Selector zero falls through without a supported information result. Thus the
earlier zero-selector request was not a validated general-information query.
This is a concrete request defect; the phrase “invalid selector” is still not
a verified firmware label for raw status `2`. Also, `F0` does not enter the
native generic-ACK branch: the captured five-byte `F0/00/02` is preserved as
a control failure, not assigned a native ACK JSON error code. A five-byte
`F0/02/value` has an activation-information interpretation in the native code;
packet size alone must not classify every `F0` reply as an ACK.

Only selectors 4 and 3 are prepared for the next attempt. They are information
reads, distinct from activation, clock-setting, or other administrative writes.
No selector sweep or secret-key query is prepared.

| Query plaintext | Expected data reply | Fields before checksum |
| --- | --- | --- |
| `03 F0 04 09` | `08 F0 04 ... C`, 9 bytes | Offset 3: `u8storage_status`; 4–5: LE16 `u16storage_number`; 6: `u8config_times`; 7: `u8key_times` |
| `03 F0 03 0A` | `13 F0 03 ... C`, 20 bytes | 3–4: LE16 `u16startover_time`; 5–8: LE32 `iactivation_time`; 9–12: LE32 `icurrent_time`; 13–16: LE32 `ilast_time`; 17–18: LE16 `u16last_index` |

The exact accepted sizes are derived from the complete fixed field layouts
plus the final checksum. They are strict local parser requirements, not a
claim that the native code checks all bounds. Evidence: field loads at
`0x7bbc`–`0x7c40`, JSON converters at `0xa5cc` and `0xa724`. In particular,
storage bytes 6 and 7 are **two separate one-byte counters**, even though the
receive path copies them together with a halfword load. The JSON converter
loads each byte separately. Time values remain unsigned raw fields; neither
their epoch nor the meaning of zero/status values is inferred.

### Captured firmware selects `08`, with first index 1

Offline inspection of the prior private `2A28` captures confirms the branch
condition **major at least 2, minor exactly 1**. The exact version string stays
private. `q.b.O1()` (`q/b.java:915`) unconditionally selects `a2(index)` for
this branch, which calls `V120RawData(..., index, 0, ...)`. The `0A` packed-only
query used in the second bench did not follow that firmware dispatch.

For later minor versions, `O1()` selects raw data when `X0() == 0` and packed
`U1()` otherwise. Static `e0` starts at zero (`q/b.java:54`); `h2()` assigns it
at `q/b.java:1144`. The visible caller is in the activation flow at line 1317,
with an app mode selected by `q.a.s()` (special value 1213 selects mode 1).
This is app-side mode bookkeeping, not proof of a readable sensor mode or a
reason to activate/change an existing sensor. The captured minor-1 branch
does not depend on this variable.

`LocalBleServiceV3.R()` (`LocalBleServiceV3.java:65`–`:84`) loads the last local
glucose index, uses zero if there is no stored record, and requests
`getDataSugarFour(..., index + 1, ...)`. Thus a fresh read begins at **1**, not
0. The upper wrapper is native/protected; the recovered lower index argument
is passed unchanged. The app's broader flow also invokes activation and clock
updates (`jo4.j()`, `jo4.s()`, `ProximityService.c.d()`). Those writes are not
part of this read attempt. If the existing sensor cannot serve records without
them, stop and retain evidence instead of copying those side effects.

JNI `V120RawData` at `0x5538` passes the index as the first native argument
after the encryption flag, and zero as the second argument from `a2()`.
`v120_raw_data` at `0x6674` constructs exactly:

`06 08 LE16(index) LE16(second_argument) C`

The index-1 plaintext is **`06 08 01 00 00 00 F1`**, 7 bytes. The entire frame
uses the already-verified RC4 transform, with the stream reset per frame.
The local builder rejects zero, negative, and above-65535 indices. A native
low-bit truncation is not used to manufacture a valid index.

The `0A/00/04` failure maps to native error 2, but its exact firmware meaning
remains unknown. Wrong query family and zero index are now independently
identified mismatches. This is enough to prepare a supported read candidate;
it does not establish which mismatch caused that specific status.

### Separate raw-data record layout

The opcode table at `0x11080` maps `08` to `0x738c`. A length byte of 4 takes
the ACK path (`0xc009`); data goes to `0x7760` and emits record type `0xc007`.
These IDs differ from packed-only `0A` records and from the outer ACK ID.
Data uses the same index/time header and two-byte trailer as `0A`, but each
record occupies **8 bytes**, giving exact total length **`12 + 8*n`**.

For record `i`, set `o = 9 + 8*i`:

| Wire bytes | Preserved field |
| --- | --- |
| `o`, `o+1` | LE16 raw `temp` |
| `o+2`, `o+3` | LE16 raw `dump` |
| `o+4`, `o+5` | LE16 raw `current` |
| `o+6`, `o+7` | Same bit layout as the two packed bytes of `0A` |

The wire order is **temperature, dump, current**, while the native structure
orders temperature, current, dump. Evidence: loads/stores at `0x7820`–`0x7898`
and named JSON fields at `0xa344`. Index increases by 1, raw time by 60, and
reindex is `trailer_base + n - 1 - i`; unknown wrap is rejected. The reindex
name and arithmetic alone do not prove that it is a remaining-record count.
The length byte permits at most 30 records in this layout; actual firmware and
ATT batching limits remain unverified. Incomplete notifications are retained
privately and rejected, not joined with a guessed encryption boundary.

The embedded `glouse` integer still has no verified GS1 unit or validity rule.
`LocalBleServiceV3` also hands data to an app algorithm and tracks its context
index. Receiving an `08` record is necessary progress toward glucose, but is
not permission to publish the embedded integer as a normalized reading.

### Offline implementation and next bench gates

The package adds separate `parseCbioRawDataFrame`, `parseCbioStorageFrame`, and
`parseCbioTimeFrame` entry points. They validate complete plaintext frames,
exact selector/opcode and length, checksum, record count, and counter bounds.
They expose immutable raw fields and reject ACKs as data. The existing generic
parser acceptance and sealed `CbioFrame` hierarchy remain unchanged. No BLE,
decryption, credentials, command writer, app registration, or clinical
conversion was added.

Private `prepare_read_followup.py` has no radio/network imports. It verifies
the captured firmware branch and native dispatch tables, builds the three
query templates, tests index rejection and RC4 roundtrip, and checks synthetic
storage/time/raw-record decoding and every raw-frame truncation. It passed and
saved `next-read-followup-private.json` with private ciphertexts and these gates:

1. A newly posted GRAB, one known GS1 target, and a hard 15-minute deadline.
   Revalidate the same software branch, `2A25`, and `FF30/31/32`. Subscribe,
   send one encrypted selector-zero `01` auth, and require a fresh complete
   success reply, as in the second bench.
2. Send `F0/04`, then `F0/03`, with only one outstanding request. Require fresh
   full replies of 9 and 20 bytes, respectively, with the requested selector
   and valid checksum. ACK/control replies are not sufficient. Retain raw
   statuses. Require a positive storage number and last index at least 1
   before requesting records; this is a conservative bench gate, not a general
   sensor-state interpretation.
3. Send `08` at index 1 with second argument zero. Listen for full raw records,
   require the first index to match the request and following indices to be
   contiguous, and keep all raw fields private. Do not retry a rejected query
   or switch to `0A` for this firmware branch.
4. If valid records stop before the reported last index, permit at most two
   further reads from the last accepted index plus 1, bounded by that reported
   index. Do not repeat a range, infer index wrap, or use raw reindex as proof
   of remaining history. Stop on control failure, timeout, malformed/fragmented
   data, unknown layout, empty data, or the lease deadline. No automatic
   activation, clock write, calibration, key change, reset, or binding change.
5. Disconnect and report BLE RELEASE. Report actual records separately from
   valid glucose; units, time origin, algorithm context, and validity remain
   gates for any normalized output.

Verification from `packages/cgm_cbio`, using the pinned Dart executable
`/Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart` and `env CI=true`:
format completed (6 files); `--suppress-analytics analyze --fatal-infos` passed;
`--suppress-analytics test --reporter expanded` passed **21 tests**. Seven new
tests cover field order/stride, unsigned values, ACK/data and selector
separation, immutability, empty/maximum batches, overflow, every truncated
prefix, every single-byte corruption, and invalid byte values. Fixtures are
synthetic; the earlier 65,536 packed-bit combinations still pass. No full
native build or live read is claimed by these checks.

Final `format --output=none --set-exit-if-changed lib test` passed with 6 files
and no changes. `git diff --check`, scoped-file key/address redaction checks,
and private artifact mode checks passed. The first root `make lint` stopped
because the sandbox blocked Flutter's cache-stamp write; the permitted local
retry of `env CI=true FLUTTER_SUPPRESS_ANALYTICS=true
DART_SUPPRESS_ANALYTICS=true make lint` passed across the workspace. No SDK
change, dependency change, BLE operation, or full `make check` was performed.

## Third authorized Mac attempt: information data received; history gate empty

The user posted another BLE GRAB at approximately **00:21 BKK on 2026-09-10**,
expiring at **00:36 BKK**, and authorized the prepared authentication → storage
→ time/index → bounded `08` read path. The private probe started at
**00:24:11**, connected at **00:24:27**, and recorded the disconnect callback
at **00:24:30 BKK**. It then exited and BLE RELEASE was reported. Radio use,
including filtered reacquisition, was about 19 seconds. No further BLE
operation ran during the evidence checks below.

The known CoreBluetooth target was reacquired with the `FF30` filter. The
model and software matched the previous private captures. Two reads of `2A25`
agreed with each other and with the address used in the successful second
bench. `FF31` notification and `FF32` write properties passed, and the
negotiated limits supported the single 26-byte authentication write.

| Request | Request length | Complete reply length | Redacted result |
| --- | --- | --- | --- |
| Encrypted `01`, selector 0 | 26 | 5 | Fresh checksum-valid auth success, result/status `01 00` |
| Encrypted `F0/04` storage | 4 | 9 | Full storage data; raw storage status 0 and storage number 0 |
| Encrypted `F0/03` time/index | 4 | 20 | Full time data; last index 0, activation-time field 0, last-time field 0 |
| `08` records from index 1 | Not sent | None | Prepared positive-history gate failed |

Exactly three application requests and three notifications were captured.
All replies passed exact length and sum-to-zero integrity checks after the
per-frame transform. Storage and time replies carried selectors 4 and 3,
respectively, and matched the expected native layouts. These are **full
information data replies**, not transport completions or control ACKs. The
corrected selectors therefore progressed beyond the earlier `F0/00/02` reply.

The prepared gate required storage number greater than zero and last index at
least 1 before requesting records. Both returned zero. The script stopped at
`empty_history_gate`, unsubscribed, disconnected through the client context,
and recorded normal process completion with no exception classified as an
unexpected error. **No record query, retry, activation, clock write, mode
switch, reset, calibration, key change, or binding change was sent. Zero
glucose records were received.**

The zero fields are verified observations. They do not alone prove a labelled
activation state, empty physical memory, sensor failure, or the absence of an
additional read prerequisite. The capture does not contain an `F0/02`
activation-state reply. The `08` candidate remains physically untested, and
there is no basis here to claim that its corrected opcode/index succeeds or
fails. Another identical GRAB is not yet a prepared route to glucose: first
resolve the zero-history state from supported GS1 state semantics or an
authorized source of existing active history. The excluded administrative
writes require their own verified scope before any physical attempt.

### Private evidence and verification

The new scratch artifacts are `mac_read_probe_0021.py`,
`mac-read-0021-private.json`, and `verify_0021_capture.dart`. The JSON was
created under umask `077` and remains mode `0600` in the mode-`0700` scratch
directory. Raw identity, authentication, ciphertext, and complete information
fields remain there. Nothing from the capture was added to repository test
fixtures; only the redacted results above are recorded here.

`python3 -m py_compile /tmp/cbio-re-20260909/mac_read_probe_0021.py` passed.
The private Dart verification used the current `cgm_cbio` package to parse the
captured auth, storage, and time frames. All extracted fields agreed with the
independent private Python inspector; the verifier also checked the failed
history gate, exactly three requests, disconnect evidence, and absence of
unexpected errors. Its output contained only pass/fail metadata.

Exact successful command (no Pub resolution or network access):

```sh
env CI=true DART_SUPPRESS_ANALYTICS=true \
  /Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart \
  --packages=/Users/fungus/dev/_worktrees/OpenGlucose/feature/codex-cbio-gs1/packages/cgm_cbio/.dart_tool/package_config.json \
  /tmp/cbio-re-20260909/verify_0021_capture.dart
```

The first direct-script invocation used `--suppress-analytics`, which the Dart
VM rejected before executing the script. The successful command uses the
environment setting instead. The package code and synthetic tests were not
changed in this bench follow-up. Their prior 21-test and lint results still
describe that code; no new full-build or normalized-glucose claim is made.

**BLE RELEASE completed at 00:24:30 BKK. Live glucose remains unresolved.**

## Owner-confirmed unactivated unit: offline activation sequence

**Historical preparation status, 2026-09-10: activation attempt prepared; awaiting a new posted
BLE GRAB.** The user reports Dom's confirmation that this GS1 was **never
activated in the vendor app**. No radio operation or state-changing command
ran during this preparation. The previous empty-history diagnostic-read plan
is superseded; do not spend a GRAB repeating reads against the unactivated unit.

### What the zero fields establish

The third capture's storage number, last index, activation time, last time,
and startover field are zero. Its current-time field and configuration/key
counters are nonzero. The Python and Dart decoders agree with every captured
field. This is not an all-zero buffer or a missing-field default. Owner-confirmed
nonactivation now gives independent context for the absence of record history.

The immediate `empty_history_gate` was a conservative **bench-script condition**,
not a returned sensor error. No equivalent test was found in the recovered
`v120_raw_data` builder or visible `q.b.O1()` dispatcher. Before the owner's
confirmation, an offline diagnostic plan considered one `08` read despite zero
metadata. That plan was never run and is now explicitly retired in its private
JSON and script entry point. The next physical work is activation, not that
diagnostic read.

The separate state request is **`03 F0 02 0B`**, with expected complete reply
**`04 F0 02 state C`**, 5 bytes. Native `0x7b7c` copies byte 3 into the
`u8activation` field; `struct_to_json_cgmv120_u8activation` at `0xaac8` emits
type `0xc02b`. GS1 `ActivationResult.getU8activation()` preserves that integer.
This is an information selector, distinct from opcode `02` auth switching and
from the authentication ACK's result byte. The exact state enum is not yet
physically verified. The next bench uses pre-state 0 and post-state 1 as
explicit confirmation hypotheses, with unknown values stopping the attempt.

`u16startover_time` is a separate LE16 field in `F0/03`; GS1 Java stores it in
a `long`, but native wire width remains 16 bits. The available converter and
bean do not establish its unit, warmup duration, or reset meaning. It is not
the LE32 activation epoch. No reset/startover command, clock backdating, or
warmup bypass is included in the new plan.

### GS1 app inputs and the activate → clock → read sequence

`LocalBleServiceV3.R()` (`:65`–`:84`) calls the public library with the next
index, `(int)(System.currentTimeMillis()/1000)`, a fixed eight-character
sensitivity input, and app mode zero. The visible lower path is:

1. `q.a.s()` (`q/a.java:900`) converts the sensitivity input to a float, scales
   it by 1000, casts to `int`, and calls `jo4.j(device, index, epoch, scaled, 0)`.
2. `jo4.j()` stores index/epoch and delegates to `ProximityService.c.a()`, which
   calls `q.b.m1(index, epoch, scaled, mode)`.
3. For the captured major-at-least-2/minor-1 software branch, `m1()` at
   `q/b.java:1314`–`:1320` calls
   `V120Activation(0, encrypted, ..., epoch, scaled, ...)`. `h2(mode)` updates
   only app-side read-mode bookkeeping.
4. The later GS1 read path `jo4.s()` → `ProximityService.c.d()` (`:321`–`:326`)
   first invokes `q.b.J1()` with current UTC epoch seconds, then `q.b.O1(index)`.
   `J1()` (`q/b.java:837`) builds `V120IsecUpdate`; `O1()` selects `08` raw reads
   for this software branch. Some intervening callbacks remain protected, so
   their exact timing/retry policy is not copied into the bench.

The fixed app input's last four characters are decimal `1234`. Native
`md_sensitivity_decrypt_faction` (`0xfcb4`, numeric branch `0xfd28`–`0xfda0`)
copies those four characters, checks them against `0123456789`, converts them
as base-10, divides by double `1000.0`, and converts to float. The JNI wrapper
at `0x5b2c` returns that positive float. Mirroring the Java float multiplication
and integer cast gives the activation parameter **1234**, bytes `D2 04 00 00`.
The offline preflight derives this from the recovered GS1 call site rather
than substituting a guessed sensor code. This is an **app-derived protocol
parameter**, not a measured per-sensor calibration or proof of glucose accuracy.

JNI `V120Activation` at `0x5454` passes the low 32 bits of its Java epoch
argument as native argument 1 and the scaled integer as argument 2.
`v120_activation` at `0x6560` constructs exactly 11 bytes. The clock builder
`v120_isec_update` at `0x6448` constructs exactly 7 bytes:

| Operation | Plaintext before per-frame RC4 | Success evidence required |
| --- | --- | --- |
| Activate | `0A 07 LE32(current_UTC_epoch_seconds) LE32(1234) C` | Fresh complete `07` ACK, result 1/raw status 0, then state readback |
| Update clock | `06 03 LE32(current_UTC_epoch_seconds) C` | Fresh complete `03` ACK, result 1/raw status 0, then time readback |
| Read records | `06 08 01 00 00 00 F1` | Full validated `08` records beginning at index 1, not an ACK |

`C` makes the entire plaintext sum zero modulo 256. All request bytes use the
already-verified GS1 RC4 key with a fresh stream per frame. Actual timestamps
must be generated immediately before the future write; no captured, synthetic,
or backdated epoch is a live activation input. The bench builder restricts
timestamps to positive current-era Java `int` seconds and rejects zero, negative,
noninteger, and overflow inputs. No activation packet was sent in this pass.

GS3 independently corroborates the shapes: `og5.k()` (`og5.java:194`–`:199`)
passes its time and `(int)(sensitivity*1000)` to `V120Activation`; GS3 native
`0xa854` and `0xa73c` match the GS1 11-byte activation and 7-byte clock layouts.
`da0.java:474`–`:488` handles activation replies by calling `rl0.K()` (clock
update) and scheduling `rl0.I()` (data query) after 200 ms. That app path has
looser failure handling than the proposed bench. The bench requires explicit
success and does not copy continuation after an ambiguous or failed activation.

Native generic ACK IDs are `0xc008` for opcode `07` and `0xc004` for opcode
`03`, inside outer type `0xc00d`. Error dispatch maps activation raw 4→3 and
5→4, while clock raw 2→1 and 4→2; other values use the unknown fallback. Those
are numeric mappings, not fully verified error labels. No error is treated as
permission to retry activation or to proceed as if activation succeeded.

### Original guarded physical sequence (now blocked on state meaning)

This sequence records the plan used for the later leases. The `00`/`01`
pre/post-state values were hypotheses. The 16:07 `FF` reply did not meet the
precondition; the plan is **not ready for reuse** until that state is understood.

Private `prepare_activation_followup.py` and
`next-activation-followup-private.json` contain the prepared builders, inspected
reply handling, app-parameter provenance, and the following bounded sequence:

1. Start only in a new posted activation GRAB, with the same target/software,
   stable `2A25`, expected GATT properties, and a hard 15-minute deadline.
   Authenticate once with the previously successful selector-zero `01` request.
2. Read `F0/02` and `F0/03`. Require complete valid replies, state byte 0,
   activation time 0, and last index 0, consistent with the owner's confirmation.
   A discrepancy stops before mutation; do not reinitialize an active sensor.
3. Before any `07` write, create an exclusive private attempt journal with the
   target, baseline, UTC epoch, app-derived parameter, and request. Send **one**
   encrypted `07` packet. On timeout, disconnect, ambiguous ATT completion, or
   failure, retain that journal and stop; do not automatically repeat activation.
4. Only after its matching success ACK, send **one** encrypted `03` clock update
   with current UTC seconds and require its matching success ACK. Record each
   transition privately. A later attempt must reconcile the journal and state
   instead of repeating `07`.
5. Read `F0/02` and `F0/03` again. Require the candidate 0→1 state transition,
   activation time equal to the sent activation epoch, and current time
   consistent with the just-set clock. These are trial confirmation gates;
   a different layout/value stops without reset, reactivation, or guessed fix.
6. After confirmed activation, make at most three `F0/03` + `F0/04` metadata
   checks at least 60 seconds apart. Send the single index-1 `08` request only
   when last index is at least 1 and storage number is positive. Listen for
   complete raw records for at most 60 seconds/512 notifications. Preserve the
   raw temperature/current/dump, embedded glucose bits, and warnings privately.
7. Disconnect and report BLE RELEASE on completion, failure, or deadline. If
   activation is confirmed but records have not begun, release the radio and
   retain state for a later check **without reactivation**. Activation success,
   raw records, and valid normalized glucose remain separate outcomes.

The proposed `07` and `03` writes change sensor state. They were excluded from
the previous read-only GRABs and have not yet been executed. The user now asks
for this concrete activation sequence and will post the next GRAB; this
document does not itself start that lease. No key/binding change, calibration
command, reset, firmware operation, auth-mode switch, or warmup bypass is
prepared. Native/app algorithm context and measurement validity remain required
before any result can be published as live glucose.

### Offline tests and boundary

The package adds `parseCbioActivationFrame` for selector-specific `F0/02`
inspection and `parseCbioStartAckFrame` for an explicitly expected `07` or `03`
ACK. All raw state/result/status values are retained, with no inferred enum or
permission to write. The existing generic parser and sealed frame hierarchy
are unchanged. No command builder, key, BLE transport, or activation API was
added to `cgm_cbio`; all preparation builders remain private and offline.

New synthetic coverage includes all 256 activation bytes, state-versus-control
separation, zero history alongside an independent nonzero clock/counters,
expected-opcode correlation, unknown ACK results, truncation, corruption,
oversize replies, and invalid byte values. Private preflight also verifies
GS1/GS3 header instructions, the app parameter's numeric/float path, LE32 field
order, exact packet lengths, checksums, timestamp bounds, and RC4 roundtrip.
No vendor library or protected app code was executed. The protected Java
`patch` payload remains a limit on full callback/state-enum recovery; candidate
decoding work did not establish additional state semantics.

Final package verification, with the pinned Dart executable and `env CI=true`:

| Command | Result |
| --- | --- |
| `dart --suppress-analytics format --output=none --set-exit-if-changed lib test` | Passed; 6 files, no changes |
| `dart --suppress-analytics analyze --fatal-infos` | Passed; no issues |
| `dart --suppress-analytics test --reporter expanded` | **25 tests passed** |
| `python3 /tmp/cbio-re-20260909/prepare_activation_followup.py` | Offline activation preflight passed |
| `python3 -m py_compile /tmp/cbio-re-20260909/prepare_activation_followup.py` | Passed |
| `git diff --check` | Passed |

Scoped key/address redaction, private artifact modes, and retirement of the old
diagnostic-read plan were checked. Workspace lint passed in the earlier read
parser pass; this last extension was checked with the package analyzer above.
No full `make check`, native build, or physical activation result is claimed.

**Historical stop point:** the activation sequence was prepared with no BLE
used in that offline pass. The later 16:07 evidence and FF trace below supersede
its readiness status; another GRAB alone does not resolve the state gate.

## Guarded activation lease: 2026-09-10, 12:12 BKK

The user confirmed the posted GRAB at approximately **12:12 BKK**, with a hard
expiry of **12:27 BKK**, and explicitly authorized one `07` activation using
current UTC seconds and the app-derived parameter `1234`, followed by ACK and
state readback. No retry or empty-history read was authorized. The prepared
private probe included exact known-target/software/serial checks, successful
authentication, inactive-state readback, and an exclusive, fsynced attempt
journal before any activation write. It also bounded the clock/readback and
positive-history-only record path. None of those connected stages was reached.

| Event or gate | Redacted result |
| --- | --- |
| Probe start | 2026-09-10 **12:17:37 BKK** |
| Reacquisition | One known-target scan, filtered by `FF30`, with a 40-second timeout |
| Stop | **12:18:18 BKK**, `target_not_rediscovered` |
| Connections / disconnects | 0 / 0; no connection was established |
| Auth / activation `07` / clock `03` writes | **0 / 0 / 0** |
| Information / history queries | **0 / 0** |
| Notifications / raw records / validated glucose | **0 / 0 / none** |
| Activation attempt journal | Absent; the pre-write gate was never reached |
| Retry | None |
| Radio disposition | Probe exited; **BLE RELEASE** announced before lease expiry |

This result establishes only that the known target was not reacquired during
this scan. It does not establish why it was absent, its current activation
state, or whether the activation command works. No new ACK or state evidence
exists. The owner-confirmed never-activated history and the earlier zero
metadata remain the last available evidence, not a fresh state check.

Verification: `python3 -m py_compile` passed for the private lease script. An
offline capture check found exactly `start`, `stop_gate`, and `finished`
events, with the stop reason above; no request, connection, or notification
events and no activation journal were present. The private directory and
capture modes were checked as `0700` and `0600`. Only these redacted results
are stored here. No package code changed in this lease, so the existing
25-test result above remains the latest package verification; no new parser
or glucose claim is made.

The activation sequence remains prepared but physically untested. Before a
future attempt, the known unit must be available for reacquisition and a new
BLE GRAB must be posted. Repeat all identity and inactive-state gates in that
future lease; this expired lease grants no further radio work. Preserve the
exclusive no-retry journal rule before any eventual `07` write.

## Guarded activation lease: 2026-09-10, 16:07 BKK

The user posted a new GRAB at approximately **16:07 BKK**, expiring at
**16:22 BKK**, and authorized the prepared sequence: auth, inactive baseline,
one `07` with current UTC seconds and parameter `1234`, one `03` clock write,
state readback, then `08` only if records exist. The repeated GRAB message was
treated as the same lease. The earlier capture was preserved; the new private
probe reused the same exclusive activation-journal guard and made no retry.

**Outcome: known-target authentication passed; activation was not sent.**
The first physical `F0/02` information reply contained raw state **`FF`**, not
the prepared gate's hypothesized `00`. The complete `F0/03` reply still had
zero activation time and last index. The probe stopped and disconnected without
changing the gate to fit the observation.

| Event or gate | Redacted result |
| --- | --- |
| Probe start | 2026-09-10 **16:09:24 BKK** |
| Connection | **16:09:37 BKK**, known target reacquired with the `FF30` filter |
| Identity | GS1 model, exact prior software, stable matching six-byte `2A25`, expected GATT and write-length gates passed |
| Auth `01` | One 26-byte request; valid 5-byte ACK, result/status **`01 00`** |
| Baseline `F0/02` | One 4-byte request; valid 5-byte information reply, raw activation **`FF`** |
| Baseline `F0/03` | One 4-byte request; valid 20-byte information reply |
| Time metadata | Activation time, startover, last time and last index all **0**; current time nonzero |
| Stop reason | `inactive_baseline_gate` |
| Disconnect and finish | **16:09:40 BKK**; disconnect callback recorded |
| Activation `07` / clock `03` / history `08` writes | **0 / 0 / 0** |
| Activation journal / retries | No journal created; no retries |
| Notifications / raw records / validated glucose | **3 / 0 / none** |
| Radio disposition | **BLE RELEASE** announced after disconnect, before lease expiry |

All three replies passed complete-frame length and additive-integrity checks.
`F0/02` is selector-specific information, not an authentication ACK or an
activation rejection. State `FF` is retained as an unsigned byte; neither
"active" nor "inactive" is established for it. The owner's never-activated
confirmation and the zero metadata do not validate the earlier `00` state
hypothesis. No result for opcode `07` or post-activation state can be claimed.

The immediate offline task is to trace `FF` (including possible signed `-1`
comparisons) through the exact GS1 Java/native activation-state path and
establish the correct precondition before another physical activation attempt.
Do not replace the guard with `FF` merely because this capture contains it.
The sensor was available in this lease; the unresolved state interpretation is
now the blocking condition. A new GRAB is required for any further radio work.

Verification used the unchanged public offline parsers against the private
capture. Auth, activation state and every time field agreed with the Python
inspection. The verifier also required exactly the three expected request
phases, a disconnect callback, the inactive-state stop, no error event and no
activation journal. No raw input was copied into repository tests or docs.

| Command/check | Result |
| --- | --- |
| `python3 -m py_compile /private/tmp/cbio-re-20260909/mac_activation_1607.py` | Passed |
| `env CI=true DART_SUPPRESS_ANALYTICS=true /Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart --packages=packages/cgm_cbio/.dart_tool/package_config.json /private/tmp/cbio-re-20260909/verify_1607_capture.dart` | Passed; all three captured replies and stop conditions verified offline |
| Capture inventory | Exactly three requests and three notifications; no activation, clock or history request |
| Private artifact modes | Scratch directory `0700`; probe, capture and verifier `0600` |

`packages/cgm_cbio` remains unchanged in this lease, with no transport or
activation builder. Its prior 25 synthetic tests already cover every raw
activation-state byte, including `FF`; no additional enum or glucose claim is
introduced. The full suite was not rerun for this documentation-only update.

## Offline FF trace after the 16:07 lease

**Verified cause of the stop:** `inactive_baseline_gate` was raised by the
private bench predicate, not by the GS1. The predicate required state `00`
**and** zero activation time **and** zero last index. The actual values were
`FF`, zero and zero, so its first condition failed. The time response did not
contradict the state response: these are separate selectors and fields, with
no visible decoder rule deriving one from the other. Their combination does
not define a state enum.

The static trace now extends past the Java decompiler gap:

| Stage | Exact local evidence | Established behavior |
| --- | --- | --- |
| GS1 wire state to native struct | `libdata-handle-lib.so`, `0x7b7c`–`0x7b90` | `ldrb w8, [sp, #0x423]` loads frame byte 3; `strb` stores it; information type is `0xc02b` |
| GS1 struct to JSON | `struct_to_json_cgmv120_u8activation`, `0xaac8`; load at `0xaadc`; key at `0x1133b` | `ldrb w2, [x19]` passes unsigned **255** to `cJSON_AddIntToObject` under `u8activation`; no boolean or signed-byte conversion |
| GS1 JSON receive branches | Recovered `sijoy-section-2.dex`, `q/c.smali`, method `e()`, labels `:cond_52b` and `:cond_b5d` | Both type-`c02b` branches use Gson to create `ActivationResult`, then call `q.a.r(device, 3, 0, 0, object)`; neither reads or compares the state field |
| GS1 app callback forwarding | `q/a.java:889` and matching DEX instructions | Calls `ConnectListener.CGMSystemMessage(device, 3, object)` without a state check |
| GS1 value access | `ActivationResult.java:36` and `sijoy-section-1.dex` getter | Returns an `int` field unchanged; no cast to Java `byte` |
| GS1 app consumer | `LocalBleServiceV3.java:144`; `LocalBleServiceV3.smali:572` | `CGMSystemMessage` is marked `native` and has no DEX instruction body |
| GS3 corroboration | `libdata-handle-lib2.so:0x119c0`; `og5.java:371`; `da0.java:491`; `yy4.java:11` | Also serializes an unsigned byte and forwards an `ActivationResult`; its app information callback uses selector **2**, not the GS1 callback type **3** |

The GS1 `q.c.e()` method was present in DEX but missing from JADX's normal
Java output. Direct disassembly recovered the two forwarding branches above.
The disassembler came from the already installed JADX jar; no tool or package
was downloaded. Both recovered GS1 payload DEXs were disassembled. Their
visible instructions contain **zero calls to `getU8activation()`**; direct
field access is confined to the bean's getter/setter. This is a statement
about the recovered code, not proof that the protected app ignores the value.

Thus `FF` is **not converted to signed `-1` in the verified wire → JSON →
bean → callback path**. At this stage, a comparison or cast inside the protected
callback remained unknown. GS3's app consumer is also a protected native method; its
visible forwarding path does not supply the missing GS1 enum. The remaining
NetEase `patch` payload was not decoded/applied in this pass. No callback body
or firmware state definition was recovered from it.

There is no verified basis here to label `FF` as inactive, active, erased
flash, an unsupported-state sentinel, or a sensor error. In particular,
"erased flash is often FF" is not evidence of this firmware's meaning.
The owner-confirmed nonactivation remains useful independent evidence, but
does not supply the missing protocol definition requested for the guard.

**Decision:** leave both activation-gate predicates unchanged; no `07` retry,
no state write, and no BLE. Mark the private activation plan
`offline-blocked-activation-state-FF-unresolved`; its preparation script now
prints **NOT READY**, even when the packet-builder checks pass. The former
state-`00`/post-state-`01` assumptions remain recorded only as hypotheses.
`packages/cgm_cbio` retains raw state bytes and has no activation policy or
transport. A revised physical sequence is not ready.

The next required evidence is the protected GS1 callback/state comparison or
an exact-firmware state definition. The identified recovery boundary is
`LocalBleServiceV3.CGMSystemMessage(device, 3, ActivationResult)` and its
protected callees. A new radio attempt or a guessed enum does not close it.

Verification in this offline pass:

| Command/check | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/trace_activation_ff.py` | Passed: exact unsigned-load instructions and JSON keys in both libraries, all 256 synthetic state bytes, both GS1 callback branches, getter behavior, protected-method boundary, captured failed gate and zero `07` writes |
| `python3 /private/tmp/cbio-re-20260909/prepare_activation_followup.py` | Existing packet/parameter/integrity preflight passed; plan regenerated as **not ready**, with no gate relaxation |
| From `packages/cgm_cbio`: `env CI=true /Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart --suppress-analytics test --reporter expanded --name 'activation information\|zero history'` | **2 tests passed**: all state bytes retained; zero history preserves independent clock/counters |

The callback recovery below supersedes this pass's unresolved Java boundary;
it does not establish an activation-state enum.

No vendor executable was run, no health reading was normalized, and no private
capture was added to source or fixtures. Public package code did not change.

## Protected GS1 callback recovery: 2026-09-10, offline

**Result: the recovered `LocalBleServiceV3.CGMSystemMessage` body discards
both the message type and result object. It logs a device-name message and
returns. There is no `FF`, `255`, or signed `-1` comparison in this callback.**
This closes the requested callback trace, but does **not** define what the
GS1 firmware means by `F0/02 = FF`. The activation plan remains **NOT READY**.
No BLE operation, gate change, or `07` write was made in this pass.

### Recovery and structural checks

The NetEase `patch` was decrypted offline using the `addition.data` metadata
field `r` combined with the loader's first key literal, followed by RC4. Key
material and all recovered vendor code remain private. The clear patch has
a count/data-base header and delta-ULEB pairs that identify a DEX encoded
method's `code_off` field and its replacement code item. This is distinct
from the outer archive and DEX-header decryptions described earlier.

| Artifact | Verified recovery |
| --- | --- |
| GS1/sijoy patch | **17,751** entries; all map to original section-1 DEX method slots |
| GS3 patch | **20,535** entries; all map to original section-1 DEX method slots |
| Replacement bounds | Every replacement has the original reserved code-item length, including exception-handler data; no overlapping replacements |
| Derived DEX checksums | SHA-1 and Adler-32 recomputed for the analysis copies; this does not restore or validate an APK signature |
| GS1 callback in patch | No match: method ID **5225**, `code_off` field **5268594**, remains native with zero code offset in original section 2 |
| GS1 section-0 metadata | **48** records; alignment, lengths and code-item bounds consume all **7,756** bytes exactly |

The additional method bodies are in section 0 of `addition.data`, not in
the section-1 patch. Each record holds a short parameter/return-type string,
access flags, a tag and a code item. The opcodes are permuted. Reading them
as normal DEX instructions gives invalid results.

The recovered ARM64 loader dispatches an encoded opcode through the 256-entry
`u16` table at **`0x188aa`**:
`handler = 0xb31d4 + 4 * table[encoded_opcode]`. The private decoder maps
the instruction kinds used in the 48 records; all bodies decode to their
declared code-unit boundaries. It does not claim support for every protected
opcode or a different loader build.

All 48 metadata records match the 48 native methods with five-byte access-flag
slots in GS1 DEX section 2, in encoded-method order. Every short type string,
original access flag, consecutive tag and input-register width agrees.
Record **25**, tag **`0x01000019`**, therefore maps to
`LocalBleServiceV3.CGMSystemMessage(BluetoothDevice, int, Object)`.
Its 16-byte code-item header also has exactly one match in the original DEX,
at **`0x21d98c`**; that original instruction span is zeroed. This is a static,
structurally checked method mapping, not an executed JNI registration trace.

### Complete callback and callees

The recovered callback code item is **66 bytes**: a 16-byte header and
**25 code units / 50 instruction bytes**, comprising **11 instructions**.
It has four registers, four input registers, two outgoing argument slots and
**no exception handlers**. At entry, `v0=this`, `v1=device`, `v2=message type`
and `v3=result object`.

| Code-unit offset | Established action |
| --- | --- |
| `0000`–`0002` | Replace `v2` with a new `StringBuilder` and initialize it; the message type is discarded before use |
| `0005`–`0007` | Replace `v3` with a fixed log prefix and append it; the result object is discarded before use |
| `000a`–`000e` | Call `LocalBleService5AbstractV3.u(device)` and append its returned string |
| `0011`–`0015` | Convert the builder to a string and pass it to `hm.e(String)` |
| `0018` | Return; no state read, cast, branch, switch, event forwarding or protocol command |

The seven required opcode mappings were checked against the ARM64 handlers:
encoded `56/81/35/2C/09/57/AA` correspond to `new-instance`, `invoke-direct`,
`const-string`, `invoke-virtual`, `move-result-object`, `invoke-static` and
`return-void`. The private verifier checks the complete callback instruction
sequence and resolves its type, string and method references against DEX 2.

`LocalBleServiceV3` does not override `u(BluetoothDevice)`. The inherited
method checks a Bluetooth permission and returns either the device name or
a permission-message string. It does not receive `ActivationResult`.
`hm.e → g → f → o → n` passes the string to the `fz1` logging helper.
Its string/clock/logging branches do not receive or inspect the discarded
state. Actual device names were not added to this document or fixtures.

The restored section-1 bean code also preserves `u8activation` as an `int`
through parcel read/write and string formatting. No activation getter call
was found in either recovered GS1 DEX instruction set or any of the 48
decoded metadata bodies; field access stays inside the bean. This finding
is scoped to these recovered artifacts, not to all app versions or firmware.

### Activation decision and verification

For this consumer, callback type `3` has **no activation-specific branch**.
The app's lack of a comparison cannot establish an inactive enum. The observed
unsigned `255` still reaches the callback unchanged and is then discarded;
the zero time/index fields remain separate evidence. Neither `FF = inactive`
nor the old `00`/`01` hypotheses is verified by this code.

Keep the blocked plan and both existing predicates unchanged. Do not remove
the raw-state gate because this callback ignores the value. A revised physical
sequence requires a state definition from the exact firmware/protocol or
another identified consumer that actually interprets this field. This callback
is no longer an unresolved protected body that can supply that definition.

All commands below used existing local tools. The Java decoder is an analysis
utility using the installed JADX dexlib; it does not execute vendor methods.

| Command/check | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/map_patch.py` | Both patches restored; all slot, length and nonoverlap checks passed |
| `python3 /private/tmp/cbio-re-20260909/decode_metadata.py` | All 48 structural method matches and code bounds passed; 63 encoded instruction kinds used |
| `java -cp /private/tmp/cbio-re-20260909:/opt/homebrew/Cellar/jadx/1.5.4/libexec/lib/jadx-1.5.4-all.jar InspectMetadata /private/tmp/cbio-re-20260909/sijoy-section-2.dex /private/tmp/cbio-re-20260909/sijoy-section-0-standard.bin` | All 48 bodies decoded; output redirected to a private file |
| `python3 /private/tmp/cbio-re-20260909/verify_callback_boundary.py` | Complete callback, callee boundary, preserved header, blocked plan and private modes passed; no activation journal |
| `python3 -m py_compile /private/tmp/cbio-re-20260909/map_patch.py /private/tmp/cbio-re-20260909/decode_metadata.py /private/tmp/cbio-re-20260909/verify_callback_boundary.py` | Passed |
| `git diff --check` | Passed |

`packages/cgm_cbio` did not change in this pass. No state-enum test was added
because no enum was verified. The prior all-256-state parser coverage remains
applicable; this documentation/static-analysis pass does not claim a new full
package run, full workspace validation, activation success or live glucose.

## Other GS1 state consumers: 2026-09-10, offline

**Result: no activation-state interpretation exists in the recovered GS1
application receive path examined here.** Both concrete listener classes
resolve to the same discard-only callback. This is a bounded code-flow proof
for the local sijoy build, **not** proof that no vendor firmware, server,
other app build or dynamically supplied code can interpret `FF`.
The byte's meaning remains unresolved; the activation plan is **not
GRAB-ready** and both gate predicates remain unchanged.

### Consumer census and terminal flow

The audit covers all **13,831 class definitions** from the restored GS1
section-1 DEX (**9,335**) and section-2 DEX (**4,496**), including classes
with package-private access. These counts agree with the DEX headers. It also
checks the **48** recovered protected method bodies and the original wrapper
DEX. The local APK reports version **`01.20.01.00`**, code **33**; this is an
app version, not the connected sensor's firmware version.

| Search or edge | Verified finding |
| --- | --- |
| All `ConnectListener` implementations, including inherited interfaces | Two concrete classes: `LocalBleServiceV3` and `LocalBleServiceProxy`; their shared base is abstract |
| Proxy callback | `LocalBleServiceProxy` extends `LocalBleServiceV3` and only supplies its constructor and `onBind`; it does not override the state callback or device-name helper |
| Callback declarations | Only the interface declaration and the previously recovered service implementation |
| Listener registration | Recovered `LocalBleServiceV3.P()` (metadata record 32) passes `this` to `setOnSibListener`; metadata record 20 forwards to `q.a.H`, which sets the sole static listener field `q.a.o` |
| Other writes to `q.a.o` | Only `q.a.z0()`, which clears it to null; no second application listener registration found |
| Activation object producers | Both `q.c.e()` type-`c02b` branches construct the bean with Gson and call `q.a.r(device, 3, 0, 0, object)` |
| Branch exits | Neither branch stores the object in a field or array. Both go to `:goto_e57`, which removes the processed queue item and continues the receive loop |
| `q.a.r` | Its sole invocation is `ConnectListener.CGMSystemMessage`; no object storage, second callback, event dispatch or secondary data-listener forwarding |
| Getter/setter invocation census | **0 / 0**, across both DEX instruction sets and the protected metadata bodies |
| Direct `u8activation` field operations | **5**, all within `ActivationResult`: parcel construction, getter, setter, formatting and parcel output |
| Other references to the bean class | Only its generated parcel creator and the two receive branches; no additional state consumer |
| Raw-data callbacks | Both inherited `onDataRecive` overloads return immediately; neither concrete service overrides them |
| Secondary SDK data listener (`wn4`) | No concrete implementation in the recovered app. The activation forwarding method does not invoke this interface |

Thus an `ActivationResult` produced on either inspected receive path reaches
one implementation, which overwrites the message-type and object registers
before reading either. It cannot reach a state comparison through this path.
Generic logging and parcel serialization do not supply an activation enum.

A numeric search also found `0xc02b` in `q60`. That class is
`CipherSuite.java`: the constant names
`TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`. It is unrelated to the CGM response
type. No additional CGM dispatch consumer was found by that search.

### Native and firmware-resource search

The original wrapper DEX contains no named reference to `ActivationResult`,
`u8activation`, its callback or `ConnectListener`. Across the **27** packaged
ARM64 libraries, the state-name search finds only the three `u8activation`
occurrences in the known `libdata-handle-lib.so`; no activation bean/getter/
setter name occurs. The GS1 unsigned byte loads at `0x7b7c` and `0xaadc`, and
the JSON key at `0x1133b`, were rechecked. A native string census alone is
**not** a proof against obfuscated or unnamed native state logic.

The complete XAPK member inventory covered the base APK (**2,198** entries),
ARM64 split (**32**) and resource split (**58**). No exact-sensor firmware
image or state-definition file was identified. The base APK's 30 raw resources
are 29 audio files and one Firebase XML file. The binary/archive candidates
were accounted for as follows:

- `classes.dex` and `nedata.db`: the wrapper and recovered protected app code.
- `anchors.bin`: referenced by Huawei ScanKit alongside its detection models;
  it is not evidence of sensor firmware.
- `DebugProbesKt.bin`: a Kotlin debug-probe resource, not an identified GS1
  firmware image.
- One packaged PDF: five image-only pages. Local Chinese OCR identifies it
  as a **bundled glucose report**. It is not a verified protocol/state
  definition. No report contents, names, identifiers or readings were added
  to this document or fixtures.

`pdftotext` produced only page separators. Apple Vision OCR initially failed
inside the sandbox with a Foundation error. The same local CPU-only OCR
script succeeded outside the sandbox using system OCR resources, reading all
five pages. It made no BLE or network calls. This classification replaces the
initial assumption that the packaged PDF might be a manual; no activation
meaning is inferred from OCR keyword absence.

No tool/model download, network lookup or vendor execution was used. The
resource inventory cannot establish that an arbitrarily named or embedded
firmware payload is absent. It establishes that no local artifact has been
identified and matched to the known unit's exact firmware.

### Verification and remaining requirement

| Command/check | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/audit_gs1_state_consumers.py` | Passed: complete class census, inherited listener resolution, self-registration, both receive exits, field/call census, raw callbacks, native markers, APK inventory and unchanged blocked plan |
| `python3 /private/tmp/cbio-re-20260909/verify_callback_boundary.py` | Passed: prior complete callback recovery and callee boundary still agree |
| `swift -module-cache-path /private/tmp/cbio-re-20260909/swift-module-cache /private/tmp/cbio-re-20260909/ocr_packaged_manual.swift` | Passed outside the sandbox: local OCR of all five packaged PDF pages; output private |
| `python3 -m py_compile /private/tmp/cbio-re-20260909/audit_gs1_state_consumers.py` | Passed |
| `git diff --check` | Passed |

The new audit is private and reads local analysis artifacts. Its negative
result is deliberately limited to the recovered app route. It does not turn
`FF` into an inactive state and does not justify removing the state gate.
Further progress needs an actual state definition from a matched firmware/
protocol source or another identified consumer. The packaged report does not
close that requirement. Repeating this app callback search will not supply
the missing enum.

No BLE operation, `07`, gate relaxation or package-code change occurred in
this pass. `packages/cgm_cbio` remains offline. No enum or live-glucose test
was added because neither meaning nor glucose behavior was established.

## Explicit FF override lease: 2026-09-11, 02:48 BKK

The user posted a **02:48 BKK** GRAB with a **03:03 BKK** hard deadline and
relayed **Dom GO**: authenticate, observe the baseline without stopping on
`inactive_baseline_gate`, send one journaled `07` using current UTC seconds
and parameter `1234`, then ACK-gated clock `03`, state/time readback and `08`
only if records exist. This later instruction superseded the earlier
no-activation instruction for this lease. It was an explicit operational
exception, **not verification of an `FF` enum**.

A separate private probe preserved the historical scripts and the shared
exclusive no-retry journal. The lease-specific probe recorded the raw baseline
state without requiring `00`; it retained the known identity, exact prior
software, stable six-byte `2A25`, GATT, authentication, complete-frame integrity
and response-freshness gates. Nonzero baseline activation time or last index
would stop before a possible duplicate activation. Post-write state would be
observed without assigning an enum; exact activation-epoch readback and a
plausible current clock remained prerequisites for bounded record checks.
The historical blocked offline plan and public package policy did not change.

**Outcome: `target_not_rediscovered`; no activation attempt reached the wire.**

| Event or check | Redacted result |
| --- | --- |
| Start | 2026-09-11 **02:50:56 BKK** |
| Scan | One **40-second** `FF30`-filtered lookup for the previously known target |
| Stop and finish | **02:51:36 BKK**, `target_not_rediscovered` |
| Connections / auth requests | **0 / 0** |
| Baseline replies | **0**; no new observation of `FF` or time fields |
| Activation `07` / clock `03` / history `08` writes | **0 / 0 / 0** |
| Activation journal | Absent; execution never reached journal creation |
| Notifications / records / validated glucose | **0 / 0 / none** |
| Retry | None |
| Radio disposition | **BLE RELEASE**, after scanner completion and before lease expiry |

No conclusion about current activation state, empty history, command success
or glucose follows from a target lookup miss. No follow-up scan used the
remaining lease time. The prepared one-write path remains physically untested.

| Exact verification | Result |
| --- | --- |
| `python3 -m py_compile /private/tmp/cbio-re-20260909/mac_activation_0248.py /private/tmp/cbio-re-20260909/verify_0248_attempt.py` | Passed |
| Offline packet preflight | Existing builders reproduced exact activation/clock lengths, little-endian epoch, additive integrity and app-derived parameter `1234`; synthetic `07`/`03` success ACK parsing passed |
| `python3 /private/tmp/cbio-re-20260909/verify_0248_attempt.py` | Passed: exactly start/stop/finish events, 40-second target miss, no activation journal, private `0700`/`0600` modes, one activation call site and exclusive journal-before-write order |
| `git diff --check` | Passed |

Only redacted status and counts are stored here. The raw capture and probe
remain private. `packages/cgm_cbio` has no change in this lease; no package test
rerun or new compatibility claim is implied by this documentation update.

## Confirmed activation lease: 2026-09-11, 02:55 BKK

The user relayed Dom GO again with a 03:10 BKK deadline. The private probe
retained identity, firmware, serial, integrity and authentication checks. It
observed `FF` without the old inactive-state stop, as explicitly authorized.
The exclusive activation journal was flushed before the only `07` write.

| Event or check | Redacted result |
| --- | --- |
| Activation session | 02:56:37–02:59:56 BKK; connected 02:56:50 |
| Journal / activation / clock | Journal first; one `07` then one ACK-gated clock `03`, at 02:56:52 |
| Both write ACKs | Complete valid replies, result `01`, status `00` |
| Activation time readback | Exact match to the journaled UTC epoch; epoch kept private |
| Raw activation field | Baseline `255`, readback `60` |
| Metadata at about 60 / 121 / 183 seconds | Storage `1 / 2 / 3`; `last_index=0` throughout |
| Main session requests / notifications | `13 / 13`; no `08` in this session |
| Read-only continuation | 03:00:42–03:00:58 BKK; connected 03:00:55 |
| Continuation metadata | Storage `4`, status `00`; activation epoch unchanged, `last_index=0`, raw state `56` about 245 seconds after activation |
| Continuation query | One seven-byte `08` from index `1`; complete five-byte success ACK `01 00` |
| Continuation requests / notifications | `5 / 5`; zero record frames |
| Passive follow-up | 03:02:07–03:02:47 BKK; 40-second target miss, no connection or writes |
| Final disposition | BLE RELEASE; activation journal retained; no reactivation |

The main probe's old index guard prevented a record query even though storage
was nonzero. Its “history remains empty” console message was too broad: the
evidence is **nonzero storage with reported last index zero**. The authorized
continuation used successful nonzero storage plus the matching activation epoch
to permit one index-1 query. It did not use `last_index` as an upper bound.

The continuation reader incorrectly required a record frame immediately and
stopped at `raw_control_or_wrong_layout` on the successful `08` ACK. Thus it
did not test whether records would follow that ACK. The later passive lookup
miss did not answer that question. No live glucose was captured.

The state transition `255 → 60 → 56` supports a countdown hypothesis, but does
not prove a warmup duration, readiness enum or universal meaning of `FF`.
The nonzero raw startover field is also retained privately without an enum.
Neither observation authorizes another activation or a reset.

| Exact verification | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/verify_0255_lease.py` | Passed: one activation, one clock, one read query; journal ordering, no overlapping sessions, 18 valid complete notifications, zero records, all sessions ended before deadline |
| `env CI=true DART_SUPPRESS_ANALYTICS=true /Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart --packages=packages/cgm_cbio/.dart_tool/package_config.json /private/tmp/cbio-re-20260909/verify_0255_capture.dart` | Passed: all 13 main-session replies agree with the public offline parsers; ACK, epoch, state and journal checks |
| Python syntax checks | Main activation, read continuation and passive observer passed |

Older offline audits that assert journal absence describe the pre-activation
state. They must not be rerun as current-state checks without separating their
static proof from that historical assertion. The activation journal must not
be removed to make an old audit pass. No package code changed during this lease.

## Read-only lease: 2026-09-11, 03:04 BKK

The user posted a new GRAB after RELEASE, with a 03:19 BKK deadline. Scope
was known-target reacquisition, authentication, storage/time/state reads, one
`08` from index 1 and/or passive notification observation. Activation was
explicitly excluded. The activation journal was required and retained.

The first launch could not access Bluetooth inside the filesystem sandbox
(`BleakBluetoothNotAvailableError`). It made no connection or writes. The
same bounded operation then ran with authorized host Bluetooth access and a
separate private capture. The command allowlist permitted only auth `01`,
information `F0` selectors 4/3/2, and one journaled `08`.

| Event or check | Redacted result |
| --- | --- |
| Query session | 03:08:29–03:08:44 BKK; connected 03:08:38 |
| Identity / authentication | Known GS1, same prior software, stable six-byte `2A25`; auth result `01`, status `00` |
| Storage / time / state | Storage `12`, status `00`; matching activation epoch; `last_index=0`; raw activation `48` |
| Record request | Exactly one index-1 `08`, with a separate exclusive intent journal before write |
| Record reply | Valid five-byte `08` success ACK, result `01`, status `00`; no record frame captured |
| Query-session failure | Local `TypeError` before the observation loop; disconnect callback recorded |
| Passive follow-up | Started 03:09:57; connected 03:10:02; observation started 03:10:05 BKK |
| Follow-up metadata | Storage `14`, status `00`; matching activation epoch; `last_index=0`; raw activation `46` |
| Follow-up writes | Auth and three information reads only; no repeated `08`, no `07`, no clock write |
| Passive observation end | 03:14:05 BKK, after 240 seconds; no record notifications |
| Host sessions combined | Nine requests, nine valid complete replies, zero raw records |
| Activation / clock writes in this lease | `0 / 0`; both private journals retained |
| Radio disposition | Disconnected and BLE RELEASE at 03:14:05 BKK, before the 03:19 deadline |

The query script had been changed to accept a successful `08` ACK and continue
waiting for records. However, its timer expression accidentally retained an
outer single-argument `min(float)`, which raised `TypeError`. Syntax and source
checks did not detect that runtime error. The connection closed without a
record observation period. This is a probe defect, not a sensor rejection.

The passive follow-up used a corrected monotonic deadline and an offline test
that evaluated the timer expression. It could send only authentication and
information reads. It did not repeat the lease's `08`. A reconnect-only
observation cannot establish that a stream requested on the prior connection
will resume; absence of notifications on this connection does not prove empty
storage or failure to generate records.

| Exact verification | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/verify_0304_lease.py` | Passed: one journaled index-1 `08`, no activation/clock writes, nine RC4-checked complete replies, matching activation epochs, no overlapping sessions, disconnects before deadline, private directory/file modes |
| `python3 -m py_compile /private/tmp/cbio-re-20260909/mac_observe_0304.py /private/tmp/cbio-re-20260909/verify_0304_lease.py` | Passed |
| Offline observer preflight | Passed: AST call inventory permits only auth and information selectors; timer expression evaluated with a synthetic deadline, producing the expected 240-second bound |
| Redaction check | Passed: known target identifier, serial and new notification ciphertext absent from this document |
| `git diff --check` | Passed |

The successful-ACK path still needs a continuous-connection record observation
on a future authorized lease. Test that path with synthetic ACK-then-record
events and an evaluated deadline before using the radio again. Keep activation
blocked by its existing journal. The raw state countdown is an observation,
not a verified readiness gate. No live glucose or general sensor compatibility
is claimed. `packages/cgm_cbio` remains offline; no package code changed in
this lease. Its separate raw-data parser is not a BLE stream receiver.

## Continuous read preparation: 2026-09-11, offline after the 03:04 lease

The user requested a corrected continuous-connection record path, warmup
analysis and an alternate-poll check before another physical attempt. The
existing activation journal remains mandatory. There is no second `07`, clock
update, reset, state-enum change or public BLE integration in this preparation.

### What explains the prior wall, and what remains unknown

The two record queries do not establish that the sensor failed to stream.
The first reader stopped on its success ACK. The second closed because of a
local timer error before its observer loop. The four-minute follow-up observed
a different connection without a new query. Thus **continuous observation
after a successful `08` on the same connection has not yet been tested on the
device**. That is the next specific physical test.

The recovered app also separates ACKs from records. GS1 `q/c.smali`, branch
`:cond_41a`, handles inner reply type `0xc009` through `q.a.q()` and continues
the receive loop. `q/a.java:874` forwards the result to `CGMCmdDoReply`.
`LocalBleService5AbstractV3.java:31` only logs command success; it does not
request a disconnect, another query or record completion. The native raw
record route remains separate (`0xc007`, `12 + 8*n` bytes). The record observer
must not count a five-byte control reply as a record or a terminal data event.

The captured minor-1 GS1 dispatch still selects `O1(index) → a2(index) →
V120RawData(index, 0)`. That path has no device-last-index prerequisite. The
app's fresh local-history index is `1`. Device time information is copied
to a bean and passed to the previously recovered callback that discards its
object. The prior `last_index > 0` condition was a bench guard, not a recovered
firmware requirement. Zero remains a raw observation; its meaning is unresolved.

### Warmup evidence, with limits

`com/sisensing/bsmonitoring/viewModel/BsMonitoringViewModel.java:956` (`h0()`)
contains a local initialization timer. If `firstBsMill` is zero or its fallback
flag is set, it initializes `J0` to **3600** and decrements it. Otherwise it
uses **`firstBsMill + 3540000` milliseconds**, which is first-data time plus
59 minutes. `I0()` at line 692 displays the value as minutes and seconds using
division and remainder by 60. The referenced `ExceptionHandle.ERROR.UNKNOWN`
constant is 1000, so that division converts milliseconds to seconds.

This is an **app display rule**, not an exact-firmware activation-state enum.
It does not read `ActivationResult`, prove the meaning of `FF`, or permit a
warmup bypass. First-data time must not be silently substituted for activation
time in a future decoder.

Three complete post-activation metadata sets independently show:

| Storage number | Raw activation | Sum | Last index |
| --- | --- | --- | --- |
| 4 | 56 | 60 | 0 |
| 12 | 48 | 60 | 0 |
| 14 | 46 | 60 | 0 |

The activation epoch is unchanged in all three. This fits a count of elapsed
minutes and a remaining-minute field during an initial hour, but does not prove
that storage counts readable glucose records or that `last_index` has the same
meaning in that period. At this offline continuation, more than eight hours had
elapsed since the confirmed activation. A new read can test the later state
without another activation or an artificial clock change.

### Alternate poll assessment

The GS1 storage consumer is **not copied as a read poll**. `q.c` forwards
`DeviceStorageResult.getU16storage_number()` to `q.a.m()` (`q/a.java:809`),
then `jo4.g()` and `ProximityService.c.a(int, device)` at line 344. That code
requires app-side `Y0() == 1` and compares storage with `Z0() + 10`.
Its two branches reach `ProximityService.e() → q.b.I1() → V120Reset` or
`ProximityService.c() → q.b.l1() → V120Activation`. Neither branch is included
in the new probe. No source evidence makes either command necessary here.

GS3 `da0.java:506` has a different storage-based path: for pending operation
259, it calls `rl0.I()` when storage exceeds the saved operation index by more
than four. This supports storage-driven polling in that app, but is not an
exact-GS1 rule. It does not authorize a selector sweep, `0A` firmware override
or repeated `08` on a GS1 connection. The next attempt uses the already matched
GS1 `08` query and corrects observation before introducing another command.

### Prepared probe and offline verification

The private `gs1_record_observer.py` has no radio access or command builder.
It accepts an injected receiver, decoder and monotonic clock. A successful
`08` ACK is intermediate; it continues through quiet windows until the fixed
deadline or an explicit record bound. It validates complete frames, request
freshness and contiguous indices starting at 1. Failures, unknown layouts,
duplicate/gapped indices, disconnect or cancellation stop observation. Raw
fields remain private and are not normalized to glucose.

`mac_continuous_records.py` uses this exact observer. Its concrete sequence is:

1. Require evidence of a newly posted GRAB and priority/radio coordination;
   reject expired or longer-than-15-minute leases before radio access.
2. Reacquire only the known `FF30` target, for at most three minutes, leaving
   time for observation and disconnect. Revalidate GS1 model, prior software,
   stable `2A25` and `FF31`/`FF32` properties. Subscribe before authentication.
3. Authenticate once, then read storage `F0/04`, time `F0/03` and state `F0/02`.
   Require complete replies, successful nonzero storage and the journaled
   activation epoch. Log raw state and last index without assigning an enum.
4. Reserve an exclusive per-lease query intent, then send **one `08` from
   index 1**. Keep this connection and subscription open after its success ACK.
5. Observe for up to **480 seconds**, bounded by the lease with a 20-second
   cleanup reserve, 512 record-phase notifications and 1024 raw records. No
   repeated query, activation or clock write is available in the write allowlist.
6. Disconnect and release; validate any captured raw records separately before
   claiming live glucose. A timeout remains evidence of no records in that
   window, not proof of empty storage or a reason to reactivate.

The deadline now uses one explicit conversion from remaining wall-clock lease
time to a monotonic stop time. Synthetic tests evaluate that expression at
runtime. The same-connection tests execute the actual probe with fake BLE;
they do not substitute a different observation implementation.

| Exact verification | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/test_gs1_record_observer.py` | **10 tests passed**: delayed ACK-then-record flow, ACK-only full wait, records without ACK, repeated ACK, malformed/failure/wrong-opcode frames, gaps/duplicates, stale events, disconnect, cancellation, timer and capture bounds |
| `python3 /private/tmp/cbio-re-20260909/test_mac_continuous_records.py` | **4 tests passed**, actual probe with fake BLE: ACK then two delayed batches on one connection; ACK-only observation; failed ACK cleanup; existing query journal prevents another write. All verify zero `07`/clock writes and preserved synthetic activation journal |
| `python3 /private/tmp/cbio-re-20260909/audit_post_activation_path.py` | Passed: recovered ACK callback, app timer, all three storage/state pairs, excluded reset/activation branches, preserved activation-journal fingerprint |
| Python syntax checks | Observer, probe, tests and audit passed |
| `git diff --check` | Passed |

Only redacted conclusions are in this repository. The code used for the bench,
captures, lease/query evidence and extracted vendor material remain in the
private scratch directory. `packages/cgm_cbio` is unchanged in this pass and
has no transport access. No live glucose result or new physical compatibility
claim follows from these synthetic tests.

The user authorized sending `BLE GRAB @Codex — Cbio GS1` in Competition when
ready. OpenClaw's group lookup, run with host access, reports **no configured
channels**; no group post was made. A configured posting route or relayed
confirmation of the post and priority check is required before this script can
run. No scan or sensor write occurred in this offline continuation.

## Bridge-confirmed continuous read lease: 2026-09-11, 11:53 BKK

The user confirmed that the bridge posted `@everyone BLE GRAB @Codex — Cbio
GS1` in Competition and that the other contender yielded. The private lease
record uses receipt-time 11:53:37 BKK and a 12:08:37 hard deadline. The prepared
probe ran with host Bluetooth access. It preserved the exclusive activation
journal and allowed only authentication, three information selectors and one
record query. The absence of a local messaging channel did not block this
bridge-confirmed lease.

**Outcome: raw history and a live raw stream confirmed; mg/dL still unresolved.**

| Event or check | Redacted result |
| --- | --- |
| Probe start / known-target connection | 11:54:01 / 11:54:15 BKK |
| Identity and authentication | Known GS1, prior software, stable six-byte `2A25`; auth success |
| Storage / time / state | Storage `538`, status `00`; original activation epoch; `last_index=0`; raw activation `0` |
| Record request | One index-1 `08`, with exclusive query intent before write |
| Record ACK | Complete success reply, result `01`, status `00`; observer stayed connected |
| Observation start | 11:54:18 BKK, same connection and notification subscription |
| Initial replay | 538 raw records, indices 1–538 |
| Fresh continuation | Four further records, indices 539–542, arriving about once per minute without another query |
| Requests / replies / raw frames | `5 / 43 / 38` |
| Accepted records | `542`, contiguous indices, raw time advances 60 per record |
| Freshness | Last record time within 120 seconds of notification receipt; absolute times remain private |
| Packed glucose fields | All zero; not treated as zero glucose readings |
| Raw current fields | All nonzero; values remain private |
| Activation / clock writes | `0 / 0`; activation journal fingerprint unchanged |
| End | Disconnect callback and `ConnectionError` at 11:58:19 BKK, after about four minutes of observation |
| Radio disposition | All radio work stopped; `BLE RELEASE @Codex — Cbio GS1` announced for bridge relay |

The disconnect ended the run before its planned eight-minute maximum. No
cause is assigned to the disconnect and no reconnect/retry followed. The
probe retained all 542 accepted records before exiting. A separate local
group post was not claimed; the RELEASE was supplied in this conversation
for the same bridge that confirmed GRAB.

The new evidence closes the continuous-observation gap: a successful `08`
can be followed by both replay and fresh records on this target. It also
disproves using `last_index=0` as proof of no raw records in this firmware:
the field was still zero while 538 records were available. In the initial
replay, each raw `reindex` equals `538 - index`; all four fresh rows have
`reindex=0`. This verifies remaining-record behavior for this capture, without
assigning a universal meaning to the field or changing parser policy.

Raw state changed from the earlier countdown-like values to `0`. This is
consistent with the app's warmup timing, but it does not isolate whether warmup,
continuous observation, elapsed time or their combination explains the earlier
ACK-only results. No `FF` enum or justification for reactivation follows.

### Remaining glucose conversion, now traced to an app algorithm

The recovered protected `LocalBleServiceV3.L()` body (metadata entry 29)
calls `ds.a()` with its `gh1` algorithm instance and the raw record object.
`defpackage/ds.java:31` handles `CGMRecordV120` by dividing raw temperature
and raw current by `10.0f`, retaining dump separately, then calling:

`gh1.i(index, current / 10, temperature / 10, 0, configuredLow, configuredHigh)`

The function sets the app glucose value from that algorithm result, and gets
trend and warning fields from the algorithm context. It does **not** convert
the record's packed `glouse` field directly. All-zero packed fields in this
capture therefore provide no mg/dL value to scale.

The protected initialization body `LocalBleServiceV3.J()` (entry 27, offsets
`0097–00b6`) reads `DeviceEntity.getAlgorithmVersion()`, calls `m9.a(version)`
and initializes the selected algorithm with `DeviceEntity.getBlueToothNum()`.
It requires initialization result `1`. `m9.java:13` selects among five local
algorithm versions; an empty stored version selects `r9` / V1.1.6A. That is an
app fallback, not a firmware-derived proof of the correct algorithm version.

`r9.f()` passes the connection code to
`NativeAlgorithmLibraryV116A.initAlgorithmContext(context, 0, code)`.
ARM64 JNI `0x2874` calls `initEncryptAlgorithmContext`; native `0x2eacc`
reads eight code bytes, calls `md_sensitivity_decrypt`, checks the resulting
sensitivity and initializes the algorithm context. This is distinct from
the activation request's app-derived parameter `1234`. The activation value
must not be substituted for a verified per-sensor connection-code input.

The existing app converter (`wc1` / `xc1`) includes a factor of `18.016` for
unit display, but that factor applies after the algorithm result. It cannot
turn raw current, a zero packed field or an ACK into mg/dL. The captured
history can now support an offline algorithm replay once the correct version,
connection-code input, context initialization and validity rules are verified.
The private location of this sensor's connection/QR code has been requested;
no code or label content belongs in this document.

### V1.1.6A replay gate (offline, fail-closed)

The supplied `phone.png` was confirmed as a Libre 2 UI screenshot. It was
discarded and is not a GS1 connection source. Its OCR artifacts were removed.
The private capture and APK/DEX evidence expose no `BlueToothNum` value. The
`gs1-registration-private.json` artifact is DEX package-registration metadata;
it is not a sensor connection code.

The recovered call chain is:

`LocalBleServiceV3` protected initialization →
`DeviceEntity.getAlgorithmVersion()` → `m9.a()` → `r9` V1.1.6A fallback →
`getBlueToothNum()` → `initAlgorithmContext(context, 0, code)` → native
sensitivity decrypt and context initialization.

The exact device algorithm version and verified eight-byte connection input are
missing. Native replay is therefore blocked. Do not substitute activation
parameter `1234`, serial, BLE address, `2A25`, registration metadata, or OCR
text. No BLE, activation, or native replay was performed in this audit. There
is no verified mg/dL result.

The 542-frame dump cannot produce a glucose value by a field-only formula. Each
V1.1.6A record supplies index, time, reindex, temperature, current, dump, and
status fields. The packed glucose field is zero in this capture. `ds.a()`
divides temperature and current by 10, then sends `(index, current,
temperature, 0, low_limit, high_limit)` to `gh1.i()`. For V1.1.6A, `gh1.i()`
is only a JNI call to `processAlgorithmContext`; no Java arithmetic maps current
to glucose. The native context is initialized from the per-sensor code and may
contain serialized state. Therefore current, temperature, time, and dump do not
define a unique glucose value without that context. A synthetic decode would be
an unsupported estimate and is rejected.

### Identity versus connection code

The capture identity contains model, software, and serial values only. The
recovered app flow keeps these separate: `BaseCgmConnectActivity.l1(str)`
passes the scanned link code directly to `gh1.f(str)` for native validation,
then `DeviceEntity.setBlueToothNum(str)` stores that same link code. The serial
is read through the device-information characteristic and is only placed in a
metadata callback. No recovered code hashes, concatenates, or otherwise
derives `BlueToothNum` from serial, model, software, address, or firmware.

Native V1.1.6A exports an encrypted initializer with `(selector, byte*)`
semantics behind the Java `(AlgorithmContext, int, String)` method. The JNI
wrapper requires selector `0`, obtains the Java UTF-8 string, and passes it to
the native initializer. The native decryptor requires exactly eight code bytes;
its calibration path consumes the final four bytes as a hexadecimal value and
scales it to a sensitivity float. The first four bytes are used for device-name
matching in the recovered app path. Neither portion is present in the capture.

The library also exposes a lower-level direct-sensitivity initializer. It
accepts a float and creates a fresh ~2.4 KiB algorithm context, but no captured
field supplies a verified sensitivity. The app can restore a serialized binary
context only when one was previously saved; the capture contains no such
context. The identity fields cannot replace either the missing four-byte
calibration suffix or a verified direct sensitivity. Replay remains blocked.

| Exact verification | Result |
| --- | --- |
| `python3 /private/tmp/cbio-re-20260909/verify_continuous_1153.py` | Passed: five allowed requests, one journaled `08`, 43 decrypted checksum-valid replies, 38 raw frames, 542 contiguous records, four fresh rows, ACK-before-data ordering, same connection, retained journal, private modes and stop before deadline |
| `env CI=true DART_SUPPRESS_ANALYTICS=true /Users/fungus/.local/flutter/bin/cache/dart-sdk/bin/dart --packages=packages/cgm_cbio/.dart_tool/package_config.json /private/tmp/cbio-re-20260909/verify_continuous_capture.dart /private/tmp/cbio-re-20260909/mac-continuous-1789102417-private.json` | Passed: every field in all 542 raw records agrees with the public offline parser; auth and metadata agree; `08` ACK separately validated and correctly rejected as raw data |
| Offline reindex check | Passed: initial replay matches remaining count; all four fresh rows have zero remaining count |
| Offline V1.1.6A field-path audit | Passed: 542 records have zero packed glucose; `ds.a()` performs only current/temperature scaling before the JNI algorithm call; no Java glucose decode exists |
| Offline V1.1.6A native-input audit | Passed: JNI selector and UTF-8 boundary, exact eight-byte code length, four-byte calibration suffix path, direct-sensitivity initializer, ~2.4 KiB context, optional context restore, and 542-record schema checked; no code or glucose values generated |
| `git diff --check` | Passed |

No raw capture, identifier, code, current/temperature value or glucose result
is stored in the repository. `packages/cgm_cbio` remains discovery plus offline
inspection; no transport or app registry session was enabled by this lease.
Live raw data is confirmed, but live glucose and registry integration remain
unfinished. The next work is algorithm replay, not another activation.

## Unknowns and next work

1. Extend the one-candidate `FF30`/`FF31`/`FF32` evidence to exact firmware and
   advertisement rules before general compatibility claims. The wrapper-only
   DEX search is superseded by protected DEX recovery and the Mac GATT probe.
   Radio is released; any further physical work needs a new BLE GRAB.
2. Resolve the observed `F0/02` raw state `FF` offline. The 02:55 lease used
   the explicit one-attempt override and confirmed activation; it did not
   establish the state meaning. Do not reactivate. The 16:07 lease authenticated and stopped before `07`;
   the earlier state-`00` hypothesis is not a verified inactive enum. The
   protected callback has now been recovered and discards the state object;
   seek an exact-firmware definition or a different state consumer, rather
   than expecting a comparison in that callback.
   The supported information selectors now have full-response
   evidence. Extend opcode-only correlation
   to exact response semantics, fragmentation, and freshness before live parsers
   or writes are integrated into a driver.
3. The continuous `08` path is now physically confirmed. Preserve its
   ACK/data separation and the storage/zero-index discrepancy. The 542 captured
   records permit offline work without further airtime. Establish firmware
   selection, authentication prerequisites and side effects. Do not infer GS1
   secrets or activation semantics from GS3 symbols.
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
