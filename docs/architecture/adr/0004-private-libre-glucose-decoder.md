# ADR 0004: Isolate the optional Libre glucose decoder

- Status: Accepted for private Android bench work; distribution is not approved
- Date: 2026-09-05
- Owner: `@shroominic`
- Risk: R2 implementation; external distribution retains the R3 gate

## Context

The MIT LibreTools reference establishes Gen1 decryption and raw fields, not
factory-calibrated glucose. A bounded review found no verified permissive
converter. The maintainer explicitly approved the GPL route if necessary while
preferring MIT. The bench sensor is expired and applied to fruit; this work
cannot establish wearable glucose accuracy.

## Decision

Keep the existing MIT crypto/transport package free of GPL implementation
inputs. Put the GPL-derived factory conversion and its exact upstream notices,
license, pinned provenance, and synthetic tests in `cgm_libre2_glucose`.
The MIT live driver accepts an optional decoder contract. The app supplies the
GPL implementation only from a separate, guarded full-UI Android debug entry
point. Normal `lib/main.dart` does not import the GPL adapter.

This separation preserves source attribution and allows removal. It is **not**
a license exception: a distributed combined executable that includes the GPL
decoder must satisfy the applicable GPL terms for the combination, even when
the components live in separate packages. Existing MIT source notices remain.
See the [GNU license FAQ](https://www.gnu.org/licenses/gpl-faq.html.en#WhatDoesCompatMean)
and [license compatibility explanation](https://www.gnu.org/licenses/license-compatibility.en.html).

Calibration must come from exact-length, CRC-verified FRAM bound to the current
protected receiver UID and initial patch information. No guessed coefficients,
cross-sensor fixture, raw ADC conversion shortcut, or host artifact discovery
is permitted. Missing evidence suppresses glucose, not a healthy BLE stream.
Decoded packets need independent CRC, age, quality, temperature, and finite
math checks. Provisional bench output must not be presented as validated
clinical glucose or silently exported as such.

## Alternatives

- Continue MIT-only raw packet capture: preserves current license simplicity
  but does not supply calibrated glucose.
- Guess conversion from raw values: rejected for data correctness.
- Treat DiaBLE's repository-level MIT label as covering all inherited factory
  conversion: rejected; per-file lineage is required.
- Relicense all source without reviewing rights and dependencies: rejected.

## Consequences and release gates

Before sharing an APK, TestFlight build, or combined source distribution:

1. Review the exact compiled/resolved graph, all notices, reciprocal license
   terms, and intended platform/store distribution conditions.
2. Supply corresponding source, modifications, build instructions, and any
   required installation information under the applicable terms. Do not call
   the combined decoder build MIT-only.
3. Complete independent decoder review and exact-model conformance evidence;
   synthetic differential tests alone are insufficient.
4. Verify normal release entry-point exclusion or approve an explicitly
   compliant decoder-enabled release. A runtime flag alone is not proof of
   exclusion from an artifact.

No journal, NFC activation, streaming-enable result, or login counter is rolled
back when removing the decoder. It performs no network, storage, or device I/O.
