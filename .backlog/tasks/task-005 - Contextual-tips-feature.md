---
id: TASK-005
title: Contextual tips feature
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:2-build'
dependencies:
  - TASK-004
priority: medium
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ship the Tips experience on top of the contextual-messaging engine (TASK-004). Tips are short, helpful, dismissible nudges that help users get more from the app and understand their glucose patterns — framed as observations/guidance, never medical advice.

Includes:
- An initial library of tip content (onboarding tips, "log your first meal", "your glucose was stable overnight", "try tagging caffeine", metric explainers).
- Tip surfaces in the UI (e.g. a dismissible card on the dashboard / contextual inline hints).
- Wiring tip triggers to real app/data state via the engine.

**Fleet: parallelizable after TASK-004. Touches app UI (dashboard/tip card widgets) + a tips content file. Shares the messaging engine with TASK-006 but the UI surfaces differ; coordinate on shared widgets if any.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Tip content library defined and wired to engine triggers
- [ ] #2 Dismissible tip surface renders from messaging state
- [ ] #3 Tips respect frequency caps and never repeat after dismissal
- [ ] #4 Copy reviewed for wellness (non-medical) framing
<!-- AC:END -->
