---
id: TASK-027
title: Camera-assisted meal capture
status: To Do
assignee: []
labels:
  - 'epic:ai'
  - 'phase:3-polish'
dependencies:
  - TASK-024
  - TASK-020
priority: low
ordinal: 27000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Photo-based meal logging: snap a meal photo and get suggested components and rough macros as a DRAFT entry the user edits/confirms. Inspired by Ultrahuman/Vively/GlucoSense AI meal capture. Optional and AI-gated.

Includes:
- Camera/photo-picker capture; store the photo as an optional event attachment.
- Vision-assisted suggestion of meal components + estimated macros via the AI foundation (TASK-020), always as an editable draft.
- Clear "estimates only" framing; nothing auto-saved.

**Fleet: parallelizable after TASK-024 + TASK-020. Touches camera capture + meal draft UI + AI vision path. Coordinate with TASK-024 (meal entry) on the draft/edit surface.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Capture a meal photo (camera/library), stored as an optional attachment
- [ ] #2 AI suggests components + estimated macros as an editable draft
- [ ] #3 "Estimates only" framing; user confirms before saving
- [ ] #4 Camera permission handled; degrades gracefully when AI is off
<!-- AC:END -->
