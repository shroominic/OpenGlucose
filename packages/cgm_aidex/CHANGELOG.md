## Unreleased

- Defer history-range and catch-up requests while the sensor-reported elapsed
  time is still inside AiDEX's 60-minute warmup, preventing the expected lack
  of history from becoming a session-wide `StateError`. Deferred work resumes
  automatically at the warmup boundary, while genuine post-warmup protocol
  failures still become safe session errors.
- Establish the Android OS bond before service discovery, refresh GATT when
  setup creates a new bond, and keep an existing healthy bond on its initial
  connection. A typed discovery timeout or disconnect now gets one bounded
  fresh-GATT retry after the failed operation finishes, without removing the
  bond or repeating sensor activation. Exhausting that recovery stops
  automatic session retries. Timing profiles can override the recovery close
  gap and post-connect settle for deterministic tests.
- Retain only privacy-safe BLE failure metadata and closed setup phases.
  Initialization no longer removes a local bond automatically after an
  unclassified setup error.

## 1.0.0

- Initial version.
