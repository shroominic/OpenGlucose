## Unreleased

- Add validated health events and samples, repository contracts and in-memory
  implementation, timeline composition, explainable glucose analytics, weekly
  recap aggregation, and privacy-minimized AI provider/insight APIs.
- Add optional typed import provenance and platform-scoped source identity for
  activity, sleep, and heart-rate samples. Repository implementations now
  replace provenance-bearing source records deterministically and retain typed
  source-deletion tombstones; manual and legacy samples remain append-only.

These additive public APIs require a minor version bump before any independent
package publication.

## 1.0.0

- Initial version.
