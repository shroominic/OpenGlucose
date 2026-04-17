import Flutter
import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

final class GlucoseLiveActivityController {
  static let shared = GlucoseLiveActivityController()

  private let channelName = "com.aidex.cgm/live_activity"
  private let backgroundPayloadKey = "com.aidex.cgm.live_activity.basePayload"
  private let iso8601 = ISO8601DateFormatter()
  private let defaults = UserDefaults.standard
  private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    formatter.locale = .current
    return formatter
  }()
  private var channel: FlutterMethodChannel?

  private init() {}

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
      AidexBackgroundMonitor.shared.configureTarget(
        sensorName: sensorName,
        serial: serial
      )
      result(true)
    case "clearBackgroundSensor":
      AidexBackgroundMonitor.shared.clearTarget()
      result(true)
    case "end":
      end(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func upsert(payload: [String: Any], result: @escaping FlutterResult) {
    persistBackgroundPayload(payload)
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }

    guard let sensorName = payload["sensorName"] as? String, !sensorName.isEmpty else {
      result(
        FlutterError(
          code: "bad_payload",
          message: "Missing sensorName in Live Activity payload.",
          details: nil
        )
      )
      return
    }

    Task {
      let state = contentState(from: payload)
      do {
        let activity = try await upsertActivity(
          sensorName: sensorName,
          state: state
        )
        result(activity.id)
      } catch {
        result(
          FlutterError(
            code: "request_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  func upsertBackgroundGlucose(
    sensorName: String,
    valueMgdl: Int,
    observedAt: Date
  ) {
    guard #available(iOS 16.1, *) else {
      return
    }

    Task {
      var payload = defaults.dictionary(forKey: backgroundPayloadKey) ?? [:]
      payload["sensorName"] = sensorName
      payload["stageCode"] = "live"
      payload["stageLabel"] = "LIVE"
      payload["valueText"] = String(valueMgdl)
      let unitText = (payload["unitText"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      payload["unitText"] = (unitText?.isEmpty == false) ? unitText : "mg/dL"
      let updatedText = timeFormatter.string(from: observedAt)
      payload["lastReadingText"] = updatedText
      payload["detailText"] = "Updated \(updatedText)"
      payload["trendSymbol"] = ""
      payload["deltaText"] = ""
      payload["isStale"] = false
      payload["recordedAtIso8601"] = iso8601.string(from: observedAt)
      persistBackgroundPayload(payload)

      let state = contentState(from: payload)
      do {
        _ = try await upsertActivity(sensorName: sensorName, state: state)
      } catch {
        return
      }
    }
  }

  private func end(result: @escaping FlutterResult) {
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }

    Task {
      for activity in Activity<GlucoseLiveActivityAttributes>.activities {
        await end(activity, immediately: true)
      }
      result(true)
    }
  }

  @available(iOS 16.1, *)
  private func contentState(from payload: [String: Any]) -> GlucoseLiveActivityAttributes.ContentState {
    GlucoseLiveActivityAttributes.ContentState(
      stageCode: payload["stageCode"] as? String ?? "pending",
      stageLabel: payload["stageLabel"] as? String ?? "CONNECTING",
      valueText: payload["valueText"] as? String ?? "--",
      unitText: payload["unitText"] as? String ?? "mg/dL",
      lastReadingText: payload["lastReadingText"] as? String ?? "--",
      lifeText: payload["lifeText"] as? String ?? "",
      detailText: payload["detailText"] as? String ?? "",
      trendSymbol: payload["trendSymbol"] as? String ?? "",
      deltaText: payload["deltaText"] as? String ?? "",
      isStale: payload["isStale"] as? Bool ?? false,
      recordedAt: date(from: payload["recordedAtIso8601"] as? String)
    )
  }

  private func persistBackgroundPayload(_ payload: [String: Any]) {
    let sanitized = payload.filter { !($0.value is NSNull) }
    defaults.set(sanitized, forKey: backgroundPayloadKey)
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
    let staleDate = state.recordedAt?.addingTimeInterval(15 * 60)
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
}
