---
id: TASK-007
title: First-run onboarding flow
status: To Do
assignee: []
labels:
  - 'epic:onboarding'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A light, honest first-run onboarding that gets a new user from install to a working sensor with the right expectations. Inspired by Stelo/Lingo's emphasis on guided setup, but kept minimal and privacy-forward.

Steps (keep it short — skippable where reasonable):
1. Welcome + one-line value prop (open-source, local-first, wellness — not a medical device).
2. Connect sensor: scan, select, pair, activate, warmup expectation (~1h) — hand off to the sensor lifecycle UX (TASK-008) for the heavy lifting.
3. Set target/display range (the user's preferred glucose range and units).
4. Privacy explainer: data stays on device, nothing goes to the manufacturer, BYO-key for any optional AI.
5. Wellness disclaimer acknowledgment (self-experimentation framing; not for diabetes management/medical decisions).

Persist that onboarding is complete so it only shows on first run (re-runnable from settings).

**Fleet: parallelizable, but depends conceptually on TASK-008 (sensor lifecycle) for the pairing step — can be built in parallel against a stubbed pairing handoff, then wired. Touches new onboarding screens in `openhealth/lib` + a "first run complete" flag in prefs. Foundation: blocks nothing hard but should land early for new-user quality.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 First-run flow: welcome, connect-sensor handoff, set range, privacy explainer, wellness disclaimer
- [ ] #2 Onboarding completion persisted; not shown again on subsequent launches; re-runnable from settings
- [ ] #3 Privacy + non-medical wellness framing stated plainly
- [ ] #4 Steps are skippable where sensible and the app is usable after completion
<!-- AC:END -->
