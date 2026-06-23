---
id: TASK-037
title: Developer mode and sensor diagnostics
status: To Do
assignee: []
labels:
  - 'epic:dev-ex'
  - 'phase:3-polish'
dependencies: []
priority: low
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A hidden/opt-in developer mode for power users and contributors: sensor diagnostics, raw BLE/session logs, an advanced log view, and an event-correlation debug view. Builds on diagnostics already in the `cgm_aidex` driver. Aligns with OpenGlucose's hackable, open-source ethos ("hackable with Claude/Codex").

Includes:
- Toggle to reveal developer mode.
- Sensor diagnostics readout + raw session/log viewer.
- Advanced data/event log view and correlation inspector.

**Fleet: parallelizable. Touches a new dev-mode screen in `openhealth/lib` reading driver diagnostics. Independent of mainstream UI; low conflict risk.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Opt-in developer mode toggle
- [ ] #2 Sensor diagnostics + raw session/log viewer
- [ ] #3 Advanced log/event-correlation view
- [ ] #4 Hidden by default; no impact on normal users
<!-- AC:END -->
