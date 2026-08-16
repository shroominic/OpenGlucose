## Unreleased

- Add the standard Bond Management Service transfer procedure behind the
  public confirmed-transfer contract. It validates the advertised feature,
  issues one write-with-response, disconnects, then removes and verifies the
  local operating-system bond without using the unsafe-admin API.
- Subscribe only to the two pre-authentication AiDEX channels before the
  vendor handshake, then enable the remaining channels after authentication.
  A notification timeout or disconnect gets one bounded fresh-GATT recovery
  with full listener cleanup, bond verification, fresh discovery, and
  connection-scoped reauthentication. The recovery never removes a bond,
  resets a sensor, or repeats sensor activation.
- Defer history-range and catch-up requests while the sensor-reported elapsed
  time is still inside AiDEX's 60-minute warmup, preventing the expected lack
  of history from becoming a session-wide `StateError`. Deferred work resumes
  automatically at the warmup boundary, while genuine post-warmup protocol
  failures still become safe session errors.
- Discover the GATT table before starting Android bonding, refresh GATT and
  rediscover when setup creates a new bond, and keep an existing healthy bond
  on its initial connection. A typed discovery timeout or disconnect gets one
  bounded fresh-GATT retry after the failed operation finishes, without
  removing the bond or repeating sensor activation. Exhausting that recovery
  stops automatic session retries. Timing profiles can override the recovery
  close gap and post-connect settle for deterministic tests. A safe pre-bond
  sensor-state read now distinguishes a sensor-side pairing that Android no
  longer retains, without changing either side automatically.
- Tear down a failed setup link after preserving its structured error, so a
  later user retry starts with a fresh GATT client instead of an occupied
  connection. Cleanup never removes the Android bond or closes session data
  controllers.
- Retain only privacy-safe BLE failure metadata and closed setup phases.
  Initialization no longer removes a local bond automatically after an
  unclassified setup error.

## 1.0.0

- Initial version.
