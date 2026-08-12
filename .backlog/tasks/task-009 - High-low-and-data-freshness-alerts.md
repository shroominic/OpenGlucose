---
id: TASK-009
title: High/low and data-freshness alerts
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:1-foundation'
dependencies:
  - TASK-008
priority: high
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Turn the app from passive viewer into something operational. Add user-configurable alerts:
- High and low glucose thresholds (custom values + units), with a wellness-framed (non-diagnostic) presentation.
- Stale-data alert (no fresh reading for N minutes).
- Disconnect alert (sensor connection lost).
- Local notifications (foreground + background) + an in-app alert history.

Honesty guardrail: these are user-configured wellness alerts, NOT clinical hypo/hyper safety alarms; copy must avoid implying medical-grade urgent-low protection. State the wellness/self-experimentation framing where thresholds are set.

Build alert evaluation in pure Dart over normalized readings; deliver via platform notifications. Reuse sensor state from TASK-008 for disconnect/stale detection.

**Fleet: parallelizable after TASK-008. Touches a new alerts package (pure-Dart evaluation) + platform notification wiring in `openhealth/lib` (android/ios notification channels). Reads sensor state from TASK-008 — coordinate, don't edit the same lifecycle widget simultaneously.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 User-configurable high/low thresholds with units; stale-data and disconnect alerts
- [ ] #2 Local notifications fire foreground and background; in-app alert history kept
- [ ] #3 Alert evaluation is pure-Dart over normalized readings and unit-tested
- [ ] #4 Copy reviewed: wellness alerts, explicitly NOT clinical hypo/hyper safety alarms
<!-- AC:END -->
