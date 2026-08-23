# Meal-response evidence contract

`cgm_core` provides `MealResponseAnalytics` as a pure-Dart calculation. It
joins one logged meal with identified local glucose samples. It is a data
quality and self-experimentation aid. It does not say that a meal caused a
glucose change. It is not medical advice, diagnosis, treatment, dosing, or an
emergency signal.

## Inputs and identity

The caller passes a `HealthEventType.meal` and `IdentifiedGlucoseReading`
values. Each glucose record must have a non-empty, unique local or imported
record ID. The result contains only IDs, timestamps, source types, counts, and
metrics. It does not copy a meal description, note body, or raw glucose series.

All arithmetic uses UTC instants. The algorithm sorts inputs by instant,
source name, and record ID. It rejects duplicate timestamps in a relevant
window rather than selecting an apparently valid response from ambiguous data.

## Default qualification

The default policy uses:

- a 30-minute baseline window: `[meal - 30 minutes, meal)`;
- a two-hour response window: `[meal, meal + 2 hours]`;
- at least two baseline samples and three response samples;
- at least 50% observed response coverage;
- no gap larger than 30 minutes, including the gap before the first sample and
  after the final sample; and
- one glucose source only, unless a caller explicitly opts in after applying a
  reviewed source-priority policy.

Display-provisional readings and readings after the caller's supplied `now`
instant are excluded. The evidence object records their counts. Sparse,
gapped, future, duplicate, out-of-order, DST-crossing, and mixed-source data
therefore has a deterministic, inspectable result.

## Output

Every `MealResponse` includes `MealResponseEvidence` with:

- calculation version and meal event ID;
- exact baseline and response windows;
- accepted baseline and response sample IDs;
- source summary, sample count, active span, sample cadence, coverage span,
  and largest gap;
- duplicate and excluded-reading counts; and
- a qualification status.

Only a sufficient response exposes peak rise, time to peak, and observed
trapezoidal glucose-delta area. The area covers observed adjacent samples only;
it never interpolates or extrapolates across missing data.

## Integration boundary

This contract has no Flutter, SQLite, native HealthKit, Health Connect, or
network dependency. The source-aware repository work owns persistence IDs and
source precedence. UI and AI layers must show the evidence/qualification before
they phrase a result, and must preserve the calculation version when storing a
derived observation.
