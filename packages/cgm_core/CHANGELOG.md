## Unreleased

- Add validated health events and samples, repository contracts and in-memory
  implementation, timeline composition, explainable glucose analytics, weekly
  recap aggregation, and privacy-minimized AI provider/insight APIs.
- Add deterministic, evidence-backed metabolic observations for glucose,
  journal, activity, sleep, and heart-rate context. AI insights now persist
  typed evidence and a wellness safety boundary, and reject explicit unsafe
  model output before persistence.
- Add the local-first `JournalService` facade for meal, exercise, and note
  entry, imported activity/sleep/heart-rate samples, and mixed timeline context
  queries. The service has no cloud or AI dependency and supports deterministic
  identifier/clock injection for tests.
- Add the dry-run-first `LocalDataDeletionCoordinator` contract covering
  journal/context records, AI artifacts and key, alert history, sensor state
  and archive, background surfaces, caches, and temporary exports. Execution
  requires exact confirmation, detects stale plans, verifies each domain, and
  reports partial failures without claiming complete erasure.

These additive public APIs require a minor version bump before any independent
package publication.

## 1.0.0

- Initial version.
