import Flutter
import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

final class GlucoseLiveActivityController {
  static let shared = GlucoseLiveActivityController()

  private let channelName = "com.aidex.cgm/live_activity"
  private let sensitiveLockScreenOptInKey =
    "com.aidex.cgm.live_activity.sensitiveLockScreenOptIn"
  private let iso8601 = ISO8601DateFormatter()
  private let defaults = UserDefaults.standard
  private let restrictedState = NativeRestrictedStateStore.shared
  private var channel: FlutterMethodChannel?
  // All Activity<…> operations (lookup, request, update, end) are funneled
  // through this chain so concurrent upsert calls can't each observe an empty
  // Activity.activities and both call Activity.request — which would leave two
  // Live Activities registered for the same sensor.
  private var activityChain: Task<Void, Never> = Task {}
  private let activityChainLock = NSLock()

  private init() {}

  private func serializeActivityWork(_ operation: @escaping () async -> Void) {
    activityChainLock.lock()
    let previous = activityChain
    let next = Task {
      await previous.value
      await operation()
    }
    activityChain = next
    activityChainLock.unlock()
  }

  func configure(with messenger: FlutterBinaryMessenger) {
    guard channel == nil else {
      return
    }
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = methodChannel
  }

  /// A pre-upgrade Live Activity can outlive the process that created it and
  /// still contain raw glucose. End it at launch unless the explicit sensitive
  /// lock-screen opt-in is present; the normal redacted payload then recreates
  /// an activity only after current app state is restored.
  func enforceLaunchPrivacy() {
    guard !defaults.bool(forKey: sensitiveLockScreenOptInKey) else {
      return
    }
    try? clearPersistedBackgroundPayload()
    guard #available(iOS 16.1, *) else {
      return
    }
    serializeActivityWork {
      for activity in Activity<GlucoseLiveActivityAttributes>.activities {
        await self.end(activity, immediately: true)
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "upsert":
      guard let payload = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "bad_args",
            message: "Expected a payload dictionary.",
            details: nil
          )
        )
        return
      }
      upsert(payload: payload, result: result)
    case "setBackgroundSensor":
      guard let payload = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "bad_args",
            message: "Expected sensor payload dictionary.",
            details: nil
          )
        )
        return
      }
      let sensorName = payload["sensorName"] as? String ?? ""
      let serial = payload["serial"] as? String
      do {
        try AidexBackgroundMonitor.shared.configureTarget(
          sensorName: sensorName,
          serial: serial
        )
        result(true)
      } catch {
        result(storageError())
      }
    case "clearBackgroundSensor":
      var persistenceFailed = false
      do {
        try AidexBackgroundMonitor.shared.clearTarget()
      } catch {
        persistenceFailed = true
      }
      do {
        try clearPersistedBackgroundPayload()
      } catch {
        persistenceFailed = true
      }
      if persistenceFailed {
        result(storageError())
      } else {
        result(true)
      }
    case "getSensitiveContentEnabled":
      result(defaults.bool(forKey: sensitiveLockScreenOptInKey))
    case "setSensitiveContentEnabled":
      guard let enabled = call.arguments as? Bool else {
        result(
          FlutterError(
            code: "bad_args",
            message: "Expected a sensitive-content boolean.",
            details: nil
          )
        )
        return
      }
      setSensitiveContentEnabled(enabled, result: result)
    case "end":
      end(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setSensitiveContentEnabled(
    _ enabled: Bool,
    result: @escaping FlutterResult
  ) {
    defaults.set(enabled, forKey: sensitiveLockScreenOptInKey)
    guard defaults.synchronize() else {
      failClosedAfterPreferenceFailure(
        result: result,
        error: FlutterError(
          code: "privacy_preference_failed",
          message: "Could not save the Live Activity privacy setting.",
          details: nil
        )
      )
      return
    }
    guard !enabled, #available(iOS 16.1, *) else {
      result(true)
      return
    }

    // Fail closed before Flutter recreates the activity with a redacted
    // payload. This prevents a crash between consent withdrawal and upsert
    // from leaving the previous glucose value visible.
    serializeActivityWork {
      for activity in Activity<GlucoseLiveActivityAttributes>.activities {
        await self.end(activity, immediately: true)
      }
      result(true)
    }
  }

  private func failClosedAfterPreferenceFailure(
    result: @escaping FlutterResult,
    error: FlutterError
  ) {
    // UserDefaults may have accepted the in-memory mutation even when the
    // durable write failed. Force the process back to the private default and
    // remove any activity that might still contain sensitive content.
    defaults.set(false, forKey: sensitiveLockScreenOptInKey)
    _ = defaults.synchronize()
    guard #available(iOS 16.1, *) else {
      result(error)
      return
    }
    serializeActivityWork {
      for activity in Activity<GlucoseLiveActivityAttributes>.activities {
        await self.end(activity, immediately: true)
      }
      result(error)
    }
  }

  private func upsert(payload: [String: Any], result: @escaping FlutterResult) {
    let displayPayload = lockScreenPayload(from: payload)
    do {
      try persistBackgroundPayload(displayPayload)
    } catch {
      result(storageError())
      return
    }
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }

    guard let sensorName = displayPayload["sensorName"] as? String, !sensorName.isEmpty else {
      result(
        FlutterError(
          code: "bad_payload",
          message: "Missing sensorName in Live Activity payload.",
          details: nil
        )
      )
      return
    }
    serializeActivityWork {
      let state = self.contentState(from: displayPayload)
      do {
        let activity = try await self.upsertActivity(
          sensorName: sensorName,
          state: state
        )
        result(activity.id)
      } catch {
        result(
          FlutterError(
            code: "request_failed",
            message: "Could not update the private Live Activity.",
            details: nil
          )
        )
      }
    }
  }

  func upsertBackgroundGlucose(
    sensorName _: String,
    valueMgdl: Int,
    observedAt: Date
  ) {
    guard #available(iOS 16.1, *) else {
      return
    }

    serializeActivityWork {
      var payload: [String: Any]
      do {
        payload = try self.restrictedState.liveActivityPayload() ?? [:]
      } catch {
        return
      }
      let language = LiveActivityLanguage(
        payloadLanguageCode: payload["languageCode"] as? String
      )
      payload["sensorName"] = "OpenGlucose"
      payload["stageCode"] = "live"
      payload["stageLabel"] = LiveActivityText.liveGlucose(for: language)
      payload["languageCode"] = language.rawValue
      payload["isWarmup"] = false
      payload["valueText"] = String(valueMgdl)
      let unitText = (payload["unitText"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      payload["unitText"] = (unitText?.isEmpty == false) ? unitText : "mg/dL"
      let updatedText = self.localizedTimeText(observedAt, language: language)
      payload["lastReadingText"] = updatedText
      payload["detailText"] = LiveActivityText.updated(updatedText, for: language)
      payload["trendSymbol"] = ""
      payload["deltaText"] = ""
      payload["isStale"] = false
      payload["recordedAtIso8601"] = self.iso8601.string(from: observedAt)
      payload = self.lockScreenPayload(from: payload)
      do {
        try self.persistBackgroundPayload(payload)
      } catch {
        return
      }

      let state = self.contentState(from: payload)
      let displaySensorName = payload["sensorName"] as? String ?? "OpenGlucose"
      do {
        _ = try await self.upsertActivity(
          sensorName: displaySensorName,
          state: state
        )
      } catch {
        return
      }
    }
  }

  private func end(result: @escaping FlutterResult) {
    var persistenceFailed = false
    do {
      try clearPersistedBackgroundPayload()
    } catch {
      persistenceFailed = true
    }
    guard #available(iOS 16.1, *) else {
      if persistenceFailed {
        result(storageError())
      } else {
        result(false)
      }
      return
    }
    let didPersistenceFail = persistenceFailed

    serializeActivityWork {
      for activity in Activity<GlucoseLiveActivityAttributes>.activities {
        await self.end(activity, immediately: true)
      }
      if didPersistenceFail {
        result(self.storageError())
      } else {
        result(true)
      }
    }
  }

  @available(iOS 16.1, *)
  private func contentState(from payload: [String: Any]) -> GlucoseLiveActivityAttributes.ContentState {
    let language = LiveActivityLanguage(
      payloadLanguageCode: payload["languageCode"] as? String
    )
    let stageCode = payload["stageCode"] as? String ?? "pending"
    let isWarmup = payload["isWarmup"] as? Bool ?? false
    let lastReadingText = payload["lastReadingText"] as? String ?? "--"
    let stageLabel = nonEmptyString(payload["stageLabel"])
      ?? LiveActivityText.stageLabel(
        stageCode: stageCode,
        isWarmup: isWarmup,
        for: language
      )
    let detailText = nonEmptyString(payload["detailText"])
      ?? LiveActivityText.fallbackDetail(
        stageCode: stageCode,
        isWarmup: isWarmup,
        lastReadingText: lastReadingText,
        for: language
      )
    return GlucoseLiveActivityAttributes.ContentState(
      stageCode: stageCode,
      stageLabel: stageLabel,
      languageCode: language.rawValue,
      isWarmup: isWarmup,
      valueText: payload["valueText"] as? String ?? "--",
      unitText: payload["unitText"] as? String ?? "mg/dL",
      lastReadingText: lastReadingText,
      lifeText: payload["lifeText"] as? String ?? "",
      detailText: detailText,
      trendSymbol: payload["trendSymbol"] as? String ?? "",
      deltaText: payload["deltaText"] as? String ?? "",
      isStale: payload["isStale"] as? Bool ?? false,
      recordedAt: date(from: payload["recordedAtIso8601"] as? String)
    )
  }

  private func persistBackgroundPayload(_ payload: [String: Any]) throws {
    let sanitized = payload.filter { !($0.value is NSNull) }
    try restrictedState.saveLiveActivityPayload(sanitized)
  }

  /// Glucose is sensitive health data. Until a future settings surface records
  /// an explicit user opt-in, Live Activities show only a generic sensor state.
  /// The opt-in key deliberately defaults to false.
  private func lockScreenPayload(from payload: [String: Any]) -> [String: Any] {
    LiveActivityLockScreenRedaction.apply(
      to: payload,
      sensitiveContentEnabled: defaults.bool(forKey: sensitiveLockScreenOptInKey)
    )
  }

  private func clearPersistedBackgroundPayload() throws {
    try restrictedState.clearLiveActivityPayload()
  }

  private func storageError() -> FlutterError {
    FlutterError(
      code: "restricted_storage_failed",
      message: "Could not update backup-excluded health state.",
      details: nil
    )
  }

  @available(iOS 16.1, *)
  private func requestActivity(
    attributes: GlucoseLiveActivityAttributes,
    state: GlucoseLiveActivityAttributes.ContentState
  ) throws -> Activity<GlucoseLiveActivityAttributes> {
    if #available(iOS 16.2, *) {
      return try Activity.request(
        attributes: attributes,
        content: activityContent(for: state),
        pushType: nil
      )
    }
    return try Activity.request(
      attributes: attributes,
      contentState: state,
      pushType: nil
    )
  }

  @available(iOS 16.1, *)
  private func update(
    _ activity: Activity<GlucoseLiveActivityAttributes>,
    state: GlucoseLiveActivityAttributes.ContentState
  ) async {
    if #available(iOS 16.2, *) {
      await activity.update(activityContent(for: state))
    } else {
      await activity.update(using: state)
    }
  }

  @available(iOS 16.1, *)
  private func upsertActivity(
    sensorName: String,
    state: GlucoseLiveActivityAttributes.ContentState
  ) async throws -> Activity<GlucoseLiveActivityAttributes> {
    if let existing = Activity<GlucoseLiveActivityAttributes>.activities.first(where: {
      $0.attributes.sensorName == sensorName
    }) {
      await update(existing, state: state)
      return existing
    }

    for activity in Activity<GlucoseLiveActivityAttributes>.activities {
      await end(activity, immediately: true)
    }

    let attributes = GlucoseLiveActivityAttributes(sensorName: sensorName)
    return try requestActivity(attributes: attributes, state: state)
  }

  @available(iOS 16.1, *)
  private func end(
    _ activity: Activity<GlucoseLiveActivityAttributes>,
    immediately: Bool
  ) async {
    let dismissalPolicy: ActivityUIDismissalPolicy = immediately ? .immediate : .default
    if #available(iOS 16.2, *) {
      await activity.end(nil, dismissalPolicy: dismissalPolicy)
    } else {
      await activity.end(using: nil, dismissalPolicy: dismissalPolicy)
    }
  }

  @available(iOS 16.2, *)
  private func activityContent(
    for state: GlucoseLiveActivityAttributes.ContentState
  ) -> ActivityContent<GlucoseLiveActivityAttributes.ContentState> {
    let staleDate = state.recordedAt?.addingTimeInterval(10 * 60)
    return ActivityContent(
      state: state,
      staleDate: staleDate,
      relevanceScore: 1.0
    )
  }

  private func date(from iso8601String: String?) -> Date? {
    guard let iso8601String, !iso8601String.isEmpty else {
      return nil
    }
    return iso8601.date(from: iso8601String)
  }

  private func localizedTimeText(
    _ date: Date,
    language: LiveActivityLanguage
  ) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    formatter.locale = language.dateFormatterLocale
    return formatter.string(from: date)
  }

  private func nonEmptyString(_ value: Any?) -> String? {
    guard let text = value as? String else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Removes health and sensor identifiers before content reaches ActivityKit.
/// A validated warmup countdown is device state rather than a glucose value,
/// so it remains useful on the lock screen without requiring the separate
/// sensitive-glucose opt-in.
enum LiveActivityLockScreenRedaction {
  static func apply(
    to payload: [String: Any],
    sensitiveContentEnabled: Bool
  ) -> [String: Any] {
    guard sensitiveContentEnabled else {
      return redact(payload)
    }
    var brandedPayload = payload
    brandedPayload["sensorName"] = "OpenGlucose"
    brandedPayload["languageCode"] = LiveActivityLanguage(
      payloadLanguageCode: payload["languageCode"] as? String
    ).rawValue
    brandedPayload["isWarmup"] = payload["isWarmup"] as? Bool ?? false
    return brandedPayload
  }

  static func redact(_ payload: [String: Any]) -> [String: Any] {
    let stageCode = payload["stageCode"] as? String ?? "pending"
    let language = LiveActivityLanguage(
      payloadLanguageCode: payload["languageCode"] as? String
    )

    if let remainingMinutes = validatedWarmupMinutes(in: payload) {
      return [
        "sensorName": "OpenGlucose",
        "stageCode": "progress",
        "stageLabel": LiveActivityText.sensorWarmingUp(for: language),
        "languageCode": language.rawValue,
        "isWarmup": true,
        "valueText": String(remainingMinutes),
        "unitText": "min",
        "lastReadingText": "--",
        "lifeText": "",
        "detailText": LiveActivityText.sensorWarmingUp(for: language),
        "trendSymbol": "",
        "deltaText": "",
        "isStale": false,
      ]
    }

    return [
      "sensorName": "OpenGlucose",
      "stageCode": stageCode,
      "stageLabel": LiveActivityText.stageLabel(
        stageCode: stageCode,
        isWarmup: false,
        for: language
      ),
      "languageCode": language.rawValue,
      "isWarmup": false,
      "valueText": "--",
      "unitText": "",
      "lastReadingText": "--",
      "lifeText": "",
      "detailText": LiveActivityText.openAppToViewGlucose(for: language),
      "trendSymbol": "",
      "deltaText": "",
      "isStale": payload["isStale"] as? Bool ?? false,
    ]
  }

  private static func validatedWarmupMinutes(in payload: [String: Any]) -> Int? {
    guard payload["isWarmup"] as? Bool == true,
          let valueText = payload["valueText"] as? String,
          let remainingMinutes = Int(valueText),
          (1...180).contains(remainingMinutes) else {
      return nil
    }
    return remainingMinutes
  }
}
