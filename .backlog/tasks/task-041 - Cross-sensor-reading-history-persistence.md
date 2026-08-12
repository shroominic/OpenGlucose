---
id: TASK-041
title: Cross-sensor reading-history persistence
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 41000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Raw historical **glucose readings must persist across sensor changes.** Today, starting a **new** sensor risks losing the **old** sensor's reading history. Glucose readings are the user's own data — they must survive sensor swaps, app restarts, and offboarding/expiry of the previous sensor.

Build durable persistence for the raw reading time series plus a **per-sensor session archive**, so each sensor session's readings are retained and the full history is queryable as one continuous timeline spanning multiple sensors:
- Persist every reading keyed to its sensor/session, never overwritten when a new sensor starts.
- A per-sensor session archive (sensor id, start/end, lifecycle outcome) linking each session to its readings.
- Continuous cross-sensor history query (one timeline across sensor changes) for charts/metrics.
- Survives new-sensor onboarding, app restart, and previous-sensor expiry.

This is **distinct from TASK-003** (local persistence for *events and insights*) and from any events/insights persistence — this task is the **raw reading history + per-sensor session archive**. Reuse the TASK-003 storage engine/repository pattern rather than inventing a new one.

**Fleet: parallelizable; aligns with TASK-003's storage engine. Touches the persistence layer (`packages/health_store` or the reading store) + session/sensor metadata; minimal app wiring. Coordinate with TASK-008 (sensor lifecycle) for session start/end boundaries.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Raw glucose readings persist across sensor changes — starting a new sensor never loses the old sensor's readings
- [ ] #2 Per-sensor session archive links each sensor session to its readings (id, start/end, outcome)
- [ ] #3 Continuous cross-sensor history is queryable as one timeline for charts/metrics
- [ ] #4 History survives new-sensor onboarding, app restart, and previous-sensor expiry
- [ ] #5 Tests cover persistence across a simulated sensor swap
<!-- AC:END -->
