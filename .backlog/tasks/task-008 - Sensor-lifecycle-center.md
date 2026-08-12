---
id: TASK-008
title: Sensor lifecycle center
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Make sensor state legible at all times. Today the app scans/connects/syncs but does not give a clear, always-available picture of where the sensor is in its lifecycle. Add explicit, user-facing states: scanning, pairing, warming up (with countdown), ready/active, reconnecting, expiring (sensor age + remaining life), expired, and failed.

Includes:
- A sensor lifecycle/status surface (card or dedicated screen) showing current state, sensor age, remaining-life, and last successful sync time.
- A warmup countdown (~1h) and a background-freshness indicator.
- An explicit reconnect button and a documented auto-retry policy.
- State machine that derives these from driver/session signals (build on existing `session_presentation.dart` / `app_controller.dart`).

Strongest common denominator across Stelo, GS3, Lingo, Supersapiens — the #1 gap to "daily driver".

**Fleet: parallelizable, but it is the central sensor-state surface — TASK-009 (alerts) and TASK-007 (onboarding pairing step) depend on its state model. Touches `openhealth/lib/src/session_presentation.dart`, `app_controller.dart`, and a new lifecycle widget. Coordinate with TASK-009 since both read sensor state.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Explicit states surfaced: scanning, pairing, warming-up (countdown), ready, reconnecting, expiring, expired, failed
- [ ] #2 Sensor age, remaining-life, and last-successful-sync time displayed
- [ ] #3 Manual reconnect action + documented auto-retry policy
- [ ] #4 State derived from driver/session signals via a tested state machine
<!-- AC:END -->
