---
id: TASK-021
title: AI insights and chat over local data
status: To Do
assignee: []
labels:
  - 'epic:ai'
  - 'phase:3-polish'
dependencies:
  - TASK-020
  - TASK-012
priority: medium
ordinal: 21000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user-facing AI features built on the AI foundation (TASK-020) and metrics (TASK-012):
- AI-generated insights: day/week pattern summaries grounded in the user's local readings, events, and metrics ("your largest spikes followed late dinners", with the data shown).
- A chat interface to ask questions about the user's own local data ("what happened to my glucose after my run yesterday?"), answered from local context.

Hard requirements:
- Every insight/answer is framed as patterns/observations and can cite the underlying data; NO medical or treatment advice, no diagnoses.
- Works only when the user has enabled AI and configured a provider; clear, honest empty/disabled state otherwise.
- Natural-language search over the local journal/history as part of chat.

**Fleet: parallelizable after TASK-020 + TASK-012. Touches new insights + chat UI in `openhealth/lib` and the `packages/ai` context builder. Independent of UX-polish chart work; coordinate only on the navigation slot (TASK-014).**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 AI day/week insight summaries grounded in local data, with the supporting data shown
- [ ] #2 Chat over local data + natural-language search of journal/history
- [ ] #3 Outputs cite underlying data; strictly observational, never medical advice
- [ ] #4 Honest disabled/empty state when AI is off or unconfigured
<!-- AC:END -->
