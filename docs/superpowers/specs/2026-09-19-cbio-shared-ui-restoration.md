# GS1 integration: unchanged shared UI

## Authoritative direction

The user's latest direction supersedes the raw-only dashboard and permanent
GS1-specific presentation work. Production OpenGlucose must retain its existing
AiDEX/Libre2 multi-sensor UI. GS1 plugs into the existing normalized sensor
contract; it does not introduce a second product UI.

No GS1-specific raw labels, screens, support references, clock/index/history
widgets, archive recovery workflow, or permanent diagnostic copy belongs in the
production UI. Temporary diagnostics require a narrowly justified private path
and removal before release. Do not keep polishing the superseded raw UI.

Verified glucose decoding remains a required deliverable. Publishing no glucose
is an honest interim state while decoding is unresolved, not a substitute for
the requested complete sensor implementation. Raw integers or their engineering
scale must never be relabeled as normalized glucose to make the UI look complete.

## Source-bound restoration baseline

Audit source and published PR #209 head:
`ac016e3a1d31b17cc7b05f340f3a8098dd9fb12d`.
PR base: `5b3a78e044f8dabad647c3cfd30d827cd38ff941` (`main`).

The pre-CBIO sensor-line baseline is
`02140e72ef553bee4035777862ce601cdc1d9ae6`, whose parent
`821f9a34bfc8af12e6a31438b88b6ed75ca370ee` adds the Libre2/Anytime multi-sensor
base. The next commit, `3c47637496ce7caaf192fadecaf1b1e7f4cb027e`, introduces
CBIO. Main and this sensor line share ancestor
`6a6c7f3584902d7cb3c27000a50df64323ebf5fe`.

There is no safe single whole-file reset baseline. Main subsequently adds
English/Chinese localization and export improvements, while main alone does not
contain the multi-sensor implementation. A read-only virtual merge of main and
the pre-CBIO tip conflicts in main, controller, session presentation, live
activity and onboarding. Its conflict-marked tree is not an approved baseline.

Restore CBIO-only hunks in the current source, checking both historical lines.
Preserve all unrelated main, Libre2, Anytime, user and safety changes. Do not
blanket-revert CBIO commits: many mix protocol, privacy, persistence and UI.

## Restoration map

| Current surface | Remove or restore | Preserve |
| --- | --- | --- |
| `openhealth/lib/main.dart` | CBIO hero/raw value and notice, lifecycle bypass, chart placeholder, freshness details, raw index/range/clock/progress/support rows, CBIO-driven archive/recovery presentation; CBIO-added key/value spacer | Current localized shared dashboard, settings, archive, multi-sensor selection/setup and unrelated changes |
| `openhealth/lib/src/session_presentation.dart` | CBIO import/type tests, vendor-specific phase/stage/freshness/error/raw-value/range/clock/support presentation | AiDEX/Libre2 behavior, localized shared errors and normalized-reading behavior |
| `openhealth/lib/src/sensor_connection_screen.dart` | CBIO-only progress override and getter | Entire existing multi-sensor connection flow and Libre2/Anytime safeguards |
| `openhealth/lib/src/dashboard_chart.dart` | `rawDiagnosticsOnly` API and new raw-history placeholder | Existing common chart; generic data-quality defenses may remain without new UI |
| `openhealth/lib/src/messaging/message_context_builder.dart` | CBIO identity-based tutorial eligibility | Shared eligibility driven by normalized readings and existing user dismissals |
| `openhealth/lib/l10n/app_en.arb`, `app_zh.arb` and generated files | Six raw/support keys plus three CBIO-induced recovery keys once unused | All existing localization and neutral multi-sensor onboarding/setup copy |
| `openhealth/lib/src/live_activity_payload.dart`, `integrations_settings_pane.dart` | Vendor-specific production presentation/identity branches | Shared privacy, consent, freshness and quality policies; normalized-only input |
| `openhealth/lib/src/healthkit_export.dart` | No vendor branch currently exists; do not remove its generic raw/provisional rejection | Existing consent/watermark behavior and generic quality defenses before native and injected exporters |
| `openhealth/lib/src/sensor_archive_export.dart` | Production GS1-only raw-export presentation/workflow | Existing normalized archive/export contract and preservation of legacy raw bytes |
| `openhealth/lib/src/app_controller.dart`, `persistence/cbio_history_state.dart` | Stop exposing raw archives as normalized `history`/`latestReading`; remove UI-only accessors when unused | Atomic raw checkpoint/archive state, sensor identity, failed-write retention, legacy recovery ownership and cross-driver rejection |
| `packages/cgm_cbio/` and driver composition | Produce the existing normalized contract only from verified decoding; keep raw protocol state separate | Authentication, framing, serialized polling, exact witness guards, terminal cleanup and private diagnosis until no longer needed |

Six raw/support keys: `rawSensorChartUnavailable`, `rawSensorValueNotice`,
`rawSensorValueLabel`, `rawSensorHistorySaved`, `rawSensorIndexLabel`,
`supportReference`. Three recovery keys: `archiveNeedsRecovery`,
`archiveRecoverySummary`, `archiveRecoveryNotice`.

Do not erase old raw archives or migrate their engineering values into glucose.
The current producer projects raw records into both `history` and `rawHistory`
and sets a raw record as `latestReading`. The boundary must be corrected before
removing presentation guards, including restored and archived records whose old
quality flags are absent. Restricted raw persistence remains distinct from the
normalized public reading projection. No public `cgm_core` breaking migration,
new raw UI, storage deletion or new sensor command is authorized by this spec.

## Approved private storage boundary

Root approved these exact private data-layer routes after the initial audit:

- Existing `openHealth.history.cbio.v1.<binding>` raw envelopes remain unchanged.
- `openHealth.driverState.cbio.rawArchives.v1` is a private manifest in the same
  restricted, backup-excluded health store. It owns raw archive descriptors;
  raw archives no longer need a production archive/recovery UI workflow.
- New normalized GS1 history uses
  `openHealth.history.normalized.v1.<existing canonical encoded driver+sensor binding>`.
  Reuse the existing canonical binding encoder; do not create a second identity
  algorithm or infer a sensor identity from display text.
- Persist the private descriptor before atomically updating the normal archive
  index. Preserve original raw blobs and legacy lists. The migration must be
  idempotent after interruption and fail without losing the prior raw state.

This permits the narrowly specified manifest/routing migration, not a general
storage framework or public core-schema redesign. The exact interface plan below
was independently reviewed and approved for staged RED-to-GREEN implementation.

### Accepted ownership and interfaces

- Package `lib/src/cbio_private_state.dart` exports
  `abstract interface class CbioPrivateStateStore` with
  `Future<String?> read(String sensorKey)` and
  `Future<void> write(String sensorKey, String envelope)`. The package remains
  independent of Flutter and the app's `HealthStateStore`.
- `CbioSensorDriver` adds optional `CbioPrivateStateStore? privateStateStore`,
  `Future<void> prepareTarget(DiscoveredSensor sensor)` and
  `Future<void> flushPrivateState()`. Driver/session private ownership reuses
  the raw-v1 codec with byte-identical schema, ordering and validation.
- Target preparation validates only: no radio, selection, writable resources
  or activation. Read-only staged state is discardable; connect reloads after
  flushing the old owner. Writes are serialized; failed dirty state remains
  owned and retryable until a successful durable write.
- App `persistence/cbio_private_state_adapter.dart` implements the store over
  `HealthStateStore` and exposes `Future<void> migrateLegacyArchives()`.
  Migration durably copies raw descriptors plus original index text into the
  version-1 manifest before replacing the normal index. Known normalized routes
  are excluded. Unknown versions, malformed or ambiguous descriptors preserve
  all originals and fail closed.
- Extract the existing encoder unchanged into
  `persistence/sensor_state_identity.dart` and reuse it in adapter/controller.
  Add only the exact manifest key to the restricted-store allowlist;
  `_isHistoryKey` remains the existing `openHealth.history.*` classification.
- `CgmAppController` accepts optional constructor callbacks
  `Future<void> Function(DiscoveredSensor)? prepareTarget`,
  `Future<void> Function()? flushPrivateState` and
  `String? Function(DiscoveredSensor)? historyNamespace`. Null means existing
  behavior. A namespace override never falls back to legacy/raw routes.
- `driver_factory.dart`, its IO/stub variants and bootstrap compose the adapter
  and hooks after store initialization/migration. No renderer edits belong in
  the boundary stage. Remove shared-controller CBIO proof/raw machinery only
  once equivalent private ownership and regression tests exist.
- Every public `CgmReading`-valued snapshot field obeys normalized semantics,
  explicitly including `history`, `rawHistory` and `latestReading`. The name
  `rawHistory` is not permission to expose protocol records. Private raw state
  uses private typed records. Tests must assert that actual protocol acquisition
  and legacy restoration populate none of these fields until decoding is
  independently verified. Empty normalized fields are interim, not completion.
- Public normalized history counters remain zero/unknown while decoding is
  unavailable; do not advertise decoded-history/raw-history availability from
  private raw acquisition. Raw progress, retention counts and polling remain
  private. This truthful interim capability state is not feature completion.
- Disconnect drains and flushes private writes. Required app flush propagates
  failures independently of generic disconnect error handling. Synchronous
  dispose cannot promise completion: schedule flush, retain last durable data,
  and report sanitized persistence failure without false durable-success claims.
  Async handoff generation checks after awaits prevent stale/canceled commits.

The additive package API requires changelog and compatibility coverage. Preserve
generic data-quality defenses independent of sensor identity. No user-data
deletion/reset, public core change, new storage framework or new radio operation
is authorized.

## Minimal app-only handoff hooks

The host may inject optional/no-op-default `prepareTarget(sensor)`,
`flushPrivateState()` and `historyNamespace(sensor)` hooks at the existing
controller/storage boundary. They are app composition details, not new
`cgm_core` APIs or renderer vendor branches. AiDEX/default behavior stays
unchanged when hooks are absent.

Required transition order is: prepare target without committing selection;
durably flush old private state; only then commit the new selected identity.
Do not rely on `session.disconnect()` alone for durability: the current host
swallows disconnect errors. A failed required flush must remain observable to
the durable-handoff path and retain the old identity and dirty private state
for retry. A failed target preparation must not disconnect or replace the old
session. A prepared target must be released without activating it if the old
flush fails. The private-store owner defines exact close/dispose and retry
semantics before code; no new generic lifecycle framework is needed.

Required regression cases include:

- target preparation failure retains the old live session, selection and data;
- old flush failure prevents new identity/connection commit and retains dirty
  raw state; a subsequent successful retry commits exactly once;
- delayed target preparation or old flush cannot commit a canceled/superseded
  handoff or overwrite a newer selection;
- private descriptor write failure leaves the normal archive index unchanged;
- normal index write failure after durable private copy is safely repeatable,
  without losing bytes or multiplying descriptors;
- malformed/unknown manifests and legacy descriptors fail closed while keeping
  originals; interrupted migration is idempotent;
- identical storage keys on different drivers encode to distinct routes;
  normalized loads never fall back to raw-v1 or legacy raw history namespaces;
- no-op/default hooks preserve AiDEX/Libre2/Anytime existing behavior;
- private flush failures on explicit disconnect/dispose are reported truthfully
  and do not erase the last durable state.

## Acceptance

- GS1-specific conditionals and diagnostic strings are absent from production
  main/session presentation/localization/messaging/health surfaces. Protocol,
  composition and private data migration may remain sensor-specific.
- Given equivalent normalized snapshots, AiDEX, Libre2 and GS1 use the same
  components, layout and actions; only existing sensor identity text differs.
- Raw acquisition, legacy restore, failed reconciliation and archived raw data
  cannot populate normalized current/history, charts, wellness, exports or
  glucose-bearing live surfaces. Existing bytes and sensor-bound checkpoints
  survive upgrade, failure, restart and handoff unchanged.
- Existing AiDEX/Libre2/Anytime and localized setup behavior remains verified.
- Playwright screenshots compare shared screens in English/Chinese at narrow
  and phone widths, both units and relevant normal/error/empty/stale states.
- Driver/host regression tests cover normalized/raw separation and all existing
  witness, persistence and terminal guards. Independent review and precise
  app/package/native checks precede a source-bound private device test.
- Actual release completion still requires verified normalized glucose,
  supported-model/lifecycle evidence, sustained live and historical acquisition,
  restart/reconnect/screen-off proof and artifact/distribution approval.

Keep one `feature/cbio-gs1` carrier and PR #209 open. No main merge, public
release, sensor reset/activation/calibration or phone data clearing is implied.
