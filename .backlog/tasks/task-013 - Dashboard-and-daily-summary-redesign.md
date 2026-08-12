---
id: TASK-013
title: Dashboard and daily summary redesign
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:2-build'
dependencies:
  - TASK-012
priority: medium
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A usable "today" home view: current glucose + trend, sensor state, key metrics from TASK-012, recent events, and contextual tips — the daily landing surface. Inspired by Stelo/Supersapiens/Ultrahuman home screens but on-brand minimal.

Includes:
- Hero current-reading card with trend/slope.
- Today's key metrics row (time-in-range, average, spikes).
- Recent events strip + quick-add entry point.
- Sensor lifecycle summary (from TASK-008) and a tip/info-box slot (TASK-004).

**Fleet: NOT parallelizable with other dashboard/chart tasks — edits the dashboard shell and `dashboard_chart.dart`. SERIALIZE with TASK-011 (chart overlays), TASK-014 (nav/theming), and any task touching the home screen. These four UX tasks share widgets; run them one at a time.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Home view shows current reading + trend, today's key metrics, recent events, sensor summary
- [ ] #2 Quick-add event entry point and a tip/info-box slot present
- [ ] #3 Renders cleanly with empty data and with a full day of data
- [ ] #4 On-brand minimal styling consistent with the theming task
<!-- AC:END -->
