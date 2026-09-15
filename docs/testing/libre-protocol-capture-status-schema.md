# Libre protocol-capture status schema

`files/protocol-captures/capture-status.json` is an app-private readiness
record. It contains no raw BLE/NFC bytes or device identifiers. Schema version
2 binds readiness to one native capture, one Dart process, one installed build,
one BLE trace session, and one exact BLE segment file.

The Dart layer sends exactly these 13 fields to `setBleCaptureStatus`:

| Field | Type | Meaning |
| --- | --- | --- |
| `processSessionId` | string | Random filename-safe identity created before `startNfcCapture`; unchanged for this Dart process capture. |
| `bleTraceSessionId` | string | Current `LocalBleTraceSink` session token. |
| `bleTraceFileName` | string or null | Exact current `ble-<session>-<segment>.jsonl` file; null until the first durable write. |
| `scannerState` | enum string | `not_started`, `starting`, `running`, `suspended`, `stopped`, or `error`. |
| `scannerServiceUuids` | string array | Canonical lowercase 128-bit physical scan-filter representation. A running Libre capture is exactly `[FDE3]`. A running `yuwell_anytime_passive` capture is exactly `[]`, which means the Android debug scan is explicitly unfiltered. No other running list is accepted. |
| `sinkState` | enum string | `not_started`, `healthy`, `capacity_reached`, `write_error`, or `closed`. |
| `lastCommittedBleSequence` | positive integer or null | Recorder-owned sequence of the last event durably flushed to the exact BLE file. |
| `lastCommittedBleRecordedAtUtc` | UTC string or null | Recorder UTC time for that committed event. |
| `capacityReached` | boolean | True after the bounded BLE trace capacity is exhausted. |
| `sinkErrorCode` | safe string or null | Fixed non-sensitive error classification. Native exception text is never included. |
| `heartbeatAtUtc` | UTC string | Dart status time. |
| `heartbeatMonotonicMicroseconds` | positive integer | Process-relative progress token. Compare it only with an earlier value having the same `processSessionId`; it is not Android elapsed realtime. |
| `stopping` | boolean | True before scanner/sink/native teardown starts. |

The native bridge validates the exact key set and adds these authoritative
fields to the persisted JSON:

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Exactly `2`. |
| `nativeCaptureSessionId` | string | Native NFC/status session identity. |
| `processId` | positive integer | Android application PID. |
| `versionCode` | positive integer | Installed Android build version. |
| `lastUpdateTime` | positive integer | Installed-package update epoch milliseconds. |
| `nativeCaptureWritable` | boolean | Native trace/status storage remains writable. |
| `nfcTraceFileName` | string or null | Exact current native NFC JSONL file for this native capture session. |
| `activityResumed` | boolean | Activity is resumed at status commit. |
| `rfPointOfUseEligible` | boolean | Native point-of-use gate: scanner running, sink healthy, capacity available, not stopping, and activity resumed. |
| `statusCommittedAtUtc` | UTC string | Native durable-status commit time. |
| `statusCommittedAtElapsedRealtimeNanos` | positive integer | Android elapsed-realtime timestamp for host freshness checks. |

A healthy Dart status is written only after `recordCaptureHeartbeat()` appends
and flushes a new event through the same recorder and sink as BLE data. Thus
each healthy status has a strictly newer BLE sequence. The publisher serializes
the complete commit, snapshot, and native-write transaction. Its periodic
two-second timer runs while scanner state is `running` or `suspended`, the sink
is healthy, and capture is not stopping. State transitions, including
`suspended`, `error`, and `stopping`, are
also published and get a new committed sequence while the sink remains healthy.
`running` additionally requires an acknowledgement from the exact
FlutterBluePlus scan attempt after its awaited native `startScan` succeeds;
the process-global `isScanning` flag alone cannot establish readiness.

During an active BLE connection, `suspended` can be the expected scanner state.
An advancing, healthy, bound recorder can continue recording in this state
without NFC RF readiness. Do not resume scanning only to satisfy the NFC-ready
check. Recorder heartbeats prove recording progress, not receipt of sensor
notifications; verify live packets separately.

Readiness fails closed unless the persisted record is current, bound to the
installed build/PID/process/native sessions, has `rfPointOfUseEligible=true`,
names the exact current BLE trace file, and its BLE sequence and both freshness
clocks advance. A harness must collect only the named BLE session/file. It must
not select the numerically highest sequence across old `ble-*.jsonl` or
`nfc-*.jsonl` files because those independent sequences restart per session.

The profile wrapper binds its session to one of these exact scan modes. It
accepts the empty-list representation only for `yuwell_anytime_passive`; it
accepts `[FDE3]` only for the Libre profile. This prevents an omitted filter,
an additional filter, or a session from the other profile from becoming ready.
