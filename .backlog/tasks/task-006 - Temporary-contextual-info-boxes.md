---
id: TASK-006
title: Temporary contextual info boxes
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:2-build'
dependencies:
  - TASK-004
priority: medium
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ship occasional, temporary info boxes on top of the contextual-messaging engine (TASK-004). Unlike persistent tips, these are time- or state-bounded notices (e.g. "Sensor warming up — readings stabilize in ~1h", "New: you can now export your data", "Heads up: your last sync was 40 min ago") that appear when relevant and then go away.

Includes:
- Info-box UI surface (banner/inline card) distinct from tips, with clear dismiss + auto-expiry.
- Trigger wiring for transient states (warmup, stale data, new-feature announcements, data-import completion).
- Expiry/auto-hide behavior so boxes don't linger after the condition clears.

**Fleet: parallelizable after TASK-004. Touches app UI (info-box/banner widget) + trigger wiring. Shares the messaging engine with TASK-005; serialize if the same banner widget is edited by both.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Temporary info-box surface with dismiss + auto-expiry
- [ ] #2 Triggers wired for warmup, stale-data, and announcement-style states
- [ ] #3 Boxes auto-hide once the underlying condition clears
- [ ] #4 Non-medical, observation-only framing
<!-- AC:END -->
