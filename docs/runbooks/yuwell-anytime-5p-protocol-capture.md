# Passive protocol capture: Yuwell Anytime 5P

This R2 runbook prepares a debug-only BLE advertisement capture. It is for
interoperability research only. It does not establish product support, sensor
compatibility, clinical accuracy, diagnosis, dosing, treatment, or emergency
use.

The capture profile is passive and non-connectable. It does not register a
production driver. It does not perform GATT operations, NFC operations, pairing,
bond changes, activation, or writes.

The repository also has a separate, explicit live-driver debug mode. Do not
confuse it with the passive entry point below. The live mode can authenticate,
configure, initialize, and write to a sensor. Use it only for an approved
physical-device run with the private trace and durable Android secure store.
It is not available in normal builds. Its explicit engineering output policy
can show only authenticated, contiguous, post-warmup V1150 packed values as
provisional debug readings. Those values are not production-validated.

## Privacy boundary

Bluetooth captures can contain restricted device and health-adjacent data.
Store them outside Git in access-controlled storage. Do not commit, publish, or
attach raw advertisements, payloads, device addresses, sensor identifiers,
screenshots, HCI logs, or diagnostic archives. Share only reviewed and redacted
protocol conclusions.

Do not collect a bugreport by default. It can include broad personal and device
data. Use it only when an approved capture question requires it, and apply the
same private-storage and redaction controls.

## Build and start

Build an Android debug app with the two required compile-time flags:

```sh
flutter run --debug -d "$ANDROID_SERIAL" \
  --target lib/protocol_capture_main.dart \
  --dart-define=OG_PROTOCOL_TRACE=true \
  --dart-define=OG_PROTOCOL_CAPTURE_PROFILE=yuwell_anytime_passive
```

The dedicated entry point does not import or construct the normal app UI,
application controller, or live driver registry. It exists so capture readiness
does not depend on unrelated product-screen work in the current branch.

## Approved live-driver iteration

Use the normal application entry point with all three explicit flags:

```sh
flutter run --debug -d "$ANDROID_SERIAL" \
  --dart-define=OG_PROTOCOL_TRACE=true \
  --dart-define=OG_PROTOCOL_CAPTURE_PROFILE=yuwell_anytime_passive \
  --dart-define=OG_PROTOCOL_CAPTURE_LIVE_YUWELL=true
```

This installs the separate `com.openglucose.app.debug` application. Android
Keystore credentials are scoped to that package and cannot move into the
signed release application. A sensor initialized by this build therefore
remains attached to the debug package for its session. Confirm that consequence
before the first state-changing command.

Keep raw BLE traces in app-private storage. Retrieve them only into the private
protocol-reference directory, and print only sanitized milestones or hashes to
the terminal. Do not commit or attach a raw trace. If a write times out or the
phone disconnects, stop automatic iteration and use the journaled read-only
recovery path.

Use the profile wrapper with an absolute output directory outside all Git
worktrees:

```sh
./scripts/yuwell-anytime-passive-capture.sh doctor \
  --output-root /private/path/openglucose-protocol-captures

SESSION=$(./scripts/yuwell-anytime-passive-capture.sh start \
  --output-root /private/path/openglucose-protocol-captures)

./scripts/yuwell-anytime-passive-capture.sh verify-app-ready \
  --session "$SESSION"
```

Readiness accepts only the explicit unfiltered scan representation. If the
profile flag is missing, the app uses the service-filtered Libre default and
readiness fails for this session.

## Record and stop

Use only neutral, pre-approved snapshot labels. Keep the recorder passive
throughout the session:

```sh
./scripts/yuwell-anytime-passive-capture.sh snapshot \
  --session "$SESSION" --label 00-baseline-phone

./scripts/yuwell-anytime-passive-capture.sh snapshot \
  --session "$SESSION" --label 01-app-idle

./scripts/yuwell-anytime-passive-capture.sh snapshot \
  --session "$SESSION" --label 02-advertisement-observed

./scripts/yuwell-anytime-passive-capture.sh stop \
  --session "$SESSION" --label phase-99-final
```

The wrapper rejects Libre NFC observation and probe commands for this profile.
Stop the session if readiness fails, the app leaves the foreground, or capture
storage reports an error.
