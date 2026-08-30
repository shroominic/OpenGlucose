# Recent observed rise candidate contract

`cgm_core` provides `RecentObservedRiseAnalytics` as a pure-Dart, local
calculation. It can identify at most one *recent observed upward excursion*
from identified glucose records. Its only intended later use is an optional,
non-blocking invitation to add personal context to a diary.

It does **not** say that a meal, activity, sleep, medication, or any other
event caused a glucose change. It is not a medical alert, diagnosis, dosing
tool, treatment recommendation, or emergency signal.

## Explicit policy, not a magic spike threshold

There is no default `minimumRiseMgdl`. The caller must construct and pass a
`RecentObservedRisePolicy` with an explicit observed-rise threshold. That
threshold is a reviewed product observation rule, not a clinical threshold.
The policy also records every local data-quality and attachment-time bound:

- bounded lookback window and maximum candidate age;
- maximum age of the newest reading;
- maximum permitted gap between relevant records and from the final record to
  evaluation time;
- minimum full-window and per-episode record counts;
- minimum observed episode duration; and
- the optional diary attachment range before the observed start and after the
  observed peak.

The core API requires both `now` and the policy. It never reads a wall clock
or selects a threshold implicitly, so the result is reproducible in tests and
when later reviewing a local attachment.

## Fail-closed input and freshness gates

An assessment has a nullable candidate. Any state other than `qualified` has
no candidate. The calculation rejects records with:

- empty or duplicate local IDs;
- missing timestamps, non-positive/non-finite values, future timestamps, or
  display-provisional values;
- no records in the bounded lookback window;
- a stale newest record or too few window records;
- duplicate instants, more than one CGM record source, or a gap larger than
  the policy permits; and
- no sufficiently sampled or recent observed excursion.

The source gate is intentionally strict. Source precedence, overlap removal,
and sensor identity belong to the source-aware data spine before this contract
is called. The candidate contract must receive one unambiguous measurement
stream.

All comparison uses UTC instants. Input order does not affect the result.
The unit tests cover out-of-order inputs and a daylight-saving-time boundary.

## Observed episode rule

Within a fresh, continuous, source-homogeneous window, the algorithm only
uses a bounded local turning-point pair:

1. A trough is the final reading of a flat-or-descending plateau that is
   followed by a higher reading. The first record in the window is never a
   trough because it has no bounded prior context.
2. A peak is the final reading of a flat-or-ascending plateau before a lower
   reading, or the final reading in the window.
3. The episode is the inclusive readings from the most recent trough through
   that peak. It must meet the policy sample-count, span, and observed-rise
   rules.
4. The calculation exposes only the newest eligible episode. If newer episodes
   are ineligible, an older eligible episode can remain available only while it
   is still within the explicit maximum candidate age.

This rule avoids treating a monotonically rising window edge as a complete
event with a known baseline. It also avoids combining coverage from one
episode with the observed rise from another.

## Candidate identity and evidence

The stable candidate ID is a length-prefixed composition of:

- calculation version;
- observed start reading ID; and
- observed peak reading ID.

It does not include the evaluation clock, so the same local records retain
the same identity across refreshes. `RecentObservedRiseEvidence` records the
calculation version, UTC bounds, selected endpoint IDs, all qualified-window
IDs, episode IDs, one source, exact policy, observed cadence/gap facts, and
freshness facts. These ID lists are immutable. The contract never copies raw
sensor packets, journal text, or a causal conclusion.

## Bounded diary timing

A qualified candidate exposes this range for a later user-selected diary time:

`[episodeStart - attachmentWindowBeforeEpisode,
min(peakAt + attachmentWindowAfterEpisode, evaluatedAt)]`

The upper bound cannot be in the future. A later UI can let a person adjust an
activity or meal time only inside this range. It must show that this is
personal context added by the person, not evidence that the activity or meal
caused the observed change.

## Integration boundary

This draft adds no Flutter UI, chart, HealthKit/Health Connect import, SQLite
schema, cloud service, AI request, notification, or automatic journal entry.
It must not create dashboard space for people who only want to read glucose.

A later opt-in diary/context surface may consume a `qualified` candidate as a
single, quiet “add context” affordance. It must:

- remain hidden when no candidate qualifies;
- not claim a cause, diagnosis, or medical significance;
- preserve candidate ID, policy, and calculation version with any local
  attachment; and
- never derive or persist a candidate from a different source-selection rule
  without re-running this contract.
