---
id: TASK-002
title: Normalized event and health-data domain models
status: To Do
assignee: []
labels:
  - 'epic:health-data'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Foundation data layer for everything beyond raw glucose. Add vendor-agnostic, pure-Dart domain models for user-logged events and imported health signals, living in the reusable packages (e.g. `packages/cgm_core` or a new `packages/health_core`) — NOT in Flutter UI code, per the workspace's protocol/UI separation.

Models to define:
- `HealthEvent` base with typed variants: meal, exercise/workout, sleep, medication/supplement, note, mood/energy, stress, illness, fasting, caffeine, alcohol.
- Each event carries: timestamp(s) (point or interval), free-text note, tags, and optional structured payload (e.g. carbs/protein/fat for meals; duration/intensity/HR for workouts; quality/stages for sleep).
- Imported health-signal models: activity/steps, workouts, sleep sessions, heart rate samples, calories — normalized so they are source-agnostic (HealthKit vs Health Connect vs manual).
- Stable ids, source provenance (manual / healthkit / health-connect / derived), and serialization (JSON) for local persistence and export.

This is the schema that journaling, analytics, chart overlays, imports, AI, and export all build on. Keep it pure Dart and well-tested.

**Fleet: parallelizable (foundation, blocks many). Touches `packages/cgm_core` (or new `packages/health_core`) models + tests only — no app UI. Should land EARLY; downstream tasks (journaling, analytics, imports, AI, export) depend on it.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pure-Dart `HealthEvent` model with all listed variants and a normalized imported-signal model set
- [ ] #2 Source provenance + stable ids + JSON (de)serialization round-trip covered by tests
- [ ] #3 Models live in a reusable package, not in `openhealth/lib`, and have no Flutter dependency
- [ ] #4 Unit tests for serialization and variant construction pass
<!-- AC:END -->
