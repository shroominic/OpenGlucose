# Product safety boundary

OpenGlucose is an open-source wellness and self-experimentation tool. It is not
approved to diagnose, prescribe treatment, calculate medication doses, replace
a blood glucose meter, or provide emergency monitoring. Product copy, metrics,
AI output, notifications, exports, and release notes must not imply otherwise.

## Safety principles

- Preserve raw readings and provenance. Display calibration must never overwrite
  the source measurement.
- Label stale, missing, provisional, simulated, and manually adjusted data.
- Do not derive safety-relevant conclusions from sparse or irregular coverage.
- Do not turn AI text into alerts, dosing, sensor commands, or automatic actions.
- Fail closed for destructive sensor operations, release signing, health-data
  sharing, and lock-screen disclosure.
- Keep demo data unmistakably separate from real sensor data.

## High-risk changes

The following require a health/safety owner, explicit acceptance criteria,
independent review, regression evidence, and a rollback plan:

- glucose parsing, units, calibration, time alignment, or derived metrics;
- sensor pairing, activation, destructive/admin commands, or history recovery;
- alerts, lock-screen presentation, exports, persistence, migration, or deletion;
- health-platform imports/exports or any new third-party data flow;
- AI prompts, models, provider adapters, output policy, or automation;
- signing, distribution, or store metadata that changes intended use.

Release UI must not expose factory trim, reset, shelf-mode, or clear-storage
commands without a separately approved privileged workflow. Each destructive
operation needs capability checks, bounded inputs, explicit confirmation,
auditable local outcome, and recovery guidance.

## Safety acceptance evidence

Critical behavior is verified with deterministic fixtures, corrupted and
boundary inputs, unit and timezone conversions, sparse/future/out-of-order data,
reconnect and partial-history behavior, permission denial, and stale-data UI.
Supported production sensors additionally need a bounded real-device matrix
covering documented firmware and OS combinations.

An exception must follow the waiver process in
`docs/engineering/standards.md`; controls for an R2/R3 change and P0/P1 review
findings cannot be silently disabled or hidden in a permanent ignore.
