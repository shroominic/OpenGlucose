# Privacy and data handling

OpenGlucose is local-first, not data-free. This document separates required
policy from the checked-in implementation status and outstanding verification.
Platform store disclosures and applicable legal obligations require an assigned
privacy owner before public distribution.

## Classification and flows

| Class                  | Examples                                                                              | Required handling                                                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Restricted health data | glucose values/times, calibrations, health events, derived metrics, AI inputs/outputs | Local by design; no automatic upload; native backup, logging, export, and deletion controls require the verification described below |
| Sensitive device data  | sensor serial/device ID, BLE advertisements, diagnostics, firmware                    | Minimize, keep on device, redact from filenames/logs/lock screen                                                                     |
| Secret                 | API keys, signing keys, store credentials                                             | Platform secret store or ephemeral release environment; never repository/preferences/logs                                            |
| Operational            | app version, non-sensitive error class, check result                                  | May be retained only when documented and stripped of health/device identifiers                                                       |

Native persistence is implemented to keep sensor identity and glucose history
in versioned, dedicated application-support files. Dart writes use serialized,
transactional snapshots with interrupted-commit recovery. On first launch they
migrate restricted legacy preference keys and remove them only after the new
file is durable. Schema-three history blobs use deterministic SHA-256 filenames
instead of reversible base64 storage keys. Startup atomically renames
schema-two blobs, resumes mixed pre/post-rename states, and preserves both
copies while failing closed if an unexpected conflict prevents safe migration.
iOS-native background sensor state and the redacted Live Activity payload use
a separate excluded directory/file instead of
`UserDefaults`. The upgrade purges an old raw Live Activity payload before
loading native state; it migrates the target transactionally, and purges the
target even on failure so a recoverable rescan is preferred to backup exposure.
Android configuration disables backup/device transfer and excludes app domains;
final device verification remains release evidence. On iOS, the implementation
requests `NSURLIsExcludedFromBackupKey`, reads the attribute back, and fails the
restricted-store startup if it is not confirmed. Local tests exercise the
storage behavior. Physical app-container inspection on `Shroominic` confirmed
the current restricted directory and files were backup-excluded in build 17 on
2026-08-14; a full backup/restore rehearsal remains separate evidence. These are
implementation and device-check claims, not proof of store enforcement.

The dedicated file is JSON and is not encrypted by OpenGlucose itself. It
relies on the application sandbox and operating-system at-rest protections;
their device-state behavior and threat-model sufficiency remain verification
work. Backup exclusion is not encryption.

Display-only preferences may remain in platform preferences. In an actual web
build, `PreferencesHealthStateStore` delegates to `shared_preferences`, whose
web implementation uses origin-scoped browser `localStorage`; browser clearing,
profiles, extensions, origin access, and browser sync/backup behavior are
outside the mobile controls. Unit/widget tests instead use mocked in-memory
preferences. The web build is a demo/test surface and must not be represented
as a private or supported health-data retention surface.

Lock-screen implementations default to redacted glucose on Android and iOS.
On iOS launch, any pre-upgrade Live Activity is ended when sensitive display has
not been explicitly enabled, preventing old unredacted state from surviving an
upgrade. Final device verification remains outstanding. There is intentionally
no user opt-in UI yet; adding one is a privacy-triggered feature.

## Retention and deletion

Glucose history is retained locally while a sensor is selected so reconnection
can recover. The exact product retention period is **planned, not yet approved**.
Until a complete delete-all path and retention setting exist, this is a release
risk rather than an implicit indefinite-retention policy.

“Clear cache” is not a verified account/data erasure control. A complete erase
must stop active writes, clear every sensor history, selected sensor, native
background target and payload, live activity/notification, journal/database,
AI insight, API key, temporary export, and derived cache, then verify absence
after relaunch. See `docs/runbooks/data-recovery.md`.

The current app does not provide a verified delete-all flow. Disconnecting or
clearing one selected sensor is not equivalent to complete erasure.

## Sharing and export

The iOS app implements an opt-in, write-only Apple Health integration. It sends
glucose values and their timestamps as blood-glucose samples only after the
user enables the integration and taps **Sync now**; simulated/demo data is
blocked. It does not read HealthKit data. Apple Health's privacy, retention,
backup, and deletion behavior applies once a sample is written. The local
contiguous export watermark and last-sync time use the restricted state store,
not backup-eligible preferences. Because a HealthKit write and the local cursor
cannot commit atomically, an interrupted sync can write a duplicate sample on
retry. The UI discloses this at-least-once behavior.

Archived sensor details provide an explicit single-file export through the
platform share sheet. A confirmation preview displays the sensor-session date
range, reading count, every exported category, and a mutually exclusive choice
of CSV, tab-delimited plain text, or an Excel workbook before the share sheet
opens. Every format contains glucose values/times, units, record source,
sensor-relative minute, raw/qualifier fields, provisional state, archive reason,
and session timing. XLSX exports are genuine Office Open XML workbooks with
numeric measurement cells; they are not renamed CSV files.
Stable session IDs, storage keys, serials, device IDs, display names, model,
firmware, and driver IDs are omitted. The filename is neutral. Native exports
use one scoped temporary directory, delete their source file after the share
sheet completes, and remove stale OpenGlucose/share-plugin cache copies at the
next launch. Startup also removes the exact legacy
`openhealth_<sensor-id>_<timestamp>.csv` regular-file shape that older builds
wrote into the platform cache; near-matches, other extensions, directories,
and unrelated cache entries are left untouched. Cleanup is best effort because
platform share targets and operating systems may retain copies under their own
terms. Export never starts automatically; the destination is user-controlled
and its privacy and retention terms apply.

These files are user-readable data exports, not recovery/restore backups.
Recovery exports remain planned: they must be encrypted, versioned, integrity
checked, and restored only after an explicit preview.

## Logs, analytics, and incidents

Policy requires production logs to omit health values, sensor identity, BLE
payloads, notes, prompts/responses, API keys, and signing credentials. Release
startup makes its first BLE-plugin call a fail-closed request for
`flutter_blue_plus` log level `none`, before storage initialization or any BLE
operation. This suppresses the plugin's Dart and native runtime BLE logs; debug
and profile builds retain local diagnostics. Other console and in-app
diagnostic paths still require a complete production/device audit; do not treat
them as redacted or safe to share. No hosted crash/analytics
processor is approved by this baseline. Any such collection remains off until
its fields, processor, retention, consent, and deletion path receive privacy
review. Follow
`docs/runbooks/privacy-security-incident.md` for suspected disclosure.

## AI

AI is off by default and requires a user-supplied key. The current Generate
action sends a 24-hour aggregate to the HTTPS provider URL shown in settings:
reading count, average, range, standard deviation, time in/below/above range,
estimated A1c, meal/exercise/note counts, and total logged carbohydrates. It
does not send raw readings or note text. The UI discloses those categories and
that provider retention terms apply. Redirects, credentials in URLs, query
parameters, and non-HTTPS endpoints are rejected. Before public distribution,
the prompt/model/policy still requires representative medical/dosing
adversarial evaluation and an accountable privacy/safety owner.
