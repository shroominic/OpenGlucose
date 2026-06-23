---
id: TASK-003
title: Local persistence for events and insights
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:1-foundation'
dependencies:
  - TASK-002
priority: high
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Persist user events, imported health signals, and derived insights on-device so journaling and summaries are available fully offline — consistent with OpenGlucose's local-first, user-owned-data positioning.

Build a local store (e.g. SQLite/Drift, Isar, or sembast — pick and record an ADR) for `HealthEvent`s and imported signals from TASK-002, plus a cache for derived analytics. Provide a clean repository interface so UI and analytics read/write through it without knowing the backend. No cloud dependency.

Requirements:
- Insert/update/delete/query events by time range and type.
- Store imported health signals with dedup by source + external id.
- Cache derived insights (e.g. daily metrics) with invalidation when underlying data changes.
- Migration story for schema evolution.

**Fleet: parallelizable after TASK-002. Touches a new persistence package (e.g. `packages/health_store`) + repository interfaces; minimal app wiring. Record an ADR for the chosen storage engine in `docs/decisions/`.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Local store persists events and imported signals across app restarts
- [ ] #2 Query by time range and type; dedup imported signals by source + external id
- [ ] #3 Repository interface abstracts the storage engine from UI/analytics
- [ ] #4 ADR recorded for the storage choice; migration path documented
- [ ] #5 Tests cover CRUD, dedup, and a migration
<!-- AC:END -->
