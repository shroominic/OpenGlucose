---
id: TASK-032
title: Athlete mode (optional)
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:3-polish'
dependencies:
  - TASK-010
  - TASK-012
  - TASK-019
priority: low
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
An optional, event-centric mode for athletes/self-experimenters, inspired by Supersapiens — layered on the SAME data foundation, never forced on everyone. Treats glucose as a fueling/performance signal.

Includes:
- Event-first workflow (workout as the central object) with fueling windows / carb-timing overlays on the trace.
- Custom sport-specific target zones (narrow, tunable) distinct from the everyday range.
- Post-workout recovery summary and workout-vs-workout comparison by glucose pattern.
- Stays modular: toggled in settings; core CGM tracking unaffected when off.

Honesty: performance/fueling observations for self-experimentation, not medical or clinical guidance.

**Fleet: parallelizable after deps, but it is a large mode spanning journal + analytics + charts. Touches a new athlete-mode module + overlays on the chart (coordinate with TASK-011/013). Best as its own track once the foundations land. Keep it behind a settings toggle so it doesn't entangle the default experience.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Optional, settings-toggled mode; core CGM tracking unchanged when off
- [ ] #2 Event-first workflow with fueling-window/carb-timing overlays
- [ ] #3 Custom sport-specific target zones + post-workout recovery summary + workout comparison
- [ ] #4 Self-experimentation/performance framing, not medical guidance
<!-- AC:END -->
