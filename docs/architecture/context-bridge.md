# Local context bridge

## Status

This is a local-only application foundation. It assembles a bounded cache for
future glucose-context presentation. It does not add a dashboard card, chart
overlay, diary editor, import control, background task, remote service, or AI
feature.

## Inputs and refreshes

`ContextBridge` is owned by the Flutter application composition root. It reads
only data that the app already has:

- the current ready, non-stopped, lifecycle-non-expired active-sensor session
  history after a provable warmup boundary;
- source-aware activity, sleep, and heart-rate samples already in the local
  health repository;
- local manual fast-journal entries; and
- durable local attachment facts.

The cache range is seven days by default, with one day of interval lead-in for
activity and sleep. Diary queries use both a bounded time window and a bounded
entry count. The bridge listens to active-session changes and the existing
Apple Health context-import controller. A successful manual diary save asks
the bridge to reload through its app scope. Widgets read the cached snapshot;
they do not receive or query a repository.

The bridge never starts a Health import, requests permissions, creates
background work, calls an AI model, or connects to a remote service.

The active session must have a known, non-future session start and pass the
same time-based lifecycle-expiry predicate used by the application controller.
Each retained reading must prove that it is post-warmup through a
sensor-relative minute or a normalized timestamp after that session's warmup
end. The bridge drops a reading whose placement is unknown. It does not reuse
retained history while a session is connecting, stopped, explicitly expired,
or past its sensor lifetime.

## Privacy boundary

The snapshot exposes bridge-generated opaque IDs only. It does not expose a
sensor storage key, device ID, serial, raw packet, source app/device metadata,
or imported external record ID. Imported items retain their normalized source
label, interval, kind, and permitted display values. Manual diary labels stay
local because they are user-authored diary content.

Each reading ID is derived from a private active-session discriminator before
it reaches the snapshot. The same timestamp and value from a different sensor
session cannot share an ID. Imported IDs also include the local source class,
so equal source-side external identifiers from different platforms do not
collide.

## Candidate safety

The bridge can adapt the reviewed deterministic recent-observed-rise contract,
but it is off by default. A product surface must explicitly configure a
non-clinical policy and supply disclosure text that says it is non-clinical or
not medical advice.

Even with that policy, the bridge fails closed when an active-session input is
unproven post-warmup, invalid, raw/calibration-only, provisional,
future-dated, duplicated by timestamp, or mixed across reading sources. Safe
display readings can still remain source-labelled in the cache, but they do
not produce a candidate when the input set is mixed or otherwise incomplete.
A candidate is a bounded opportunity to attach local context. It never states
a cause of a glucose change.

## Attachment facts

`context_attachment_facts` is an additive SQLite table. It links a manual
journal entry to an opaque candidate revision ID, a stable session-scoped
opaque episode key, calculation version, and bounded timing window. The
episode key derives from the private active-session key plus the episode start;
it does not include the mutable candidate peak. The store atomically claims
that episode key once, so a later higher peak cannot re-enable or duplicate an
attachment. It stores no glucose values, raw packets, sensor identifiers, or
external platform identifiers. A claim returns no attachment only when the
journal row or episode was already claimed; an unrelated opaque fact-ID
collision is a storage failure.

The table is deliberately separate from the legacy `health_events` JSON
contract. Schema-four attachment rows remain readable during migration, but
they lack the session discriminator required to prove a stable episode key and
therefore do not suppress a schema-five episode claim. New writes require
typed, bridge-generated opaque candidate and episode links.

## Deliberately deferred work

The next presentation PR can decide how to show optional context without
crowding the reading-first dashboard. It must use `ContextBridgeSnapshot`,
preserve the candidate safety boundary verbatim, and provide a quiet default
for people who only want glucose data. That work includes chart annotations,
the recent-rise question-mark interaction, timing adjustment, diary browsing,
statistics, and any user action that creates an attachment fact.

Apple Health/Health Connect import UX, permission policy, import scheduling,
meal capture, image or local-AI processing, and health insights remain outside
this foundation.
