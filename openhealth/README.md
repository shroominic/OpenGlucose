# openglucose (app)

The Flutter reference app for **OpenGlucose** — an open-source, local-first,
privacy-first glucose monitoring app. See the [repository README](../README.md)
for the vision, sensor roadmap, and product roadmap.

> Note: this module directory is still named `openhealth/` for historical
> reasons; the package name is already `openglucose`. A repo-wide rename of the
> module/package/Android namespace is planned (TASK-001 in [`.backlog/`](../.backlog/)).
> The `cgm_aidex` driver keeps its name — "Aidex" is the sensor vendor.

## What this app is

On Flutter IO platforms (Android/iOS) it drives the real Aidex CGM via the
workspace's `cgm_aidex` driver over BLE. On web and in widget tests it falls
back to a demo driver so the UI is verifiable without native Bluetooth.

Glucose data stays on the device. This is a wellness / self-experimentation
app — **not** a medical device and not a substitute for medical advice.

## Architecture

This app is the UI layer over the pure-Dart CGM stack in `../packages`
(`cgm_core`, `cgm_ble`, `cgm_aidex`, `cgm_ble_flutter`). New product features
should extend the shared packages and keep analytics pure Dart, rather than
embedding logic in the Flutter UI. See the root README and the backlog for the
planned architecture.

## Getting started

```sh
flutter pub get
flutter run
```

For Flutter setup, see the [Flutter docs](https://docs.flutter.dev/).
