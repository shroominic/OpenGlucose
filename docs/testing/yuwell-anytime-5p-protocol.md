# Yuwell Anytime 5P protocol evidence boundary

This document separates verified reference evidence from facts observed on a
physical Anytime 5P. A first physical observation now exists — see
"First physical observation" below — but it stops at the version handshake.
The current work remains an interoperability investigation, not a
compatibility or clinical-accuracy claim.

OpenGlucose must not use this work for diagnosis, dosing, treatment, or
emergency monitoring. Raw captures can contain health data, device identities,
and pairing material. Keep them outside Git in private, access-controlled
storage. Commit only synthetic fixtures and redacted evidence.

## Evidence labels

- **OFFICIAL-DOCUMENT-VERIFIED**: stated in a Yuwell product document.
- **OFFICIAL-APP-STATIC**: independently described from static analysis of the
  verified Yuwell Android application. It is not yet observed on a target.
- **PUBLIC-CORROBORATION**: independently reported by a public implementation
  or capture. A related Anytime model is not proof for the 5P.
- **TARGET-DEVICE-UNVERIFIED**: must be confirmed on the exact sensor,
  transmitter firmware, phone, and operating-system combination.
- **HARD UNKNOWN**: evidence is not sufficient. Do not guess or send a write
  that depends on it.

## First physical observation

**2026-09-09, macOS Mac-BLE debug harness (`yuwell_macos_debug_main.dart`),
target: an Anytime 5P.** A bounded scan/connect/observe session ran to a
clean, safe stop. This is **TARGET-DEVICE-CONFIRMED** for exactly these
facts, nothing more:

- The device advertised as an exact `Anytime` plus ten-digit candidate and
  was reachable over GATT.
- The connected topology matched the reference primary service
  `00001000-1212-efde-1523-785feabcd123`, notify characteristic
  `00001001-...`, and write characteristic `00001002-...` **exactly**.
- Notify-before-write ordering held: notifications subscribed cleanly before
  any write.
- The one-byte version request (`[0x01]`) was written and produced a real,
  decodable response.
- The driver read that response and correctly, safely stopped: this unit's
  firmware branch is not `V1150`, so the driver failed closed at
  `YuwellSessionFailureKind.unsupportedFirmware` before sending any
  state-changing command (no date/communication-ID/configure/initialize/
  low-power write was ever attempted). Disconnect was clean.

No sensor identifier, address, or raw payload from this session is recorded
anywhere in this repository, per the private-storage rule below.

This promotes discovery, GATT topology, and the version handshake from
**OFFICIAL-APP-STATIC** to **TARGET-DEVICE-CONFIRMED** on this one unit. It
does not change any `HARD UNKNOWN` below: the final glucose algorithm is
still not implemented, and this unit's own firmware branch (being non-V1150)
means a live glucose read is not available from it under the current,
deliberately narrow `V1150`-only admission gate — extending that gate to
another branch still requires the independent specification and synthetic
validation described under "Differential-validation plan".

## Application identity correction

The earlier `com.microtechmd.*` applications are AiDEX applications. They are
not Yuwell Anytime applications and are excluded from this evidence set.

The reference APK used for this investigation came from the download page
encoded by the Anytime 5P box QR and has this verified identity:

| Field | Value |
| --- | --- |
| Android package | `com.yuwell.cgm` |
| Display label | `鱼跃安耐糖` |
| Version | `3.8.21.2` (`382120`) |
| APK SHA-256 | `f4123b437cf71a9be3aa4f1cd5071ada95103f3e67736f16de43bba5786c9ac0` |
| Signing identity | certificate subject and issuer identify Yuwell |
| Signature result | APK Signature Scheme v2 verified |

The APK, decompiled output, native libraries, raw sensor codes, and captures
are reference evidence only. They are not repository inputs and must not be
committed or distributed with OpenGlucose. Implementations must be new,
clean-room code derived from described wire behavior.

## Product facts

The official Anytime 5-family manual and product page state these properties:

| Property | Anytime 5P value | Evidence |
| --- | --- | --- |
| Wear life | 16 days | OFFICIAL-DOCUMENT-VERIFIED |
| Warmup | 45 minutes | OFFICIAL-DOCUMENT-VERIFIED |
| Reporting interval | 3 minutes, 480 points per day | OFFICIAL-DOCUMENT-VERIFIED |
| Calibration | factory calibration | OFFICIAL-DOCUMENT-VERIFIED |
| Calibration data | encoded in the product QR | OFFICIAL-DOCUMENT-VERIFIED |

The manual groups the 5P with other Anytime 5 variants that share key
components, functions, performance, and manufacturing, with stated exterior
differences. That makes related captures useful hypotheses, but it does not
replace a target 5P capture.

The application maps its internal CT5 lifetime code `4` to an initialization
index of 15 and an end index of 7695 at a 3-minute interval. The application
also contains mappings for other 8-, 10-, and 14-day family variants. These
are **OFFICIAL-APP-STATIC** and must not replace the manual's public product
definition or a target observation.

## Discovery and GATT topology

The official application contains this CT5 topology:

| Purpose | UUID |
| --- | --- |
| Primary service | `00001000-1212-efde-1523-785feabcd123` |
| Notify/read characteristic | `00001001-1212-efde-1523-785feabcd123` |
| Write characteristic | `00001002-1212-efde-1523-785feabcd123` |

The application maps device names beginning with `Anytime` to its CT5 path.
Some internal helpers also contain a `ZY_WATCH` name prefix. Neither prefix nor
the UUID alone is a production-safe identity rule:

- the service is shared by several Yuwell protocol generations;
- the exact 5P advertisement name and service-data layout are
  **TARGET-DEVICE-UNVERIFIED**; and
- a production discovery rule must require a target-proven combination of
  name, service, manufacturer data, and a non-empty platform identity.

The official application starts an unfiltered BLE scan for this flow, then
applies its own name/sensor-code checks. The first OpenGlucose capture must
therefore use an explicit debug-only unfiltered profile. It must not broaden
production scanning.

The application's own `ist.com.sdk.ProtocolTools.verify(byte[])` (delegating
to `ProtocolToolsHolder.verifyHolder`) is the exact call site that turns one
scan-advertisement payload into `type`/`category`/`name`/`isBound` fields.
This is **OFFICIAL-APP-STATIC** source grounding for the 27-byte
manufacturer-data claim below, not a new claim of its own. `CT5InitViewModel`'s
scan callback calls it on every scan result, matches the decoded `name`
against the expected candidate, and branches on `isBound` alone: a bound
match enters the application's own recovery flow (`enterRecoveryMode()`,
traced under "Reference session branches" below); an
unbound match proceeds to a fresh connect. Both branches still require a full
GATT connect and the version handshake below before any further step —
`isBound` read from the advertisement is a UI-routing hint the application
uses for itself, not a substitute for the authenticated binding-status check
(`0x11`) OpenGlucose's own driver already uses for the same purpose over GATT.

`verifyHolder`'s own body sharpens that grounding rather than just repeating
it: it is a generic, length-prefixed BLE advertising-data (AD structure)
walker, not a CT5-specific envelope parser. It recognizes standard AD
types — `0x01` Flags (one byte, read into `Verify.type`, only at total
length `2`), `0x03` Service UUIDs (skipped), and `0x08`/`0x09`
Local/Shortened Name (read into `Verify.name`, except one exact total
length that instead sets `Verify.category`) — plus `0xFF` Manufacturer
Specific Data, where it reads exactly 3 bytes into `Verify.category` and
one following byte into `Verify.isBound` (nonzero-vs-not), for either a
5-byte or a 27-byte total AD structure. For the 27-byte form specifically,
it consumes only that first 4-byte prefix and explicitly discards the
remaining 22 bytes unparsed. Those 22 bytes are where the six-record and
checksum content the paragraph above describes would live —
`verifyHolder` is confirmed *not* to be the method that reads them. A
`ProtocolToolsHolder_CT5$BroadData` class exists as a pointer for whoever
picks that thread up next; that dig is done — see "Advertisement decoder:
`ProtocolToolsHolder_CT5.verify()`" under "Live, history, and advertisement
records" below. It is a separate class from `ProtocolToolsHolder` above,
with its own result type, and it consumes this same 27-byte structure
differently. Any AD type/length combination outside the ones
above leaves this reference parser's buffer position unresolved for that
one structure — a fragility of the reference implementation, not a
wire-format fact. A future OpenGlucose parser should walk every AD
structure by its own declared length regardless of whether the type is
recognized, rather than copy that shortcut.

## Frame integrity and command map

Most CT5 command frames are:

```text
[opcode, payload..., sum8]
sum8 = low 8 bits of the sum of all preceding bytes
```

The one-byte version request is an exception. The following map is
**OFFICIAL-APP-STATIC**. It identifies states for capture and offline parser
tests. It does not authorize transmission to a sensor.

| Opcode | Reference purpose |
| --- | --- |
| `0x01` | version |
| `0x03` | set date/time |
| `0x05` | device/self check |
| `0x06` | initialize |
| `0x0A` | unbind |
| `0x0F` | low-power transition |
| `0x11` | read-only binding-state check |
| `0x30` | set communication ID |
| `0x31` | check communication ID |
| `0x35` | live record/acknowledgement path |
| `0x37` | history request/response |
| `0x38` | configuration |
| `0x3F` | query sensor/transmitter code |
| `0x45` | alternate live record/acknowledgement path |
| `0x47` | alternate history path |

These exact request encodings are suitable for offline tests only:

| Operation | Reference encoding |
| --- | --- |
| version | `[01]` |
| check | `[05 55 AA 04]` |
| low power | `[0F 55 AA 0E]` |
| binding-state check | `[11 55 AA 10]` |
| query code | `[3F 55 AA 3E]` |
| date | `[03, year-1900, month, day, hour, minute, second, sum8]` |
| history | `[37, start-index-le16, count, sum8]` |
| alternate history | `[47, start-index-le16, count, sum8]` |

Do not add initialize, configuration, unbind, reset, activation, calibration,
or ownership-changing writes to an OpenGlucose session until their target
effects, retry semantics, and recovery behavior are separately approved and
verified.

The history (`0x37`/`0x47`) and query-code (`0x3F`) *requests* above encode
with no apparent session dependency, but their *responses* are not so
simple: both are decrypted with the session cipher `driver.dart` derives via
`deriveCipherFromSetIdResponse` from the `0x30` set-ID write's response, per
**OFFICIAL-APP-STATIC** analysis of the CT5 driver. Sending either cold —
before that state-changing write completes — cannot produce a response
OpenGlucose can meaningfully decode, independent of whether transmitting it
is otherwise safe. This is a stronger reason than "no precedent," and it is
why only `0x11` (binding-state check) is both a simple unauthenticated
request and a response OpenGlucose can read cold: it is the one operation in
this table that is plaintext on the wire, not merely simply-encoded on
request.

## Communication identity and payload transform

The official application derives a 12-digit communication identity and splits
it into three four-character values: an ID, random A, and random B. A set-ID
request contains random B and a four-byte convolution of random B with random
A. The response and random A derive a one-byte session transform value.

The reference wire-to-clear transform:

1. XORs each wire byte with the one-byte session value.
2. Expands the bytes into most-significant-bit-first bits.
3. Scans left to right and inverts the current bit when the next bit is zero.
4. Reassembles the clear bytes.

The clear-to-wire transform applies the inverse bit operation from right to
left, then XORs each byte with the session value. The official application
names these helpers from an internal perspective that does not consistently
describe their wire direction; OpenGlucose APIs must use the semantic names
`decode(wire)` and `encode(clear)`.

This is **OFFICIAL-APP-STATIC** and has **PUBLIC-CORROBORATION**. It can be
implemented and tested with synthetic values. Do not log or commit a real
communication identity, session value, sensor code, or transformed payload.

The application persists identity/session material and uses it on reconnect.
OpenGlucose must not put this material in discovery metadata, health-state
JSON, SharedPreferences, logs, filenames, exceptions, or fixtures. A future
live implementation needs a separate injected credential store backed by
Android Keystore/iOS Keychain, or it must keep the values ephemeral.

## Reference session branches

Static analysis indicates this first-use branch:

```text
connect -> verify topology -> enable notifications -> version -> date
        -> set communication ID -> query sensor/transmitter code
        -> decode calibration/session metadata -> configure -> initialize
        -> low-power/ready
```

It indicates this saved-session branch:

```text
connect -> verify topology -> enable notifications -> version
        -> check saved communication ID -> set date -> history
        -> read binding state -> low-power/ready -> live notifications
```

The application-layer choice between these two branches, and a third,
narrower one, happens in `CGMCallbackHandlerCT5`'s device-prepared callback,
before either sequence above starts: it looks up a locally persisted
`Transmitter` record for this identity first.

- A record found: reuses that record's stored `sureClose` field directly as
  the session cipher (`AuthInfo.setCipher`), together with the
  already-derived ID/random-A/random-B, then sends `0x31` (check
  communication ID) — no fresh `0x30` set-ID round-trip appears in this
  path. This is the saved-session branch above, and `sureClose` is the same
  field `ProtocolToolsHolder_CT5.setKCipher` reads for the advertisement
  path (see "Advertisement decoder"): `TransmitterRepository
  .saveTransmitterFirstInit` writes it once, during first-time pairing, in
  the same call that persists the communication ID, `K`, and `R`. For a
  transmitter this app has already bound locally, the advertisement decoder
  and the connected-GATT session read the identical stored value.
- No record found, and the application is not in `enterRecoveryMode()`:
  proceeds to `getVersion()` — the first-use branch above.
- No record found, and the application *is* in `enterRecoveryMode()`: reads
  a cipher from `PreferenceSource.getCT5InitCipher()` instead — a
  SharedPreferences-backed value distinct from any `Transmitter` record,
  written during a CT5Init flow that has not yet reached a durable save.
  `enterRecoveryMode()` (cited above, under "Discovery and GATT topology",
  as the effect of a bound scan-advertisement match) sets a single boolean
  flag on this callback handler; this is the branch point traced here. That
  flag has other read sites in this same handler this document does not
  trace. This third path is a narrower variant of the saved-session branch,
  not a distinct opcode sequence — it changes only where the cipher comes
  from, not what is sent.

The application also sends `0x0F` after initialization and after every
completed history cycle. This repeated reference behavior supports treating
the low-power command as replayable after an interrupted response. OpenGlucose
still journals the command and validates the response before it advances its
durable session phase.

These are **OFFICIAL-APP-STATIC**, not target observations. Several operations
can change persistent sensor state. A capture label does not approve the
corresponding write.

The OpenGlucose live path remains Android-debug-only and requires explicit
activation metadata. It implements the observed initialization sequence with
a secure credential store and a durable write journal. It does not implement
unbind, reset, OTA, calibration, or ownership transfer. Unknown write outcomes
fail closed unless the reference application proves that an operation is
normally replayed, as it does for `0x0F`.

## Application-side version gate

**OFFICIAL-APP-STATIC.** `CT5InitViewModel`'s data-receive handler filters
incoming notifications to exactly two opcodes at this stage of its own
flow — `0x05` (self-check) and `0x01` (version) — and its version handler
enforces a hard-coded allowlist before it will call `setDate` at all:
`V1100` only at the exact date `2024-10-24`; `V1110` only at the exact date
`2025-03-24`; and unconditionally `V1120`, `V1130`, `V1140`, `V1150`,
`V1200`, `V1210`. Any other reported version — or a date-gated version
outside its one exact accepted date — makes the application report an
init failure and call `close()` on the connection. It never reaches
`setDate` or anything after it on that path.

This is a *broader* gate than the transmitter-computed trust check the
"Live, history, and advertisement records" section below already describes:
`TransmitterRepository.FIRMWARE_VERSION_V1150` is still the only version the
application trusts for a transmitter-computed value, with no sibling
constant. The application's own code therefore treats "firmware new enough
to initialize" (`V1120`-`V1210`) and "firmware whose transmitter value it
will trust" (`V1150` only) as two different questions.

This does not change any `HARD UNKNOWN` above and does not license widening
OpenGlucose's own `unsupportedFirmware` gate: the native algorithm that the
`V1120`-`V1210` range would still need for any non-transmitter-computed
value remains unimplemented. It is cited here as version-gate evidence, not
as grounds to admit those versions any further than the one read-only
binding-status query OpenGlucose's driver already sends for evidence on any
non-`V1150` unit (see the package's evidence-boundary doc).

## CT5Init activity: view-layer session lifecycle

**OFFICIAL-APP-STATIC.** `com.yuwell.cgm.view.normal.home.guide.ct5.CT5Init`
is the guide-flow Activity that hosts `CT5InitViewModel`. It is a distinct
class, not previously covered in this document, and it adds a
session-lifecycle layer above the ViewModel logic already recorded here:

- `onCreate` reads a `BSN` string extra from the launching `Intent` and
  compares it against `PreferenceSource.getCT5InitBSN()`, the BSN this flow
  last saved. A mismatch clears saved CT5-init recovery state
  (`PreferenceSource.clearCT5InitRecovery()`) before anything else runs:
  recovery is keyed to this identifier, not only to "was there an
  interrupted init."
- Calling the ViewModel's `getConfig()` (a backend config fetch, not a BLE
  operation) is itself permission-gated: `onCreate` only calls it once a
  local permission check passes, otherwise it calls `requestPermission()`
  first.
- `onDestroy` unconditionally calls `CT5InitViewModel.stopBleScan()`, which
  itself no-ops unless a scan is active (guarded by the ViewModel's own
  boolean scan flag) and otherwise stops the platform scanner and a timer.
  Scan lifetime is therefore bounded by this Activity's lifecycle as a
  backstop, independent of any protocol-level timeout.
- `CT5InitViewModel.startInit(Date)` **is** `startBleScan(Date)` — there is
  no separate init-specific scan entry point. `startBleScan` builds
  `ScanSettings` with `SCAN_MODE_LOW_LATENCY` and hardware batching
  explicitly disabled, and is reentrancy-guarded by the same flag
  `stopBleScan` checks.
- The first scan is reached only past a four-part prerequisite gate in the
  permission-success callback (`onPermissionRequestSuccess`, traced through
  its AspectJ wrapper): the app's runtime-permission set, an
  Android-12-plus BLE-specific permission re-check, location services
  (GPS) enabled, then the Bluetooth adapter enabled — each unmet condition
  routes to its own prompt instead of proceeding. Only once all four hold
  does the Activity clear the version-gate-failure latch and schedule
  `startInit(new Date())` on the next handler tick. That `Date` is the
  reference timestamp the resume window below measures from: a resumed
  retry inside that window reuses this same original `Date` rather than
  minting a new one, so the 30 seconds is a fixed budget from the first
  attempt, not a sliding window renewed by each retry.

`onTransmitterStateReceived(TransmitterState)` is this Activity's single
dispatch point for session state, keyed on `TransmitterState.newState`
against the constants that class defines
(`com.yuwell.cgm.data.model.local.TransmitterState`; source-grounded, not
inferred). It splits into two groups:

- Terminal states that return immediately: `INIT_SUCCESS` (calls the
  ViewModel's `finishGuide()`, whose async completion later drives the
  Activity's own `getGuideFinish()` observer to broadcast
  `TransmitterState.FINISH_GUIDE` through the app's `MessageSender` and
  then close the Activity — two steps through two components, not one),
  `UNBINDING` (clears the saved reference timestamp), `ERROR_BOUND`,
  `ERROR_SENSOR_INFO` (shows the app's QR-error string), and
  `CHECK_TRANSMITTER_VERSION_FAIL` — which stores the failure detail, logs
  the app's own `"checkTransmitterVersion fail:"` line, and shows
  `WearVersionTipDialog`, whose own callback closes the Activity regardless
  of which option the dialog reports: this path has no retry inside
  `CT5Init`. `CHECK_TRANSMITTER_VERSION_FAIL` is the UI-layer surface of the
  version-handler allowlist this document already establishes under
  "Application-side version gate"; it is an independent, corroborating code
  path (the Activity's own state-code dispatch and log string), not a new
  claim about the gate's condition.
- `DISCONNECTED` and `CHECK_FAIL` share one fall-through tail instead of a
  dedicated branch: it returns immediately if a version-gate failure was
  already recorded or there is no saved reference timestamp; otherwise,
  inside a 30-second window of that timestamp it re-arms the UI and calls
  `startInit` (a re-`startBleScan`, itself a no-op if a scan is already
  running); outside that window it clears the timestamp and runs the same
  recovery path a failed connection attempt uses. This is a UI resume/retry
  window, not a protocol timeout, and it never fires once a version-gate
  failure has latched.

Two more LiveData observers converge on already-seen recovery helpers, but
not identically: `getScanOverTime()` calls the exact same helper pair
`onRequestFailed` calls, while `getBound()`'s `true` case shares only one of
the two — the Activity treats an already-bound sensor as a distinct recovery
path from a generic scan timeout or connect failure, not an identical one.
`getBound()`'s `true` case is the Activity-side reaction to the same
advertisement `isBound` flag already discussed under "Discovery and GATT
topology"; this document's conclusion there — `isBound` is a UI-routing
hint, not an authenticated check — is unchanged, this only adds where that
hint's `true` case lands once wired to this Activity.

This adds a previously undocumented layer above `CT5InitViewModel` without
changing any conclusion already recorded for it: everything here is
session/UI lifecycle — BSN-keyed recovery, permission gating, scan
configuration, and state-code-driven dialog-vs-resume branching — and none
of it touches live, history, or advertisement record content.

## Live, history, and advertisement records

Static analysis shows three encrypted live/history layouts:

| Path | Live size | History record size | Known core fields |
| --- | ---: | ---: | --- |
| base | 15 bytes | 11 bytes | index, background/working current, temperature, trend, packed glucose, status |
| voltage | 19 bytes | 15 bytes | base data plus electrode/voltage fields |
| alternate voltage | 21 bytes | 17 bytes | additional warning/calibration fields |

Indexes are little-endian. The reference application derives sample time from
the initialization time and `(index + 1) * 3 minutes`. All-`FC` records are end
padding and all-`FF` records are invalid in the reference implementation.
Exact field meaning, scaling for every firmware, and all status bits remain
**TARGET-DEVICE-UNVERIFIED**.

The application can parse a 27-byte CT5 manufacturer-data structure with a
category, bound flag, type/count nibble, little-endian starting index, six
three-byte transformed records, and an additive checksum over the referenced
payload. A related public Anytime 5H SE capture reports a similar six-record
advertisement, but its trailing integrity byte was not fully established.
Advertisement glucose is therefore not a production capability until a 5P
capture proves identity, integrity, session binding, counter behavior, and
decoding.

The packed glucose-like field is not automatically the final official value.
In the connected-GATT path in the inspected application, both the normal and
alternate record parsers preserve that field, but the callback still runs the
stateful native algorithm over current, temperature, calibration parameters,
and contiguous history before it publishes the normal glucose record. The
alternate value is also stored separately for comparison. A separate
advertisement-display path accepts a transmitter value without the native
algorithm. This does not prove that the two values are equivalent.

### Advertisement decoder: `ProtocolToolsHolder_CT5.verify()`

**OFFICIAL-APP-STATIC**, cross-checked against smali. `com.yuwell.cgm.utils.
ProtocolToolsHolder_CT5` is a separate class from `ist.com.sdk.ProtocolTools`/
`ProtocolToolsHolder` above, with its own result type (`Verify_CT5`, not
`ProtocolTools.Verify`). Its `verify(byte[])` has exactly one call site in
the inspected DEX — `CGMService`'s field `j0` — and `CT5InitViewModel`'s scan
callback never calls it; that callback only ever reaches `ist.com.sdk.
ProtocolTools.verify`/`verifyHolder`. The two decoders do not call each
other.

A private helper (`ProtocolToolsHolder_CT5.a([B)Z` in smali) gates
`verify()`: for the same type-`0xFF`, 27-byte AD structure, it skips a
4-byte prefix, sums the next 21 bytes, and requires the low 8 bits of that
sum to equal the following byte. `verify()` returns `null` for a checksum or
shape mismatch here, and for any other exception, including a
nibble-encoded count that reads past the end of the payload described below.

That helper's other branches are worth tracing precisely against smali, not
just jadx: a second, distinct instance of the same decompiler-fidelity issue
this document already resolved once for `lambda$algorithmGlucose$10` (see
below) turns up inside `a([B)Z` itself. jadx renders the non-`0xFF` branches
so that both AD type `3` (Service UUIDs) and type `9` (Complete Local Name)
appear to share one more, redundant skip whenever the element's length is
exactly `13`. The smali does not agree: type `9`'s branch jumps straight
back to the loop top and never reaches that check; only type `3` genuinely
falls through into it, so only type `3` at length `13` is actually
double-skipped by this helper — a real over-read, not a decompiler illusion.
Type `8` (Shortened Local Name) reaches that same length-`13` check
directly, with no skip of its own first: at length `13` it is skipped
correctly, but at any other length this helper advances zero bytes for it,
so the next loop iteration reads that element's own value bytes as a new
length/type pair. All three are fragilities of the reference app's own
advertisement scanner, in the same register as the `verifyHolder` fragility
already noted above — none touch the type-`0xFF`/27-byte branch this
document otherwise relies on, so nothing about the checksum gate or the
record decode below changes. Exception handling in this same helper is also
stricter than a literal reading of the decompiled `catch` block suggests:
the smali `catch` handler for the method's one try region falls straight
through to the method's final `return false` — an exception anywhere in one
pass aborts the whole scan immediately, it does not log and continue looking
at the rest of the payload for a later, valid element.

Where `verifyHolder` discards the remaining 22 bytes of that structure
unparsed (see above), `ProtocolToolsHolder_CT5.verify()` is the method that
reads them: after 3 bytes (category) and 1 byte (bound flag, `== 1`), it
reads one byte split into a count (low nibble) and a type selector (high
nibble), a little-endian 2-byte starting index, then 18 bytes it runs
through the same `ConvertTools.encode(bytes, kCipher)` transform the GATT
session path uses — `kCipher` here is set immediately before each call from
`Transmitter.sureClose`, a per-transmitter persisted int field. That field's
full provenance, and the one case where the GATT path reads a *different*
cipher instead, are traced under "Reference session branches" below; for a
transmitter this app has already bound locally, it is the identical stored
value on both paths, not independently derived ones. It then reads that
decoded payload as `count`
fixed 3-byte big-endian records — nothing in this method caps `count`
against the 18-byte payload itself; an over-long count throws and is caught
by the same shape-error handling above — branching only on the type nibble:

- type `1`: `dValue = (raw >> 10) * 0.01`, `dTrmpture = (raw & 0x3FF) * 0.1 -
  40.0`;
- type `2`: `trend = raw & 0x1F`, `errorCode = (raw >> 5) & 0xFF`,
  `glucoseValue = (raw >> 13) & 0x7FF`.

Both record types also carry `nIndex = <the 27-byte structure's starting
index> + <the record's position in this batch>`, re-deriving each record's
absolute index from the one little-endian starting index already noted
above. A type selector outside `1`/`2`, or a zero count, leaves the returned
`Verify_CT5` non-null but with zero `BroadData` records: category and bound
are still set from the fixed-position bytes read earlier, only the record
list is empty. This is not a parse failure — it is indistinguishable, from
the caller's side, from a genuinely empty batch.

`verify()`'s only caller, `CGMService`'s `lambda$algorithmGlucose$10`,
requires `isBound()` true and a category match before reading any record,
then hands every type-`2` record straight to
`CGMCallbackCT5.onBroadcastNewGlucoseRead()` as a `CurrentGlucose` — with no
native-algorithm call anywhere in that method. This is the exact source
grounding for "a separate advertisement-display path accepts a transmitter
value without the native algorithm" above.

jadx flags this same method's surrounding index/gap-continuity logic as
unreliably decompiled ("Removed duplicated region for block"), leaving an
empty `if` body in the Java text where the source implies real branching.
That gap is now closed against smali directly, rather than characterized
from "the plain accessor calls" alone as the previous revision of this
document put it. The empty branch is a jadx duplicated-region artifact, not
a behavioral no-op: in the raw bytecode, the comparison it hides decides
only whether execution *joins* the one record-processing loop every entry
path shares — it is not a second path with independent behavior. Concretely,
with `i12` the last-published `glucoseId`, `i13 = i12 + 1`, and `i14` the new
batch's first `nIndex`: if `i13 < i14` (a gap — the batch starts after
records this method has not seen) or `i13 > i14 + size - 1` (the whole batch
is already old), the branch falls through without publishing, exactly like
the sibling "no recent record" `else` case below it. Otherwise — `i13` lands
inside `[i14, i14 + size - 1]` — control joins that same `else` case's loop,
which always walks the batch from its first record regardless of where
`i13` fell inside that window. The loop's own per-record guard is the real
replay gate: each candidate's `glucoseId` is compared against the
last-published id and skipped unless strictly greater, independent of the
outer window check. Two things follow, both source-level, from this trace
alone: the outer check only gates whether the loop runs at all, never which
records within it publish; and nothing anywhere in this method reads a
firmware-version field. The `V1150`-only gate this document establishes
elsewhere belongs to the connected-session alternate-record selector, a
different code path — this advertisement callback does not consult it.
Resolving the gap does not change any conclusion above: the method still
runs no native algorithm and still requires only `isBound()`, a category
match, and `verify()`'s own checksum to publish a transmitter-computed
`glucoseValue`. If anything it sharpens the existing reason this path stays
out of scope for OpenGlucose's own admission gate — the absence of a
firmware check here is a property of the reference app's own code, not a
precedent for widening OpenGlucose's `unsupportedFirmware` gate to match it.

The alternate branch selector is exact: the application enables it only when
the persisted firmware-version string starts with `V1150`. It then sends an
alternate initialization frame and uses `0x45`/`0x47` live/history traffic.
All other recognized CT5 versions use the older initialization and
`0x35`/`0x37` traffic. The inspected application still invokes its local native
algorithm for connected records in both branches. A four-argument callback
that would accept the transmitter value exists but has no call site in the
inspected DEX.

After the session transform, an alternate record carries background and
working current as unsigned hundredths, temperature as an integer byte offset
by 40 plus a hundredths byte, and a 12-bit packed glucose value. The high four
glucose bits share a byte with the trend nibble; the following byte contains
the low eight bits. This field layout is exact for the inspected application,
but its value is an independent transmitter field and is not an input to the
native algorithm. A synthetic native oracle therefore cannot prove equality;
that comparison requires paired same-index target records and official output.

The native calibration-code decoder is no longer a hard unknown. It selects
one of three strict 17-, 18-, or 21-character layouts and parses fixed ASCII
positions. There is no hidden key or cryptographic operation in this decoder:

- the 17-character layout has `K = digits[10..11] / 10` and
  `R = digits[12..13] / 10`;
- the 18-character layout has `K = digits[10..12] / 100` and
  `R = digits[13..14] / 10`; and
- the 21-character layout has a market code, lifetime code, calibration
  selector, `K = digits[13..15] / 100`, and `R = digits[16..17] / 10`.

The source text for this decoder is the decrypted response to opcode `0x3F`.
It is not the 12-character code scanned from the retail box. OpenGlucose now
expresses the three layouts in clean-room Dart with synthetic tests and no
native dependency.

## Native algorithm contract and clean-room gap

The native entry-point contract is now understood. The final CT5 mathematics
remain a **HARD UNKNOWN**. This distinction is important: OpenGlucose can
validate and preserve the input sequence without pretending that it can yet
produce the official glucose result.

The CT5 configuration is:

| Field | CT5 value | Meaning |
| --- | ---: | --- |
| warmup points | 15 | 45 minutes at a 3-minute interval |
| life points | 7695 | 16-day family lifecycle bound used by the application |
| algorithm selector | 11 | CT5 branch |
| `R` | decoded per sensor | calibration parameter from the `0x3F` text |

The algorithm input contains:

- the last record index in the call;
- equal-length arrays of working current, background current, and temperature;
- paired calibration-event indexes and reference glucose values;
- the per-sensor `K` value;
- reserved calibration fields;
- low- and high-warning thresholds; and
- the local calendar day, hour, and minute derived from the record timestamp.

The outer contract rejects null or empty current/temperature arrays, unequal
array lengths, invalid event pairs, selectors outside `1...11`, and non-positive
`K` for selectors `9...11`. A multi-record call must contain the complete
sequence from index zero through its declared last index. It is not an
arbitrary rolling window.

The result has these fields:

| Field | Representation |
| --- | --- |
| lifecycle day/hour counts | signed one-byte values |
| reference-glucose advice and `GLU_MG` | signed 16-bit values |
| reference/internal counts | signed 32-bit values |
| warning, error, trend, calibration status | signed 32-bit codes |
| data quality and early-warning minutes | one-byte values |

The Java layer publishes `GLU_MG` as mg/dL and derives mmol/L by dividing it by
18. It does not apply a second glucose formula.

The selector dispatcher has separate pre-processing and result branches for
selectors `1...8`. Selectors `9`, `10`, and `11` share one later-generation
state-machine family; CT5 selects `11`. In that family:

1. record index zero resets the main state and at least five auxiliary state
   blocks;
2. every later record must be exactly the previous index plus one;
3. a gap or out-of-order record clears the main state and returns algorithm-data
   error `2` with no glucose result; and
4. later non-zero indexes remain invalid until index zero starts a new replay.

Synthetic differential checks against the local reference binary confirm that
a 15-point configuration crosses its output boundary on zero-based record 14,
and that a complete 15-point batch has the same result as 15 sequential calls.
These checks use no real identity or health data. They are contract evidence,
not an implementation and not a clinical-accuracy claim.

A deterministic 4,749-point synthetic matrix also rules out a safe stateless
scale formula. Constant, persistent-step, and isolated-impulse sequences show
lifecycle-dependent drift, temperature compensation, step overshoot and
damping, and isolated-current outlier rejection. In the tested no-calibration-
event path, changing `K` and temperature changes the result, while changing
background current or `R` alone does not. That last observation is conditional:
it does not establish that background current or `R` are unused when
calibration events, warnings, or other lifecycle states are active. The matrix
is reproducible synthetic evidence, but it is not sufficient to specify the
state machine independently.

The CT5 branch is not a small formula. Its reset path covers more than 900 bytes
of process-global state. Its result path includes a large per-sample pipeline,
temperature/current compensation, smoothing, trend and quality calculation,
warning/calibration handling, and several downstream state updates. Static
analysis does not yet assign safe semantics to every state field and constant.
Translating the instructions mechanically would not be an independently
reviewable clean-room algorithm.

OpenGlucose therefore must not:

- ship or load the native library extracted from the APK;
- approximate current as glucose;
- treat the packed transmitter field as final glucose without a target match;
- start a local state sequence at the newest record; or
- publish a result after any record gap.

### Differential-validation plan

The minimum target evidence depends on the firmware branch:

1. Record the sanitized firmware branch, record layout, and indexes. Keep `K`,
   `R`, raw records, identifiers, and algorithm traces in private storage.
2. Obtain one complete, contiguous history beginning at index zero. Preserve
   working current, background current, temperature, timestamps, status fields,
   and the official application's output for each index.
3. Replay that same sequence in single-point and complete-batch forms. Confirm
   the warmup boundary, gap error, index-zero recovery, trend, quality, warning,
   and lifecycle transitions.
4. For `V1150`, compare the packed transmitter value with the application's
   published `GLU_MG` at every index across warmup, at least one reconnect, and
   an overlapping history/live window. Any mismatch blocks that shortcut.
5. For other firmware, implement a new pure-Dart state machine only after its
   stages and state variables are independently specified. Validate it with
   synthetic constant, step, temperature-outlier, gap, reset, and batch vectors,
   then use complete physical sessions as held-out tests.

A single successful sensor session can promote transport interoperability. It
cannot establish clinical equivalence of a reimplemented glucose algorithm.

### V1150 transmitter-value gates

The pure-Dart `YuwellV1150GlucoseValidationReport` can summarize sanitized
same-index comparisons outside Git. It reports missing indexes, conflicting
duplicates, exact-value mismatches, reconnect epochs, warmup coverage, and
history/live overlap. It does not call the reference library and does not make
a value safe to publish by itself.

Use two distinct milestones:

1. **Engineering evidence only:** one exact `V1150` target; at least 60
   contiguous indexes beginning at zero; indexes 14 and 15; at least two
   connection epochs; at least ten same-index history/live overlaps; and zero
   value mismatches or duplicate conflicts. Passing this milestone permits
   continued target testing. Before this evidence exists, only the explicit
   private Android debug build may show the packed field, and it must mark every
   value provisional. Normal and release builds must publish no Yuwell glucose.
2. **Publication gate:** three independently reviewed physical-sensor sessions
   from at least two manufacturing lots, all on the exact supported firmware;
   each session captured contiguously from index zero through natural
   expiration; at least two reconnects and 30 history/live overlap indexes per
   session; exact transmitter/native equality at every comparable index; and
   separately verified warmup, error, warning, trend, timestamp, and expiration
   behavior. One value mismatch, one unexplained duplicate conflict, or one
   unknown status blocks publication.

After that evidence is approved, the runtime path must remain fail-closed. It
may publish the packed value only for the exact reviewed firmware, alternate
opcode and 17-byte record layout, a valid authenticated frame, a contiguous
index, a post-warmup record, and a reviewed no-error status. Unknown firmware,
layout, status, gap, checksum, transform, or session state must produce no
`CgmReading`. The non-V1150 branch remains blocked because it has no validated
local final-value provider.

### OTA firmware-update path

**OFFICIAL-APP-STATIC.** The application bundles two Gecko Bootloader
(`.gbl`) firmware images as assets and can update a connected transmitter
through `OTAViewModel`/`OTAUtils`. Static analysis of that path, and of the
two image files themselves, closes it off as a shortcut to `V1150`:

- `OTAViewModel` selects the update asset by the device's *current* reported
  version: `update.gbl` for a device on `V1200`; the other bundled image,
  `CT3A_V1400_241213A.gbl`, for a device on `V1300` or `V1400`. The full
  ladder the application implements is `V1200 -> V1300 -> V1400`. `V1150`
  is not a node in it, at either end or in between.
- Each `.gbl` image's own embedded application-version string confirms its
  target: `update.gbl` contains the plaintext string `V1300`;
  `CT3A_V1400_241213A.gbl` contains `V1400`, matching its filename exactly.
  Extracted at a fixed structural offset inside the GBL container; the two
  files agree on format up to that point and only diverge from there,
  which corroborates a real embedded target-version field rather than a
  coincidental byte match.
- `TransmitterRepository.FIRMWARE_VERSION_V1150 = "V1150"` is the only
  version literal the application trusts for a transmitter-computed value;
  `V1200`/`V1300`/`V1400` have no sibling constant anywhere in that class.
  Completing this OTA ladder would not make a unit's packed value
  trustworthy even if it reached `V1400`.
- `OTAUtils`/`OTAViewModel`'s own gating functions (`isNewCT3Sensor`,
  `isCT4Sensor`) and the complete absence of any `CT5` reference in either
  file read as CT3/CT4-product logic, not CT5/Anytime-5P. This update
  mechanism may not target the Anytime 5P transmitter at all. Lower
  confidence than the two points above — not traced to a live
  device-model call site.

Net: an official-app OTA update cannot promote a unit to `V1150` through
this mechanism, independent of whether it is offered to a CT5 unit in the
first place. This resolves a previously open question (whether an OTA path
reaches `V1150`) with a documented negative finding instead of leaving it
unverified; it does not relax any rule in "OpenGlucose therefore must not"
above.

## Confidence table

| Finding | Confidence | Basis |
| --- | --- | --- |
| CT5 configuration `15 / 7695 / 11` | high | application metadata and native dispatch |
| native input/config/result field contract | high | JNI and native call-site agreement |
| selector `9...11` shared family branch | high | native dispatch tables |
| index-zero reset and strict contiguous indexes | high | static path and synthetic differential checks |
| zero-based output boundary at record 14 | high for the reference build | synthetic differential checks |
| exact CT5 glucose mathematics | incomplete | multiple unresolved stateful stages |
| CT5 topology + version handshake on a real 5P | high | 2026-09-09 macOS physical session (see "First physical observation") |
| target retail 5P firmware branch | one unit confirmed non-`V1150` | 2026-09-09 macOS physical session; other units/lots unconfirmed |
| application's own init-vs-trust version gate is two different checks (`V1120`-`V1210` init-eligible, `V1150`-only transmitter-trusted) | high (source-level) | static analysis of `CT5InitViewModel`/`TransmitterRepository` — see "Application-side version gate" |
| `CT5Init` (the guide Activity, distinct from `CT5InitViewModel`) drives session lifecycle from `TransmitterState` codes, gated behind a four-part permission/GPS/Bluetooth prerequisite check whose completion timestamp is the origin of the 30s resume window shared by `DISCONNECTED`/`CHECK_FAIL`, with `CHECK_TRANSMITTER_VERSION_FAIL` (23) as the version gate's dedicated, non-retrying UI path | high (source-level) | static analysis of `CT5Init`/`TransmitterState`, cross-referenced against `CT5InitViewModel.startBleScan`/`stopBleScan` — see "CT5Init activity: view-layer session lifecycle" |
| `ProtocolTools.verify()` is a generic BLE AD-structure walker, not a CT5-specific envelope, and does not itself parse the six-record/checksum advertising content | high (source-level) | static analysis of `ProtocolToolsHolder.verifyHolder` — see "Discovery and GATT topology" |
| `ProtocolToolsHolder_CT5.verify()` is the app's own decoder for that six-record/checksum content, with its sole call site in `CGMService`, never `CT5InitViewModel` | high (source-level) | static analysis of `ProtocolToolsHolder_CT5`/`CGMService`, cross-checked against smali — see "Advertisement decoder" under "Live, history, and advertisement records" |
| `lambda$algorithmGlucose$10`'s jadx-empty continuity branch only gates loop entry (per-record `glucoseId` comparison is the real replay guard), and the method never reads a firmware-version field | high (source-level) | full smali trace of `CGMService.lambda$algorithmGlucose$10`, resolving the jadx "Removed duplicated region" warning — see "Advertisement decoder" |
| `ProtocolToolsHolder_CT5.a([B)Z`'s non-`0xFF` skip branches: jadx's Java over-states which AD types double-skip at length 13 (only type `3` truly does; type `9` does not, despite reading the same in decompiled Java); type `8` skips nothing unless length is exactly 13; any exception aborts the whole scan immediately rather than continuing past it — a second, distinct jadx-vs-smali discrepancy in this class, same failure class as the `lambda$algorithmGlucose$10` row above | high (source-level) | full smali trace of `ProtocolToolsHolder_CT5.a([B)Z`, cross-checked line-by-line against its jadx Java rendering — see "Advertisement decoder" |
| `Transmitter.sureClose` is one persisted field written once by `TransmitterRepository.saveTransmitterFirstInit` and read by both the advertisement decoder (`ProtocolToolsHolder_CT5.setKCipher`) and the connected-GATT session (`CGMCallbackHandlerCT5`'s `AuthInfo.setCipher`) for an already-bound transmitter, resolving this document's own prior "does not yet prove" note; a third, narrower session-start path (`enterRecoveryMode()` with no local record) reads a different, SharedPreferences-backed cipher instead | high (source-level) | static analysis of `CGMCallbackHandlerCT5.lambda$onDevicePrepared$0`, `TransmitterRepository.saveTransmitterFirstInit`, and `Transmitter.sureClose`'s full read/write site list — see "Reference session branches" |
| `V1150` packed value equals published glucose | unknown | requires target differential capture on a `V1150` unit |
| official-app OTA reaches `V1150` | no (documented negative) | static analysis of `OTAViewModel`/`OTAUtils` and both bundled `.gbl` images — see "OTA firmware-update path" |
| history (`0x37`/`0x47`) and query-code (`0x3F`) responses are cold-decodable | no — session-cipher-dependent | static analysis of `driver.dart`'s use of `deriveCipherFromSetIdResponse` |

## Structural investigation status: ProtocolToolsHolder_CT5 / CT5Init / notification

As of 2026-09-12, static structural analysis of `ProtocolToolsHolder_CT5`
and `CT5Init` (the Activity, and, where already cited, `CT5InitViewModel`)
is complete at the depth this document tracks. Every method, branch, and
cross-class call site relevant to admission, session lifecycle, and
advertisement decoding has been traced against jadx and, wherever jadx's
rendering of non-trivial control flow was suspect, independently
re-verified against smali — see "Advertisement decoder" and "CT5Init
activity" above and their confidence-table rows. Two threads this
document itself had left as bare citations (`Transmitter.sureClose`'s
provenance, `enterRecoveryMode()`'s effect) have since been traced and
closed, not merely re-described. `CT5Init`'s remaining untraced methods
(`m37049L` and similar activity-local helpers) are UI navigation/dialog
plumbing with no admission or protocol content; tracing them further
would not change any conclusion here.

Separately, `YuwellAnytimeSession._runNotification`'s generic exception
catch (`YuwellSessionFailureKind.notification`, in
`packages/cgm_yuwell_anytime`) has been checked three independent ways: a
full manual trace of every throw site inside `_handleNotification` (each
already funnels into a more specific failure kind or is a guarded
no-op), a coverage-tool run confirming it is the only
failure-kind-related line in `driver.dart` with zero test coverage, and a
check of whether `_publishFailure` itself could throw uncaught there (it
cannot: it independently guards `_closing`/`_snapshotController.isClosed`
before doing anything). It presents as an unreachable defensive backstop
through the public synthetic-test surface, not a live condition.

Neither of these is a closed door — a new decompiled artifact, a specific
notification-reachability angle, or physical target evidence for the
native-algorithm `HARD UNKNOWN` below would all extend this record. Re-
digging the same two classes or re-asking the same general question
without one of those would repeat already-recorded analysis rather than
extend it, the same way this document already declined to keep asking
Dom about the OTA lead once "OTA firmware-update path" closed it with a
documented negative finding.

## Required physical evidence

Before a live driver is registered, collect and independently review a
redacted evidence set that proves:

1. the 5P advertisement name, service/manufacturer fields, and stable identity;
2. GATT service, characteristic, and property topology;
3. notification-before-command ordering;
4. the target's version, lifetime, warmup, and firmware branch without exposing
   identifiers;
5. whether Android bonding occurs and how disconnect/reconnect behaves;
6. a separately approved read-only authenticated attach, including failure and
   unknown-outcome cases;
7. history record size, pagination, counters, deduplication, and timestamps;
8. live record size, integrity, error/status mapping, and reconnect behavior;
9. whether advertisement decoding matches authenticated GATT data; and
10. whether V1150 alternate records match the official value over a
    contiguous live/history series, and whether other firmware requires the
    unavailable native algorithm.

The initial capture is passive. OpenGlucose must not connect or write. If the
operator later uses the official app, that is a separate authorized action;
the capture harness only observes and records it.

## Hard unknowns

- The official stateful glucose algorithm and its clinical equivalence.
- Which of the three decoded calibration-code layouts the exact retail 5P uses.
- Whether V1150 transmitter-computed values are equivalent to the values that
  the application publishes after its native algorithm.
- Meaning/check digits of QR fields beyond the proved format, lifetime branch,
  and name matching.
- Exact 5P advertisement and GATT *topology* is now confirmed on one unit
  (see "First physical observation"); behavior beyond the version handshake
  (live/history/configure/initialize) on any target firmware remains
  unobserved.
- All status, warning, calibration, and error bits.
- Whether Android bonding is required or created.
- Persistence, replay, and retry behavior after interrupted writes.
- Safe activation, reset, unbind, transfer, and recovery semantics.

## Public reference sources

- [Official Anytime 5-family manual](https://cn.yuwell-poctech.com/Public/Uploads/uploadfile/files/20250902/AT5caiseshuomingshu.pdf)
- [Official Yuwell-POCTech CGM product page](https://en.yuwell-poctech.com/products/cgm)
- [OpenAnytime research implementation](https://github.com/qqqqqf-q/OpenAnytime)
- [xDrip CT5 interoperability discussion](https://github.com/NightscoutFoundation/xDrip/discussions/4303)

Public projects are corroborating evidence only. Review their licenses before
using code. Facts from a no-license repository may inform observations but its
code must not be copied.
