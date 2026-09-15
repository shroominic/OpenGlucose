/// Meaning of timestamps in a driver's normalized history.
enum CgmReadingTimestampBasis {
  /// Samples are placed on the sensor's session timeline. This does not alone
  /// prove that subtracting a sensor minute gives its activation time: protocol
  /// clock offsets can exist. See [CgmRetainedLifecyclePolicy].
  sessionRelative,

  /// The phone's receipt instant, not a reconstructed measurement/activation
  /// instant. Gaps must not be filled or shifted onto a guessed sensor clock.
  receivedAt,

  /// Current samples use receipt time; historical samples use that acquisition
  /// instant minus a protocol-verified sensor-minute offset. Neither is proof
  /// of a UTC activation instant. Per-reading evidence belongs to the host.
  acquisitionRelative,
}

/// How a repeated sensor minute/source updates retained local history.
enum CgmHistoryDuplicatePolicy {
  /// Accept the later normalized record, including corrected sensor timing.
  replaceExisting,

  /// Preserve the first accepted record and its original timestamp/value.
  keepFirst,
}

/// Whether retained history can supply the app's latest-reading candidate.
enum CgmCurrentReadingPolicy {
  /// Preserve the legacy latest-reading-or-history fallback. Consumers still
  /// apply warmup, freshness, quality, and connection presentation rules.
  latestOrHistory,

  /// Require a current live sample from a ready session. History alone is not
  /// proof of a current reading or a healthy connection.
  liveOnly,
}

/// Whether retained samples can reconstruct sensor lifecycle timing.
enum CgmRetainedLifecyclePolicy {
  /// The driver permits the legacy timestamp/minute inference. Receipt-time
  /// profiles remain excluded by [CgmSensorDataProfile.canInferRetainedLifecycle].
  inferFromReadings,

  /// Only explicit session lifecycle evidence can establish start or expiry.
  /// Neither retained sample age nor a reception gap establishes expiry.
  reportedOnly,
}

/// Driver-declared interpretation of normalized data, without device I/O.
///
/// These defaults preserve the historical app behavior for drivers that have
/// not adopted [CgmSensorDataProfileProvider]. A profile is not evidence that a
/// particular sensor has started, finished warmup, expired, or sent valid data.
/// Live session information remains authoritative. Capability flags separately
/// declare operations: `supportsHistory` means sensor backfill, not whether a
/// session can accumulate received samples in local history.
///
/// This profile does not alter reading JSON, authorize device operations, or
/// introduce sensor-specific commands into the core package.
final class CgmSensorDataProfile {
  const CgmSensorDataProfile({
    this.warmupMinutes = 60,
    this.expectedLifetimeMinutes = 15 * 24 * 60,
    this.timestampBasis = CgmReadingTimestampBasis.sessionRelative,
    this.duplicatePolicy = CgmHistoryDuplicatePolicy.replaceExisting,
    this.currentReadingPolicy = CgmCurrentReadingPolicy.latestOrHistory,
    this.retainedLifecyclePolicy = CgmRetainedLifecyclePolicy.inferFromReadings,
  }) : assert(warmupMinutes >= 0),
       assert(expectedLifetimeMinutes > 0);

  /// Explicit compatibility default for an existing driver with no profile.
  static const legacy = CgmSensorDataProfile();

  /// Declared model defaults, used when no live session information exists.
  final int warmupMinutes;
  final int expectedLifetimeMinutes;
  final CgmReadingTimestampBasis timestampBasis;
  final CgmHistoryDuplicatePolicy duplicatePolicy;
  final CgmCurrentReadingPolicy currentReadingPolicy;
  final CgmRetainedLifecyclePolicy retainedLifecyclePolicy;

  /// Receipt and acquisition-relative timestamps never become lifecycle
  /// evidence, even with the legacy inference-policy default.
  bool get canInferRetainedLifecycle =>
      timestampBasis == CgmReadingTimestampBasis.sessionRelative &&
      retainedLifecyclePolicy == CgmRetainedLifecyclePolicy.inferFromReadings;
}

/// Optional additive driver contract. Reading this getter must perform no I/O,
/// reserve no counters, and neither connect nor activate a sensor.
///
/// Hosts resolve it through their driver registry for both live and archived
/// data; they must not identify a vendor by its data-policy field values.
abstract interface class CgmSensorDataProfileProvider {
  CgmSensorDataProfile get sensorDataProfile;
}
