# Architecture decision records

Architecture decision records (ADRs) capture durable decisions and their
consequences. Accepted describes the agreed direction; it does not imply every
enforcement detail is already implemented.

| ADR                                     | Status   | Decision                                                                                |
| --------------------------------------- | -------- | --------------------------------------------------------------------------------------- |
| [0001](0001-package-boundaries.md)      | Accepted | Separate domain, BLE transport, vendor protocol, platform adapter, and app composition  |
| [0002](0002-local-first-health-data.md) | Accepted | Keep health data local by default and make movement explicit                            |
| [0003](0003-platform-release-model.md)  | Accepted | Build source-bound mobile artifacts and release only through fail-closed platform lanes |
| [0004](0004-evidence-backed-observations.md) | Accepted | Keep metabolic observations deterministic, typed, evidence-backed, and AI output bounded |
| [0005](0005-source-aware-health-context-import.md) | Accepted | Import bounded, read-only health context through one source-aware local contract |

## Adding an ADR

Use the next four-digit number. Record the date, status, context, decision,
alternatives, consequences, and follow-up controls. An ADR is appropriate for a
durable, cross-cutting, costly-to-reverse, or cross-team choice. Routine
implementation detail belongs in code and contributor documentation.

Valid statuses are Proposed, Accepted, Superseded, and Rejected. A superseding
record must link both directions; do not rewrite the historical decision to
make it look current.
