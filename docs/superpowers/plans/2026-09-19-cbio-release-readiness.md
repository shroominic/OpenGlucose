# CBIO release readiness implementation plan

> Use test-driven development and independent task review. Retain the single feature/cbio-gs1 branch and PR #209. Do not merge or publish release artifacts.

## Objective and acceptance

Deliver production GS1 support through the shared sensor UI, with evidence-backed glucose decoding and units, accurate lifecycle, durable history, reliable live/reconnect behavior, reproducible release artifacts, and real-phone verification. A raw-data-only screen does not satisfy this objective.

Risk: R2 for protocol/reliability/data work; R3 approval required for activation, destructive commands, signing or changes to distribution of vendor material. Accountable product owner: @shroominic.

## Global constraints

- Preserve all sensor/user data and unrelated work. No reset, unbind, activation, calibration, firmware or phone-profile changes.
- Do not claim that raw / 10 is mg/dL or mmol/L without independent evidence. Preserve raw data and do not retrospectively relabel persisted samples.
- Reuse the AiDEX presentation and sensor-neutral contracts where supported by evidence; do not disguise incomplete data as production glucose.
- Synthetic fixtures only. No credentials, health records, private reference code or identifiers in tracked artifacts.
- SDK: repository-pinned `.toolchains/flutter/bin`. Tests, analysis and formatting run in the dedicated worktree. Use apply_patch for edits.
- Independent review plus focused RED/GREEN evidence are required for each code task. Final make check, native builds and phone proof remain release gates.

## Task 1: Close session I/O failure and serialization defects

Files: packages/cgm_cbio/lib/src/cbio_glucose_session.dart; packages/cgm_cbio/test/cbio_glucose_session_test.dart; packages/cgm_cbio/CHANGELOG.md.

- [x] Read the existing fake BLE boundaries and the session state machine. Run the existing package tests as baseline.
- [x] Add failing tests demonstrating that the serial characteristic must use its discovered service UUID (including an iOS-style opaque device ID), rather than a fabricated empty service UUID. Assert the actual characteristic reference used at the BLE boundary.
- [x] Resolve the serial from discovered services; retain existing correctly validated MAC fallback when no usable serial exists. No new wire commands.
- [x] Add failing tests for initial history-write and live-write failures. A failure must publish a structured terminal failure, cease live timers and settle pending callers; it must not later emit ready from an idle/deadline callback.
- [x] Test topology/auth/write terminal errors releasing the established GATT connection and preserving the failure snapshot. Cleanup errors are caught without replacing the closed failure code; dedicated throwing-cleanup tests remain a verification follow-up.
- [x] Add failing tests for overlapping refresh/history requests and disconnect during an outstanding read. Ensure every caller settles and queries are single-flight/serialized; do not overwrite a pending completer or allow timers to resurrect a closed/error session.
- [x] Implement the smallest fixes satisfying those tests. Keep the current read-budget policy unchanged in this task; it is a subsequent release defect, not waived.
- [x] Run package tests, dart analyze --fatal-infos, and format-check. Update package changelog, self-review and commit only owned files.

Task review must separately verdict requirement compliance and code quality. Report the base/head, RED failures, GREEN results, modified files and remaining concerns.

## Remaining release work (not waived or declared complete)

1. Trace the reference payload/processed/native algorithm and lifecycle evidence; implement verified normalized glucose and model admission only when source and target evidence justify them.
2. Correct chart/export raw-unit contamination; unify the verified-reading UI with AiDEX while keeping uncertainty visible until verification is complete. Test both unit preferences, raw/provisional/mixed/archived data and screenshots.
3. Persist history epoch/counter and clock provenance across process restarts with migrations and interruption tests; prevent old/new sensor eras merging.
4. Replace the finite production polling halt with bounded recoverable operation and verify overnight/screen-off freshness, drop/reconnect, restart and history completion.
5. Establish evidence-backed warmup/activation/expiry/model behavior, without deriving activation from first observation.
6. Resolve source policy versus artifact-embedded vendor material, malformed configuration checks, signing provenance and reproducible builds. Do not silently redesign provisioning or assert runtime injection.
7. Update contradictory compatibility/release docs and PR claims; retain Libre2 ancestry. Run independent full review, complete native/check matrix and real-phone release-artifact demonstration without clearing app data.

## Progress ledger

- Original base: `7e58f862ce44c1049cca428ed76b5d26bb742bb`.
- Task 1 implementation `4cca7d1`, independent-review timer fix `c219345`, and nine-case terminal callback regression matrix `b0fc74b` are on the single feature branch. Mutation RED reproduced four history-resurrection and two catch-up-emission failures; restored guards passed all nine cases. Explicit-close cases remain independently protected by closed-session helpers. See `docs/superpowers/task-1-report.md`.
- Reviewed containment `31097a9` was cherry-picked as `9b46082`: raw integer display, unit-free notice, no CBIO glucose chart, blank raw glucose export cells, and CBIO identity gates for wellness/HealthKit/live surfaces. This is interim containment, not calibrated sensor completion.
- Reviewed UI polish `78b607f` was cherry-picked without conflict as `d5075a7`: shared compact dashboard layout, one raw-value notice, neutral Connected/Disconnected labels, explicit freshness, hidden unsupported lifecycle/expiry, and range/clock/history details under Current sensor. English/Chinese wording and unchanged AiDEX paths were independently inspected. Fresh canonical checks: four app suites (`cbio_app_surface`, `cbio_clock_anchor_surface`, `cbio_timestamp_guard`, `session_presentation`) passed 72 tests; six touched Dart files passed format check; app analysis passed. This integrates source only; the separate UI lane owns its isolated build/device evidence.
- Polling worker commit `9b650346026187f33c714c14f004f552395f1bec` is **not integrated** pending independent review. Based on the also-unintegrated checkpoint producer `51b7b7b`, it removes the production lifetime cap while preserving an explicit nullable bench cap, coalesces paced reads, preserves earliest catch-up cursors, and settles callers at terminal boundaries. Worker package evidence: 196 passed, two real-material skips, clean analysis/format, with RED for cap/pacing/coalescing/late-write/paused-status defects and synthetic 1001-tick runs for both empty and growing archives. No radio or sustained phone behavior is proved by those tests.
- Reviewed package checkpoint `a442826` and review fixes `832d206` were cherry-picked as `8447528` and `a597034`: versioned sensor-bound witness, fail-closed counter reconciliation, explicit anchor provenance, retained validated checkpoint on disconnect. **Host atomic checkpoint/archive persistence and legacy-era separation are not implemented by these commits. Do not deploy this combined build until that integration is reviewed.**
- Combined code verification head: `a5970344bd7580d354cd035012e950a753f4c92a`. Cherry-picks had no conflicts. Both the terminal-callback matrix and checkpoint tests survived the automatic test-file merge. No push, main merge, release, or combined-build phone install performed.
- Fresh package checks at that head: `dart format --output=none --set-exit-if-changed lib test` (30 files, no changes), `dart analyze --fatal-infos` (no issues), `dart test --reporter expanded` (182 passed, two existing real-material-injection skips).
- Fresh app checks: `dart format --output=none --set-exit-if-changed lib test` (123 files, no changes), `flutter analyze --no-pub` (no issues). `flutter test --no-pub --reporter expanded` over the twelve files listed below passed 192 tests. Commands used the pinned SDK from each package/app directory.
- App test files: `cbio_app_surface_test.dart`, `dashboard_chart_test.dart`, `live_activity_payload_test.dart`, `sensor_archive_export_test.dart`, `session_presentation_test.dart`, `healthkit_export_test.dart`, `cbio_timestamp_guard_test.dart`, `cbio_clock_anchor_surface_test.dart`, `cbio_live_freshness_test.dart`, `app_controller_persistence_test.dart`, `expired_sensor_archive_test.dart`, and `home_archive_feedback_test.dart` (all under `openhealth/test/`). These existing host tests do not prove new CBIO atomic checkpoint integration.
- Remaining release gates are unchanged in scope: verified calibrated decoder and exact model admission; sensor-derived typed lifecycle; host atomic persistence/migration/interruption behavior; sustained polling beyond the current 480-read cap; vendor-material artifact distribution/provisioning policy; full workspace/native artifact checks; and real-phone live/history/reconnect/restart/screen-off release proof. Source review and synthetic checks do not replace these gates.
- Integration ownership: the isolated host-persistence lane may add only a closed resume-status signal and exact confirmed input-checkpoint binding to `cbio_glucose_session.dart`, emitted after witness reconciliation. Polling work must remain read-only/design-only until that producer commit is available, then rebase on it. Do not overlap edits or bypass the confirmed-witness host gate. The separate UI lane owns visual/device follow-ups; canonical integration does not install its combined artifact.
- Ruling: fix deterministic reliability defects while investigating decoding in parallel. No sensor commands or unit promotion are authorized by passing tests. Cost if wrong: follow-up adaptation to the independently established protocol, not a shipped incorrect glucose claim.
- Evidence report: `docs/superpowers/cbio-offset4-evidence-report.md` confirms offset 4 is raw algorithm input and activation state is unresolved; this blocks any raw `/10` promotion and corrects the stale “not activated” hypothesis.
