---
id: TASK-039
title: Contributor docs and architecture overview
status: To Do
assignee: []
labels:
  - 'epic:docs'
  - 'phase:1-foundation'
dependencies: []
priority: medium
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Lower the barrier for contributors (human and AI) to the open-source app. Add a CONTRIBUTING guide and an architecture overview documenting the package split (`cgm_core` / `cgm_ble` / `cgm_aidex` / `cgm_ble_flutter` / app), the protocol-vs-UI boundary, the local-first/privacy principles, and how to add a new sensor driver or feature package.

Includes:
- `CONTRIBUTING.md`: setup, run, test, branch/commit conventions, the "extend shared packages first / keep analytics pure Dart / keep sensors modular" build rules from the inspiration roadmap.
- `docs/architecture.md`: package map + data flow (driver -> normalized readings/events -> local store -> analytics -> UI surfaces).
- Point to the backlog as the source of planned work.

**Fleet: parallelizable, docs-only. Touches `CONTRIBUTING.md` + `docs/`. Zero conflict with app code; can run anytime.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 CONTRIBUTING.md with setup/run/test + branch/commit + build-rule conventions
- [ ] #2 docs/architecture.md with package map and data-flow diagram/description
- [ ] #3 Guidance for adding a new sensor driver and a new feature package
- [ ] #4 Links the backlog as the source of planned work
<!-- AC:END -->
