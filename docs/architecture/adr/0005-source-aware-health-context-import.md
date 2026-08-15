# ADR 0005: Source-aware, bounded health-context imports

- Date: 2026-08-15
- Status: Accepted

## Context

OpenGlucose needs activity, sleep, and heart-rate context from Apple Health and
Android Health Connect. Platform APIs return source identifiers and intervals,
but bounded reads may overlap or repeat records. Appending every returned point
would duplicate context and make downstream analytics unreliable. Health data
also must remain local and source permissions must be explicit.

## Decision

Use one app-owned importer seam around the existing `health` package. The seam
accepts a user-selected set of categories and a bounded foreground time window,
requests read-only permissions for exactly those categories, maps records into
the shared `cgm_core` activity/sleep/heart-rate models, and writes them to the
local `HealthRepository`.

Every imported sample carries optional `HealthSampleMetadata`: platform record
identifier, source bundle/package and name, source device, device model,
recording method, and a deletion flag for future anchored sync. The repository
uses a namespaced source-plus-record identifier as a unique local key. Legacy
rows remain readable and nullable identities are added by a SQLite migration.

Tests inject a deterministic fake reader and never require a HealthKit account,
Health Connect installation, network, or real health data.

## Alternatives considered

- Store only normalized values: rejected because repeated reads cannot be
  de-duplicated safely and source attribution is lost.
- Add separate HealthKit and Health Connect domain models: rejected because it
  would duplicate mapping and diverge analytics semantics.
- Add a new native SDK: rejected because the reviewed `health` dependency is
  already present and covers the bounded foreground MVP.

## Consequences

- Imports are local-first, read-only, and user-selectable.
- Native permission declarations are required on iOS and Android; background
  delivery and anchored deletion polling remain follow-up work.
- Source identifiers are restricted local metadata and must not be copied into
  user-facing exports or logs.
- A future importer can persist deletion tombstones and anchors without
  changing the normalized sample shape.

## Follow-up controls

- Add per-category Settings UI and explicit sync status messaging.
- Add native/device evidence for HealthKit and Health Connect permission flows.
- Implement anchored queries and deletion reconciliation before claiming
  continuous background synchronization.
