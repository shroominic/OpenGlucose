# ADR 0004: Localize the app through a user-controlled language policy

- Status: Accepted
- Date: 2026-08-31
- Owners: `@shroominic`

## Context

OpenGlucose must be usable in English and Simplified Chinese without changing
sensor behavior, privacy controls, or health data. A device locale is a useful
first-run signal, but it is not always the user's preferred app language. The
main Flutter interface and Android notifications and iOS Live Activities must
also agree on the selected language.

## Decision

OpenGlucose supports English and Simplified Chinese through generated Flutter
localization catalogs. The persisted language preference has three values:

1. **System** is the default. A system locale whose language code is `zh` uses
   Simplified Chinese. All other locales use English.
2. **English** forces English.
3. **Simplified Chinese** forces Simplified Chinese.

The setting is local to the device and contains only the language preference.
It does not alter sensor state, Bluetooth pairing, glucose records, Health
data, exports, or any privacy preference. A manual selection overrides later
system-locale changes until the user selects System again.

The app passes a language code and semantic state to native live surfaces.
Native code must translate its own labels from the language code. It must use
semantic fields, such as `isWarmup`, rather than infer behavior from a
translated label. This keeps notifications and Live Activities consistent with
the app while preserving redaction and lifecycle behavior.

Only a Simplified Chinese catalog is currently shipped. Traditional Chinese and
other languages require their own reviewed catalog and a follow-up decision if
their locale-selection behavior differs.

## Alternatives considered

- **English only:** has no selection complexity, but excludes Chinese-language
  device users from the primary experience.
- **Follow the device locale with no override:** gives a simple first-run
  result, but prevents users from selecting their preferred app language.
- **Translate only Flutter screens:** leaves notifications and Live Activities
  inconsistent and makes native text depend on the device rather than the app
  preference.
- **Send translated native strings from Flutter:** couples native presentation
  to Flutter wording and encourages behavior decisions based on localized text.

## Consequences

- New user-visible copy must be added to both localization catalogs and
  reviewed for meaning, tone, and safety context.
- Widget, controller, and native payload tests must cover system selection,
  manual override persistence, and both language states.
- The system choice maps all `zh` locales to Simplified Chinese until a
  separate Traditional Chinese experience is approved.
- Native surfaces receive a small presentation contract but retain ownership of
  their platform-specific rendering.

## Follow-up controls

- Keep catalog-key parity checks and verify translated safety, privacy, and
  recovery messages during review.
- Capture English and Simplified Chinese simulator evidence before release.
- Review new languages for locale policy, native-surface coverage, and product
  terminology before adding them.
