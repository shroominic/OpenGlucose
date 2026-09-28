# cgm_libre2

Pure Dart classification, framing, handshake planning, and an explicitly
NFC-bootstrapped Gen1 BLE driver for the audited Abbott SAS-compatible Libre
2-family reference paths.

> [!CAUTION]
> Every match and state in this package is **reference-verified and
> target-unverified**. A matching UUID or sequence does not establish retail
> Libre 2 compatibility. This package is for deterministic capture analysis
> and integration planning, not diagnosis, dosing, treatment, emergency
> monitoring, or unreviewed live sensor use.

## Implemented boundary

- strict 16-bit and 128-bit UUID normalization and role classification;
- conservative SAS, GKS, incomplete, ambiguous, malformed, and unknown GATT
  topology classification;
- observation-driven Gen1 and Gen2 sequence state machines;
- exact one-byte recorded challenge-request, 14-byte challenge, and 19-byte
  authenticated-request length checks;
- exact 7+18 byte Gen2 session-information assembly;
- exact 20+18+8 byte, 46-byte encrypted composite assembly;
- deterministic 10-second incomplete-composite discard;
- one-action-at-a-time Gen1/Gen2 live handshake planning with stale-operation
  rejection and no automatic retry;
- the reference-verified Gen2 `0x20` challenge-request action, still marked
  target-unverified and with its BLE write mode unresolved;
- typed BLE, NFC bootstrap, Gen1 authorization, Gen2 authentication, and
  verified-session boundaries;
- strict eight-byte algorithm-order UID and six-byte Gen1 patch-information
  inputs for a closed Libre 2/Libre 2 Plus reference model set;
- pure Gen1 UID-derived primitive, exact 43-block FRAM decryption with header,
  body, and footer CRC validation, and exact 46-byte BLE decryption with CRC
  validation;
- closed Gen1 lifecycle evidence from byte 4 of an already CRC-verified,
  decrypted FRAM value, with all unsupported values mapped to `unknown`;
- pure, redacted plans for the five-byte activation parameters, nine-byte
  enable-streaming parameters, and twelve-byte with-response F001 login value;
- immutable opaque-byte events and payload-free typed errors;
- a concrete Gen1 BLE session over the workspace `cgm_ble` contract, restricted
  to the exact device address returned by the reviewed NFC streaming executor;
- a bounded fresh-advertisement wait before one physical connection, with
  explicit one-attempt transport capability and no default-connect fallback;
- durable login-counter reservation before one F001 write with response,
  durable outcome recording before F002 subscription, and CRC-validated packet
  diagnostics without publishing uncalibrated values as glucose.

The package depends only on the existing sensor-neutral `cgm_core` and
`cgm_ble` workspace contracts; it has no Flutter, native-plugin, network, or
platform-storage dependency. The private capture validator uses Dart `crypto`
for SHA-256 bindings and Dart `ffi` for its descriptor-bound POSIX file read.
The live planner remains pure; only the explicit Gen1 driver executes BLE.

## Deliberate exclusions

There is no bonding, NFC executor, receiver-switch operation, Gen2
authentication, certificate, nonce, or built-in glucose conversion. There is
no retry of failed or uncertain login commands. The package derives Gen1 activation and
enable-streaming bytes but cannot transmit them. Those operations belong to
the separately reviewed native executor. A lifecycle classification, activation
response, or streaming response alone is not proof of a working BLE session.
The explicit Gen1 driver can transmit a derived BLE login only after a protected
bootstrap provider and durable counter store supply the required inputs.

Gen1 authorization and Gen2 session verification can enter the machine only as
explicit results from isolated external providers. Sensitive bootstrap and
session contexts remain opaque. The planner and state machine perform no I/O
and never treat an external result as target evidence.

Gen1 and Gen2 use the same audited SAS UUID topology. Callers must select a
generation from separately reviewed patch evidence. `unknown` fails closed;
the classifier never guesses a generation.

## Offline example

```dart
import 'package:cgm_libre2/cgm_libre2.dart';

final topology = classifyLibreTopology(<LibreGattServiceSnapshot>[
  LibreGattServiceSnapshot(
    uuid: 'fde3',
    characteristicUuids: const <String>['f001', 'f002'],
  ),
]);

final machine = LibreProtocolStateMachine(
  generation: LibreSecurityGeneration.gen2,
);
machine.process(const LibreConnectedObservation());
final events = machine.process(LibreTopologyObservation(topology));

assert(
  events.every(
    (event) =>
        event.evidenceStatus ==
        LibreEvidenceStatus.referenceVerifiedTargetUnverified,
  ),
);
```

Raw notification payloads are restricted device data. Although opaque events
expose immutable bytes for a later reviewed parser, their `toString` methods
redact the bytes. Do not print or commit real captures.

## Live Gen1 integration

`LibreGen1Driver` requires a `BleTransport` with verified
`BleSingleAttemptTransport` capability, a
`LibreGen1StreamingBootstrapProvider`, and a `LibreGen1LoginCounterStore`.
The application must supply these explicitly; package import does not start
Bluetooth or register the driver. The provider must return the protected,
journaled NFC streaming result with initial patch information, algorithm-order
UID, chosen streaming base, exact Android address, and a permitted lifecycle
at the NFC bootstrap. Passive NFC detection and sensor activation
alone cannot bootstrap the driver.

Call `reloadBootstrap()` after NFC streaming setup. The `bootstrappedSensor`
getter provides the exact selected target for direct connection; a shared scan
registry can instead use `mapScanResult`. Discovery never guesses from a name,
UUID, or nearby device. `connect` reloads and rechecks the bootstrap so a stale
selection cannot authorize a replaced target.

After a Dart restart, `reloadBootstrap()` can restore the saved target without
scanning, connecting, reserving a counter, or repeating NFC setup. The protected
store remains authoritative: a missing or unreadable result clears the cached
target, and a new explicit connection reserves the next durable count even if
the previous login outcome was unknown. The saved lifecycle is historical
evidence, exposed as `lifecycleAtNfcBootstrap`; it cannot establish a current
warmup countdown, sensor age, or readiness. Wall-clock time and received
CRC-valid packets do not promote that evidence into a glucose reading.

Before connecting, the session enters `awaitingAdvertisement` and scans for
up to 150 seconds. This bounded window accommodates the roughly two-minute
advertisement gaps observed during local target testing; it is not a guarantee
that a sensor is present. Only the exact bootstrap address advertising FDE3 is
accepted.
`BleScanResult.observedAt` must be within the current attempt, not a cached
observation or an undated result. The timestamp must describe the original
advertisement, not when a wrapper replays it. The session waits for scan
cancellation to finish before calling `connectOnce`; a failed or uncertain
cancellation blocks connection and retains the driver lease. The default
`connect` method is never used. The app's shared and recording wrappers must
forward the one-attempt capability without adding retries. Existing drivers
can continue to use the default transport connection behavior.

`advertisementTimeout` can shorten the 150-second bound, and `utcNow` supports
deterministic tests. Neither option changes login sequencing or authorizes a
retry. A timeout, missing target, or cancellation sends no login and reserves
no login counter.

The driver checks the exact FDE3/F001/F002 topology and characteristic
properties. It reserves a new counter durably before one F001 write with
response. The durable store must reject missing/replaced bootstrap IDs and
never reuse a reserved count. Only a completed write and durable acknowledgement
permit F002 subscription. Unknown outcomes consume the counter. Another login
requires a new explicit connection unless it is the single guarded recovery
described below; all snapshots disable the app's generic automatic reconnect.
No bond, bond-removal, MTU, or additional characteristic command is sent.

`LibreGen1Session.currentStatus` and `statuses` expose only closed phases,
failure kinds, and the number of CRC-validated composite packets. Its normal
`CgmSessionSnapshot` contains equivalent redacted diagnostics and, by default,
no glucose reading, raw history, or calibration data. A CRC-valid packet proves
receipt and integrity, not calibrated glucose accuracy. Raw ADC values must
not be shown as mg/dL.

Each physical disconnect or failure invalidates the current attempt.
Unconfirmed transport cleanup retains the driver lease and blocks another
connection. Explicit `LibreGen1Session.disconnect()` then preserves its terminal
`cleanupUnconfirmed` snapshot and closes Dart streams, but throws the closed
`LibreGen1LiveException(cleanupUnconfirmed)` instead of reporting success.
Repeated calls return the same failed future; a late transport completion does
not clear the quarantine or retry cleanup. The application must not interpret
closed Dart streams as a confirmed sensor disconnect.
Notification data arriving during subscription acknowledgement is
bounded to one exact composite packet and processed only after acknowledgement.

One explicit user session permits at most one recovery, and only after a
durably acknowledged login, confirmed subscription, at least one valid packet,
and an actual unexpected physical-disconnected event. Stream errors or stream
completion alone cannot trigger it. Recovery waits for confirmed cleanup,
rereads and compares the exact bootstrap, starts a new fresh-advertisement
window, and reserves a new durable counter for one new login. Missing evidence,
invalid packets, cancellation, failed cleanup, or any failed replacement stop
without another attempt. Success does not replenish the budget. Recovery never
repeats NFC or bond operations. The `reconnecting` phase and
`cgm.libre2.recoveryAttempts` metadata expose this bounded behavior.

The debug shared transport holds scan-pause ownership for the whole
`connectOnce` connection, not merely connection setup. It resumes scanning only
after confirmed connection cleanup; failed or timed-out cleanup quarantines
ownership. Default transport connections used by AiDEX remain unchanged.

## Optional current-sample conversion

`glucoseDecoderProvider` is an optional injection point, not a bundled glucose
algorithm. Its `prepare` operation must bind independently reviewed calibration
evidence to the exact bootstrap without sensor I/O. It is called again for a
replacement connection. No GPL implementation or dependency is included here.

The driver sends only CRC-valid composites to the injected decoder. It accepts
a current result only with no rejection, finite positive mg/dL, sensor age
60–65535 minutes, matching sample age, and a positive unexpired expected
lifetime when supplied. Accepted minutes must increase across the entire user
session, including recovery. Values use the receipt UTC time and vendor source,
are explicitly display-provisional, and contain no raw values. Missing evidence
and decoder errors leave transport running with only
closed `cgm.libre2.decoder` outcomes. They do not expose exception text or
convert old FRAM lifecycle evidence into a current warmup timer. Supplying a
decoder requires separate licensing, calibration, and physical-device review.

### Received-sample history

Each accepted current sample also enters immutable `snapshot.history`, ordered
by strictly increasing sensor minute. This is collection of incoming readings,
not sensor-memory backfill: the driver does not request, interpolate, or invent
missed minutes, sparse trend samples, or earlier history. `supportsHistory`
remains false and `syncHistory` remains unsupported because this driver cannot
perform an on-demand sensor history sync.

Each point keeps its first accepted value and original receipt UTC timestamp.
The timestamp is not a sensor measurement time or an inferred activation time.
Repeated or older minutes cannot replace a point, including across recovery or
after buffer eviction. Phone-clock changes do not rewrite earlier timestamps;
wall-clock ordering can therefore differ from sensor-minute ordering.

`historyLimit` bounds the in-memory rolling buffer from 1 to 65,536 readings.
The default is 65,536, enough for the entire accepted 16-bit sensor-minute
domain. A smaller limit evicts the oldest accepted minute, without resetting
the session's deduplication baseline. Previously published history lists cannot
be changed by the driver or callers.

History survives the one guarded connection recovery, rejected samples,
decoder errors, and disconnect in the same explicit session. Keeping earlier
points does not make the current state healthy: warmup, expired/invalid data,
and failed/disconnected transport still suppress the current reading and retain
their non-ready state. A new explicit session starts with empty in-memory
history; the application owns any local persistence or restoration. All points
remain display-provisional. Applications must retain that quality flag and
must not treat history collection as permission to export or validate readings.
No sensor-start time, remaining life, or current lifecycle is inferred here.

The two new package dependencies are existing MIT workspace contracts. They
add no external package, native permission, cloud destination, or background
service. App composition and its protected native storage retain those duties.

## Pure Gen1/Gen2 planner boundary

`LibreLiveHandshakePlanner` is a pure coordinator for a future application
driver. It emits exactly one pending transport or security action and requires
the matching operation ID before it advances. A stale callback fails closed;
disconnect clears the pending security context and does not reconnect.

The application must separately provide all of the following before a physical
handshake is possible:

- a streaming-ready NFC bootstrap context and evidence-backed generation
  selection;
- Gen1 authorization or Gen2 authenticated-request/session verification;
- a BLE adapter bound to the selected device;
- target evidence for write-with-response versus write-without-response; and
- an explicit physical-device approval gate and capture/stop policy.

Passive NFC detection is not a streaming-ready bootstrap context. The pure
planner does not acquire one or execute an action. The separate Gen1 driver
above supplies its concrete transport sequence only with explicit providers.

## Gen1 offline core

`LibreGen1OfflineCore` accepts a UID that the platform has already normalized
to the algorithm byte order and exact six-byte patch information. It rejects
unknown model signatures and every non-Gen1 security marker. A platform UID is
not automatically reversed. For the audited Android NFC-V path,
`Tag.getId()` is already in the Gen1 algorithm order; reversing it makes the
pinned Example2 FRAM vector fail its CRC checks.

FRAM input is exactly 344 bytes. Decryption succeeds only if the header, body,
and footer CRCs all pass. BLE input is exactly 46 bytes; the two-byte seed is
not part of the returned 44-byte plaintext, and its trailing CRC must pass.
Both results remain opaque restricted device data. The lifecycle parser accepts
only the private-constructor `LibreGen1DecryptedFram` result. It maps FRAM byte
4 values `0x01` through `0x06` to the closed states `notActivated`, `warmingUp`,
`active`, `expired`, `shutdown`, and `failure`; every other value is `unknown`.
Its result contains no source byte or glucose data and remains
reference-verified, target-unverified evidence. It does not authorize an NFC or
BLE operation.

The command plans are data-only. They identify the `0xA1` custom-command shape,
reference-handled response length, state-changing intent, and the reference BLE
with-response/F002 ordering. They do not execute, retry, persist a streaming
base or counter, accept a response, or claim target compatibility.

## Private Gen1 capture validator

The offline CLI accepts exactly one explicit file named
`nfc-gen1-fram-capture.json`:

```sh
dart run tool/validate_gen1_fram_capture.dart \
  /absolute/private/path/nfc-gen1-fram-capture.json
```

On macOS and Linux, the file must be regular, no larger than 16 KiB, not a
symbolic link, readable by its owner, and inaccessible to its group and world.
The validator uses `O_NOFOLLOW`, keeps one descriptor through the bounded read,
and checks type, permissions, size, and change metadata through that descriptor.
Other platforms fail closed. The CLI does not search a directory, write a file,
contact a network, spawn a helper command, or construct or send a sensor
command. It accepts the exact 16-field host schema v1 or the exact 18-field
explicit-read schema v2 after the protected collector binds it to a host capture
session. Schema v2 requires `sourceKind: explicitLibre2Lifecycle`, a valid
`explicitAttemptId`, and model `libre2`; an unbound null capture session is
rejected. Neither schema accepts extra fields or escaped duplicate keys.
Both require closed Gen1 model metadata, a direct algorithm-order UID
SHA-256 binding, the UID-derived `e007` manufacturer prefix, the six-byte patch
SHA-256 binding, exact 344-byte encrypted FRAM input, all three FRAM CRCs, and
the closed lifecycle parser.

Success writes exactly one JSON line and exits zero:

```json
{"validated":true,"model":"libre2","lifecycle":"active","length":344,"evidenceStatus":"referenceVerifiedTargetUnverified"}
```

Failure writes exactly one JSON line containing one closed error code and exits
nonzero, for example:

```json
{"validated":false,"error":"invalid_schema"}
```

Output never includes a UID, raw bytes, digest, path, glucose value, native
error, parser exception, or stack trace. A valid result is read-only,
target-unverified lifecycle evidence. It does not authorize activation,
streaming enablement, Bluetooth login, or another sensor operation.

See [the third-party notices](THIRD_PARTY_NOTICES.md) and
[the evidence boundary](doc/evidence-boundary.md) for pinned provenance.

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib test tool
dart analyze --fatal-infos
dart test
```
