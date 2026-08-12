---
id: TASK-001
title: Rename openhealth to openglucose across codebase
status: To Do
assignee: []
labels:
  - 'epic:core'
  - 'phase:1-foundation'
dependencies: []
priority: high
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The product is now OpenGlucose, but the app module directory is still `openhealth/` and several identifiers still use the legacy `openhealth` / `aidex_flutter` / `com.aidex.aidex_flutter` names. Do a clean, repo-wide rename so naming is consistent with the OpenGlucose brand.

Scope of the rename:
- App module directory `openhealth/` -> `openglucose/` (the Flutter reference app).
- Android `namespace` `com.aidex.aidex_flutter` and the Java package path `com/aidex/aidex_flutter` (MainActivity, GlucoseLiveUpdateService) -> a consistent `com.openglucose.app` package.
- Any lingering `aidex_flutter` references in `openhealth/README.md` (currently the default "A new Flutter project" template) and the iOS project where they do not refer to the Aidex *driver* (the `cgm_aidex` package and Aidex protocol stay named Aidex — that is the sensor vendor, not the app).
- Update workspace references, import paths, melos/pubspec workspace globs, CI paths, and docs that point at `openhealth/`.

Honesty/scope note: do NOT rename the `cgm_aidex` package or Aidex protocol symbols — "Aidex" is the real sensor vendor and must stay. This task only retires the legacy *app* name.

**Fleet: NOT parallelizable — run ALONE.** Touches nearly everything: `openhealth/` (entire dir, becomes `openglucose/`), `openhealth/android/app/build.gradle.kts`, `openhealth/android/app/src/main/java/com/aidex/aidex_flutter/*`, `openhealth/pubspec.yaml`, `openhealth/ios/Runner.xcodeproj/project.pbxproj`, root `pubspec.yaml`/workspace config, CI configs, and docs. Must be sequenced so no other branch is mid-flight in `openhealth/`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 App module directory renamed to `openglucose/` with all workspace/import/CI references updated
- [ ] #2 Android namespace and Java package renamed off `com.aidex.aidex_flutter` to a consistent `com.openglucose.*`; app builds and runs
- [ ] #3 No remaining `openhealth` or `aidex_flutter` app-name references (excluding the legitimate `cgm_aidex` driver package and Aidex protocol/vendor names)
- [ ] #4 `flutter build` (android + ios) and the existing test suite pass after the rename
- [ ] #5 README(s) and docs updated to the new module path
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Bundle id `com.openglucose.app` is already set in `build.gradle.kts` and iOS `PRODUCT_BUNDLE_IDENTIFIER`; the mismatch to fix is the Android `namespace`/Java package and the module directory name.
<!-- SECTION:NOTES:END -->
