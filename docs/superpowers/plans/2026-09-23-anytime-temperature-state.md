# Anytime Temperature State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the independently reviewed CT5 selector-11 temperature-state recurrence as a pure internal research primitive without changing sensor admission or glucose output.

**Architecture:** Keep the state machine under `cgm_yuwell_anytime/lib/src` and test it through a direct `src` import so it does not become public API. The class accepts finite IEEE-754 binary32 words, owns only reachable temperature state, and exposes reset/advance results as exact words. It is deliberately not wired into the session driver.

**Tech Stack:** Dart 3.11.4, `dart:typed_data`, package:test.

**Spec:** `/private/tmp/anytime-temperature-dart-spec.CX8neS/BRIEF.md` and accepted review `/private/tmp/anytime-temperature-dart-spec.CX8neS/REVIEW_RECEIPT.md`.

## Global Constraints

- R2 sensor-algorithm research change; independent review is required before commit.
- Do not export the primitive from `cgm_yuwell_anytime.dart`.
- Do not modify `driver.dart`, firmware gates, transport, persistence, or reading publication.
- Do not add vendor binaries, private records, identifiers, or health data.
- Do not describe this stage as a glucose decoder or physical compatibility result.

---

### Task 1: Internal temperature-state recurrence

**Files:**
- Create: `packages/cgm_yuwell_anytime/lib/src/temperature_state.dart`
- Create: `packages/cgm_yuwell_anytime/test/temperature_state_test.dart`
- Modify: `packages/cgm_yuwell_anytime/doc/evidence-boundary.md`

**Interfaces:**
- Consumes: unsigned 32-bit words encoding finite binary32 temperatures.
- Produces: internal `YuwellCt5TemperatureState.reset()` and `.advance(int temperatureBits)` methods returning exact state words.

- [ ] **Step 1: Write the failing tests**

  Add literal tests for all 24 reviewed observations, the `0x41fe8fff` separate-rounding discriminator, clamping, reset and instance independence, and rejection of out-of-range/NaN/infinity inputs without state mutation. Import the absent implementation directly from `package:cgm_yuwell_anytime/src/temperature_state.dart`.

- [ ] **Step 2: Run the focused test to verify RED**

  Run: `/Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart test test/temperature_state_test.dart --reporter expanded`

  Expected: failure because `lib/src/temperature_state.dart` does not exist.

- [ ] **Step 3: Implement the minimal state machine**

  Create `YuwellCt5TemperatureState` with nullable internal state. Validate the input word before mutation, decode with big-endian `ByteData`, clamp to `[12.0, 48.0]`, and separately round `0.75 * previous`, `0.25 * clamped`, and their sum through binary32. `reset()` clears state and returns positive zero.

- [ ] **Step 4: Run the focused test to verify GREEN**

  Run the focused test command from Step 2 and require every assertion to pass.

- [ ] **Step 5: Document the boundary**

  Add one evidence-boundary bullet stating that the internal primitive reproduces only the reviewed reachable temperature recurrence; admission, effective-temperature selection, compensation, smoothing, quality, trend, warning, glucose, firmware support, and driver wiring remain excluded.

- [ ] **Step 6: Verify the package**

  Run from `packages/cgm_yuwell_anytime`:

  ```sh
  /Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart format --output=none --set-exit-if-changed lib test
  /Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart analyze --fatal-infos
  /Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart test
  ```

  Require formatting and analysis success plus the full package suite passing.

- [ ] **Step 7: Obtain independent review**

  Provide the three changed package files, this plan, RED output, and exact GREEN/format/analyze/full-test results to the independent reviewer. Do not commit until blocking findings are resolved.
