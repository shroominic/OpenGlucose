## Unreleased

- Add optional `BleSingleAttemptTransport` capability and preserve it through
  the recording wrapper without fallback or hidden retry. Add optional
  `BleScanResult.observedAt` for consumers that require a fresh advertisement.
  Existing transports and normal connection behavior remain compatible.
- Add identifier-free BLE failure categories, operations, retry policy, and
  metadata round-tripping for app-owned recovery presentation. This additive
  public API requires a minor version bump before independent publication.
- Add opt-in recording transport and connection decorators with a versioned,
  sensitive event schema for local protocol capture. Sink failures are isolated
  from BLE behavior. This additive public API requires a minor version bump
  before independent publication.
- Record scan cancellation and cancellation failure as terminal trace events.

## 1.0.0

- Initial version.
