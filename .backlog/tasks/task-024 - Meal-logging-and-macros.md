---
id: TASK-024
title: Meal logging v1 and macros
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:2-build'
dependencies:
  - TASK-010
priority: medium
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deepen meal events beyond a note: a low-friction meal entry with time, optional carbs and notes, tags, and optional macro fields (calories/protein/carbs/fat/fiber). Search-free for v1 (type the values) — no food database yet; AI/photo capture comes later (TASK-026/027).

Includes:
- Meal-specific entry form layered on the journal event (TASK-010): time, carbs, macros (optional), tags, note.
- Duplicate-previous-meal and meal templates for repeat entries.
- Macro totals surfaced where relevant (e.g. daily macro summary).

**Fleet: parallelizable after TASK-010. Touches the meal-entry portion of the journal UI + the meal event payload. Coordinate with TASK-010 (same journal screens) — ideally same owner or serialized.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Meal entry with time, optional carbs, optional macros (cal/protein/carb/fat/fiber), tags, note
- [ ] #2 Duplicate-previous-meal and templates
- [ ] #3 Daily macro summary surfaced
- [ ] #4 Fully manual/offline; no medical-advice framing
<!-- AC:END -->
