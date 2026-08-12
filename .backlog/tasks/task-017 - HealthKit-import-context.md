---
id: TASK-017
title: Apple Health (HealthKit) — import activity, sleep, heart rate
status: To Do
assignee: []
labels:
  - 'epic:integrations'
  - 'phase:2-build'
dependencies:
  - TASK-002
priority: medium
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Read activity (steps/workouts), sleep, heart rate, and calories FROM HealthKit into OpenGlucose's normalized health-signal models (TASK-002), so the glucose trace gains real context (the basis for correlation and richer insights).

Includes:
- HealthKit read permissions for steps, workouts, sleep analysis, heart rate, active energy.
- Map `HKSample`s -> normalized signals with source provenance = healthkit; dedup by external id.
- Background/periodic refresh and a manual "sync now"; persist via TASK-003.
- Settings to choose which data types to import.

**Fleet: parallelizable after TASK-002. iOS-only; touches `openhealth/ios` (HealthKit read entitlement + usage strings) + import bridge in `openhealth/lib`. Parity with TASK-018 (Health Connect) — share the normalized mapping layer so both platforms produce identical models.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Read permissions + import for steps/workouts, sleep, heart rate, active energy
- [ ] #2 Samples mapped to normalized signals (provenance=healthkit), deduped by external id
- [ ] #3 Manual sync + periodic/background refresh; persisted locally
- [ ] #4 Per-type import toggles in settings
<!-- AC:END -->
