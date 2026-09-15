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
| `V1150` packed value equals published glucose | unknown | requires target differential capture on a `V1150` unit |

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
