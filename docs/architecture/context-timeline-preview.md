# Context timeline preview

- Status: Draft, isolated, non-shipping visual component
- Owner: `@shroominic`
- Scope: typed fixture/source seam only

## Boundary

`CompactContextTimeline` is not composed into `main.dart`, Home, Settings, a
release artifact, or a platform integration. It has no repository, platform,
HealthKit, Health Connect, network, or persistence access. The component reads
one synchronous `ContextTimelineSource` snapshot and can emit only an unsaved
draft intent to a receiving feature.

The preview is collapsed by default. It does not replace a glucose surface,
modify glucose data, add a journal record, request a permission, or make a
medical claim.

## Truth rules

- The selected time window filters every displayed record. A fallback lane
  status becomes **Partial data** only when it has a record in that selected
  window. An upstream source must provide an explicit status when it knows that
  data is unavailable, stale, partial, or conflicting.
- Individual details show their exact local time window, source label, and
  qualification. A mixed-source heart-rate rail lists every represented source;
  it never attributes the entire rail to the newest sample's source.
- The optional attachment prompt is generic. It is not called a glucose rise,
  pattern, explanation, or cause. It lets a receiving feature prepare an
  unsaved draft only. There is no production prompt provider in this change.
- Sample snapshots carry the visible `SAMPLE DATA — NOT FROM A SENSOR` notice.
  The preview must never imply that sample, imported, stale, partial, or
  inaccessible context is live sensor data.

## Deferred work

A future app-facing context surface needs a reviewed coordinator, a
deterministic evidence-bound candidate policy before any glucose-pattern cue,
source-priority rules, persistence/lifecycle ownership, privacy review, and
redacted device evidence. That work is outside this preview.

## Deterministic evidence

`openhealth/test/context_timeline/compact_context_timeline_test.dart` checks
the collapsed state, range/status truth, mixed-source drill-down, generic
non-causal prompt copy, screen-reader labels, compact layouts, and reduced
motion. It also owns the deterministic sample screenshot below:

![Redacted deterministic context timeline sample](context-timeline-preview-sample.png)

The golden uses Flutter's deterministic test font, so text is rendered as
redacted blocks. The same widget test asserts the readable semantic labels.
The fixture contains synthetic sample data only; no sensor identifier, person,
or real health record is captured in the image.
