---
id: TASK-040
title: Sensor warmup flow fix
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sensor **warmup flow** is currently "somewhat broken" (per the founder). After inserting/pairing a new sensor, the ~1h warmup phase does not behave correctly — symptoms still to be confirmed (e.g. warmup state/countdown not entered or exited correctly, readings surfacing during warmup, or warmup not clearing into ready/active).

**BLOCKED — awaiting founder's details.** Do **not** guess-fix this. The exact reproduction, expected behavior, and which signals are misbehaving must come from the founder before any code change. Capture those specifics here first, then implement.

This is closely related to TASK-008 (Sensor lifecycle center), which owns the warmup-countdown / ready state model — coordinate so the warmup fix and the lifecycle state machine stay consistent. Likely touches `openhealth/lib/src/session_presentation.dart` / `app_controller.dart` and the warmup state derivation.

**Fleet: BLOCKED until founder provides the warmup specifics — do not start implementation. When unblocked, coordinate with TASK-008 (shared warmup/ready state model).**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Founder's warmup specifics captured here (repro + expected behavior) before any fix
- [ ] #2 Warmup state is entered, counted down (~1h), and cleared into ready/active correctly
- [ ] #3 No misleading readings surfaced during warmup
- [ ] #4 Behavior consistent with the TASK-008 lifecycle state model; regression test added
<!-- AC:END -->
