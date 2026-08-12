---
id: TASK-043
title: Fix sensor-life label 14 -> 15 days
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The app shows a **14-day** sensor life, but the Microtech **Aidex X** is a **15-day** sensor. Correct the sensor-life label/constant so remaining-life, expiry, and any "X days" copy reflect 15 days for Aidex X.

Quick fix: update the sensor-life value (ideally a per-driver capability/constant, not a hardcoded UI string) and any dependent countdown/expiry math.

**Note: this will likely be folded into TASK-008 (Sensor lifecycle center), which owns sensor age / remaining-life / expiry — cross-reference TASK-008. If TASK-008 lands first, verify it uses 15 days for Aidex X and close this out.**

**Fleet: quick, parallelizable, low conflict. Touches the Aidex sensor-life constant/capability (`packages/cgm_aidex` / `cgm_core`) and any UI copy. Coordinate with TASK-008 to avoid duplicate edits to the same lifecycle code.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Aidex X sensor life reads 15 days everywhere (label, remaining-life, expiry math)
- [ ] #2 Value sourced from a per-driver capability/constant, not a hardcoded UI string
- [ ] #3 Reconciled with TASK-008 lifecycle (no conflicting 14-day value remains)
<!-- AC:END -->
