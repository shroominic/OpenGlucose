# Libre-family protocol capture

This runbook prepares a high-detail Android diagnostic recording before an
operator presents a sensor to a phone. It is an evidence-collection procedure,
not a Libre 2/3 implementation or a compatibility claim. The harness does not
install or launch apps, change Bluetooth or NFC settings, scan, pair, bond,
unbond, clear log buffers, read or write GATT, transmit NFC commands, or send
commands to a sensor.

Use only a phone and sensor that you own or are authorized to test. OpenGlucose
is wellness/reference software. Do not use this procedure for diagnosis,
dosing, treatment, or emergency monitoring.

## Risk and stop boundary

Passive collection is **R2** because its output can contain restricted health
and device data, Bluetooth details, screenshots, system state, and app traces.
It needs an accountable owner, private storage, a retention decision, redacted
review evidence, and independent review.

The host harness stops before active protocol work. The dedicated observation
app also stays passive. Passive BLE advertisement scan is R2 and must use
reviewed transport boundaries. First target NFC contact, connection, pairing,
and every target-unverified RF command are R3 while side effects are unknown.
Any operation that activates, resets, retires, transfers, changes a sensor
session, removes a bond, writes calibration, or can irreversibly alter the
sensor is **R3**. Do not cross that boundary from an exploratory shell. R3 work
needs explicit accountable approval, a fail-closed control, rehearsal on
fakes, recovery/rollback evidence, and no unresolved P0/P1 finding.

The optional full-UI mode is not an observation-only app. It retains the
existing live AiDEX/LinX driver, including normal restored-session reconnect
behavior and its reviewed GATT operations. The harness records that work but
does not authorize it. Use the dedicated observation app when the approved
plan requires a strictly passive app surface.

When the operator uses a vendor or test app while capture is active, that app
can contact or change the sensor. The capture harness does not authorize that
action. Record the app/version and authorized test plan separately without
putting a real identifier in a filename or repository issue.

## Privacy and artifact handling

The output is restricted. It can contain glucose values, sensor or phone
identifiers, Bluetooth addresses, notification text, other apps visible on the
screen, UI accessibility text, package state, and packet material. In full-UI
mode the app-private BLE trace also records live AiDEX connection state,
service topology, reads, writes, notifications, and raw GATT bytes. A
bugreport can contain substantially more unrelated personal data.

- Use a private, access-controlled output directory with encrypted storage.
- Do not use a repository, synced public folder, issue attachment, chat, or CI
  artifact store. The tool rejects output inside any Git worktree or Git
  directory and creates roots/sessions/snapshots with mode `0700` and files
  with mode `0600`.
- Do not rename a state with a serial, address, person, glucose value, or free
  text. The CLI accepts only the neutral labels listed below.
- Keep the raw set unchanged for analysis. Work from a separate redacted copy.
  Redact screenshots, XML, logs, dumpsys, app JSONL, and bugreport contents—not
  only filenames. Recompute hashes for the redacted copy and identify it as a
  derivative.
- Keep raw evidence only as long as the approved investigation needs it, then
  delete it with the storage owner's approved process. A hash is an integrity
  check, not proof that the evidence is safe to share.

## Choose and bind the app mode

Use two terminals: one for Flutter and one for the host harness. Keep the same
`ANDROID_SERIAL`, `OPENGLUCOSE_CAPTURE_PROFILE`, and
`OPENGLUCOSE_CAPTURE_LIVE_AIDEX` values in the harness terminal for the full
session.

Choose the flags below now, but do not run Flutter until the host `start`
command in the start sequence has completed. The installed debug app must be
stopped during host startup.

For the strict observation-only surface, select the Libre profile and bind the
host to live AiDEX being off:

```sh
export OPENGLUCOSE_CAPTURE_PROFILE=libre
export OPENGLUCOSE_CAPTURE_LIVE_AIDEX=false

(
  cd openhealth
  flutter run --debug -d "$ANDROID_SERIAL" \
    --target lib/protocol_capture_main.dart \
    --dart-define=OG_PROTOCOL_TRACE=true \
    --dart-define=OG_PROTOCOL_CAPTURE_PROFILE=libre \
    --dart-define=OG_PROTOCOL_CAPTURE_LIVE_AIDEX=false
)
```

For the normal product UI with the existing AiDEX/LinX driver and concurrent
Libre-family recording, bind both the app and harness to live AiDEX being on:

```sh
export OPENGLUCOSE_CAPTURE_PROFILE=libre
export OPENGLUCOSE_CAPTURE_LIVE_AIDEX=true

(
  cd openhealth
  flutter run --debug -d "$ANDROID_SERIAL" \
    --target lib/main.dart \
    --dart-define=OG_PROTOCOL_TRACE=true \
    --dart-define=OG_PROTOCOL_CAPTURE_PROFILE=libre \
    --dart-define=OG_PROTOCOL_CAPTURE_LIVE_AIDEX=true
)
```

The `OPENGLUCOSE_...` value controls host verification. The matching
`OG_PROTOCOL_CAPTURE_LIVE_AIDEX` Dart define controls driver composition in the
debug app. The host stores the selected boolean in `session.properties` and
rejects later commands run with a different value. This prevents an
observation-only FDE3 scan from being mistaken for a full-UI scan, or the
reverse. `true`, `false`, and the two full UUID lists are literal contract
values; aliases are not accepted.

Full-UI recording is concurrent with the app, but it is not gap-free
background capture:

- The shared BLE scanner stops while a GATT connection starts and resumes in a
  `finally` path. Advertisements during that interval can be missed.
- Android NFC reader mode is available only while the Flutter activity is
  resumed. Pausing or backgrounding the activity disables NFC observation.
- Android can throttle or stop BLE work after the app leaves the foreground.
  This build has no foreground-service guarantee for continuous capture.

Thus, “background capture” means that the private recorder runs behind the
visible OpenGlucose screens while the app is open. It does not mean complete
operating-system background coverage or proof that every packet was recorded.

## Before the sensor is near the phone

Requirements: Android Platform Tools (`adb`), Git, `shasum` or `sha256sum`, one
unlocked and authorized USB-debugging phone, and Android's Bluetooth HCI snoop
developer setting already configured for **full** capture. The harness reads
that setting but never changes it. Some phones need a Bluetooth or phone
restart after the operator changes the setting; follow the phone vendor's
instructions before this runbook. Do not change it during a session.

Select the Android user that contains the debug app before `doctor` or `start`.
The harness reads `am get-current-user`, accepts only one canonical
non-negative Android user ID, and binds that ID into the private
`session.properties`. It does not enumerate or record Android user names. The
selected Android user must stay current for the full session. Each later
command and each app-private `run-as` operation checks the current user and
fails closed if it changed. Switch back to the original user before starting a
new session; do not reuse a session across Android users.

Choose a persistent directory outside every Git worktree:

```sh
export OPENGLUCOSE_CAPTURE_ROOT=/absolute/private/path/openglucose-protocol-captures
```

If more than one ADB target is present, select the authorized phone:

```sh
export ANDROID_SERIAL=authorized-adb-serial
```

Do not copy that value into notes or filenames. Verify readiness without
touching the sensor:

```sh
./scripts/libre-protocol-capture.sh doctor
```

`DEVICE READY` means exactly one selected authorized device, non-Git output, and at
least one Android setting/property reports full HCI snoop. It does **not** prove
that the OEM writes a snoop artifact, that every packet is present, or that the
app recorder is running, or that sensor contact is approved. If doctor reports
filtered, disabled, or unverified,
stop. Change settings manually only under the approved device plan, then run
doctor again.

## Start and snapshot sequence

Start before Flutter and before the sensor is near the phone. Quit the debug
app first; the harness does not stop it for you. `start` rejects a running
debug app, and an uncertain process check also fails closed before app storage
is changed. Wait for `start` to complete before launching Flutter.

The command starts continuous
`logcat -b all` without clearing existing buffers, inserts a neutral session
marker, records HCI-setting evidence, and takes a baseline snapshot. It prints
the absolute session directory:

```sh
SESSION=$(./scripts/libre-protocol-capture.sh start \
  --package com.openglucose.app.debug)
```

Host startup removes stale grant artifacts under the app-private NFC RF lease
and holds that lease through its baseline snapshot. Running it alongside the
app's capture startup or paused-state heartbeat can disable capture readiness.
The process check prevents an already-running app from entering this conflict;
do not launch the app concurrently after the check.

After startup, reuse the same `SESSION` for Flutter hot restarts or full app
restarts. Do not run host `start` again. `snapshot` and `verify-app-ready` remain
available while the app runs; verify readiness again after each app restart.

The default package is `com.openglucose.app.debug`. The tool records package
state but does not launch it. The debug package must be installed for the
Android user that was current at `start`. The session records
`capture_live_aidex=true|false`; every later harness command must use the same
environment value. At each snapshot it uses Android
`adb shell -T run-as <package> --user <bound-id>` to read the exact NFC trace
filename and current BLE session from schema-v2 status. The no-PTY shell-v2
transport keeps stdout and stderr separate and returns the remote command exit
status; an unavailable shell-v2 transport fails closed. It exports only that
NFC file and strict `ble-<current-session>-00..07.jsonl` segments from
`files/protocol-captures`; it never recursively discovers app files. If status
or a trace is absent, collection records `unavailable`.

After the debug app has started its capture surface, verify the app-owned
status separately:

```sh
./scripts/libre-protocol-capture.sh verify-app-ready --session "$SESSION"
```

This reads two exact schema-v2 samples approximately three seconds apart.
`APP CAPTURE READY` requires the current PID, installed version and update
time, stable native/process/BLE session identities and safe filenames, a
healthy writable sink, resumed activity, RF point-of-use eligibility, no
capacity/error/stopping state, and advancing native elapsed time, Dart
heartbeat, BLE sequence, and BLE commit time. The running scanner filter must
exactly match the session mode:

- observation-only Libre: `[FDE3]`;
- full-UI Libre with live AiDEX: `[FDE3, 181F]`, in that order; or
- the separate explicit unfiltered profile: `[]`.

Both UUIDs are stored in canonical 128-bit lowercase form. Missing, reversed,
duplicate, or additional services fail readiness. The samples and package
evidence must be current. Any mismatch fails closed.
`DEVICE READY` and `APP CAPTURE READY` are capture preconditions only; neither
approves sensor contact.

`start` records `00-baseline-phone`. Take `01-app-idle` next, then take a
snapshot immediately **before** and **after** each separately authorized
operator action. Do not infer a protocol state from a label. The strict
allowlist is:

```text
00-baseline-phone             01-app-idle
02-advertisement-observed     03-nfc-detected
04-patch-metadata             05-activation-requested
06-activation-response        07-ble-connected
08-native-pair-prompt         09-bonded
10-services-discovered        11-auth-challenge
12-auth-session               13-stream-subscribed
14-warmup                     15-first-composite
16-first-reading              17-disconnect-recovery

E01-native-pair-failed        E02-service-discovery-timeout
E03-auth-length-mismatch      E04-auth-integrity-failed
E05-stream-fragment-timeout   E06-device-disconnected
E07-unexpected-write          E08-unknown-service-map
E09-sensor-state-mismatch     E10-capture-gap
```

Use only a label supported by direct observation; numbering is classification,
not proof of a required order. `phase-99-final` is reserved for `stop`. Example:

```sh
./scripts/libre-protocol-capture.sh snapshot --session "$SESSION" \
  --label 01-app-idle
```

Each snapshot records a screenshot, UI hierarchy, device clock, Bluetooth
manager state, NFC state, activity state, window state, target package state,
HCI-snoop setting evidence, exact status-bound app traces, host monotonic nanoseconds,
Logcat byte offset, and separate NFC/BLE byte and sequence offsets when extractable. HCI
byte offset is explicitly `unavailable` until an OEM artifact exists. Free-text
operator observations are omitted; the harness never accepts them. Logcat
remains continuous. Every snapshot and the stopped session have SHA-256
manifests.

### Classify patch information with one debug-only NFC probe (R3)

Do **not** arm this during readiness, baseline collection, or routine passive
monitoring. A command described as read-only by reference material is still
target-device-unverified on this sensor/firmware and is therefore R3. Only the
accountable supervisor can run this step after explicit R3 approval and after
the reviewed debug app contains the corresponding one-shot handler:

```sh
./scripts/libre-protocol-capture.sh arm-target-unverified-nfc-probe \
  --session "$SESSION" \
  --ack-r3-target-unverified
```

The first presentation used to create a target observation is itself R3. After
that approved observation, remove the phone from the target. Run the neutral
control below, then arm and re-present the target within the grant lifetime:

```sh
./scripts/libre-protocol-capture.sh verify-target-observation \
  --session "$SESSION" \
  --ack-reference-e007-target-unverified
```

This requires a fresh app-owned `nfc-target-context.json`, exact current
native/process identities, a 64-lowercase-hex target UID hash, and prefix
`e007`. The prefix is reference evidence only. It does not prove a physical
model or compatibility. Each verification attempt first invalidates the prior
host-side observation and arming hash. It reads into a private pending file,
validates the exact schema, identities, and freshness, then atomically publishes
the observation and its hash. A remote read error, malformed response, stale
response, interruption, or hash failure leaves no usable arming hash. Remote
command and parser details remain in mode-`0600` session diagnostics rather
than operator output.

The arm command requires the active session package to be exactly
`com.openglucose.app.debug`. The debug app must first create this app-private
context at capture start or restart:

```text
files/protocol-captures/nfc-grant-context.json
```

The grant context binds a nonce, native/process sessions, installed build and
update time, and the `e007` reference prefix. Arm reruns full two-sample
readiness immediately, rereads both contexts, and uses the phone clock. It
writes a 90-second app-private grant as pending, fsyncs it, renames it, and
fsyncs the directory. App-private reads and the staged write use the same
no-PTY shell-v2 transport, so a remote command failure is not treated as a
successful transfer. Any transfer or durability failure fails closed. No
remotely reparsed `sh -c` is used.

```text
files/protocol-captures/target-unverified-nfc-grant.json.pending
files/protocol-captures/target-unverified-nfc-grant.json
```

The final JSON has exactly these 12 fields: `schemaVersion`, `nonce`,
`nativeCaptureSessionId`, `processSessionId`, `versionCode`, `lastUpdateTime`,
`targetUidSha256`, `iso15693ManufacturerPrefix`, `operation`, `sessionId`,
`issuedAtEpochMillis`, and `expiresAtEpochMillis`. `operation` is exactly
`target_unverified_patch_info_probe`; `sessionId` is the active neutral session
directory basename; expiry is 90 seconds after issue and never more than 120
seconds. The native debug handler must validate every field against its current
context and phone clock, validate session syntax, and delete the grant **before**
any use.

The acknowledgement records that approval exists; it does not create approval.
The command does not launch the app, enable NFC, poll for a tag, transmit an
NFC command, or contact a sensor. The reviewed debug app is responsible for
consuming the grant at most once and permitting only its separately reviewed
target-unverified probe. The grant is not approval for activation,
authentication, a handshake, a write, a session change, or any other NFC
command. Before fresh readiness and context validation, arming removes the
fixed patch, Gen1 FRAM, and Gen1 activation final/pending grant files and
fsyncs their app-private directory. If that cleanup is not durable, arming
fails closed. The three grants can never be armed together. The harness never
accepts or extends an earlier grant.

The debug app sends one classic patch-information request only after the grant
is consumed. It requires an exact eight-byte NFC-V UID whose reversed
manufacturer bytes match the separately acknowledged `e007` reference, and it
derives the request manufacturer byte from that UID. A successful UI result
requires an exact seven-byte response, a clear ISO 15693 error bit, and a known
Libre 2-family model signature. The UI reports only the verified model. It
does not expose the UID, raw bytes, or inferred security generation, and it
does not claim activation, warmup, Bluetooth readiness, or glucose support.

### Read one classified Gen1 FRAM image (separate R3 gate)

Do not combine patch classification and FRAM capture under one grant. Complete
the first touch and confirm successful patch-information classification first.
The debug app then writes this closed, redacted context:

```text
files/protocol-captures/nfc-patch-info-context.json
```

It has exactly 12 fields: `schemaVersion`, `nativeCaptureSessionId`,
`processSessionId`, `versionCode`, `lastUpdateTime`, `targetUidSha256`,
`iso15693ManufacturerPrefix`, `model`, `generation`, `patchInfoSha256`,
`observedAtUtc`, and `observedAtMonotonicElapsedNanos`. The schema is 1. The
model is only `libre2` or `libre2Plus`; generation must be exactly `gen1`.
`patchInfoSha256` hashes exactly the six-byte patch-information payload after
the ISO 15693 status byte. The context contains no UID or patch bytes.

Use this two-touch order:

1. Verify a target observation, arm the patch-information grant, and touch the
   target once. Wait for successful Gen1 classification and take the
   `04-patch-metadata` snapshot.
2. Remove the phone. Verify the current target observation again. This binds
   the host evidence to the context written by the first touch.
3. Arm the separate FRAM grant:

   ```sh
   ./scripts/libre-protocol-capture.sh \
     arm-target-unverified-gen1-fram-read \
     --session "$SESSION" \
     --ack-r3-gen1-fram-read
   ```

4. Touch the same target a second time within 90 seconds. Do not retry after a
   partial, failed, or ambiguous read. Disarm and inspect the private trace.

The FRAM arm repeats two-sample readiness and uses the phone clock. It requires
the exact current target and patch contexts to match the active native/process
sessions, installed build, target hash, `e007` prefix, closed model, and Gen1
generation. Both contexts must be fresh. The patch observation must be at or
after the target observation used to arm. A changed target, malformed context,
extra field, stale timestamp, build change, process restart, Gen2 result, or
unknown model fails closed.

The arm command atomically publishes only this 90-second file:

```text
files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending
files/protocol-captures/target-unverified-gen1-fram-read-grant.json
```

The final JSON has exactly the patch grant's 12 fields plus
`patchInfoSha256`. Its `operation` is exactly
`target_unverified_gen1_fram_read`. The distinct acknowledgement cannot arm a
patch probe, and the patch acknowledgement cannot arm a FRAM read. Arming
either kind durably removes both old grant kinds before publishing one new
grant.

After native code consumes and deletes that grant, the only approved NFC
sequence is the reviewed Gen1 read-only sequence. It revalidates patch
information, then reads blocks 0 through 42 with 15 standard `0x23`
multiple-block requests. Each request reads at most three 8-byte blocks; the
last reads block 42. The result must be exactly 344 bytes. There is no automatic
retry, extended `0xB3` fallback, single-block `0x20` fallback, activation,
enable-streaming command, authentication command, or BLE authorization.

On success, native code atomically writes the fixed app-private
`nfc-gen1-fram-capture.json`. Collect it immediately in the same running
session without printing its contents:

```sh
./scripts/libre-protocol-capture.sh collect-gen1-fram-capture \
  --session "$SESSION"
```

Collection repeats readiness, reads only the fixed app-private artifact and
current target/patch contexts, and validates the exact 16-field schema. It
binds native/process/capture sessions, build, target, prefix, patch hash, model,
generation, UID hash, payload hash, exact hex lengths, and fresh UTC/monotonic
times. The exact fields are `schemaVersion`, `nativeCaptureSessionId`,
`processSessionId`, `captureSessionId`, `versionCode`, `lastUpdateTime`,
`targetUidSha256`, `iso15693ManufacturerPrefix`, `patchInfoSha256`, `model`,
`securityGeneration`, `algorithmOrderUidHex`, `patchInfoHex`,
`encryptedFramHex`, `observedAtUtc`, and
`observedAtMonotonicElapsedNanos`. It then fsyncs and atomically publishes an
owner-only copy and SHA-256 as `restricted/nfc-gen1-fram-capture.json` with its
SHA-256 beside it. Operator output contains only a neutral success line and the
artifact SHA-256. It never prints a UID, patch bytes, FRAM bytes, or private
path.

`algorithmOrderUidHex` is the Android `Tag.getId()` byte order used directly by
the Gen1 algorithm. Collection hashes those eight bytes directly for
`targetUidSha256`; it does not reverse them. The `e007` manufacturer prefix is
bound to UID bytes 7 and 6 in that order, so the direct UID ends in `07e0`.

Keep the raw artifact private. Do not print it, commit it, attach it to GitHub,
or paste it into a shared transcript. Before any later state-changing step,
decrypt offline with the reviewed Gen1 implementation and require all three
FRAM CRC regions to validate. A valid size, successful NFC read, or one valid
CRC is insufficient. CRC or decryption failure stops the run and does not
authorize a retry, activation, enable-streaming, or BLE login.

### Activate one CRC-verified Libre 2 Gen1 sensor (separate R3 gate)

This is a state-changing, target-device-unverified operation. Do not use it
for Libre 2 Plus, Gen2, a lifecycle other than `notActivated`, or an artifact
that did not pass the offline validator. The pinned actual-send evidence covers
Libre 2 only. A reference integration that appeared to send an empty `A1`
request discards its computed activation parameter before transport; it is not
a second activation frame.

After collection, keep the phone away from the sensor. The FRAM touch changes
the current target-observation time, so rerun `verify-target-observation` with
its documented acknowledgment before arming. The arm command then reruns
capture readiness, verifies the current target and patch contexts, verifies the
mode-`0600` collected artifact and its hash, and runs the offline Dart validator.
It requires all three FRAM CRCs and lifecycle exactly `notActivated`. Then run:

```sh
./scripts/libre-protocol-capture.sh \
  arm-target-unverified-gen1-activation \
  --session "$SESSION" \
  --ack-r3-gen1-activation
```

The command creates one 90-second grant with exactly 20 fields. It binds the
native/process/build/session/target/patch identities, model `libre2`, generation
`gen1`, one random attempt ID, the complete source-artifact hash, the encrypted
FRAM hash, lifecycle `notActivated`, and the SHA-256 of the planned request.
It prints no UID, FRAM, patch, authentication, or request bytes. If the fixed
app-private activation journal already exists, arming removes all grant files
and stops. There is no automatic reconciliation or retry.

On the next touch, native code independently repeats all gates. It requires the
same tag and patch, reads the complete 344-byte FRAM image on that same NFC
connection, validates all CRCs, and requires current lifecycle
`notActivated`. Before transmission it atomically writes and fsyncs
`nfc-gen1-activation-journal.json` with state
`transmit_intent_committed`. It then sends exactly one request:

```text
02 A1 uid[6] 1B auth[4]
```

There is no inventory preamble, retry, fallback, alternate addressed request,
second write, or success inference from response length. The exact five-byte
clear-error response is transport shape only. Native code immediately
rechecks patch information, rereads all 43 FRAM blocks on the same connection,
validates all three CRCs, and reports success only when lifecycle is
`warmingUp`. Any interruption after durable intent but before that proof is
`unknown_outcome`. The journal remains owner-only and blocks every later arm
until a separately reviewed reconciliation procedure exists.

To remove only a grant before the touch, without removing or changing a
journal, use:

```sh
./scripts/libre-protocol-capture.sh \
  disarm-target-unverified-gen1-activation \
  --session "$SESSION"
```

Disarm before leaving the planned state or after an aborted attempt:

```sh
./scripts/libre-protocol-capture.sh disarm-target-unverified-nfc-probe \
  --session "$SESSION"

./scripts/libre-protocol-capture.sh \
  disarm-target-unverified-gen1-fram-read \
  --session "$SESSION"
```

Any of the three disarm commands removes all fixed final and staged app-private
grant files. Start, arm rollback, and `stop` also remove all three grant
families; `stop` does this before its final snapshot. Disarm does not change
NFC, Bluetooth, app, bond, or
sensor state. No cleanup command removes the durable activation journal. Take
neutral snapshots immediately before arming and after the app reports the
observed result.

## Stop and collect

Stop normally and request an Android bugreport only when the privacy owner has
approved its much broader contents:

```sh
./scripts/libre-protocol-capture.sh stop --session "$SESSION" --bugreport
```

Without `--bugreport`, stop still takes `phase-99-final`, exports current traces,
disarms, force-stops only `com.openglucose.app.debug` for the session-bound
Android user, verifies its PID is gone and status is absent or no longer
advances, writes a marker, and stops only the exact logcat process whose PID,
start time, and command
fingerprint match the session. It refuses a reused or changed PID. To collect a
bugreport separately before or after stop:

```sh
./scripts/libre-protocol-capture.sh bugreport --session "$SESSION"
```

The final session hash manifest is written only after logcat stops, so it does
not claim integrity for a file that is still changing. Active snapshots have
their own stable manifests; a bugreport collected during an active session has
a report-directory manifest.

An OEM bugreport is the best available passive attempt to retrieve its HCI
snoop artifact. Presence and location are OEM/Android-version dependent. Check
the private ZIP locally; absence is evidence that capture was not obtained,
not permission to claim a protocol result.

The app automatically retains native NFC as at most 8 files of 16 MiB each.
BLE retention is at most 4 sessions, each with 8 segments of 16 MiB. Export the
needed current session before rotation. The harness does not bulk-copy older
sessions.

## Exact unknowns to resolve from authorized evidence

Do not fill these gaps from product names, shared UUID lists, another project
without license/provenance review, or a single successful observation:

- exact model, regional hardware revision, firmware, Android/OEM stack, and
  whether Libre 2, Libre 2 Plus, Libre 3, and Libre 3 Plus differ;
- NFC technology, command/APDU framing, CRC/MAC, authentication, key derivation,
  counters/nonces, encryption, activation semantics, and replay behavior;
- whether NFC only bootstraps BLE or also starts/changes the sensor session;
- BLE advertisement structure, address randomization, service identifiers, and
  whether OS pairing or bonding is required;
- GATT services, characteristics, descriptors, properties, MTU, ordering,
  timeouts, handshake messages, authentication, encryption, and reconnect
  resumption;
- notification framing, sequence/counter rules, timestamps, units, trend and
  history layout, duplicate/gap behavior, and integrity checks;
- warmup representation, start instant, duration, progress transitions, and
  behavior across disconnect, phone restart, sensor expiry, and sensor error;
- transfer between phones, concurrent-client behavior, bond lifecycle, and
  which side retains session state; and
- firmware/region/platform differences and safe handling of unknown frames.

Bluetooth HCI snoop cannot capture NFC. Encrypted application payloads can stay
opaque even when HCI packets are present. Logcat, UI, and timing correlation can
support a hypothesis but do not establish keys, semantics, safety, or
compatibility. A compatibility claim requires a documented
model/firmware/platform combination, redacted physical-device evidence,
capability gaps, and a last-verified release/date under
[`docs/compatibility.md`](../compatibility.md).

## Bug investigation record

For each run, keep a private index outside Git with the source commit, app build
type/version, phone model/OS, sensor family as printed on packaging, authorized
operator actions and UTC times, session-directory hash manifest, observed
result, and gaps. Store real serials or addresses only if strictly necessary
and approved; prefer a locally generated case alias. Do not state that a state,
handshake, warmup, or reading is understood until independent captures and
offline parser fixtures reproduce it without real data.
