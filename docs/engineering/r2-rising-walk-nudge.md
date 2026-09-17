# R2 traceability: sharp-rise walk nudge

- **Owner:** `@shroominic`
- **Risk class:** R2 — health-derived behavioral guidance
- **Scope:** A deterministic, in-app-only wellness nudge for a fresh,
  in-range, monotonic glucose rise. It uses no new dependency, persistence,
  cloud flow, notification, sensor command, or schema.
- **Safety controls:** The detector fails closed for warmup; non-ready or
  disconnected state; health error, malfunction, signal loss, or expiry;
  stale, provisional, non-finite, or untimestamped input; sparse, falling, or
  insufficient traces; and current values outside 100–179 mg/dL. Red remains
  reserved for safety alerts. The copy contains no diagnosis, dosing,
  treatment, emergency instruction, or native-alert replacement.
- **Privacy:** It processes current local controller state only. Dismissal is
  recurring and exists only for the active controller run.
- **Recovery:** Revert the focused feature commit to remove the detector,
  nudge, hero badge, chart-tail presentation, and demo fixture together. No
  stored migration or remote rollback is required.
- **Release controls:** Require independent review by the accountable owner,
  deterministic regression evidence, and staged demo evidence before merge or
  release. Capture redacted phone-width visual evidence on a loopback-capable
  host; the repository's physical-device exception does not waive that review.
