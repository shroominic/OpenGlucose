## Unreleased

- Add `CgmReadingTimestampBasis.acquisitionRelative` for live receipt times
  mixed with historical receipt-minus-offset times. Both remain excluded from
  retained lifecycle inference. This adds no reading JSON field or RF action.
- Add descriptive `CgmSensorVariant` and `CgmSensorVariantSource`, with optional
  `CgmSessionInfo.sensorVariant` and explicit clearing through `copyWith`.
  Revision axes remain distinct and unknown values are not compatibility or
  operation authority. This does not change reading or discovery JSON.

- Add `supportsHistoryBackfill` as an alias of the existing history capability;
  clarify that locally retained samples are independent of sensor backfill.

- Add the optional `CgmSensorDataProfileProvider` and immutable
  `CgmSensorDataProfile` contract for timing defaults, timestamp basis,
  duplicate handling, current-reading selection, and retained lifecycle
  inference. Legacy defaults preserve existing driver behavior; reading JSON,
  `CgmDriver`, and `CgmSession` contracts are unchanged.
- Add validated health events and samples, repository contracts and in-memory
  implementation, timeline composition, explainable glucose analytics, weekly
  recap aggregation, and privacy-minimized AI provider/insight APIs.

These additive public APIs require a minor version bump before any independent
package publication.

## 1.0.0

- Initial version.
