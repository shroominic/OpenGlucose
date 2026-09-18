# CBIO GS1 device evidence

A GS1 session used to leave nothing behind: the harnesses printed lines, the
app kept the last 250 log entries in memory, and the only durable record of a
hardware run was whatever a human had saved by hand. This lane turns one device
run into one reviewable artifact.

## Command

```sh
make cbio-gs1-evidence DEVICE_ID=<adb serial>
```

Optional:

- `HARNESS=<openhealth/integration_test/..._test.dart>` selects the harness
  (default: the authenticated session).
- `EVIDENCE_DIR=<dir>` selects the output directory
  (default: `../evidence` next to this repository).
- `CBIO_STREAM_SECONDS=<n>` bounds the post-read streaming window.
- `CBIO_EVIDENCE_LOG=<file>` re-records an artifact from an already captured
  device log instead of running a device. This is how an artifact is reproduced
  without hardware.

The command runs the assertion-bearing harness on the device, keeps the device
log, and writes one artifact into the evidence directory. It exits non-zero when
the harness fails, after writing the artifact, so a failed session still leaves
evidence and still fails loudly.

## Artifact

One file per run: `gs1-session-<utc>-<harness>.json`, plus an `INDEX.md` row.
The file is the harness's `CBIO-EVIDENCE` record, validated before it is
written:

| Key | Content |
|---|---|
| `schema` | `cbio.session-evidence/1` |
| `identity` | harness path, harness revision, app package, app revision, platform string |
| `outcome` | `completed`, `aborted_no_target`, `aborted_missing_characteristics`, `aborted_authentication_failed`, `failed` |
| `writes` | command frames actually sent, per classified kind |
| `records` | glucose and raw record counts, first/last index, raw value range |
| `notifications` | FF31 notifications observed |
| `startedAtUtc`, `endedAtUtc`, `durationMilliseconds` | bounded session timing |
| `errors` | counts per closed reason from a fixed vocabulary |
| `unitStatus` | always `unverified` |

The raw glucose field has no verified scale, so no artifact, log or document may
present it as a physical glucose value.

## Redaction

`cbioSessionEvidenceArtifactViolations` rejects an artifact that:

- is missing schema, identity, outcome, records, writes or errors;
- carries an outcome, write kind, or error reason outside the closed set;
- carries a record range or raw value outside the observed envelope;
- carries a non-monotonic clock or a duration that disagrees with it;
- claims a verified unit;
- contains a Bluetooth address in colon or dash form;
- contains a long hex run that could carry credential or vendor material.

The model itself has no field for a sensor address or credential bytes, and the
harness never logs the authentication plaintext, so a rejected artifact means a
new leak path was introduced, not a formatting accident.

## Safety envelope

The allowed writes for this lane are device information, authentication, one
clock set per session, glucose reads and raw history reads. The harness
classifies every frame before transmission and fails before sending anything
outside its allow-list, so activation, reset, threshold, calibration,
key-registration and firmware frames are unreachable from this lane.
