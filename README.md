# OpenGlucose

Your open-source health and wellness app focused on local data and privacy.

OpenGlucose is MIT-licensed, local-first, and privacy-first. Your data stays on
your device — nothing is sent to the sensor manufacturer, and any optional AI is
opt-in and bring-your-own-key / on-device. This is a **wellness and
self-experimentation** app, **not** a medical device and **not** a substitute
for medical advice. It does not diagnose, treat, or manage any condition.

## Vision

The long-term direction is an open, local-first, privacy-first health platform
in the spirit of Whoop / Oura — one place where you own and reason about your
sleep, activity, recovery, heart rate, glucose, and journaling, with explainable
insights and optional on-device AI.

**Today it is OpenGlucose: focused on glucose.** It reads continuous glucose
monitor (CGM) data over Bluetooth and shows it on a live dashboard. The broader
platform (multi-signal health data, journaling, correlation, AI insights) is on
the roadmap below, not yet built. We would rather under-promise here than
overstate what exists — most of the platform vision is still ahead of us.

## Sensor integrations roadmap

OpenGlucose is built on a vendor-agnostic driver stack (`cgm_core` /
`cgm_ble` / per-vendor drivers), so adding sensors is a matter of writing a
driver, not rewriting the app.

| Sensor | Status |
| --- | --- |
| Microtech **Aidex X** (15-day, BLE, all-in-one) | ✅ Supported |
| Dexcom **G7** | 🟡 Wanted / planned |
| Dexcom **G6** | 🟡 Wanted / planned |
| Abbott **FreeStyle Libre 3** | 🟡 Wanted / planned |
| Abbott **FreeStyle Libre 2** | 🟡 Wanted / planned |
| Medtronic **Guardian** | ⚪ Wanted (exploratory) |
| Senseonics **Eversense** | ⚪ Wanted (exploratory) |

"Wanted / planned" means we'd like to support it and the architecture is ready
for a driver — not that support exists today. Commercial-sensor protocols can be
technically and legally constrained, so each is tracked as its own piece of
work. See the in-app sensor compatibility center (planned) and the backlog for
status. Today, only **Aidex X** is actually supported.

## Roadmap / TODO

Planned work is tracked in [`.backlog/`](.backlog/) (Backlog.md). It is grouped
into epics and three phases (`1-foundation` → `2-build` → `3-polish`):

- **core** — sensor lifecycle UX, alerts, local persistence, data export &
  backup, PDF reports.
- **health-data** — normalized event/health-data models, event journaling,
  explainable glucose metrics, meal logging & response, weekly recap,
  HR/activity/sleep correlation, optional athlete mode.
- **integrations** — Apple Health (HealthKit) export + import, Android Health
  Connect import, read-only share/follower mode, additional CGM drivers.
- **ai** — privacy-first, opt-in on-device / BYO-key AI foundation, insights &
  chat over your *local* data, voice & photo meal capture. AI surfaces
  **patterns and observations, never medical advice**.
- **ux** — navigation/IA & theming, dashboard redesign, annotated chart
  overlays, contextual tips & info boxes, empty/loading/error states, home
  widgets.
- **onboarding** — light first-run flow (connect sensor, set range, privacy
  explainer, wellness disclaimer).
- **docs / dev-ex** — metric definitions, contributor & architecture docs, CI,
  developer mode & diagnostics.

**Pending rename:** the app module is being renamed from the legacy
`openhealth` to **`openglucose`** (directory, Android namespace/package). The
`cgm_aidex` driver keeps its name — "Aidex" is the sensor vendor. Tracked as
TASK-001.

## Flutter CGM SDK Workspace

This workspace splits the CGM stack into a pure Dart protocol layer and a very
thin Flutter transport layer:

- `packages/cgm_core`
  Sensor-agnostic domain models, session contracts, logs, diagnostics, and
  capabilities.
- `packages/cgm_ble`
  BLE transport abstractions used by CGM drivers.
- `packages/cgm_aidex`
  Pure Dart AiDEX driver and protocol implementation. This package owns the
  encrypted vendor handshake, CGM characteristic orchestration, history sync,
  calibration flow, diagnostics, and unsafe admin commands.
- `packages/cgm_ble_flutter`
  Flutter transport bridge built on `flutter_blue_plus`. It only translates
  scan/connect/read/write/notify operations into the `cgm_ble` interfaces.
- `openhealth`
  Reference UI. On Flutter IO platforms it uses the real AiDEX driver; on web
  and in widget tests it falls back to a demo driver so the UI remains
  verifiable without native BLE.

## Why the BLE split exists

The AiDEX protocol itself is now Dart. The remaining platform boundary is BLE
transport. There is no practical fully pure-Dart way to talk to Bluetooth LE on
iOS and Android without crossing into the operating system's native BLE APIs.

The chosen compromise is:

- keep all protocol logic in Dart
- keep only the BLE transport in a Flutter package
- keep that transport minimal so future CGM drivers can reuse it

## BLE options considered

- `flutter_blue_plus`
  Broad platform coverage, straightforward scan/connect/read/write/notify API,
  explicit Android bonding support.
- `flutter_reactive_ble`
  Good reactive API, but the driver still needs a platform plugin boundary and
  the characteristic orchestration would not get any more "pure Dart".
- `universal_ble`
  Wide platform coverage, but the same underlying constraint remains: BLE still
  depends on platform integrations.

For this workspace, `flutter_blue_plus` is used because it gives the smallest
adapter surface for the needs in `cgm_ble`.
