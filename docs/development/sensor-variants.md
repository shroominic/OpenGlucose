# Sensor variants and evidence

Keep a sensor's observed model and version separate from its connection
identity, data meaning, and permitted operations. A product family can contain
different protocol branches. A familiar name, advertised UUID, or saved record
does not prove which branch is safe to use.

Use this guide with the [driver guide](sensor-driver-guide.md),
[protocol workflow](sensor-protocol-workflow.md), and
[compatibility policy](../compatibility.md). It describes current code and
evidence limits; it does not expand sensor support.

## The small shared contract

[`CgmSensorVariant`](../../packages/cgm_core/lib/src/sensor_variant.dart) is an
optional descriptive value in `CgmSessionInfo.sensorVariant`. A driver supplies
it after its own identification checks. The shared app can retain that value
in `ArchivedSensorSession.sensorVariant`. It is not an executable protocol
description or a support certificate.

| Field | Meaning and rule |
| --- | --- |
| `protocolFamily` | Required implementation family. It does not route a connection or select a decoder. |
| `source` | `unknown`, `deviceInformation`, or `nfcPatchInfo`. This records the information source, not authentication or compatibility. |
| `model` | Observed or strictly parsed model label. Keep the source boundary explicit. |
| `variantCode` | Reviewed, non-unique model discriminator, such as an accepted public patch signature. Never a serial, address, UID, or credential. |
| `region` | A supported interpretation of actual model evidence, when available. Never infer it from phone locale, seller location, product language, or a serial prefix. |
| `hardwareRevision`, `firmwareRevision`, `softwareRevision` | Separate opaque revision strings. Do not relabel one as another or assume semantic-version ordering. |
| `securityGeneration` | Protocol evidence from the owning driver. A common UUID or product name cannot establish it. |

Null means **unknown**, not "all variants supported." Keep unknown revision
strings as observed data; do not invent a firmware allowlist merely because a
new descriptor exists. Existing protocol-specific safety checks still apply.
Unknown or invalid serialized source names become `unknown`. The JSON reader
accepts only bounded, nonempty text without control characters for text fields.
Construction is not a trust boundary: drivers must still keep these fields
free of identifiers, raw packets, keys, and private diagnostic content.

There is one source for the descriptor, not a per-field evidence engine. Do
not combine unrelated claims and imply that all came from the same read.
Record richer investigation provenance in the evidence report and private case
index; do not add arbitrary captured data to this shared type.

## Current source-backed branch matrix

This is an implementation/evidence matrix, not a list of supported retail
models, countries, or firmware releases. See each linked source before changing
a gate.

| Branch | Evidence represented by current code | Boundary that remains |
| --- | --- | --- |
| AiDEX / LinX | The driver reads Device Information manufacturer, model, serial, and Software Revision. Its existing `firmware` field comes from `2A28`, named `softwareRevision` in the protocol constants. | Record that value as `softwareRevision` in the descriptor. Preserve the old `firmware` field for compatibility. True firmware revision, hardware revision, and region are not established by that read. There is no universal model/region support claim. |
| Libre 2 Gen1 | The strict six-byte patch parser accepts the public three-byte signatures `9d0830`, `c50930`, and `7f0e30` as `libre2`, with its existing Gen1 marker checks. | This is parsed reference evidence, not proof of retail compatibility or glucose accuracy. The private live path also requires its protected, journaled bootstrap and exact target checks. No country mapping is implemented. |
| Libre 2 Plus Gen1, offline parser only | The same parser accepts `c60931` and `7f0e31` as `libre2Plus`. | The live streaming bootstrap rejects this model. Parser acceptance is not live support, and the descriptor must not bypass that rejection. |
| Libre Gen2 / Libre 3 | The library distinguishes security generations and reference topologies. Gen1 and Gen2 share observed SAS UUIDs. | The Gen1 parser rejects non-Gen1/unknown branches; the separate offline topology and sequencing work does not provide Gen2 or Libre 3 production connections. |
| Private Yuwell Anytime | Exact CT5 candidate names lead to later topology/version checks. The live implementation has an explicit V1150 branch and a separate output-quality gate. | Do not treat the display name as a model/version proof. Published evidence records one non-V1150 physical version handshake that stopped there; later flows remain unverified for that target. A descriptive unknown revision must not remove the existing V1150 gate. |

Sources:

- AiDEX [identity reads](../../packages/cgm_aidex/lib/src/aidex_driver.dart),
  [UUID constants](../../packages/cgm_aidex/lib/src/aidex_protocol.dart), and
  [package contract](../../packages/cgm_aidex/README.md).
- Libre [patch parser](../../packages/cgm_libre2/lib/src/gen1_security.dart),
  [live bootstrap](../../packages/cgm_libre2/lib/src/gen1_live_driver.dart),
  [generation definitions](../../packages/cgm_libre2/lib/src/model.dart), and
  [topology boundary](../../packages/cgm_libre2/lib/src/topology.dart).
- Yuwell [driver](../../packages/cgm_yuwell_anytime/lib/src/driver.dart) and
  [evidence boundary](../../packages/cgm_yuwell_anytime/doc/evidence-boundary.md).

The Libre [evidence map](../../packages/cgm_libre2/doc/evidence-boundary.md)
links exact upstream files and pinned revisions; its
[third-party notices](../../packages/cgm_libre2/THIRD_PARTY_NOTICES.md) preserve
the source licenses. The Yuwell
[protocol report](../testing/yuwell-anytime-5p-protocol.md) separates reference
findings from physical observations. Preserve these distinctions when adding a
matrix row. A descriptor or a rewritten parser does not change source license
obligations; the optional glucose decoder has its own distribution boundary.

## Preserve identity, policy, and archives

- Keep `driverId` for routing, `deviceId` for the transport target, and
  `storageKey` for persistent sensor identity. The descriptor does not change
  `DiscoveredSensor`, selected-sensor JSON, history keys, receiver credentials,
  counters, or operation journals.
- A live identity refresh supplies `sensorVariant` again. This first slice
  does not persist an active variant in the selected-sensor record or invent
  one during restore. Absence must remain usable as unknown.
- Archives preserve the optional reported descriptor with the local session
  metadata. Old archives without it still load. An archive is historical
  evidence, not a fresh identity check or an instruction to reconnect.
- Keep profile lookup under the existing trusted driver registration and
  read-only compatibility catalog. Do not look up a decoder, timing policy, or
  activation policy by a free-form descriptor string from storage.
- Use observed `CgmSessionInfo` for current timing and capabilities for actual
  operations. `SensorConnectionPolicy`, explicit intent, exact-target checks,
  and durable unknown-outcome handling remain independent of variant data.

See the [session models](../../packages/cgm_core/lib/src/cgm_models.dart),
[data profile](../../packages/cgm_core/lib/src/sensor_data_profile.dart),
[archive schema](../../openhealth/lib/src/sensor_archive.dart), and
[connection policy](../../openhealth/lib/src/sensor_connection_policy.dart).

If a new variant needs different timestamp, duplicate, warmup, lifecycle, or
decoder semantics, stop before changing an existing archived identity's
meaning. Add a reviewed immutable profile/driver identity and an explicit
storage compatibility or migration plan. A future per-variant profile resolver
needs a concrete consumer, conservative unknown handling, and its own tests;
this descriptor is not that resolver.

## Evidence and tests for an additional variant

1. Record the exact observed discriminator and source, reference commit/files,
   model/version/platform, operations tested, and unresolved region or revision
   fields. Use synthetic fixtures, not a real sensor dump.
2. Test missing optional fields and old saved records. Round-trip the descriptor
   and archive; preserve unknown revision strings. Test malformed text and
   unknown source values without promoting them to trusted evidence.
3. Test `CgmSessionInfo.copyWith` retention and explicit driver identity refresh.
   Test archive restoration with the live driver unavailable. Verify that
   legacy model/firmware display fields and reading metadata remain unchanged.
4. For AiDEX, prove `softwareRevision` comes from the existing `2A28` read, with
   no new identity command and no fabricated hardware/firmware/region fields.
5. For Libre, cover all accepted parser signatures, unsupported signatures and
   security branches, and the continued live rejection of Plus. Never select
   security generation from topology alone.
6. Prove descriptor changes alone do not alter scan routing, connection policy,
   data profiles, capabilities, decoder selection, history identity, or command
   counts. Test unknown and misleading descriptor values as inert data.
7. Run affected package/app tests, analysis, formatting, and release gates.
   Add a redacted physical support-matrix result before claiming a new exact
   model/firmware/platform combination works. Compilation is not that result.
