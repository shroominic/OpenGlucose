# ADR 0002: Keep health data local by default

- Status: Accepted
- Date: 2026-08-12
- Owners: `@shroominic`

## Context

Glucose values, timestamps, derived metrics, sensor identifiers, events,
exports, and optional AI inputs reveal sensitive personal information. Core CGM
use does not require a service account, and a mandatory backend would add
identity, access-control, retention, breach-response, vendor, and operational
boundaries before they are needed.

Platform backup, notifications, export files, screenshots, logs, and third-party
integrations can move data even when an application describes itself as
"local." Local-first therefore needs explicit controls, not just the absence of
an application server.

## Decision

Core functionality remains usable without an account or mandatory network
service. Health data is stored and processed on the user's device by default.
Any export, backup, cloud, sharing, analytics, crash-reporting, or AI path that
moves health data across that boundary must be explicit, purpose-limited,
documented, and revocable where possible.

Default controls are:

- exclude health data from platform cloud backup until an encrypted,
  user-controlled backup design is approved;
- redact glucose values on lock-screen surfaces unless the user explicitly
  opts in with a clear privacy explanation;
- minimize and bound logs, never logging credentials or stable sensor
  identifiers by default;
- provide complete deletion and test retention/migration behavior;
- preview exports, minimize identifiers, and remove temporary files; and
- keep optional AI off by default, enforce secure provider contracts and data
  sufficiency, and prevent output from becoming diagnosis, dosing, treatment,
  or emergency guidance.

OpenGlucose does not claim regulatory compliance solely because these
principles are documented. A feature that introduces a new party or purpose
requires privacy/security review and an updated data-flow record before merge.

## Alternatives considered

- **Mandatory hosted account and sync:** improves multi-device access but
  introduces unnecessary identity and data custody for the current journey.
- **Rely on OS backup defaults:** convenient, but moves health data into an
  implicit cloud boundary without a product-level decision.
- **Never allow data to leave the device:** minimizes exposure but conflicts
  with user-owned export, recovery, and deliberate interoperability.
- **Treat all analytics/AI as anonymous:** unsafe; timestamped patterns and
  sensor metadata can remain identifying even without a name.

## Consequences

- Offline behavior is a product requirement, not merely graceful degradation.
- Features must inventory data collected, purpose, location, retention,
  deletion, recipients, and failure behavior.
- Backup, sharing, AI, and diagnostics take more design and test work before
  release.
- Users may need to initiate exports or backup rather than receiving seamless
  server sync.
- Local compromise and device loss remain risks; secure platform storage and a
  future encrypted backup design require separate implementation decisions.

## Follow-up controls

- Maintain privacy/data-lifecycle documentation and platform-specific tests.
- Add redacted diagnostics and sensitive-log checks.
- Add deletion, export cleanup, and backup-exclusion verification.
- Treat new data recipients and AI providers as high-risk third-party
  integrations with an accountable owner.
