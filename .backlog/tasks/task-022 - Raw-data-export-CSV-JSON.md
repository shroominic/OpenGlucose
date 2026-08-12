---
id: TASK-022
title: Raw data export (CSV/JSON)
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:2-build'
dependencies:
  - TASK-002
  - TASK-003
priority: high
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A strong open-source differentiator and core to "user-owned data": let users export their readings and events as CSV and JSON with full timestamps and metadata. Lands early.

Includes:
- Export readings (timestamp, value, unit, trend, source) and events (full normalized model) to CSV and JSON.
- Date-range selection; share/save via the platform share sheet / file save.
- Stable, documented schema (so the format is portable and re-importable by TASK-023).

**Fleet: parallelizable after TASK-002 + TASK-003. Touches a new export module in `openhealth/lib` + reads the local store; minimal UI (a settings/data screen). Pairs with TASK-023 (import/backup) — define the shared schema once.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Export readings and events to CSV and JSON with full timestamps/metadata
- [ ] #2 Date-range selection + platform share/save
- [ ] #3 Documented, stable export schema
- [ ] #4 Tests verify export round-trips the underlying data
<!-- AC:END -->
