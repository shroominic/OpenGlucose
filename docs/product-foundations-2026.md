# OpenGlucose product foundations

- Status: Active implementation plan
- Updated: 2026-08-13
- Scope: sensor truth, archive, Settings, contextual health data, and optional AI

## Product contract

OpenGlucose must never imply that cached, sample, or imported data is a live
sensor reading. Every glucose surface has a visible provenance and one of these
states:

1. **No sensor, no history:** connect a sensor or open the clearly labelled,
   read-only sample dashboard.
2. **No active sensor, history retained:** show historical glucose and ask the
   user to connect a new sensor.
3. **Connecting or reconnecting:** cached history may remain visible, but the
   status is never `Connected` and connection errors remain visible.
4. **Live:** `Connected` requires a ready driver session and a fresh,
   timestamped reading.
5. **Expired or stopped:** archive once, stop reconnecting and background
   surfaces, clear the active sensor, retain every reading, and prompt for a new
   sensor.
6. **Sample:** keep a persistent `SAMPLE DATA — NOT FROM A SENSOR` banner and
   prohibit BLE, persistence, HealthKit, notifications, Live Activities, and
   mixing with personal history.

Derived analytics must independently qualify the selected time window. A
non-empty list is not evidence of a pattern. Every result should carry reading
count, active days, observed span, and later cadence coverage and largest gap.

## Settings information architecture

Settings is a full pushed page with inset grouped sections, available in every
sensor state:

```text
Settings
├── Sensor
│   ├── Current sensor / Connect a sensor
│   └── Sensor archive
├── Preferences
│   └── Glucose & display
├── Data & integrations
│   ├── Apple Health
│   ├── AI & models
│   └── Privacy & data
├── App
│   └── About OpenGlucose
└── Advanced (debug/demo or explicit future unlock)
    ├── Diagnostics
    ├── Calibration internals
    └── Mock scenarios
```

Custom cloud AI configuration is nested inside `AI & models` under an
`Advanced` disclosure. On-device models are the intended normal AI path.

## Durable sensor archive

The first corrective tranche uses durable, session-keyed, backup-excluded
history snapshots plus an archive manifest. Its session identity combines
driver, hardware storage key, and inferred/confirmed session start so repeated
hardware keys cannot overwrite older sessions.

The production persistence milestone is SQLite schema v2:

```text
sensor_sessions
  id, driver_id, hardware_key, serial, model, firmware,
  started_at, ended_at, end_reason, origin, archived_at

cgm_readings
  session_id, recorded_at, sensor_minute, value_mgdl, source,
  qualifier, raw_value
  UNIQUE(session_id, recorded_at, sensor_minute, source)

active_sensor_session
  singleton_id, session_id
```

Migration copies and verifies every legacy `openHealth.history.*` blob inside
one transaction before removing it. Archive deletion remains distinct from
disconnect or replace.

## Apple Health import and overlays

The current integration exports glucose only. Import must not ship until the
schema retains HealthKit UUID, source bundle/name, device, recording method,
interval, and deletion state with unique constraints; the current methods named
`upsert` are append-only and would duplicate repeated imports.

Initial read categories:

- sleep intervals and stages;
- workouts, active energy, exercise time, steps, and walking/running distance;
- heart rate, then resting heart rate, HRV, respiratory rate, and oxygen;
- historical blood glucose, excluding OpenGlucose's own exported source.

Sleep and workouts render as source-attributed background intervals behind the
glucose line. Imported raw samples remain separate; display normalization uses
per-type source priority so overlapping Apple Watch, Whoop, Oura, and iPhone
records are not blindly summed.

MVP can bounded-requery with the existing Flutter `health` package and upsert by
HealthKit UUID. Production incremental sync uses native
`HKAnchoredObjectQuery`, one persisted anchor per type, and handles deleted
objects. Permissions are progressive and requested only when the user enables
an overlay. iOS can make denied and empty reads indistinguishable, so the UI
reports `No accessible data` rather than claiming a permission outcome.

References:

- [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [HKAnchoredObjectQuery](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)
- [Flutter health package](https://pub.dev/packages/health)

## On-device AI and model catalog

Implement local inference behind the existing `AiProvider` seam. The first
physical-iPhone spike targets a pinned `llama_cpp_dart` release and matching,
checksummed llama.cpp XCFramework. This requires a reviewed Flutter upgrade
because current package main requires a newer Flutter toolchain than this
repository.

The initial runtime profile is deliberately conservative:

- 0.5–1.5B instruct GGUF;
- `Q4_K_M` weights, 2K context, compact KV cache;
- one loaded session and 256–512 maximum output tokens;
- unload on memory warning/background and stop at serious thermal state.

Compatibility uses live device signals—physical/available memory, Metal
working-set recommendation, disk, thermal state, and Low Power Mode—not a
hard-coded iPhone model table. Acceptance tests measure load time, first-token
latency, tokens/second, resident/Metal memory, thermals, battery, repeated
load/unload, background/resume, BLE coexistence, and jetsam logs.

The Hugging Face explorer begins as a curated catalog rather than an arbitrary
search surface. Each entry pins repository, immutable revision SHA, GGUF file,
LFS SHA-256, architecture, quantization, context, license URL, validated device
tiers, and benchmark evidence. Downloads use a temporary file, free-space
preflight, hash verification, atomic move, and backup exclusion.

References:

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [llama_cpp_dart](https://github.com/netdur/llama_cpp_dart)
- [Hugging Face Hub API](https://huggingface.co/docs/hub/en/api)
- [GGUF on the Hub](https://huggingface.co/docs/hub/gguf)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Long-term evaluation

Do not invent a `bio-age`. The available observations do not validate an age
estimate, and an opaque health score would contradict the product's
explainability contract. Build a **Long-term glucose profile** instead:

- total and recent usable coverage with provenance;
- rolling average, variability, and range exposure;
- recent versus prior qualified periods;
- sleep/wake and workout-correlated observations;
- transparent metric definitions and missing-data warnings.

Data from months ago remains useful for baselines and qualified comparisons,
but never fills gaps in a selected recent window.

## Delivery order

1. Sensor truth, durable session-keyed archives, window sufficiency, richer weekly
   recap, full-page Settings, and sample dashboard.
2. SQLite v2 archive/readings migration and archive management/export.
3. HealthKit source-aware schema, bounded import, and sleep/workout overlays.
4. Anchored sync, deletions, and source normalization.
5. Flutter/toolchain upgrade and physical-iPhone llama.cpp spike.
6. Curated, license-reviewed model catalog and local insights UI.
7. Coverage-aware long-term glucose profile.

Each phase must pass static analysis, unit/widget/integration tests, rendered UI
review at iPhone widths, and a real-device smoke test before merge.
