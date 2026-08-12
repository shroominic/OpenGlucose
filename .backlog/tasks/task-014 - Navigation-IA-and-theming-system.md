---
id: TASK-014
title: Navigation, IA, and theming system
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:2-build'
dependencies: []
priority: medium
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Establish the app's information architecture and a consistent theme as the product grows beyond a single dashboard. Define top-level navigation (e.g. Home / Trends / Journal / Sensor / Settings) and a shared theme (colors, typography, spacing, light/dark, brand accent) so all new surfaces are consistent.

Includes:
- Navigation shell (bottom nav or equivalent) and routing.
- Centralized `ThemeData` (light + dark), reusable design tokens, and shared component styles.
- Consolidate `display_preferences.dart` into the theme/settings surface.

**Fleet: NOT parallelizable with other UX tasks — it defines the shared nav shell and theme that TASK-010/011/013/015 all consume. SERIALIZE: land this (or at least the nav+theme scaffolding) FIRST among the UX-polish cluster, then the others build on it. Touches a new theme module + the app's root navigation in `openhealth/lib`.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Top-level navigation shell + routing defined
- [ ] #2 Centralized light/dark theme with design tokens and shared component styles
- [ ] #3 Display preferences consolidated into the theming/settings surface
- [ ] #4 Existing screens migrated to the shared theme without regressions
<!-- AC:END -->
