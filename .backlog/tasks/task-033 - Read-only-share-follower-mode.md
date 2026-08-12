---
id: TASK-033
title: Read-only share / follower mode
status: To Do
assignee: []
labels:
  - 'epic:integrations'
  - 'phase:3-polish'
dependencies:
  - TASK-008
priority: low
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Let a user share their current glucose + recent trend read-only with chosen people, in a privacy-respecting, local-first-friendly way. Inspired by GlucoSense/Stelo/GS3 follower flows — but the open, minimal version.

Approach (record an ADR): prefer mechanisms that avoid a heavy cloud backend where possible — e.g. user-controlled share links, optional self-hosted relay, or push to an existing channel (e.g. a webhook/Nightscout-style endpoint). Avoid mandatory account linking.

Includes:
- Generate a read-only share of current reading + recent trend.
- Explicit, revocable consent; clear data-leaves-device disclosure.
- Honest non-medical framing (this is wellness sharing, not remote medical monitoring).

**Fleet: parallelizable after TASK-008, but introduces the first potential backend/relay — likely needs an ADR and possibly an `ops`/relay component. Touches a new share module in `openhealth/lib`. Keep cloud surface minimal per local-first principle. Largely independent of UI-polish work.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Read-only share of current reading + recent trend with revocable consent
- [ ] #2 Mechanism chosen via ADR favoring minimal/no mandatory cloud backend
- [ ] #3 Clear data-leaves-device disclosure; non-medical wellness framing
- [ ] #4 No mandatory account linking for the basic share
<!-- AC:END -->
