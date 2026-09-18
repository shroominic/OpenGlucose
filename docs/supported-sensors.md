# Supported sensors

OpenGlucose 0.4.0 carries more than one sensor family in one codebase. This page
states what each family can do in a build of this release, and what is
explicitly provisional or unsupported. It is a product-status page, not a
compatibility certificate: [compatibility.md](compatibility.md) defines what a
compatibility claim must contain, and [product-safety.md](product-safety.md)
sets the boundary no surface crosses.

## What ships in 0.4.0

| Family | Driver | Availability in this release | Live readings | Stored history |
| --- | --- | --- | --- | --- |
| AiDEX / LinX | `aidex` | Every Android and iOS build | yes | yes |
| SIBIONICS / CBio GS1 | `cbio` | Only in a build that injects the vendor link material | provisional, raw | yes |
| FreeStyle Libre 2 (Gen1) | private receiver | Private Android debug capture builds only | private bench only | private capture |
| Yuwell Anytime 5P | private session | Private Android debug capture builds only | no | no |
| Sample data | `demo` | Simulator, web, and explicit demo builds | marked as sample | marked as sample |

AiDEX/LinX is the only family the published Android and iOS artifacts register
on their own. The GS1 driver is compiled into the app, but the link
authenticates and unmasks its replies with vendor material this repository does
not carry, so the platform registry leaves `cbio` out of any build that did not
supply it at build time (see
[packages/cgm_cbio/README.md](../packages/cgm_cbio/README.md)). The published
`openglucose-0.4.0+29.apk` is built without that material.

## GS1 (SIBIONICS / CBio)

- Discovery matches the `FF30` service and reports an unverified Cbio /
  SiSensing candidate. GS1 and GS3 share that UUID, so the match does not
  identify the exact model; name-only matches, characteristic-only matches, and
  empty device identifiers are rejected.
- A session authenticates the vendor link, sets the sensor clock once, reads
  live values, and ingests stored history under a bounded window with a
  resumable offset.
- Every value the GS1 path publishes is `raw / 10` behind the marker
  `Provisional reading. Sensor raw / 10, scale unverified.`, and
  `isUnitVerified` stays false. No GS1 surface publishes mg/dL or mmol/L.
- Writes are bounded to the device-information read, the `19 01`
  authentication frame, the one-time clock set, and the `06 0A` and `06 08`
  read queries. Activation, reset, thresholds, calibration, key-registration,
  and firmware frames are never built.
- Discovery cannot report an absent sensor from a scan that never ran. Android
  pauses unfiltered BLE scans while the display is off, so a declined pass is
  reported as an unavailable scan and the scan window holds the display through
  the app's own gate.

## Libre 2 and Yuwell Anytime

Both families are target-unverified offline work reachable only from private
Android debug capture builds. Neither is registered in the published artifact,
and neither is a production compatibility claim.

- FreeStyle Libre 2 (Gen1): an explicitly initiated NFC streaming exchange, a
  frozen receiver credential, encrypted receiver state, durable login counters,
  exact-target connection, CRC-validated packet diagnostics, and bounded
  history. A separately distributed GPL reference decoder can be injected in
  the private bench entry point to show provisional current samples. Normal
  builds import neither. Gen2 and Libre 3 are absent.
- Yuwell Anytime 5P: a bounded session that can scan, authenticate, initialize,
  acknowledge notifications, and synchronize records under a durable
  write-intent journal. The default driver policy publishes no glucose; the
  explicit debug composition can show the exact V1150 packed field as
  provisional engineering data. No vendor-native glucose algorithm is
  reproduced here.

## Not supported

- Any clinical or medical claim. OpenGlucose is wellness and
  self-experimentation software, not a medical device: no diagnosis, no
  medication or insulin dosing, no treatment decisions, and no emergency
  monitoring.
- Any non-AiDEX family in the published artifact.
- Factory trim, reset, shelf mode, threshold, calibration, and clear-storage
  commands on any family. No shipped driver builds them.
- GS3 support. The service UUID is shared with GS1 and the driver does not claim
  to distinguish the two.

## Where the evidence is

Each family's device-backed evidence, redaction rules, and open gaps are
recorded under [docs/testing/](testing/): `cbio-gs1-offline.md`,
`cbio-gs1-discoverability.md`, `cbio-gs1-auth-material.md`,
`cbio-gs1-reply-decode.md`, `cbio-gs1-glucose-live.md`, `cbio-gs1-app-live.md`,
and `cbio-gs1-evidence.md`, next to the Libre and Yuwell capture records.

Three things this release does not settle: the reference measurement that would
confirm the GS1 `/10` scale, which is the product owner's call; a device-backed
GS1 matrix across documented firmware and OS combinations; and the device half
of the screen-off discovery fix, whose bounded harness ships here while the
remaining run is tracked on its issue.
