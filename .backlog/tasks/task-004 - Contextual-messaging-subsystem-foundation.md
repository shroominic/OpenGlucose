---
id: TASK-004
title: Contextual messaging subsystem foundation
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Foundation for surfacing in-app contextual messages — short Tips and occasional temporary info boxes — driven by app/user state, without becoming nagware. This is the shared engine that TASK-005 (Tips) and TASK-006 (temporary info boxes) build on.

Build a rule-driven messaging engine:
- A `ContextualMessage` model: id, type (tip / info-box), title/body, trigger condition, priority, dismissibility, frequency cap, and an optional CTA.
- A trigger evaluator that reads app/sensor/data state (e.g. "no events logged yet", "sensor warming up", "first full day of data", "wide glucose swings today") and decides which messages are eligible.
- Persistence of dismissals and shown-counts (so a tip isn't repeated forever) — reuse the local store from TASK-003 or a lightweight prefs store.
- A simple presentation API the UI layer can subscribe to, so surfaces (banners, cards) render from local state.

Honesty/UX guardrails: messages are observations and guidance, never medical advice; respect frequency caps; everything is dismissible.

**Fleet: parallelizable (foundation). Touches a new `packages/messaging` (engine + models) and a thin app subscription point. TASK-005 and TASK-006 depend on this and should NOT start until the engine API is stable.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `ContextualMessage` model + rule/trigger evaluator implemented in a reusable package
- [ ] #2 Dismissals and shown-counts persisted; frequency caps enforced
- [ ] #3 Presentation API exposes eligible messages as local state for the UI to render
- [ ] #4 No medical-advice phrasing; all messages dismissible
- [ ] #5 Tests cover trigger evaluation, frequency capping, and dismissal persistence
<!-- AC:END -->
