---
id: TASK-012
title: Explainable glucose metrics pack
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:2-build'
dependencies:
  - TASK-002
  - TASK-003
priority: high
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The core analytics differentiator: interpretable, pure-Dart metrics derived from the glucose trace, with transparent definitions (no black-box scores). This is where OpenGlucose competes without a backend.

Compute (pure Dart, in a reusable analytics package):
- Time in range / target-range adherence (using the user's configured range).
- Average glucose; trailing variability (SD/CV-style).
- Excursion count + average excursion size.
- Spike detection with start / peak / end / duration.
- Daily summary + a simple daily exposure / area-under-curve style metric.
- Part-of-day and overnight summaries.

Surface them with in-app definitions ("what drives this number") per the explainable-metrics principle. Cache results via TASK-003.

Honesty: present as patterns/observations, not diagnoses or clinical GMI/AGP claims.

**Fleet: parallelizable after TASK-002 + TASK-003. Touches a new pure-Dart `packages/analytics` (compute + tests) + a metrics UI surface in `openhealth/lib`. The compute layer is independent; only the UI surface may overlap dashboard work (coordinate with TASK-013).**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pure-Dart metrics: time-in-range, average, variability, excursions, spike detection, daily exposure
- [ ] #2 Spike detection reports start/peak/end/duration; overnight + part-of-day summaries
- [ ] #3 In-app, plain-language definition shown for each metric
- [ ] #4 Results cached and recomputed on data change; unit tests with known fixtures
- [ ] #5 Framing is observational/pattern-based, not clinical/diagnostic
<!-- AC:END -->
