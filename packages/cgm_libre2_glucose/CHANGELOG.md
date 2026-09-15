# Changelog

## Unreleased

- Add pure `decodeLibre2Gen1EncryptedNfcFram` and immutable trend/history output
  with sensor counters and origin, using factory evidence from the same verified
  NFC snapshot and its current patch seed.
- Preserve strict model, CRC, lifecycle, lifetime, quality and mathematical
  rejection; ambiguous history-ring timing fails closed. No dates, import,
  freshness claim, sensor I/O or production registration are added.
- Verify NFC conversion against all 1023 pinned synthetic Swift factory vectors
  while keeping the existing encrypted BLE API and arithmetic unchanged.

## 0.0.1

- Add an isolated GPL-3.0-only Gen1 factory decoder with encrypted, CRC-checked inputs.
- Add synthetic differential tests against pinned xdripswift formula/table behavior.
- Not device-conformant or clinically validated; no sensor I/O or production enablement.
