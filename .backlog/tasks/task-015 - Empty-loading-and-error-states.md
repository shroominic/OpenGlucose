---
id: TASK-015
title: Empty, loading, and error states
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:3-polish'
dependencies:
  - TASK-014
priority: medium
ordinal: 15000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Polish the moments between data: first-launch empty states, loading skeletons, and clear error/recovery states across the app's surfaces (dashboard, journal, trends, sensor, settings). Production apps feel solid largely because these states are handled; OpenGlucose should too.

Includes:
- Empty states with a helpful next action (e.g. "No events yet — log your first meal").
- Loading skeletons/placeholders for async data (history sync, analytics compute).
- Error states with retry and plain-language explanation (failed sync, no sensor, permission denied).
- Consistent styling via the theme system (TASK-014).

**Fleet: parallelizable per-surface but SHARES theme/widget primitives with the other UX tasks — depends on TASK-014 theming. Coordinate so empty/loading widgets are defined once and reused. Touches many `openhealth/lib` screens; prefer a shared `states` widget set to avoid conflicts.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Empty states with a clear next action on every primary surface
- [ ] #2 Loading skeletons/placeholders for async data
- [ ] #3 Error states with retry + plain-language cause
- [ ] #4 Reusable shared state widgets styled via the theme system
<!-- AC:END -->
