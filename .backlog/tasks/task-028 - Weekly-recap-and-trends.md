---
id: TASK-028
title: Weekly recap and trends
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:3-polish'
dependencies:
  - TASK-012
priority: medium
ordinal: 28000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
An auto-generated weekly summary that creates a retention loop: top spikes, most stable windows, time-in-range trend, biggest meal responses, and week-over-week shifts — in plain language. Inspired by Lingo/Stelo/Vively recaps.

Includes:
- Weekly recap view summarizing metrics (TASK-012) and notable events.
- Week-over-week comparison (this week vs last week).
- Plain-language summary lines (optionally AI-enhanced via TASK-020, but must work without AI).

Honesty: observations and trends, not advice.

**Fleet: parallelizable after TASK-012. Recap computation in pure-Dart analytics; a recap UI surface. Optional AI enhancement via TASK-020 must be additive, not required. Coordinate with nav (TASK-014).**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Weekly recap: top spikes, stable windows, time-in-range trend, notable events
- [ ] #2 Week-over-week comparison
- [ ] #3 Plain-language summary that works WITHOUT AI; optional AI enhancement
- [ ] #4 Observational framing only
<!-- AC:END -->
