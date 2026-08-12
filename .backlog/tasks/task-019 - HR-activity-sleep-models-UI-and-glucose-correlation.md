---
id: TASK-019
title: Heart-rate, activity, sleep — UI and glucose correlation
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:3-polish'
dependencies:
  - TASK-017
  - TASK-018
  - TASK-012
priority: medium
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Now that activity, sleep, and heart-rate signals are imported (TASK-017/018) and the metrics engine exists (TASK-012), surface them and correlate with glucose. This is the first real step toward the Whoop/Oura-style multi-signal vision while staying glucose-centric today.

Includes:
- Visualizations: activity/steps, sleep sessions, and heart-rate alongside (or overlaid on) the glucose trace.
- Simple, explainable correlation views: e.g. glucose response after workouts, overnight glucose vs sleep, HR vs glucose during activity.
- Honest framing: surface observed associations/patterns, NOT causal or medical claims; show the underlying data.

**Fleet: parallelizable after its deps. Touches new visualization/correlation widgets in `openhealth/lib` + reads from analytics (TASK-012). May overlap the chart widget — coordinate with TASK-011/013. Correlation math should live in the pure-Dart analytics package.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Activity, sleep, and heart-rate visualized alongside glucose
- [ ] #2 At least: post-workout glucose response, overnight glucose vs sleep, HR vs glucose views
- [ ] #3 Correlation computed in pure-Dart analytics; framed as observed patterns, not causal/medical claims
- [ ] #4 Degrades gracefully when a signal type is absent
<!-- AC:END -->
