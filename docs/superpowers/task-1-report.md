# CBIO GS1 Task 1 report

## Scope and verdict

Task 1 closed the deterministic session I/O and serialization defects listed in
the release-readiness plan. The implementation remains provisional GS1 raw
data; it does not promote units, alter protocol commands, or claim production
glucose validation.

Base: `7e58f862ce44c1049cca428ed76b5d26bb742bb`

Head: recorded by the commit that adds this report.

Verdict: requirement-complete for Task 1, with the broader CBIO release still
blocked by the remaining plan items (unit verification, chart/export policy,
counter-era persistence, polling longevity, lifecycle evidence, credential
policy, documentation, native builds, and real-device release proof).

## RED evidence

Before the session changes, the focused test run had the intended failures:

- The serial-service assertion observed an empty `serviceUuid` at the BLE read
  boundary.
- An initial history write failure never reached a terminal snapshot and could
  later be advanced by the history deadline.
- A live write failure left `refreshLiveData()` without a structured write
  failure.
- A topology failure left the established fake GATT connection unreleased.
- Overlapping refreshes overwrote the shared pending completer and timed out.

The RED run also showed the disconnect-during-read case needed explicit pending
read settlement.

## Changes

- Resolve 2A25 from the discovered characteristic/service reference. When a
  platform omits 2A25 from the discovered list, use the already discovered GS1
  service context rather than an empty service UUID, then retain the validated
  MAC fallback for unusable responses.
- Await initial history writes and route failures through the existing closed
  `cbio.write.failed` state.
- Make live/history reads single-flight through a FIFO operation queue; settle the
  active read on disconnect or terminal failure and prevent timers from
  resurrecting error/closed sessions.
- Release notification/state subscriptions and the established GATT connection
  on terminal topology, authentication, or write failures without replacing the
  failure snapshot or surfacing cleanup details.
- Added synthetic tests for the iOS-style opaque identifier, serial reference,
  history/live write failure, topology cleanup, overlapping reads, and pending
  read settlement.
- Updated the package changelog.

## GREEN evidence

Commands run from `packages/cgm_cbio` using the pinned SDK:

```text
/Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart format --output=none lib/src/cbio_glucose_session.dart test/cbio_glucose_session_test.dart
/Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart analyze --fatal-infos
No issues found!
/Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart test
00:01 +139 ~2: All tests passed!
```

The two skips are the existing credential-injection tests; no real vendor
material was used.

## Modified files

- `packages/cgm_cbio/lib/src/cbio_glucose_session.dart`
- `packages/cgm_cbio/test/cbio_glucose_session_test.dart`
- `packages/cgm_cbio/CHANGELOG.md`
- `docs/superpowers/task-1-report.md`

## Remaining concerns

This task intentionally leaves the finite read budget unchanged. It also does
not address raw-unit contamination in shared chart/export surfaces, discovery
model admission, persisted counter eras, lifecycle/warmup semantics, artifact
credential policy, compatibility documentation, native builds, or real-phone
release verification.

## Follow-up P1 race guard

RED: a deterministic regression test forced the already-queued history idle
and deadline callbacks to run after the transport drop had published the
disconnected state. Before the guard, `_finishHistory` changed the session back
to `ready`.

GREEN: `_finishHistory` and the catch-up deadline callback now return when the
session is closing, link-dropped, or terminally failed. The focused regression
test passes (`dart test ... -n 'queued history timeout'`), and the package
suite passes (`dart test`, `+140 ~2`). Format checking and
`dart analyze --fatal-infos` also pass with no issues.

## Follow-up P2 terminal callback regression matrix

Nine deterministic cases now exercise each queued history-idle, history-deadline,
and catch-up callback after write failure, transport drop, and explicit close.
The timer double records its duration so each case selects the intended callback.
Every case also starts an active and a queued history caller, verifies both settle
at termination, then forces the cancelled callback to run. The assertions require
the same terminal stage/error, no extra snapshots, no new timer, no active timer,
and no additional transport writes.

Mutation RED: temporarily removing both callback guards with `apply_patch`
made six cases fail for the expected reasons: history callbacks returned to
`ready` after failure/drop, and catch-up callbacks emitted an extra terminal
snapshot. The three explicit-close cases still passed because the existing
publication and polling helpers independently reject closed sessions. Both
production guards were restored exactly; this follow-up changes no production
code.

GREEN after restoration, from `packages/cgm_cbio` with the pinned SDK:

```text
dart test test/cbio_glucose_session_test.dart -n 'is inert after' --reporter expanded
9 passed
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos
No issues found!
dart test --reporter expanded
149 passed, 2 existing vendor-material-injection skips
```

This closes the reviewed callback coverage gap only. It does not establish
calibrated glucose, full lifecycle, or device-backed release readiness.
