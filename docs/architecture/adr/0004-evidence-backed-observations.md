# ADR 0004: Evidence-backed observations and AI output boundaries

- Status: Accepted
- Date: 2026-08-15
- Owners: `@shroominic`

## Context

The Today experience needs compact metabolic context without presenting sparse
or correlated health data as a clinical conclusion. Optional AI can help users
explore patterns, but free-form provider text must not become an unsupported
medical, dosing, treatment, or emergency decision path.

## Decision

`cgm_core` exposes `MetabolicObservationEngine`, a deterministic provider-free
calculation over timestamped glucose readings and available local context. It
reports descriptive aggregates for glucose coverage, level/range/variability,
upward excursions, journal meals, imported activity, sleep, and heart rate.
Every observation carries one or more typed `ObservationEvidence` records with
a bounded window, aggregate value, sample count, and source label. Raw readings
and note bodies are never included in evidence or AI prompts.

`AiInsight` stores the evidence attached to the generated insight and a
persisted wellness safety boundary. `InsightService` includes evidence labels in
the prompt, validates provider text against an explicit output contract, and
fails closed on empty or explicit diagnosis/dosing/emergency guidance. AI stays
optional and BYO-key/local-first; deterministic observations do not require a
network provider.

## Consequences

- UI and future reports can show exactly which local aggregates support an
  observation or AI artifact.
- Context overlap is intentionally descriptive; it does not claim causation.
- Existing serialized insights remain readable: missing evidence fields restore
  as an empty list, while newly generated insights always include evidence.
- The output validator is a narrow fail-closed control, not a medical safety
  classifier. Prompt/model adversarial evaluation and accountable review remain
  required before external distribution.
