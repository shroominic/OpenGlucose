# Changelog

Notable repository-level changes are recorded here. Package-specific public API
changes must also be recorded in the package's own `CHANGELOG.md`.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for package
contracts. The pre-1.0 application may still change rapidly; compatibility
expectations are defined in [docs/compatibility.md](docs/compatibility.md).

## [Unreleased]

### Added

- Show a compact home-dashboard **History may be missing** action when a
  selected Libre 2 has a stale retained timestamp. It reuses the existing
  exact-target NFC history flow and stays hidden during setup, active sync, and
  for other sensor families. This does not change the production-support or
  physical-qualification gates.

- Resume the exact saved Libre receiver after successful foreground NFC history
  sync and confirmed reader disposal, without a separate Resume Bluetooth tap.
  Keep cancellation, failed imports, target changes, backgrounding, and uncertain
  cleanup from starting automatic connections; show reconnect progress separately
  from the imported count. Explain the sensor's eight-hour history window.
- Wait for a previously connected Libre sensor to return without repeatedly
  logging in or requiring Retry merely because its recovery search elapsed.
  Keep the owned connection service and show a distinct Waiting state; retain
  cancellation, native failure, exact receiver, cleanup, and fresh-counter gates.
- Add an exact saved-receiver NFC history route to the recorder-free Android
  debug integration. Reuse read-only commands and the atomic importer, preserve
  credentials/counters, and revoke one-use evidence on cancellation or lifecycle
  loss. The existing private glucose entry can use protected calibration without
  capture; normal main stays decoder-free and release support remains gated.
- Retain accepted older Libre samples already present in Bluetooth packets,
  with distinct trend/history origin and sensor-relative timestamps. Commit
  them with the live observation, preserve first acquisition and clear-history
  protection, and keep them separate from current glucose. A lazy schema-three
  history envelope supports BLE-only backfill without inventing an NFC scan.
  Physical backfill comparison and release qualification remain open.
- Add a fresh, exact-receiver Libre NFC history path: verified ring parsing,
  private decoder conversion, owner-bound atomic imports, and provenance-aware
  archives. Keep NFC scan age separate from live BLE observation age and
  preserve clear-history protection. The explicit settings action is under
  private integration; hardware backfill and release support remain unverified.
- Retain Libre acquisition origin, first receipt, and timestamp basis in
  CSV, text, and Excel archive exports. Legacy exports keep their 13-column
  format; acquisition-bearing archives add four columns. Validate the exact
  archived owner again at confirmation and block missing or corrupt data.
- Fix archive sharing from pushed settings routes and show unavailable
  archive data without a screen error or a misleading empty export.
- Pause the selected Libre connection for explicit history reads, awaiting
  Bluetooth and background-service cleanup before granting the read scope.
  Block competing reconnects and preserve the receiver and saved readings.
- Compose recorder-free Android receiver components for exact saved-receiver
  restore, durable login counters, and a transport-lifetime ownership lease.
  The existing read-only opt-in permits this validation path only in Android
  debug; default/release builds still omit it. Enrollment, crash recovery,
  decoder distribution, and hardware validation remain release gates.
- Store each private Libre observed-minute frontier and optional accepted
  reading in one atomic, receiver-bound history envelope before publication.
  Restore history without fresh live data; preserve clear-history tombstones
  and stop on uncertain writes. Existing accepted records provide only a
  lower-bound migration frontier. Older list-only builds cannot downgrade this
  active history format safely; receiver credentials/counters are unchanged.
- Add MIT Libre Gen1 timing parsing independent of glucose conversion. Live
  age expires without a newer packet and can show nominal remaining life
  without inventing a UTC activation instant.
- Add a default-off, recorder-free Android Libre 2 read-only NFC integration
  with strict native capabilities, foreground/attempt ownership, bounded reads,
  confirmed cleanup, and closed UI results. It does not activate sensors,
  enable streaming, migrate receivers, or add production glucose support.
- Add descriptive sensor variant evidence for model, region, security generation,
  and separate hardware/firmware/software revisions. Publish existing Libre
  patch identification and AiDEX Device Information observations in settings
  and archives; unknown fields remain unknown and grant no connection authority.
  Add a source-backed variant matrix and contributor test requirements.
- Correct private Libre live snapshots to use their declared 14-day nominal
  lifetime instead of the shared 15-day default, without inventing session time.

- Add optional driver data profiles for history duplicates, timestamp meaning,
  current-reading eligibility, model timing, and retained lifecycle inference.
  Add trusted app connection policies plus driver and protocol-investigation
  guides for contributors. Existing protocol/native setup remains specialized.

- Add a private Android Gen1 Libre 2 receiver path with an explicitly initiated
  NFC streaming exchange, encrypted receiver state, durable login counters,
  exact-target Bluetooth connection, and CRC-validated packet diagnostics.
  A separate GPL reference decoder can display provisional current estimates
  in the explicit private bench build. Neither path is enabled in normal builds.
- Keep sensor setup inline on the home screen with automatic Bluetooth
  discovery. A `Can't find your sensor?` action opens model-specific help;
  AiDEX/LinX stays on Bluetooth, while an explicit FreeStyle Libre 2 selection
  opens guided NFC in debug capture builds. Move sample data to Settings.
- Add an identifier-free Libre NFC scan event bridge with an animated
  listening state, neutral tag detection, verified model identification, and
  generic retry states. Raw tag identifiers and protocol bytes stay in the
  bounded app-private capture.
- Add a pure-Dart, target-unverified Libre 2-family offline protocol core for
  UUID/topology classification, observation-only sequence validation, and
  strict opaque fragment assembly. It contains no live sensor I/O, keys,
  authentication, activation, decryption, or glucose decoding.
- Add a pure-Dart, target-unverified Yuwell Anytime CT5 offline protocol core
  with synthetic checksum, framing, transform, authentication-arithmetic, and
  record-parser tests. It contains no BLE transport, live driver, activation,
  proprietary binary, real identifier, or vendor-native glucose algorithm.
- Add an app-owned multi-driver registry that routes one physical BLE scan by
  stable vendor driver ID while preserving existing AiDEX identifiers, storage
  keys, histories, and presentation behavior.

### Changed

- Renew the private durable Libre link-recovery allowance only after three
  fresh committed observations over two monotonic minutes. Keep cleanup,
  exact receiver, fresh advertisement, and new login-counter checks. A failed
  replacement, replay, or uncertain commit cannot create a retry loop.
- Leave chart intervals over 15 minutes and clock discontinuities unconnected,
  including during aggregation and area fill. Omit overlapping axis labels.
  This is a display policy, not a change to stored data or sensor cadence.
- Allow an explicit new debug scan to recover from an exhausted Bluetooth-off
  failure after confirmed scanner cleanup. Keep automatic retries bounded and
  retain quarantine for unknown failures or uncertain scan/connection cleanup.
- Distinguish the last history sync from the latest stored reading in sensor
  details. Use stored timestamps, not render time, and keep future or missing
  timestamps unavailable.
- Let an exact, durably verified Libre reception finish sensor setup even
  when the current glucose sample is unavailable. Keep saved history separate
  from current glucose, do not label a post-warmup missing sample as a new
  warmup, and reject stale, wrong-target, pending-save, or cleanup-uncertain
  completion evidence.
- Archive only new Libre observations on Disconnect, preserving existing
  segments and the active replay frontier. Count old overlapping segments once
  per saved bootstrap, and report unreadable archive data as unavailable.
- Retain a verified Libre connection during warmup or decoder-free reception
  only after a fresh observation commits. This does not make it a glucose
  reading. Reject an unbound legacy clear that could reimport archive-only data.
- Use time labels on short all-history charts, based on the actual visible
  span. Label archived recordings as saved sessions, not separate sensors.
- Save final driver readings after confirmed Disconnect and flush pending
  history before reconnect. Serialize writes to prevent old saves replacing
  newer history; keep data and block reconnect if the final save fails.
- Distinguish Libre Bluetooth-off, missing-permission, unavailable-adapter, and
  failed-scan errors from a real nearby-sensor search timeout. Native details
  remain private and no automatic retry is added.
- Suppress stale, untimestamped, non-finite, and raw home-screen values while
  retaining reading time and history. Validate connection progress against the
  actual driver/stage, support large-text setup, and label the Settings control.
- Preserve closed Android pre-login diagnostics without implying another phone
  caused the failure or changing retry, bond, or login-counter behavior.
- Use normal connection status and reading time on the home screen, without
  bench/body warnings or repeated history banners. Show source quality only as
  a `Data quality` row in Current sensor and archive details. Provisional/source
  flags, export disclosures, and wellness/health/live-surface gates are unchanged;
  sensor placement is not a runtime mode.
- Use each driver's timing for restored and archived history, preserving the
  reported warmup in new archives instead of applying 60 minutes to every
  sensor. Separate activation confirmation uses trusted connection policy,
  including a restrictive default for newly registered drivers.

- Retain accepted private Libre samples in the local history chart and archive,
  including across reconnect/restart. Preserve quality flags and the first
  receipt of each sensor minute; do not invent missing points or sensor expiry
  from receipt times. Provisional/raw data stays outside wellness summaries,
  Apple Health, and numeric live surfaces.
- Keep Libre NFC setup behind secondary model help. Expire stale NFC read
  proofs, and require a full app reopen after uncertain Bluetooth cleanup
  instead of offering an ineffective retry or sensor switch.
- Preserve verified warmup countdowns when early samples are provisional,
  without publishing their glucose values to live surfaces.
- Hide unsupported sensor calibration controls and preserve provisional/raw
  values without applying a previous sensor's local display correction.
- Harden the private Libre receiver file against ambiguous absence, unsafe
  paths, incomplete reads, and failed writes. Preserve the encrypted format,
  receiver identity, and monotonic login-counter contract.
- Keep the current NFC calibration patch separate from the frozen Libre 2
  Bluetooth receiver patch. Verify the receiver binding and all FRAM CRCs
  before saving calibration for the private debug decoder.
- Reuse a confirmed Libre receiver after a fresh, same-sensor NFC read instead
  of repeating streaming setup. Failed or stale verification cannot start a
  new NFC enable attempt.
- Restore the saved Libre receiver before discovery, and wait for a fresh
  exact-target advertisement before one explicit Bluetooth connection attempt.
  Preserve the completed NFC setup and login counters across app restarts.
- Show closed, user-readable Libre connection failures instead of raw internal
  codes, and distinguish radio search from successful data reception.
- Full-product protocol capture builds can keep the existing AiDEX and LinX
  driver available while passively recording Libre-family observations. The
  strict capture-only entry point remains observation-only.
- The one-shot target-unverified Libre patch-information probe now requires an
  exact eight-byte ISO 15693 identity, derives its manufacturer byte from that
  identity, accepts only an exact successful seven-byte response, and rejects
  unknown model signatures before publishing a UI result.
- The Libre NFC animation now starts only after the native reader confirms NFC
  and capture readiness. Reader loss publishes a closed retry state; reopening
  or retrying waits for a fresh native state instead of inventing readiness.

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

[Unreleased]: https://github.com/shroominic/OpenGlucose/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/shroominic/OpenGlucose/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/shroominic/OpenGlucose/releases/tag/v0.1.3
[0.1.2]: https://github.com/shroominic/OpenGlucose/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/shroominic/OpenGlucose/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/shroominic/OpenGlucose/compare/v0.0.1%2B10...v0.1.0
[0.0.1+10]: https://github.com/shroominic/OpenGlucose/tree/v0.0.1%2B10
