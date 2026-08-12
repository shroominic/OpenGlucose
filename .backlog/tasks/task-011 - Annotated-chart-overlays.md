---
id: TASK-011
title: Annotated chart overlays for events
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:2-build'
dependencies:
  - TASK-002
  - TASK-010
priority: high
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Render event markers (meals, workouts, sleep, medication, notes) directly on the glucose graph so users can visually correlate context with their trace. Nearly universal across the better inspiration apps.

Includes:
- Event marker glyphs/labels on the existing dashboard chart (`dashboard_chart.dart`), keyed by event type.
- Tap a marker to see event details; tap a point in time to add an event at that timestamp.
- Optional per-type visibility toggles.
- A scoped/zoomed view of the trace around a single event window (for meal-response context).

**Fleet: NOT fully parallelizable with other chart/dashboard work — directly edits `openhealth/lib/src/dashboard_chart.dart`. Serialize with TASK-013 (dashboard polish) and any other task touching the chart widget. Depends on TASK-010 events existing.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Event markers render on the glucose chart, keyed by type
- [ ] #2 Tap a marker for details; tap the trace to add an event at that time
- [ ] #3 Per-type visibility toggles and a scoped event-window view
- [ ] #4 Chart performance acceptable with many events present
<!-- AC:END -->
