# Engineering standards

This is the contributor Definition of Done for OpenGlucose. Repository commands
and CI are the technical source of truth; remote branch protection, secret
policy, and release approvals are external controls and remain unverified until
an authorized owner supplies evidence.

## Change readiness and risk

Each non-trivial change records an accountable owner, scope and exclusions,
acceptance criteria, affected interfaces/data, risk class, test evidence,
documentation impact, and release/recovery intent. Use an isolated worktree from
a recorded clean control commit and a branch such as `feature/<scope>`,
`fix/<scope>`, `chore/<scope>`, or `docs/<scope>`.

| Class | Trigger                                                                                                                        | Minimum control                                                                                                              |
| ----- | ------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| R0    | Docs/internal refactor with no behavior change                                                                                 | Relevant local check and review                                                                                              |
| R1    | Ordinary behavior, UI, or shared package change                                                                                | Regression/unit test, format/analyze/test/build as applicable, independent review                                            |
| R2    | Health/device data, BLE, database/schema, export, accessibility, third-party integration, AI, release configuration            | Named domain owner, risk-specific tests, docs, recovery plan, independent review; staged delivery where feasible             |
| R3    | Destructive sensor command, medical/dosing behavior, signing/secrets, irreversible data loss, external production distribution | Explicit accountable approval, fail-closed control, rehearsal/evidence, rollback or kill switch, no unresolved P0/P1 finding |

R0-R3 classifies the inherent risk of a proposed change and therefore the
controls it needs. It does not classify review findings.

## Review-finding severity

Reviewers use P0-P3 only for actionable findings:

| Severity | Meaning                                                                                                                              | Merge effect                                                                  |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| P0       | Critical: active or imminent severe user harm, sensitive-data or credential exposure, destructive corruption, or compromised release | Stop affected delivery and remediate before merge or release                  |
| P1       | High: credible safety, security, privacy, data-integrity, public-contract, or release-correctness defect                             | Blocks merge until fixed or covered by an explicitly approved R3-grade waiver |
| P2       | Medium: material correctness, reliability, compatibility, accessibility, or maintainability defect                                   | Fix before merge or record a narrowly scoped, owned, expiring waiver          |
| P3       | Low: limited-impact polish, clarity, test, documentation, or maintainability issue                                                   | Normally non-blocking; track when not addressed                               |

Finding severity measures impact, not effort, file count, or the change's R0-R3
class. Historical product roadmaps may use P0-P3 as backlog priority; that is a
separate, explicitly labeled vocabulary.

## Definition of Done

- Scope is small and traceable; durable cross-cutting choices have a decision
  record when warranted.
- Supported runtimes and application/native dependency graphs are reproducible;
  lockfiles appropriate to each package type remain committed.
- Changed behavior has deterministic tests. UI changes include accessibility,
  behavior, and screenshot evidence; native/device-critical changes include the
  appropriate emulator or real-device evidence.
- The canonical local `check` contract and relevant build/package validation
  pass from a clean worktree. CI uses a frozen clean checkout and is authoritative.
- Privacy, safety, setup, architecture, operations, and user-facing docs change
  with the behavior.
- Independent review resolves all P0/P1 findings and fixes or explicitly waives
  every P2 finding. Release artifacts are tied to a source commit, signed with
  release credentials, checksummed, approved, and recoverable.

## Waivers

A waiver is an issue/decision record containing the control, reason, risk,
compensating measure, accountable owner, approving reviewer, and expiry date.
It must be time-bounded and visible; permanent skips, blanket ignores, and
unrecorded failed-check bypasses are not waivers. Expired waivers block release.

## Controls register

| Control                          | Applicability           | Status                                                   | Evidence                                                                   | Owner         | Exception expiry                  |
| -------------------------------- | ----------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------- | ------------- | --------------------------------- |
| Data classification              | Health/device data      | Documented; implementation verification incomplete       | `docs/privacy/data-handling.md`                                            | `@shroominic` | Before external release           |
| Intended-use boundary            | Health metrics/AI       | Verified locally                                         | `docs/product-safety.md`                                                   | `@shroominic` | —                                 |
| Android backup exclusion         | Restricted data         | Enforced in repository                                   | manifest and `res/xml/*backup*`                                            | `@shroominic` | —                                 |
| iOS backup exclusion             | Restricted data         | Implemented in repository; platform verification pending | Dedicated file, migration, native attribute code and local tests           | `@shroominic` | Before external release           |
| Lock-screen redaction            | Restricted data         | Implemented in repository; final verification pending    | Android service, iOS controller, and local tests                           | `@shroominic` | Before external release           |
| Sensitive-log controls           | Restricted data         | Policy documented; implementation verification pending   | `docs/privacy/data-handling.md`; production/device audit absent            | `@shroominic` | Before external release           |
| Complete deletion/retention      | Restricted data         | Planned                                                  | Partial cache clear only                                                   | `@shroominic` | Before production-readiness claim |
| Physical-device end-to-end lane  | Critical sensor journey | Approved time-bounded baseline exception                 | `make test-e2e` reports deferred; redacted manual device evidence required | `@shroominic` | 2026-11-30                        |
| Release signing                  | Distributable app       | Enforced locally, external unverified                    | Android fails without release env; release runbook                         | `@shroominic` | —                                 |
| Dependency/secret scanning       | Supply chain            | Enforced in repository; external execution unverified    | `.github/workflows/security.yml` and `.github/dependabot.yml`              | `@shroominic` | —                                 |
| Private vulnerability intake     | Security reports        | Unverified external                                      | GitHub private-reporting URL documented; repository setting not verified   | `@shroominic` | Before external release           |
| Accessibility verification       | Mobile UI               | Planned                                                  | No established semantics/device lane                                       | `@shroominic` | Before production-readiness claim |
| Protected branch/required checks | Integration             | Unverified external                                      | Requires repository-admin evidence                                         | `@shroominic` | Before merging the feature train  |

Update this register as controls become enforced, verified, waived, or no longer
applicable. A checked-in file proves intent, not remote enforcement.

The physical-device E2E exception was explicitly approved with the baseline
defaults on 2026-08-12 by accountable owner and approving reviewer
`@shroominic`. It expires on 2026-11-30. The reason is that deterministic sensor
hardware automation is not yet available in the project. The compensating
control is redacted manual device evidence for every affected R2/R3 change.
This exception covers only the missing automated lane: it does not waive device
evidence, any failed check, or any privacy/safety defect, and no automated
end-to-end coverage may be claimed.
