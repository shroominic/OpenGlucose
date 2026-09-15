/// App-owned authority for activation during the ordinary connection flow.
///
/// Registrations choose this policy in trusted composition code. Advertised or
/// persisted sensor metadata must never grant activation permission. This
/// policy does not replace protocol-specific authorization or write journals.
enum SensorConnectionPolicy {
  /// Selecting Connect may authorize the driver's normal session activation.
  explicitConnect,

  /// First connect without activation, then require a separate confirmation
  /// for the same sensor if the driver reports that activation is required.
  separateConfirmation,

  /// Ordinary selection and reconnect must never authorize activation.
  /// A protocol-specific setup flow, if available, owns that authorization.
  externalSetupOnly,
}

/// Compatibility defaults for existing standalone drivers and registrations.
///
/// New drivers must declare their policy at app composition. An unknown ID is
/// deliberately restrictive, even if its discovery metadata requests otherwise.
SensorConnectionPolicy builtInConnectionPolicyFor(String driverId) =>
    switch (driverId) {
      'aidex' => SensorConnectionPolicy.explicitConnect,
      'yuwell-anytime' => SensorConnectionPolicy.separateConfirmation,
      'libre2-gen1' => SensorConnectionPolicy.externalSetupOnly,
      _ => SensorConnectionPolicy.externalSetupOnly,
    };
