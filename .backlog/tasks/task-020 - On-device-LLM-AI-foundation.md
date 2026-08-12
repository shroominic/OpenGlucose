---
id: TASK-020
title: Local/on-device LLM AI foundation
status: To Do
assignee: []
labels:
  - 'epic:ai'
  - 'phase:2-build'
dependencies:
  - TASK-002
  - TASK-003
priority: medium
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Privacy-first AI foundation: an abstraction that lets optional AI features run against the user's LOCAL data without sending raw health data to third parties by default. The app must stay fully useful with AI disabled.

Includes:
- A pluggable LLM provider interface with at least two backends: (a) on-device model (e.g. a small local model where feasible), and (b) bring-your-own-key to a user-chosen API endpoint, configured explicitly by the user.
- A context-builder that assembles relevant local data (recent readings, events, metrics from TASK-012) into prompts, with strict control over what is shared and an explicit consent/disclosure when a remote BYO-key endpoint is used.
- Privacy guarantees: no AI calls without user opt-in; remote calls only to the user's configured endpoint; clear surfacing of what leaves the device.
- Guardrail layer: outputs are framed as "patterns/observations", must avoid medical/treatment advice, and should be able to reference the data they're based on.

**Fleet: parallelizable after TASK-002 + TASK-003. Touches a new `packages/ai` (provider interface, context builder, guardrails) + settings UI for provider/key config. Record an ADR for the AI provider strategy. TASK-021/024/025 depend on this interface — keep it stable before they start.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pluggable provider interface with on-device and BYO-key backends
- [ ] #2 Context builder assembles local data with explicit control over what is shared
- [ ] #3 No AI calls without opt-in; remote only to user's endpoint; clear data-leaves-device disclosure
- [ ] #4 Guardrails enforce "patterns/observations" framing, not medical advice
- [ ] #5 App remains fully functional with AI disabled; ADR recorded
<!-- AC:END -->
