## 0.1.0

- Add target-unverified CT5 GATT and device-name classification constants.
- Add pure command framing, checksum validation, and reversible byte transform.
- Add strict parsers for synthetic CT5 history and passive packed records.
- Add caller-supplied communication-identity and set-ID framing helpers.
- Add Anytime 5P lifecycle metadata with an explicit no-driver boundary.
- Add the target-unverified V1150 BLE session driver with exact discovery and
  topology checks, notify-before-write flow, secure credential/journal
  interfaces, crash-safe activation recovery, immediate live ACKs, and private
  MTU-aware history synchronization.
- Gate public refresh/history calls on current-connection authentication and
  setup-date completion while preserving the internal setup history chain.
- Reject explicit history layouts that conflict with their response opcode,
  including ambiguous base-opcode payload lengths.
- Keep all transmitter glucose private until physical differential validation;
  pre-V1150 firmware and all unsafe administrative operations fail closed.
