# Changelog

Notable repository-level changes are recorded here. Package-specific public API
changes must also be recorded in the package's own `CHANGELOG.md`.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for package
contracts. The pre-1.0 application may still change rapidly; compatibility
expectations are defined in [docs/compatibility.md](docs/compatibility.md).

## [Unreleased]

## [0.1.6] - 2026-08-31

### Added

- OpenGlucose now supports English and Simplified Chinese across the app,
  Android live notifications, and iOS Live Activities. The app follows the
  device language by default and includes a manual language selector.

### Fixed

- Archived sensor export now opens the native iOS share sheet from the routed
  sensor-detail screen. The app shows preparation and sharing progress,
  prevents concurrent export attempts, removes partial files after failures,
  and reports identifier-free stage codes when export cannot complete.
- Device-language resolution now honors the configured locale priority. An
  English-first device no longer selects Chinese because Chinese is listed as
  a secondary language.

## [0.1.5] - 2026-08-31

### Fixed

- Archived sensor exports now open a native iOS share sheet reliably on
  iOS 26. The iPhone path no longer uses popover presentation configuration;
  iPad keeps its required anchored popover behavior.

### Changed

- The repository now includes a protected, tag-bound TestFlight delivery
  workflow. A release owner selects each upload, external-review, and tester
  notification phase explicitly; publishing a GitHub Release does not start
  TestFlight delivery.
- Android build tooling is aligned with Gradle 9.7 (#65). This maintenance
  update does not change Android app behavior.

## [0.1.4] - 2026-08-22

### Added

- The iPhone Live Activity now has an Apple Watch Smart Stack presentation for
  iOS 18 and watchOS 11. It shows privacy-gated glucose, trend, reading age,
  stale state, and warmup. The iPhone remains the only device with sensor
  Bluetooth ownership.
- Add a source-bound, ad-hoc-signed Apple-silicon macOS reviewer preview with a
  read-only CI/package lane and explicit in-app hardware limitations. macOS is
  not part of the stable release and remains unsupported until physical AiDEX,
  Intel-native-assets, privacy, signing, and notarization gates close.

### Changed

- The connected dashboard and live glucose surfaces now use the OpenGlucose
  brand instead of exposing the connected sensor name. Sensor identity remains
  available in Settings.

## [0.1.3] - 2026-08-16

### Changed

- Android GitHub releases now build, verify, and attach the APK while hidden,
  then publish one stable Latest release only after the download is complete.
- Android sensor transfer is now an explicit, confirmed action. Normal
  Disconnect preserves the pairing; Move sensor releases the current
  sensor-side pairing, waits for the link to close, and then removes the old
  phone's local bond.

### Fixed

- Android AiDEX setup now stops scanning before connection, performs discovery,
  bonding, protected notification setup, and vendor authentication in the
  required order, and avoids unnecessary reconnects for healthy bonds. A
  service-discovery or notification disconnect can use one bounded fresh-link
  recovery; a second failure stops automatic retries. Recovery cannot repeat
  sensor activation or silently remove a pairing.

## [0.1.2] - 2026-08-15

### Changed

- During the sensor's initial 60-minute warmup, the dashboard now hides
  History, Patterns, and Weekly recap. Warmup readings remain retained for a
  complete disclosed archive export but are excluded from displayed history,
  wellness analytics, and Apple Health export.

### Fixed

- Android sensor setup now stops active Bluetooth scanning before every
  connection attempt, refreshes already-paired GATT sessions before discovery,
  and avoids an unused Service Changed subscription that could interrupt setup
  on stricter Android Bluetooth stacks.
- Android live notifications and iOS Live Activities can again show ongoing
  post-warmup glucose updates after the user explicitly opts in from current
  sensor settings; the default remains redacted and disabling fails closed.
- iOS Live Activities now start during sensor warmup and continue showing the
  private countdown until the first post-warmup reading is available.
- Sensor discovery now presents a safe Bluetooth-off state with enable and
  retry guidance instead of exposing native exception types or an unrelated
  no-sensors message.

## [0.1.1] - 2026-08-14

### Fixed

- Android setup now establishes the OS BLE bond before subscribing to
  protected sensor notifications, allowing the system pairing prompt to appear
  on phones that do not auto-pair from a notification request. Permission,
  Bluetooth, pairing, timeout, and possible other-phone contention failures now
  show identifier-free recovery guidance and pause automatic retry when user
  action is required.

## [0.1.0] - 2026-08-13

### Added

- Reproducible engineering baseline documentation, ownership, contribution,
  security, support, architecture-decision, compatibility, and dependency
  policies.
- MIT license for OpenGlucose-owned source.
- Dedicated native restricted-health-state storage with migration tests for
  legacy sensor selection and glucose-history preferences.
- Repository-wide command, hook, CI, dependency-reporting, and secret-scanning
  configuration.
- Isolated demo mode with staged sensor scenarios, first-run onboarding, sensor
  lifecycle guidance, and contextual in-app messaging.
- Strict health-event/sample models, local journal and insight persistence,
  explainable glucose metrics, and weekly recap views.
- Explicit, write-only Apple Health glucose export with protected progress
  state, plus optional BYO-key AI insights over disclosed 24-hour aggregates.
- Durable session-keyed archive snapshots with CSV, TXT, and XLSX export
  through a one-file, previewed share flow.
- A clearly labeled sample dashboard for first-time users without retained
  glucose history.

### Changed

- External TestFlight builds no longer self-declare an unreviewed export-
  compliance exemption. The Account Holder must explicitly classify the build,
  and the release owner must record that determination before external beta
  approval and tester notification.
- Restricted glucose-history blobs now use deterministic SHA-256 filenames
  that do not embed reversible sensor storage keys. Schema-two filenames are
  migrated crash-safely at startup, interrupted migrations resume, and
  conflicting copies fail closed without discarding either history.
- Dart-owned sensor selection and glucose history move from ordinary platform
  preferences into an application-support file; those legacy values are removed
  only after the replacement is durable. iOS native lock-screen payloads are
  purged before migration, and background targets are purged on migration
  failure, preferring a recoverable rescan over backup exposure.
- Android backup and device-transfer configuration excludes application data.
  iOS code requests and checks the backup-exclusion resource attribute for the
  restricted file; physical-platform verification remains outstanding.
- Lock-screen surfaces redact glucose values by default; final native-platform
  verification remains a release prerequisite.
- Android release builds now require explicit release-signing environment
  variables instead of falling back to debug signing.
- TestFlight automation now requires an explicit source commit and release
  approval inputs, and uses temporary credential material.
- Settings now use a full-screen information architecture, active sensor
  lifecycle detail is kept out of the primary dashboard, and archived-session
  recap views anchor to their actual reading windows.
- Sensor restore, activation, expiry, archive persistence, and history
  deduplication fail closed around incomplete or stale sessions.
- The Android beta release lane builds from the immutable release-event commit
  SHA, revalidates its tag before and after upload, requires a dedicated signing
  identity, verifies the APK identity and version, creates build provenance,
  and attaches only the verified bytes.

### Security

- Startup removes identifier-bearing legacy
  `openhealth_<sensor-id>_<timestamp>.csv` cache exports using an exact filename
  and regular-file check, while preserving unrelated cache entries.
- Release startup sets `flutter_blue_plus` Dart/native logging to `none` before
  storage initialization or any BLE operation and fails closed if the plugin
  cannot confirm the setting.

### Known limitations

- Complete all-data/recovery export, delete-all, and configurable retention
  flows are not implemented; this beta exports one archived sensor session at
  a time, and the Apple Health integration remains a separate opt-in write-only
  path.
- The web demo stores `shared_preferences` data in origin-scoped browser
  `localStorage`; it is not a supported private health-data store.
- Automated physical-device end-to-end coverage is deferred and must not be
  inferred from demo integration or platform build checks.

## [0.0.1+10] - 2026-06-05

### Added

- Initial tagged development snapshot of the OpenGlucose Flutter app and CGM
  package workspace.

The historical Git tag is named `v0.0.1+10`, while the tagged
`openhealth/pubspec.yaml` declares `version: 0.0.1+9`. The tag is retained as
published history; do not infer an app artifact build number of 10 from the tag.

[Unreleased]: https://github.com/shroominic/OpenGlucose/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/shroominic/OpenGlucose/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/shroominic/OpenGlucose/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/shroominic/OpenGlucose/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/shroominic/OpenGlucose/releases/tag/v0.1.3
[0.1.2]: https://github.com/shroominic/OpenGlucose/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/shroominic/OpenGlucose/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/shroominic/OpenGlucose/compare/v0.0.1%2B10...v0.1.0
[0.0.1+10]: https://github.com/shroominic/OpenGlucose/tree/v0.0.1%2B10
