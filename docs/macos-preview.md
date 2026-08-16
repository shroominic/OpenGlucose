# macOS reviewer preview

The macOS target is an engineering preview. It is not part of the stable
OpenGlucose release, and it is not evidence that an AiDEX sensor works on a
Mac. Do not use this preview for diagnosis, dosing, treatment, emergency
monitoring, or any other medical decision.

## Verified in the repository

- Flutter builds one Apple-silicon `arm64` application bundle. Every bundled
  Mach-O must contain an `arm64` slice before the reviewer package is created.
- The release app sandbox has Bluetooth access and no outgoing-network
  entitlement.
- Release startup sets `flutter_blue_plus` logging to `none` before storage or
  BLE work and stops startup if that setting fails.
- The reviewer package is bound to one source commit, contains the MIT license,
  dependency notice material, build metadata, and a separate SHA-256 file.
- CI verifies the ad-hoc signature and rejects `get-task-allow` in the release
  preview.
- Cloud AI settings are disabled in this ad-hoc-signed preview. It does not
  claim the Keychain capability required to store an API key.

The locked `flutter_blue_plus` Darwin implementation exposes CoreBluetooth
scan, connect, service discovery, characteristic read/write, and notification
operations on macOS. A platform build proves only that these operations compile
and link.

## Not verified

No redacted physical Mac/AiDEX evidence is recorded. The following remain
gates before any macOS sensor-support claim:

- a verified `x86_64` native-assets build and real Intel launch before any
  Intel-compatible artifact or universal label;
- discovery with a named Mac model, macOS version, sensor model, and firmware;
- first pairing and the system authorization prompt;
- encrypted vendor handshake, live notifications, and history sync;
- disconnect, app restart, reconnect, stale-data, and out-of-range recovery;
- sleep, wake, display lock, and long-running session behavior; and
- local-state recovery and deletion on a real Mac user account.

The Darwin plugin does not expose bond state, explicit bond creation, or bond
removal. OpenGlucose therefore hides **Move sensor** on macOS. Before a
controlled Mac test, use **Move sensor to another phone** in the current
Android OpenGlucose app. Ordinary disconnect does not transfer the bond. Do not
reset an active sensor as a generic recovery step.

## Data and platform limits

Restricted sensor state stays in the app's sandboxed Application Support
container. Backup exclusion is not verified on macOS, so the user must review
the Mac's Time Machine and other backup policy. Apple Health export, iOS Live
Activities, Android live notifications, and mobile background behavior are not
macOS capabilities.

The reviewer artifact is ad-hoc signed and is not Developer ID signed or
notarized. It can trigger Gatekeeper and must not be presented as an approved
installer. Do not disable system security or remove quarantine attributes to
run it. A future external macOS distribution needs its own signing,
notarization, release approval, rollback, and support process.

The custom cloud AI pane is unavailable because this ad-hoc-signed preview
cannot carry the Keychain access-group capability required by the locked
secure-storage plugin. Do not paste an API key into the preview. A future
signed Mac target must add and runtime-test that capability before enabling the
pane.

## Build and verify

From a clean checkout on the pinned macOS toolchain:

```sh
make bootstrap
make build-macos
make test-macos-native
```

The `macOS Preview` workflow builds and packages pull requests but uploads a
downloadable workflow artifact only after a manual run against an existing
strict `vMAJOR.MINOR.PATCH` tag. It has read-only repository permissions and
cannot create or modify a GitHub Release.
