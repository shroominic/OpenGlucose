---
id: TASK-023
title: Backup — import/export bundles
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:3-polish'
dependencies:
  - TASK-022
priority: medium
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full app backup and restore: a single bundle containing settings, events, imported signals, and reading history — so users can move devices or keep their own backups, with no cloud lock-in. Extends the export schema (TASK-022) into a complete, re-importable bundle.

Includes:
- Export a complete bundle (versioned) and import/restore it, with conflict handling (merge vs replace) and dedup.
- Validation + clear errors on malformed/incompatible bundles.

**Fleet: parallelizable after TASK-022. Touches the export/import module + local store write path. Coordinate the bundle schema with TASK-022 so export and import stay in lockstep.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Export a versioned bundle (settings + events + signals + history) and import/restore it
- [ ] #2 Conflict handling (merge/replace) + dedup on import
- [ ] #3 Validation + clear errors for malformed/incompatible bundles
- [ ] #4 Round-trip test: export then import reproduces state
<!-- AC:END -->
