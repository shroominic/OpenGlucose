---
id: TASK-026
title: Voice capture for fast logging
status: To Do
assignee: []
labels:
  - 'epic:ai'
  - 'phase:3-polish'
dependencies:
  - TASK-010
  - TASK-020
priority: low
ordinal: 26000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fast meal/note logging by voice: speak an entry ("oatmeal and coffee, about 40g carbs") and get a structured draft event the user confirms. Optional, AI-assisted, privacy-respecting.

Includes:
- Speech-to-text capture (prefer on-device STT where available).
- Structured extraction (meal type, carbs/macros, tags) via the AI foundation (TASK-020), producing a DRAFT the user reviews before saving.
- Graceful fallback to plain transcription -> note when extraction is unavailable or AI is off.

**Fleet: parallelizable after TASK-010 + TASK-020. Touches a voice-input widget in the journal + the AI context/extraction path. Independent of other UX work.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Voice capture -> transcript (on-device STT preferred)
- [ ] #2 AI extraction into a structured DRAFT event the user confirms before saving
- [ ] #3 Fallback to transcript-as-note when AI is off/unavailable
- [ ] #4 Mic permission handled; works offline for transcription where the platform supports it
<!-- AC:END -->
