---
id: TASK-018
title: Android Health Connect — import activity, sleep, heart rate
status: To Do
assignee: []
labels:
  - 'epic:integrations'
  - 'phase:2-build'
dependencies:
  - TASK-002
priority: medium
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Android parity for TASK-017: read activity (steps/exercise sessions), sleep, heart rate, and active calories FROM Android Health Connect into the normalized health-signal models (TASK-002).

Includes:
- Health Connect permissions + availability/install handling (Health Connect may need to be installed on older Android).
- Map Health Connect records -> normalized signals (provenance = health-connect); dedup by record id.
- Manual sync + periodic refresh; persist via TASK-003.
- Per-type import toggles in settings, sharing the same UI as the HealthKit importer.

**Fleet: parallelizable after TASK-002. Android-only; touches `openhealth/android` (Health Connect permissions/manifest) + import bridge in `openhealth/lib`. Parity with TASK-017 — reuse the shared normalized mapping/import-settings layer so iOS and Android stay identical.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Health Connect permission + availability/install flow handled
- [ ] #2 Import for steps/exercise, sleep, heart rate, active energy mapped to normalized signals (provenance=health-connect), deduped
- [ ] #3 Manual sync + periodic refresh; persisted locally
- [ ] #4 Shared import-settings UI with the HealthKit importer; identical normalized output
<!-- AC:END -->
