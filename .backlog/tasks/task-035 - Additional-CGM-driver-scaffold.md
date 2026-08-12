---
id: TASK-035
title: Additional CGM driver scaffold (next sensor)
status: To Do
assignee: []
labels:
  - 'epic:integrations'
  - 'phase:3-polish'
dependencies: []
priority: low
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Prove the vendor-agnostic driver model by scaffolding support for a second CGM beyond Aidex, following the existing `cgm_core` / `cgm_ble` / `cgm_aidex` pattern (a new `packages/cgm_<vendor>` driver + capability registration). Pick a high-demand target from the README roadmap (e.g. Dexcom G7 or FreeStyle Libre 2/3) and scaffold the driver shape, even if full protocol support is staged.

Note: real protocol/decryption work for commercial sensors is significant and may be legally/technically constrained — this task is the architecture scaffold + capability wiring + compatibility-center entry, with protocol work tracked separately per vendor.

**Fleet: parallelizable. Touches a new `packages/cgm_<vendor>` package + driver registry + `packages/cgm_core` capability declarations. Independent of app UI. Each subsequent vendor would be its own task following this scaffold.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 New driver package scaffolded following the cgm_core/cgm_ble pattern
- [ ] #2 Capability declared and registered so the compatibility center can show it (as planned/partial)
- [ ] #3 Driver selectable through the existing driver factory without special-casing
- [ ] #4 Protocol gaps documented and tracked separately; no false "supported" claim
<!-- AC:END -->
