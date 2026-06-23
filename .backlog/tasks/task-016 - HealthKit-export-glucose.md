---
id: TASK-016
title: Apple Health (HealthKit) — export glucose
status: To Do
assignee: []
labels:
  - 'epic:integrations'
  - 'phase:2-build'
dependencies: []
priority: medium
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Write OpenGlucose readings to Apple HealthKit (iOS) as blood-glucose samples, so the user's glucose is available to the rest of their Apple Health ecosystem. Keep it user-controlled and opt-in.

Includes:
- HealthKit permission request (write blood glucose; optionally carbs from meal events).
- Map normalized readings -> `HKQuantitySample` (blood glucose) with correct units and timestamps; dedup so re-syncs don't duplicate.
- A settings toggle to enable/disable export; respect local-first (export is opt-in, nothing leaves the device except to Apple Health on-device).

**Fleet: parallelizable. iOS-only; touches `openhealth/ios` (HealthKit entitlement + Info.plist usage strings) and a new health-export bridge in `openhealth/lib`. Independent of the Health Connect tasks (different platform). Coordinate plugin choice with TASK-017/018.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 HealthKit write permission flow + Info.plist usage strings + entitlement
- [ ] #2 Readings written as blood-glucose samples with correct units/timestamps; dedup on re-sync
- [ ] #3 Opt-in settings toggle; export disabled by default
- [ ] #4 Verified on a device/simulator that samples appear in Apple Health
<!-- AC:END -->
