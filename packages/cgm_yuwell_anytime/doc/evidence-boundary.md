# Evidence boundary

This package is a clean-room interoperability core. Its protocol facts are
independently expressed as small constants, field layouts, arithmetic, and
state-free encoders. No vendor code, binary, private capture, real sensor
identifier, communication identity, or health record belongs in this package.

The repository-level source and confidence table is
[`docs/testing/yuwell-anytime-5p-protocol.md`](../../../docs/testing/yuwell-anytime-5p-protocol.md).
The verified Yuwell APK is reference evidence only. It is not a dependency,
fixture, redistribution asset, or physical-device compatibility result.

## Evidence status

- GATT UUIDs, candidate names, frame shapes, checksums, transforms, and record
  layouts are reference-verified. As of 2026-09-09, discovery, GATT topology,
  and the version handshake are additionally target-confirmed on one physical
  Anytime 5P over macOS BLE — that session's firmware branch was not
  `V1150`, so it stopped there by design. See "First physical observation"
  in [`docs/testing/yuwell-anytime-5p-protocol.md`](../../../docs/testing/yuwell-anytime-5p-protocol.md)
  for the full, sanitized account. Everything past the version handshake
  remains target-unverified.
- The CT5 calibration-code decoder is a clean-room expression of three strict
  fixed-width layouts and decimal field formulas. It does not require or embed
  the reference app's native library.
- The internal CT5 selector-11 temperature-state research primitive reproduces
  only the independently reviewed reachable clamp and binary32 recurrence. It
  is not wired into the driver and does not implement sample admission,
  effective-temperature selection, compensation, smoothing, quality, trend,
  warnings, glucose, or support for another firmware branch.
- The native algorithm's input, output, reset, and contiguous-index contract is
  documented, but its final stateful glucose mathematics is not implemented.
  This package must fail closed when no independently validated final-value
  provider is available.
- The V1150 comparison model accepts sanitized same-index transmitter and
  official-native values and reports gaps, conflicts, reconnect epochs, and
  history/live overlap. It does not collect evidence, call vendor code, or
  authorize publication of the transmitter value.
- The 45-minute warmup, 16-day wear period, and 3-minute interval are model
  metadata. They are not proof of observed sensor state.
- Unit tests use synthetic values only and prove deterministic local behavior,
  not compatibility with a retail device or firmware version.
- The live session state machine is implemented from reference evidence, but
  its default output policy publishes no glucose reading. It requires injected
  secure persistence, explicit activation authorization, exact topology, and
  the V1150 branch. A separate, explicit engineering policy can expose only a
  fail-closed provisional packed value in a private debug build; that does not
  satisfy the production-promotion gate.
- Unknown state-changing write outcomes remain durable. Recovery uses read-only
  protocol checks or an atomic same-identity journal replacement; it does not
  automatically reset, unbind, calibrate, update, or clear an OS bond.

## Promotion gate

The driver is not a hardware-compatibility or production-readiness claim.
Before it can be promoted as usable sensor support or publish glucose, record
the exact model, firmware, platform, GATT topology, passive notifications,
state transitions, official paired readings, and failure behavior with
redacted physical-device evidence. Final-value promotion requires a contiguous
same-index differential series that passes the reviewed validation gate.
