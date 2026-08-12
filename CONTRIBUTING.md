# Contributing to OpenGlucose

Thank you for improving OpenGlucose. The project handles health-adjacent data
and low-level sensor operations, so changes must be reproducible, reviewable,
and proportionate to their risk.

By contributing, you agree that your contribution may be distributed under the
repository's [MIT License](LICENSE), and that you have the right to submit it.

## Before starting

- Search existing [issues](https://github.com/shroominic/OpenGlucose/issues) and
  pull requests before proposing duplicate work.
- Follow [SECURITY.md](SECURITY.md) for a vulnerability. Private vulnerability
  reporting is an external GitHub setting and is not yet verified; do not send
  details until the private intake is visibly available.
- Do not submit real glucose histories, sensor serials, Bluetooth identifiers,
  provisioning material, credentials, or other personal data.
- Keep the product boundary clear: OpenGlucose is wellness/reference software,
  not a diagnosis, dosing, treatment, or emergency system.

Non-trivial work should have a traceable issue or task containing:

- accountable owner and scoped intent;
- acceptance criteria and explicit exclusions;
- risk level and affected interfaces or data;
- intended test and release evidence; and
- any time-bounded exception, its owner, and its expiry.

## Development setup

Use the repository-approved Flutter and Dart versions and Java 17. From a clean
checkout:

```sh
make bootstrap
make hooks
make check
```

`make hooks` verifies the pinned Lefthook version and installs the repository's
pre-commit and pre-push hooks. Run it once per worktree after bootstrap and
again after `lefthook.yml` or the installer changes. Hooks provide fast local
feedback; `make check` and CI remain authoritative.

The Make targets are the local command contract and CI should call the same
underlying commands. Useful targets are `format`, `format-check`, `lint`,
`typecheck`, `test-unit`, `test-integration`, `test-e2e`, `test`, `build`, and
`check`.

Do not introduce a second formatter, analyzer, package manager, test runner, or
hook framework without an approved migration plan. See
[docs/dependencies.md](docs/dependencies.md) before changing a manifest or
lockfile.

## Branches and worktrees

Keep meaningful work isolated from the clean control checkout:

1. Start from the recorded control commit.
2. Create a dedicated worktree and a short branch name such as
   `feature/sensor-recovery`, `fix/history-deduplication`, or
   `docs/compatibility`.
3. Do not mix unrelated formatting, generated files, or refactors into the
   change.
4. Integrate through a reviewed pull request; do not force-push shared branches
   or bypass failed checks.

Never stash, reset, clean, overwrite, or remove another contributor's worktree
to make room for a change.

## Choose the risk level

Use the R0-R3 classes and minimum controls in
[`docs/engineering/standards.md`](docs/engineering/standards.md), selecting the
highest applicable level and stating it in the pull request. A smaller code
diff is not automatically lower risk. Changes to stale-reading presentation,
timezones, unit conversion, history boundaries, authorization, destructive
sensor commands, or release signing require special scrutiny.

Do not express change risk as Low/Moderate/High or P0-P3. Reviewers use the
separate P0-P3 finding-severity definitions in the engineering standards: P0 is
critical, P1 high, P2 medium, and P3 low. A finding's severity does not replace
the pull request's R0-R3 risk class.

## Architecture rules

Follow the [architecture overview](docs/architecture/README.md) and accepted
[ADRs](docs/architecture/adr/README.md):

- `cgm_core` stays sensor-neutral and independent of Flutter;
- `cgm_ble` stays a platform-neutral transport contract;
- protocol drivers depend on abstractions, not native plugins;
- `cgm_ble_flutter` adapts a Flutter BLE plugin without owning sensor protocol;
- the app composes packages and owns platform permissions and user experience;
- local-first behavior must not silently become mandatory cloud processing.

Durable, cross-cutting, or costly-to-reverse changes need a short ADR. Copy an
existing ADR structure, assign the next number, record alternatives and
consequences, and link it from the index.

## Tests and evidence

Add the narrowest deterministic test that would fail without the change. Bug
fixes should include a regression test when practical.

- Keep unit tests offline and independent of real services and credentials.
- Use fakes for BLE protocol tests; separately record physical-device evidence
  for native adapter or sensor compatibility changes.
- Test time, timezone, unit-conversion, duplicate-import, stale-data,
  disconnect, cancellation, and partial-failure boundaries when relevant.
- UI changes require behavior verification plus screenshots on affected form
  factors. Critical user journeys require an integration or end-to-end check.
- Native changes require the affected Android or unsigned iOS build. A web
  build does not validate mobile BLE behavior.
- Public package changes require contract tests and a package changelog entry.

Run `make check` before requesting review; it includes every required gate that
the current host can execute, including platform builds and native iOS tests on
macOS. Focused targets remain useful during iteration. The current `test-e2e` target explicitly
reports that physical-device automation is deferred; it is not evidence that an
end-to-end test ran. Include exact commands and outcomes in the pull request. If
a meaningful automated check does not exist, describe the most precise manual
verification and open a follow-up rather than implying coverage.

The controls register assigns the missing physical-device E2E lane to
`@shroominic`. The baseline-default approval records a narrowly scoped exception
through 2026-11-30. Until the gap closes, R2/R3 changes affecting the sensor
journey require redacted manual device evidence; the exception does not waive
that evidence or any failed privacy/safety check.

The complete Definition of Done and controls register live in
[`docs/engineering/standards.md`](docs/engineering/standards.md); this guide
explains how contributors satisfy them.

## Pull requests

Keep commits logically reviewable. Complete the pull-request template and make
the following visible:

- what changed, why, and what did not change;
- linked issue and acceptance criteria;
- risk, health-data effects, public interfaces, and platform impact;
- tests, screenshots, build artifacts, and manual verification;
- migration, rollback, and release considerations; and
- documentation and changelog updates.

At least one independent review is expected for meaningful changes. Changes
affecting owned paths or high-risk controls require the appropriate owner. The
checked-in `CODEOWNERS` file records review intent; it does not prove GitHub
branch protection or approval rules are enabled.

Do not merge with unresolved critical findings or failed required checks unless
a maintainer records a narrowly scoped, owned, time-bounded waiver. A waiver is
not a permanent ignore or skipped test.

## Definition of done

A change is ready to integrate when:

- scope and acceptance criteria are met;
- architecture and dependency directions remain valid;
- changed behavior and important failure paths are tested;
- formatting, analysis, tests, and affected builds pass from a clean checkout
  through `make check`;
- docs, examples, changelogs, and compatibility notes are current;
- sensitive values are absent from source, fixtures, logs, and artifacts;
- independent review is complete; and
- release, migration, and recovery evidence is recorded when applicable.

See [SUPPORT.md](SUPPORT.md) for the boundary between project support, medical
questions, and sensor-vendor support.
