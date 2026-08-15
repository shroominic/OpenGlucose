## Unreleased

- Add validated health events and samples, repository contracts and in-memory
  implementation, timeline composition, explainable glucose analytics, weekly
  recap aggregation, and privacy-minimized AI provider/insight APIs.
- Add the local-first `JournalService` facade for meal, exercise, and note
  entry, imported activity/sleep/heart-rate samples, and mixed timeline context
  queries. The service has no cloud or AI dependency and supports deterministic
  identifier/clock injection for tests.

These additive public APIs require a minor version bump before any independent
package publication.

## 1.0.0

- Initial version.
