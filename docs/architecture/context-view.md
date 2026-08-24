# Opt-in Context view evidence plan

## Status and default behaviour

The Context view is an optional local reader surface. It is off by default.
When it is off, the main glucose reader does not show a context control, a
recent-rise prompt, or context content. The context bridge publishes an idle
snapshot and does not query local context stores.

Turning the Context view on makes a separate, full-height route available from
the reader history area. It does not replace the glucose reader or reserve
space for people who only want glucose data.

## Local data and redaction boundary

The route reads the cached `ContextBridgeSnapshot`. It does not query a
repository, start an import, request permission, schedule background work,
call a remote service, or call an AI model.

Only after a person presses the bounded add action does the app-owned bridge
make a local revalidation read. It checks the current setting, policy, active
readings, newest candidate, and durable local claim immediately before its one
local transaction. A stale, changed, disabled, or already-claimed opportunity
does not save an entry.

The route shows only generic context categories, bounded time windows, and
approved display values. It must not display or expose source record IDs,
sensor identifiers, device metadata, raw packets, source-app details, or
private diary text outside the diary item itself. Heart-rate data is not in the
first visual lane.

## User controls and recent-rise policy

Settings are persisted only on the device:

- **Show Context view** is off by default.
- **Suggest context for a recent observed rise** is off by default.
- A user must enter a positive observed-rise threshold before the suggestion
  setting can be enabled.

The suggestion is one optional, non-clinical opportunity to add personal
context. It does not state or imply a cause. It is hidden when the bridge has
no qualified candidate. The fast-add flow accepts a user-selected time only in
the bridge-provided bounded range. If the selected time is outside that range,
the linked save is disabled and the entry is not attached to the candidate.
A successful attached save claims the local episode, so the same action does
not appear again for that episode.

## Product scope

The route provides a source-safe timeline, generic diary context, and a quiet
entry point for a user to add a meal or activity. It keeps the default glucose
reader simple. A new persisted diary-note kind is deferred until it has a
backwards-compatible local-protocol migration.

This work does not add Health Connect or Apple Health import controls,
background synchronization, image capture, meal recognition, local AI,
clinical insights, recommendations, notifications, cloud storage, export, or
automatic causal attribution.

## Deterministic automated evidence

The required automated evidence covers these cases:

1. The persisted settings default to off. Invalid or missing thresholds are
   normalized to keep recent-rise suggestions off.
2. The disabled context bridge performs no local context query. Enabling the
   setting permits a refresh.
3. Bridge-to-timeline mapping retains only generic categories and approved
   fields. It reports activity, sleep, and diary availability independently,
   excludes restricted identifiers, and omits heart rate from the first lane.
4. The final attachment preparation rejects stale readings, elapsed candidates,
   disabled policy, and prior claims. The controller rejects times outside the
   candidate range, does not write on cancellation or error, and prevents a
   second claim for one episode.
5. The settings, route, and attachment controls have semantic labels, meet a
   minimum 44 logical-pixel action height, and render at narrow width and large
   text scale without overlap or clipped critical controls.

The implementation must run the repository lint and focused Flutter tests
before review. Test fixtures use synthetic times, values, and generic source
categories only.

## Physical iPhone evidence plan — NOT RUN

This plan is required before release approval. It is not physical-device
evidence yet.

1. Install a signed build on a real iPhone with a local active-sensor session
   and locally available health context. Do not record or export personal
   health data during the check.
2. Confirm that a fresh install keeps Context view and recent-rise suggestion
   off, and that the glucose reader has no extra context prompt or reserved
   space.
3. Enable Context view, reopen the reader, and confirm that the separate route
   is reachable, scrolls correctly, and remains readable with larger system
   text.
4. Enable the suggestion only after entering a positive threshold. Confirm
   that a qualified candidate gives one non-causal action, while an
   unqualified or stale state gives none.
5. In the add flow, test an allowed time, an out-of-range adjusted time,
   cancellation, storage failure handling, and the post-save disappearance of
   the action. Confirm that no sensitive identifiers or raw diagnostic data
   appear in the UI.
6. Reopen the app after the check. Confirm that settings and a saved local
   diary item persist, the reader remains usable when context is turned off,
   and no import, permission, network, or background task begins as a result
   of using the route.

Record only the build identifier, iPhone model, iOS version, test result, and
redacted screenshots. Mark each case pass, fail, or not run. Do not attach
health values, diary text, sensor labels, identifiers, or diagnostic logs to
release evidence.
