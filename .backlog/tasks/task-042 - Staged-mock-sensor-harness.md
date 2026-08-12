---
id: TASK-042
title: Staged mock sensor harness
status: To Do
assignee: []
labels:
  - 'epic:dev-ex'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A switchable **mock sensor harness** with staged test scenarios — the in-simulator testing backbone so sensor UX, lifecycle, alerts, and persistence can be exercised without real hardware.

Scenarios to support (switchable):
- warmup
- active-high
- active-low (low)
- expiring
- expired
- signal-loss
- multi-sensor (swap one sensor for another)
- error

Plus a **Developer-tab switcher** to flip between scenarios live in-sim. This backbone unblocks deterministic testing of TASK-008 (lifecycle), TASK-009 (alerts), TASK-040 (warmup fix), and TASK-041 (cross-sensor persistence — drives the multi-sensor swap path).

**Note: implementation is already in flight on branch `feat/mock-sensor-scenarios` — track/finish that branch rather than starting fresh.**

**Fleet: parallelizable; foundational dev-ex. Touches a mock driver behind the `cgm_core` driver factory + a Developer-tab switcher in `openhealth/lib`. Low conflict; many other sensor tasks depend on it for testing. WIP on `feat/mock-sensor-scenarios`.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Mock sensor driver supports scenarios: warmup, active-high, low, expiring, expired, signal-loss, multi-sensor, error
- [ ] #2 Developer-tab switcher flips scenarios live in-simulator
- [ ] #3 Mock driver selectable through the existing driver factory without special-casing
- [ ] #4 Multi-sensor scenario exercises a sensor swap (supports TASK-041 testing)
- [ ] #5 Work consolidated from / completed on branch `feat/mock-sensor-scenarios`
<!-- AC:END -->
