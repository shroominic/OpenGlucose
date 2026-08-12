---
id: TASK-038
title: CI — analyze, test, and build pipeline
status: To Do
assignee: []
labels:
  - 'epic:dev-ex'
  - 'phase:1-foundation'
dependencies: []
priority: medium
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up continuous integration so the growing backlog lands safely: run `flutter analyze`, `dart format --set-exit-if-changed`, and the unit/widget test suites across the workspace packages (`cgm_core`, `cgm_ble`, `cgm_aidex`, `cgm_ble_flutter`, app) on every PR, plus a build check.

Includes:
- GitHub Actions workflow: analyze + format check + test for all packages + app, and a `flutter build` smoke (android, and ios where the runner allows).
- Sensible caching for pub/Gradle.
- Status required for merge.

**Fleet: parallelizable, low conflict. Touches `.github/workflows/` + maybe a melos/workspace config. Should land early so subsequent feature PRs are gated. Independent of app code.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 CI runs analyze + format check + tests for all packages and the app on PRs
- [ ] #2 Build smoke check (android; ios if feasible)
- [ ] #3 Caching configured; CI required for merge
<!-- AC:END -->
