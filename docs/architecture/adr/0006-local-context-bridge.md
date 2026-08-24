# ADR 0006: Compose optional local context through a bounded app cache

- Status: Accepted
- Date: 2026-08-24
- Owners: `@shroominic`

## Context

Future reader surfaces may combine active-sensor glucose history with optional
manual diary entries and imported activity, sleep, and heart-rate context.
Those sources have different lifecycles and contain restricted metadata such
as sensor storage keys, platform external identifiers, source application and
device details, raw packets, and import provenance. Direct repository reads
from widgets would blur those boundaries and make a chart/UI change able to
start an import or expose identifiers accidentally.

The reviewed recent-observed-rise contract supplies a deterministic,
non-causal observation candidate, but it deliberately has no product default
threshold. A presentation must not silently enable a health-related prompt.

## Decision

The Flutter composition root owns a local `ContextBridge`. It listens only to
the current application session and existing local-context change signals. It
assembles a bounded, cached, presentation-neutral snapshot from:

- post-warmup readings from the active ready sensor session;
- source-aware samples already retained in the local health repository; and
- bounded manual journal entries.

The snapshot exposes bridge-generated opaque IDs and normalized source labels.
It does not expose sensor/device identifiers, raw packets, platform external
IDs, or provenance objects. The bridge never requests permissions, starts an
import, schedules background work, or calls AI.

Observed-rise suggestions are disabled by default. Enabling them requires an
explicit product-selected non-clinical policy and disclosure. The bridge fails
closed for invalid, raw/calibration-only, provisional, future, duplicate, or
mixed-source reading inputs.

Durable attachment facts use an additive SQLite table separate from legacy
`health_events` JSON. They link a manual diary row to an opaque candidate ID,
calculation version, and bounded time window without storing glucose values or
source identifiers.

## Alternatives considered

- **Let dashboard widgets query repositories directly:** rejected because it
  gives presentation code access to restricted provenance and creates hidden
  import/lifecycle coupling.
- **Add context overlays and a diary workflow in the same change:** rejected
  to keep the reader-first UI and product choices separately reviewable.
- **Enable a default rise threshold or causal label:** rejected because the
  deterministic contract does not define a product/medical meaning of a rise.
- **Start automatic imports or local AI from the bridge:** rejected because
  both need separate user controls, purpose review, and data-flow evidence.

## Consequences

- Future UI consumes cached bridge models and remains repository-free.
- Imported source data stays local, source-labelled, and conservative when a
  local query is empty or incomplete; it never claims a permission result.
- Context cache and attachment-fact data are local SQLite data and remain in
  the existing retention/delete-all follow-up scope.
- Chart annotations, the optional recent-rise question, timing adjustment,
  diary/statistics UI, import UX, retention controls, and AI remain separate
  work with their own accessibility and device evidence.
