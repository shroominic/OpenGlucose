---
id: TASK-030
title: Home widgets and richer lock-screen surfaces
status: To Do
assignee: []
labels:
  - 'epic:ux'
  - 'phase:3-polish'
dependencies:
  - TASK-008
priority: medium
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Quick-glance surfaces: home-screen widgets (iOS WidgetKit + Android App Widget) showing current glucose + trend, plus richer live activities / lock-screen surfaces. The app already has live-activity bridges (`ios_live_activity_bridge.dart`, `android_live_update_bridge.dart`, `live_activity_payload.dart`); extend them to widgets.

Includes:
- iOS home/lock-screen widget + Android home widget showing current reading, trend, last-sync.
- Reuse the existing live-activity payload pipeline as the data source.
- Sensible refresh/staleness behavior on the widget.

**Fleet: NOT fully parallelizable with live-activity work — touches `openhealth/lib/src/ios_live_activity_bridge.dart`, `android_live_update_bridge.dart`, `live_activity_payload.dart` and native widget targets (`openhealth/ios`, `openhealth/android`). Serialize with any task editing the live-activity payload. Depends on TASK-008 sensor state.**
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 iOS home/lock-screen widget + Android home widget showing current reading + trend + last-sync
- [ ] #2 Driven by the existing live-activity payload pipeline
- [ ] #3 Staleness/refresh handled on the widget
- [ ] #4 Verified rendering on both platforms
<!-- AC:END -->
