---
id: TASK-010
title: Event journal UI (meals, notes, events)
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:2-build'
dependencies:
  - TASK-002
  - TASK-003
priority: high
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The journaling UI on top of the event model (TASK-002) and local store (TASK-003). Lets users log and review meals, notes, and events tagged to a time so glucose can be reasoned about in context.

Includes:
- Fast-add flows: meal, workout, sleep note, medication/supplement, generic note, mood/energy.
- Quick tags (caffeine, alcohol, stress, illness, fasting) and free-text.
- Optional structured fields per type (e.g. carbs for meals; duration/intensity for workouts).
- A chronological timeline/list view to browse, edit, and delete events.
- Convenience: duplicate-previous-meal, event templates.

Keep it search-free and low-friction for v1 (manual entry); food database / AI capture come later (TASK-019/020).

**Fleet: parallelizable after TASK-002 + TASK-003. Touches new journaling screens/widgets in `openhealth/lib` + repository calls. Shares the dashboard navigation shell with the UX-polish tasks (TASK-013/014) — coordinate on nav/shared widgets.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Fast-add for meal, workout, sleep, medication, note, mood with quick tags and free-text
- [ ] #2 Chronological timeline to browse/edit/delete events, persisted via the local store
- [ ] #3 Duplicate-previous and templates for repeat entries
- [ ] #4 Works fully offline; no medical-advice framing
<!-- AC:END -->
