# Libre-family protocol capture runbook

This runbook prepares a controlled physical-device capture for a sensor that
the operator owns and is authorized to test. It is an engineering procedure,
not a sensor-compatibility claim. It does not authorize diagnosis, treatment,
dosing, or emergency use.

Do not touch a new sensor to the phone until the baseline capture is running
and the R3 gate in this runbook is approved. NFC activation or streaming setup
can change sensor state once and can be irreversible.

## Evidence labels

Every protocol statement in this runbook has one of these labels:

- **VERIFIED**: Directly observed in an audited reference implementation, an
  upstream source repository, or the current OpenGlucose policy. A reference
  result does not prove behavior on the target sensor.
- **TARGET-DEVICE-UNVERIFIED**: A capture hypothesis that must be confirmed on
  the exact sensor, firmware, phone, and operating-system combination.
- **HARD UNKNOWN**: Evidence is absent or depends on vendor-only material. Do
  not guess, copy a proprietary implementation, or send an experimental write.

Record the target model, firmware or patch metadata, phone model, OS version,
OpenGlucose commit, and test date in the redacted evidence report. Keep sensor
serials, Bluetooth addresses, and authentication material only in the private
raw capture.

## Protocol boundaries

### Abbott SAS-compatible Gen1 candidate path

**VERIFIED — reference implementation only**

The audited Abbott SAS-compatible reference path uses these Bluetooth GATT
UUIDs:

| Purpose                         | UUID                                   |
| ------------------------------- | -------------------------------------- |
| Primary service and scan filter | `0000fde3-0000-1000-8000-00805f9b34fb` |
| Login or authentication         | `0000f001-0000-1000-8000-00805f9b34fb` |
| Composite streaming data        | `0000f002-0000-1000-8000-00805f9b34fb` |

The Gen1 Bluetooth sequence in that reference is:

1. Find the FDE3 service.
2. Derive the streaming-unlock request from NFC bootstrap context.
3. Write the unlock request to F001.
4. After the write completes, enable notifications on F002.
5. Assemble each F002 reading from fragments of 20, 18, and 8 bytes, in that
   order. The encrypted composite packet is 46 bytes.
6. Discard an incomplete assembly after 10 seconds.

The audited Gen1 NFC path reads patch information with
`0x02 0xA1 0x07`. It reads FRAM with an ISO 15693 multiple-block request that
starts with `0x02 0x23`, or an extended request that starts with
`0x02 0xB3 0x07`.

The debug bridge treats the classic patch-information response as exactly one
ISO 15693 status byte followed by six patch-information bytes. That seven-byte
shape is a cross-source inference: one audited implementation validates the
status byte and strips it, then a separate layer requires six remaining bytes.
The bridge rejects an error status, a short or long response, and an unknown
three-byte model signature. It classifies security generation independently
from patch-information byte 2. The currently accepted Libre 2 and Libre 2 Plus
signatures all select the Gen1 mapping; this table is not evidence for a Gen2
target.

The Flutter event boundary receives only closed states: listening, neutral NFC
tag detection, metadata reading, verified model identification, a generic
failure reason, or `warmingUp` after the one-shot activation path independently
decrypts both FRAM images, validates all three CRC regions, and proves the exact
state transition. It never receives a UID, raw response, security generation,
native exception, raw lifecycle byte, unverified lifecycle claim, or glucose
value. Patch information alone does not establish activation, warmup, streaming
readiness, or a connection.

The debug-only physical harness separates patch classification from a Gen1
FRAM read. Both remain R3 because the exact target is unverified, even though
the reviewed commands are read-only in reference implementations. The first
grant permits one patch-information request only. A successful known Gen1
classification writes a closed `nfc-patch-info-context.json` with exact
native/process/build/target bindings and a SHA-256 of the six-byte payload. It
does not persist the UID or payload.

A second, mutually exclusive 90-second grant uses operation
`target_unverified_gen1_fram_read` and adds that patch payload hash to the
original 12-field grant schema. It requires a fresh exact Gen1 patch context,
fresh current target context, same `e007` target hash, same process/build, and
model `libre2` or `libre2Plus`. Unknown models, Gen2, added fields, stale times,
or cross-bound context fail closed.

The separately reviewed FRAM sequence covers blocks 0 through 42 in 15
standard ISO 15693 `0x23` requests. A request reads no more than three 8-byte
blocks; the final request reads block 42. Success requires exactly 344 bytes.
There is no automatic retry and no `0xB3`, `0x20`, activation,
enable-streaming, authentication, or BLE fallback. The sequence is:

1. first touch: approved patch-information classification;
2. remove the phone and verify the current target context again;
3. arm the distinct Gen1 FRAM grant; and
4. second touch within 90 seconds: patch revalidation and the fixed FRAM read.

The resulting exact 16-field app-private artifact contains algorithm-order UID,
six-byte patch information, and 344 encrypted FRAM bytes as lowercase hex. It
is restricted raw material. `collect-gen1-fram-capture` validates exact schema,
lengths, hashes, freshness, and session/build/target/patch bindings before an
atomic mode-`0600` host copy at
`restricted/nfc-gen1-fram-capture.json`. It prints only a neutral result and
artifact SHA-256. Never print or commit the artifact.

The artifact's `algorithmOrderUidHex` is already Android `Tag.getId()` order.
The collector hashes those eight bytes directly, without reversal, and binds
the `e007` manufacturer prefix to UID bytes 7 and 6. A consistent direct UID
therefore ends in `07e0`.

Decrypt only offline. All three independent FRAM CRC regions must validate
before any later state-changing experiment can be considered. Exact length,
successful transport, or a partial CRC result is not sufficient and does not
authorize activation, enable-streaming, BLE login, or a retry.

The pinned Gen1 actual-send path derives four authentication bytes for command
number `0x1B` and sends one high-data-rate custom request shaped as
`02 A1 uid[6] 1B auth[4]`. It then rereads all 43 FRAM blocks. Another audited
integration computes the same five parameters but accidentally discards them
at its NFC transport boundary and sends the empty-parameter `A1` form used for
patch information; that dead-parameter call is not a competing activation
protocol. A separate reference flow sends inventory requests before its
activation attempt. OpenGlucose does not copy that preamble because the pinned
actual-send path does not require it. All of this remains reference evidence,
not target success proof.

The debug-only activation executor is restricted to model `libre2`, Gen1, and
a source capture that the offline validator classifies as CRC-valid
`notActivated`. Libre 2 Plus is blocked because the pinned actual-send evidence
does not independently establish its state-changing command. On the same NFC
touch, the executor revalidates patch information, rereads and decrypts FRAM,
requires all three CRCs and current `notActivated`, durably journals transmit
intent, and sends the exact request once. It accepts response shape only as a
transport observation. Success requires an immediate same-connection patch
recheck and CRC-valid FRAM lifecycle `warmingUp`. No retry, inventory preamble,
fallback, addressed variant, enable-streaming command, or BLE operation is in
this lane. Any result after durable intent without post-state proof is
`unknown_outcome` and blocks another grant.

**TARGET-DEVICE-UNVERIFIED**

- The target can use these UUIDs, packet lengths, and sequence.
- The target can use the Gen1 security branch selected from its patch metadata.
- The target can accept late join instead of first activation.
- The target can advertise a stable address or an address obtained during NFC
  bootstrap.

Do not claim retail Libre 2 compatibility from the UUID match alone.

**HARD UNKNOWN**

- Whether the target accepts the reference-derived activation request.
- The persistence and retry semantics of a failed activation write.

### Abbott SAS-compatible Gen2 candidate path

**VERIFIED — reference implementation only**

The audited Gen2 branch uses the same FDE3, F001, and F002 UUIDs. Patch metadata
selects the Gen1 or Gen2 security branch. The Gen2 Bluetooth sequence is:

1. Enable notifications on F001.
2. After the F001 client-configuration write completes, write one byte,
   `0x20`, to F001 to request a challenge.
3. Receive a 14-byte challenge notification on F001.
4. Combine the challenge with the NFC bootstrap authentication context.
5. Write a 19-byte authenticated request to F001.
6. Receive session information as two F001 notifications: 7 bytes and then 18
   bytes. The complete session-information value is 25 bytes.
7. Create the secure streaming session.
8. Enable notifications on F002.
9. Assemble F002 data as 20, 18, and 8-byte fragments into one 46-byte packet.
   Discard an incomplete assembly after 10 seconds.

The audited Gen2 NFC requests include:

- challenge: `0x02 0xA1 0x07 0x20`;
- patch attribute: `0x02 0xA1 0x07 0x22`;
- encrypted FRAM read: a request that starts with
  `0x02 0xA1 0x07 0x21`, or an extended request that starts with
  `0x02 0xB3 0x07`;
- authenticated enable-streaming command number: `0x1E`; and
- authenticated scan command number: `0x1F`.

The command numbers above identify capture states. They are not approved replay
commands. The authenticated response is verified before the reference accepts
the resulting Bluetooth session context.

**TARGET-DEVICE-UNVERIFIED**

- The target selects this branch from its patch metadata.
- The target uses the exact challenge, request, session, and stream lengths.
- The target exposes warmup and active data through this stream.
- The target permits a safe late join after another phone disconnects.

**HARD UNKNOWN**

- Target keys, key derivation, authenticated-command construction, and packet
  decryption.
- Target-specific counters, nonces, certificates, and replay protections.
- Whether a failed authentication consumes or changes durable sensor state.

Do not add a vendor binary, native security library, extracted key, or copied
algorithm to OpenGlucose. Implement only independently justified
interoperability behavior.

### Libre 3 and Libre 3-family sensors

Libre 3 is a separate protocol investigation. Do not reuse the Libre 2-family
UUIDs, fragment lengths, security branch, or state transitions without direct
evidence.

**VERIFIED — audited Abbott Lingo reference implementation only**

The audited GKS reference uses a data service at
`089810cc-ef89-11e9-81b4-2a2ae2dbcce4` and a security service at
`0898203a-ef89-11e9-81b4-2a2ae2dbcce4`. Important reference characteristics
use the same suffix and these prefixes:

| Purpose          | UUID prefix |
| ---------------- | ----------- |
| Patch control    | `08981338`  |
| Status           | `08981482`  |
| Realtime glucose | `0898177a`  |
| Historic glucose | `0898195a`  |
| Clinical data    | `08981ab8`  |
| Event data       | `08981bee`  |
| Factory data     | `08981d24`  |
| Security command | `08982198`  |
| Challenge        | `089822ce`  |
| Certificate      | `089823fa`  |

Its full-authentication branch exchanges application and patch certificates,
starts ECDH, exchanges ephemeral keys, derives an authorization context, and
then performs a symmetric challenge. The patch challenge is 23 bytes:
`R1[16] || nonce1[7]`. The application encrypts
`R1[16] || R2[16] || PIN` and verifies a patch response containing
`R2[16] || R1[16] || kEnc[16] || ivEnc[8]`. Certificate and challenge values
are transported in offset-prefixed 20-byte fragments.

After authorization, the reference uses AES-CCM with a 16-byte session key, a
4-byte authentication tag, and a 13-byte nonce made from a 2-byte sequence, a
3-byte packet descriptor, and an 8-byte session IV. A realtime glucose record
is 57 encrypted bytes assembled from 19, 18, and 20-byte notifications.

The reference NFC flow distinguishes activation from an explicit
`switch-receiver` operation for an already paired patch. Payload construction,
certificate validation, ECDH, and key derivation depend on native protected
code. The reference does not use Android bond deletion as its phone-move
operation.

**TARGET-DEVICE-UNVERIFIED**

- The target advertises the audited GKS data service and exposes the same
  service map.
- The target presents the same certificate/challenge and session exchange.
- The target uses the same notification fragmentation and AES-CCM framing.
- Its NFC state supports activation or switch-receiver with the same semantics.
- Its warmup, expiry, retry, and phone-move behavior matches the reference.

**HARD UNKNOWN**

- Target certificate validity, application credentials, PIN/bootstrap context,
  ECDH/key derivation, and session-resumption rules.
- Target activation and switch-receiver payload construction.
- Firmware-specific data interpretation, warmup mapping, integrity failures,
  and recovery behavior.

The audited GKS reference exposes these patch-state codes. They are
**VERIFIED only in that reference and TARGET-DEVICE-UNVERIFIED**:

| Code | Reference state       |
| ---- | --------------------- |
| 0    | `manufacturing`       |
| 1    | `storage`             |
| 2    | `insertionDetection`  |
| 3    | `insertionFailed`     |
| 4    | `paired`              |
| 5    | `expired`             |
| 6    | `terminatedNormal`    |
| 7    | `error`               |
| 8    | `errorTerminated`     |

Stop at passive capture for Libre 3 until each required write has an evidence
source, a parser, a deterministic fixture, and explicit R3 approval when the
write can change sensor state.

## Reference state branches

The following branches are **VERIFIED in the audited Abbott SAS-compatible reference
implementation**. They are names for capture classification. They are not yet
OpenGlucose behavior and are not verified on the target.

### Sensor state

- `noSensor`;
- `warmup`;
- `ready`; and
- `expired`.

Patch-specific warmup and wear durations determine the reference state. Do not
hard-code one duration for all Libre-family sensors.

### Sensor result and error state

- `noError`;
- `rfTransmissionError`;
- `notCompatible`;
- `insertionFailure`;
- `expired`;
- `alreadyStarted`;
- `removed`;
- `responseCorrupt`;
- `terminated`;
- `notActive`;
- `temperatureTooLow`;
- `temperatureTooHigh`;
- `temporaryProblem`;
- `inWarmup`;
- `earlyAttenuation`;
- `contextCorrupt`; and
- `internalError`.

Preserve unknown values in capture data. Fail closed on malformed,
unauthenticated, or integrity-failed data. Do not translate an unknown state to
ready.

### Bluetooth and authentication state

The audited reference distinguishes:

- Bluetooth enabled or disabled;
- scan initiated;
- sensor discovered;
- connected;
- services discovered;
- authentication started;
- authenticated;
- stream subscribed; and
- disconnected.

In the reference, connect success starts service discovery. Disconnect emits a
disconnect event, clears the current authentication state, and can start a
reconnect attempt. Record these as separate transitions. Do not treat an
automatic reconnect as target-verified behavior.

For a new, absent, or expired selection, the reference evaluates activation or
late-join rules before it enables streaming and stores the selected device. For
an existing selection, it scans for that sensor. A warmup result includes the
remaining warmup time. These branches need target evidence before they become
product behavior.

## Risk gate

### R2 capture actions

R2 applies to health/device data, BLE observation, diagnostics, and physical
protocol capture that does not intentionally change durable sensor state. The
accountable owner is `@shroominic`.

Permitted after the capture-preflight check:

- inspect ADB/device state;
- take screenshots, UI trees, and Bluetooth/NFC system snapshots;
- record local app events, Logcat, and Bluetooth HCI traffic;
- observe advertisements without connecting; and
- parse existing captured bytes with offline, deterministic tools.

Connection, pairing, characteristic writes, and NFC contact are not passive
when their side effects are unknown. Keep them behind the R3 gate for a new
sensor family or unverified target.

### R3 sensor-changing actions

R3 applies before any operation that can activate, start, reset, terminate,
unpair, change ownership, persist a bond, enable streaming, or send an unknown
or destructive write. It also applies to a retry when the first write might
have succeeded despite an error response.

Before an R3 action, record all of the following in the private test plan:

1. accountable owner and explicit approval;
2. exact sensor family and redacted target description;
3. exact command and evidence source;
4. expected response, timeout, and single-attempt rule;
5. known durable side effects and stop conditions;
6. fail-closed implementation and kill switch;
7. offline fixture or disposable-target rehearsal evidence;
8. recovery or vendor-supported fallback; and
9. confirmation that no unresolved P0 or P1 finding exists.

Never infer R3 approval from the presence of a connected sensor. Stop if a
native pairing prompt, unexpected write, new service map, malformed response,
or state mismatch appears.

## Capture preflight

Complete all items before sensor contact:

- Use a dedicated, authorized Android phone with USB debugging approved for
  this computer.
- Verify that exactly one ADB target is selected.
- Record phone model, Android version, Bluetooth stack state, NFC state, app
  version, and source commit in a private manifest.
- Verify Bluetooth HCI snoop capture and a tested extraction route. A setting
  that says enabled is not proof that the bug report contains the trace.
- Start continuous all-buffer Logcat capture without clearing existing logs.
- Start the debug-only app BLE recorder when available.
- Use a neutral random capture directory outside the Git worktree. Set its
  permissions to owner-only.
- Confirm that no vendor app or second phone is actively connecting to the
  sensor. Do not uninstall another app or remove a bond as part of preflight.
- Take the `00-baseline-phone` and `01-app-idle` snapshots.
- Confirm the R2 owner and obtain the R3 approval before NFC contact or a
  connection that can pair, authenticate, activate, or enable streaming.

## Snapshot contract

Emit a neutral marker before each snapshot. Use the exact label as the marker
and filename prefix. Each snapshot should contain, when available:

- UTC and monotonic timestamps;
- screenshot and UI hierarchy;
- activity and window state;
- Bluetooth manager and NFC service state;
- app package state;
- the current app-trace sequence number;
- the current HCI/Logcat file offsets; and
- the fixed omission reason for operator free text. The harness does not accept
  free-text observations because they can contain unreviewed identifiers.

Do not stop the continuous capture between snapshots.

### Normal-path labels

| Label                       | Capture point                                                     | Gate                                          |
| --------------------------- | ----------------------------------------------------------------- | --------------------------------------------- |
| `00-baseline-phone`         | App stopped or before the test surface is opened                  | R2                                            |
| `01-app-idle`               | App open, no sensor contact                                       | R2                                            |
| `02-advertisement-observed` | Matching advertisement first appears; no connection               | R2                                            |
| `03-nfc-detected`           | First target NFC detection, before an app write                   | R3 for first target contact                   |
| `04-patch-metadata`         | Patch or model metadata parsed                                    | R3 session                                    |
| `05-activation-requested`   | Immediately before the one approved activation or late-join write | R3                                            |
| `06-activation-response`    | Response or timeout from that write                               | R3                                            |
| `07-ble-connected`          | Bluetooth connection callback                                     | R3 if pairing or persistent state is possible |
| `08-native-pair-prompt`     | Native pairing UI first appears                                   | R3                                            |
| `09-bonded`                 | Phone reports the new bond                                        | R3                                            |
| `10-services-discovered`    | Full service and characteristic map is available                  | R3 session                                    |
| `11-auth-challenge`         | Challenge request and response are complete                       | R3 session                                    |
| `12-auth-session`           | Authenticated session context is accepted                         | R3 session                                    |
| `13-stream-subscribed`      | Stream notifications are enabled                                  | R3 session                                    |
| `14-warmup`                 | First confirmed warmup state and remaining-time evidence          | R3 session                                    |
| `15-first-composite`        | First complete authenticated packet, before normalization         | R3 session                                    |
| `16-first-reading`          | First normalized reference reading with freshness state           | R3 session                                    |
| `17-disconnect-recovery`    | Controlled disconnect and observed recovery behavior              | R3 session                                    |

If Bluetooth advertisement starts only after NFC setup, `02` follows `06`.
The label numbers identify states, not a required false ordering.

### Error-branch labels

Take an immediate snapshot and stop automatic retry for these branches:

- `E01-native-pair-failed`;
- `E02-service-discovery-timeout`;
- `E03-auth-length-mismatch`;
- `E04-auth-integrity-failed`;
- `E05-stream-fragment-timeout`;
- `E06-device-disconnected`;
- `E07-unexpected-write`;
- `E08-unknown-service-map`;
- `E09-sensor-state-mismatch`; and
- `E10-capture-gap`.

Add a new neutral error label when none applies. Do not put a sensor ID,
Bluetooth address, glucose value, or authentication byte in the label.

## Bond and phone-move boundary

Bond deletion is not a supported move-to-another-phone flow.

- Deleting the local Android bond does not prove that the sensor released the
  old session, identity, or ownership state.
- A disconnect callback must not automatically delete a bond.
- Repeated bond deletion can destroy evidence and make recovery harder.
- Do not reset or terminate an active sensor to make a move appear successful.
- First stop the old app connection and isolate the old phone. Then use only a
  vendor-supported move flow or a separately reviewed and physically verified
  OpenGlucose flow.

A future move feature needs an explicit capability, model/firmware evidence,
idempotency rules, old-phone and new-phone state checks, failure recovery,
redacted physical-device evidence, and R3 approval.

## Raw-data handling

All protocol captures are restricted health data or sensitive device data,
even when no glucose value is visible. This includes HCI snoop files, Logcat,
bug reports, app JSONL traces, NFC payloads, advertisements, screenshots, UI
trees, system dumps, pairing material, and operator notes.

- Keep raw files outside the repository in an owner-only directory.
- Use neutral session and filenames. Never use a sensor serial, address, person
  name, or glucose value in a path.
- Do not print raw payloads or identifiers to the shared terminal transcript.
- Do not commit, attach to GitHub, paste into an issue or PR, or upload to a
  third-party analysis service.
- Hash each raw artifact and keep the hashes in the private manifest.
- Set an owner, purpose, and deletion date before capture.
- Produce a separate redacted evidence report. Include state names, byte
  lengths, ordering, timing ranges, error classes, hashes, and the source
  commit. Exclude payload bytes and stable identifiers.
- Treat a screenshot or bug report as restricted until a human verifies its
  redaction.
- Stop and follow the privacy/security incident runbook if an artifact is
  exposed.

Production builds must not enable raw protocol recording. A debug recorder must
fail without changing BLE behavior when its local sink is unavailable, and its
human-readable output must remain redacted.

## Completion criteria

Preparation is complete only when:

1. one authorized phone is visible to ADB;
2. continuous Logcat and debug app capture are running;
3. HCI capture and extraction are proven with a harmless Bluetooth event;
4. `00-baseline-phone` and `01-app-idle` exist and have hashes;
5. raw-data storage and retention controls are active;
6. the target-family hypothesis is selected without conflating Libre 2 and
   Libre 3; and
7. the required R2 ownership and R3 approval are recorded.

Only then can the operator receive an explicit instruction to make sensor
contact. A partially configured logger is not ready.

## Reference inputs

### Bench activation evidence, 2026-09-05

On the operator-owned Android bench setup, the explicit NFC read identified
Libre 2 Gen1 and verified `notActivated` with all three FRAM CRCs. The host
validator initially rejected the recorder's v2 envelope; exact collector-bound
v2 support fixed that mismatch without changing the protected source or the
cryptographic checks. A separate contact then completed one activation.
The durable journal reports `post_state_verified`, `verified`, and
`warmingUp`. The activation grant was consumed. Protected snapshots retain
the response and warmup evidence outside Git. No activation retry is needed.

This establishes that activation worked on this bench sensor. It does not
establish wearable glucose accuracy, BLE streaming, or calibrated glucose
decoding. Native streaming setup and BLE receiver testing follow separately.

### Private Gen1 receiver implementation

The private Android build adds `OG_PROTOCOL_CAPTURE_LIVE_LIBRE=true` to the
existing Libre trace flags. Normal debug/release builds remain unaffected.
Connection stays on the home screen and searches Bluetooth first. An empty or
failed search offers `Can't find your sensor?` and then named model help.
AiDEX/LinX remains on Bluetooth; NFC instructions appear only after selecting
FreeStyle Libre 2. After a fresh CRC-validated `warmingUp` or `active` NFC read,
the inline connection flow can start a separate streaming setup contact. Native code
holds an exact RF lease, rechecks the target and lifecycle, and durably commits
one streaming intent before sending. An uncertain transmitted result blocks
another enable command. The receiver bootstrap and login counter are encrypted
with Android Keystore and excluded from backup.

The app restores the saved receiver before discovery and routes the exact
response-derived target to `LibreGen1Driver`. The driver waits up to 150 seconds
for a fresh exact-target FDE3 advertisement, ignores older cached observations,
and confirms scan cancellation before one physical connection attempt. This
contract is preserved through the shared scanner and recording wrappers;
unsupported transports fail without falling back to a retrying connection.
Each explicit BLE connection reserves a counter before its with-response F001
login, persists the outcome, then subscribes to F002. Strict fragment assembly
and decryption validate packet CRCs. No automatic reconnect, unpair, or reset
is part of this path. No `CgmReading` is produced until a validated glucose
conversion is implemented; raw ADC values must not be labeled mg/dL.

A verified activation can replace the prior `notActivated` result only when
the native journal matches the same explicit read attempt and target. After an
app restart, a separate closed query can report that the last activation
completed. This historical result does not establish the current sensor state
or prove a Bluetooth connection.

### Pinned sources

The protocol map combines a locally audited Abbott SAS-compatible reference
implementation with pinned open-source interoperability investigations:

- [xDrip Libre NFC reader at `7c14016`](https://github.com/NightscoutFoundation/xDrip/blob/7c14016d5f1c05e4b1687e955c644431a496e9a2/app/src/main/java/com/eveningoutpost/dexdrip/NFCReaderX.java)
- [Juggluco at `11d016e`](https://github.com/j-kaltes/Juggluco/tree/11d016eb3aeffe77e86d9522f5192e83790b5a21)
- [LibreTools at `d54b088`](https://github.com/ivalkou/LibreTools/tree/d54b0883959420e5941ed293ec6b9ef2474b7ed3),
  whose Gen1 primitive and decryptors are MIT licensed
- [DiaBLE at `e6a909c`](https://github.com/gui-dos/DiaBLE/tree/e6a909c88faeada49f461d30834174cd95db4042),
  whose Gen1 activation, enable-streaming, and BLE-login flows are MIT licensed
- [Libre3Bridge](https://github.com/EasyLars/Libre3Bridge)

These projects are evidence sources, not dependencies or compatibility
certificates. Do not import their protected material, third-party binaries, or
sensor-specific secrets.

The pinned clear-source review found a complete independently portable Gen1
path but no complete Libre 2 Gen2 challenge/session/decryption path. Activation
starts the sensor; enable-streaming changes its receiver association. Keep both
as separately approved R3 operations. Do not reuse DiaBLE's factory-glucose
calibration: that section cites GPL-3.0 xdripswift and is outside the approved
MIT-only implementation boundary.
