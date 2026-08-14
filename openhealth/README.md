# OpenGlucose app

This directory contains the Flutter reference app for the OpenGlucose CGM
packages. The historical directory name is `openhealth`; the product and Dart
package name are OpenGlucose and `openglucose`.

> [!CAUTION]
> This early-stage wellness/reference app is not a medical device. Do not use it
> for diagnosis, dosing, treatment, or emergency decisions.

## Driver selection

- iOS and Android builds create `AidexSensorDriver` with the
  `FlutterBluePlusTransport` platform adapter.
- Web builds and widget tests create `DemoCgmDriver`, allowing UI development
  without Bluetooth hardware.
- A successful demo run does not validate a physical sensor or native
  background behavior.

## Run locally

Use the repository-approved Flutter toolchain. Bootstrap the entire workspace
from its root first:

```sh
make bootstrap
```

For a hardware-free demo:

```sh
cd openhealth
flutter run -d chrome
```

For a connected mobile target:

```sh
cd openhealth
flutter devices
flutter run -d <device-id>
```

Mobile operation depends on Bluetooth availability, granted platform
permissions, and a supported sensor. Never add provisioning profiles, signing
keys, `.env` files, sensor exports, or identifiers to the repository.

### Android pairing recovery

Allow OpenGlucose access to **Nearby devices** and **Location**, and keep the
phone's system Location setting on while scanning. Keep the phone close to the
sensor and accept Android's pairing prompt when it appears.

If pairing reports that the sensor became unavailable, it may be out of range
or another phone may still be connected or bonded. OpenGlucose does not claim
that one sensor supports concurrent direct-BLE readers. Stop the other phone's
connection, if applicable, and retry explicitly. Do not reset or unpair an
active sensor as a generic recovery step; the app does not do either
automatically.

## Verify changes

Run the shared checks from the repository root:

```sh
make check
```

For app-only iteration:

```sh
cd openhealth
flutter analyze
flutter test
flutter build web
```

The repository-wide `make check` covers formatting, static analysis,
unit/widget tests, the deterministic demo lifecycle integration test, Android
and web builds, and the negative Android release-signing gate. On macOS it also
runs the unsigned iOS build and `RunnerTests` on the pinned simulator. Physical-
device end-to-end automation is still deferred.

Focused native iteration can use `make build-android`, `make build-ios`, or
`make test-ios-native`. User-interface changes require behavior checks and screenshots on
the affected form factors; see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Architecture and support

- [Workspace architecture](../docs/architecture/README.md)
- [Compatibility policy](../docs/compatibility.md)
- [Dependency policy](../docs/dependencies.md)
- [Support](../SUPPORT.md)
- [Security reporting](../SECURITY.md)

The application is not a substitute for the sensor manufacturer's supported
software, medical advice, or emergency services.
