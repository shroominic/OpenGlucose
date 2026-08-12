---
id: TASK-031
title: PDF report generation
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:3-polish'
dependencies:
  - TASK-012
priority: low
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Generate a shareable PDF report (date-range) summarizing glucose trends, key metrics (TASK-012), notable events, and charts — for personal review or to bring to a wellness conversation. Inspired by Nutrisense/Stelo/GS3 reports.

Includes:
- Date-range report with summary metrics, a trend chart, and event highlights.
- Share/save via platform sheet.
- Honest framing: a personal wellness summary, NOT a clinical/AGP medical report; include the standard wellness disclaimer.

**Fleet: parallelizable after TASK-012. Touches a new report-generation module (pure-Dart data assembly + a PDF lib) + a small export UI. Independent of UX-polish chart edits (renders its own chart). Coordinate format with TASK-022 if reusing assembly.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Date-range PDF with summary metrics, trend chart, and event highlights
- [ ] #2 Share/save via platform sheet
- [ ] #3 Includes wellness disclaimer; NOT framed as a clinical/AGP medical report
- [ ] #4 Generates correctly for empty and full date ranges
<!-- AC:END -->
