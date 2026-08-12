---
id: TASK-036
title: In-app metric definitions and app docs
status: To Do
assignee: []
labels:
  - 'epic:docs'
  - 'phase:2-build'
dependencies:
  - TASK-012
priority: medium
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Make the app's metrics and behavior transparent — a key open-source differentiator. Document, in-app and in `docs/`, exactly how each metric is computed (time-in-range, variability, excursions, spike detection, daily exposure, meal-response), plus the privacy model and the wellness/non-medical positioning.

Includes:
- Public, plain-language metric definitions surfaced in-app (the "what drives this number" content for TASK-012/025).
- A `docs/` page documenting metric formulas, the privacy/data-handling model, and the wellness disclaimer language.
- Keep definitions in sync with the analytics implementation.

**Fleet: parallelizable after TASK-012. Touches `docs/` + an in-app definitions content source (read by metric surfaces). Mostly content; coordinate wording with TASK-012/025 owners.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Plain-language definitions for every shipped metric, surfaced in-app
- [ ] #2 `docs/` page with metric formulas, privacy model, and wellness disclaimer
- [ ] #3 Definitions match the analytics implementation
<!-- AC:END -->
