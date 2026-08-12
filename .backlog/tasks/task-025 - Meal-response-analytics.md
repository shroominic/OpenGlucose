---
id: TASK-025
title: Meal-response analytics
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:3-polish'
dependencies:
  - TASK-024
  - TASK-012
priority: medium
ordinal: 25000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Compute and surface post-meal glucose response cards: for each logged meal, a configurable post-meal window (e.g. 2h) with peak rise, time-to-peak, return-to-baseline, and an explainable response summary. Inspired by Veri/Lingo/GlucoSense meal scoring — but transparent (show the sub-metrics, no black-box score).

Includes:
- Pure-Dart meal-response computation in the analytics package (TASK-012), keyed to meal events (TASK-024).
- A meal-response card in the journal/meal detail and optional comparison of two meals.
- Configurable window length and baseline definition.

Honesty: present as observed glucose response patterns, not nutritional/medical advice.

**Fleet: parallelizable after TASK-024 + TASK-012. Compute lives in pure-Dart analytics (independent); UI card touches meal/journal detail — coordinate with TASK-024 owner.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pure-Dart meal-response metrics: peak rise, time-to-peak, return-to-baseline over a configurable window
- [ ] #2 Meal-response card in meal detail + two-meal comparison
- [ ] #3 Configurable window/baseline; unit-tested with fixtures
- [ ] #4 Framed as observed response patterns, not advice
<!-- AC:END -->
