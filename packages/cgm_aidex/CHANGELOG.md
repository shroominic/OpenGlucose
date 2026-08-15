## Unreleased

- Defer history-range and catch-up requests while the sensor-reported elapsed
  time is still inside AiDEX's 60-minute warmup, preventing the expected lack
  of history from becoming a session-wide `StateError`. Deferred work resumes
  automatically at the warmup boundary, while genuine post-warmup protocol
  failures still become safe session errors.
- Establish the Android OS bond before subscribing to protected
  characteristics, refresh GATT before discovery for newly created or existing
  bonds, and retain only privacy-safe BLE failure metadata and closed setup
  phases. Initialization no longer removes a local bond automatically after an
  unclassified setup error.

## 1.0.0

- Initial version.
