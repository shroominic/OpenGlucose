---
id: TASK-034
title: Sensor compatibility center
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:3-polish'
dependencies: []
priority: low
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
An in-app sensor compatibility center: which devices are supported, their capability gaps/caveats, and setup guidance. Important as OpenGlucose expands beyond the single Aidex driver toward the multi-sensor roadmap (Dexcom, Libre, etc.).

Includes:
- Supported-devices list driven by the driver stack's capabilities (Aidex X = supported today; others = planned/wanted).
- Per-device caveats (warmup, range, calibration, BLE notes) and setup guides.
- Honest "planned / wanted / not yet supported" labeling — no implying support that doesn't exist.

**Fleet: parallelizable. Touches a new compatibility screen in `openhealth/lib` reading from driver capabilities (`packages/cgm_core`). Largely independent. Mirrors the README "Sensor integrations roadmap" — keep them consistent.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 In-app supported-devices list driven by driver capabilities
- [ ] #2 Per-device caveats + setup guidance
- [ ] #3 Honest supported/planned/wanted labeling consistent with the README roadmap
<!-- AC:END -->
