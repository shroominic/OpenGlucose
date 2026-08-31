import Foundation

/// The Flutter payload publishes the resolved application language rather than
/// relying on `Locale.current`. This keeps the Live Activity aligned with an
/// in-app language override when it differs from the device language.
enum LiveActivityLanguage: String, Codable, Hashable {
  case english = "en"
  case simplifiedChinese = "zh"

  init(payloadLanguageCode: String?) {
    let normalized = payloadLanguageCode?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    self = normalized == Self.simplifiedChinese.rawValue
      ? .simplifiedChinese
      : .english
  }

  var dateFormatterLocale: Locale {
    switch self {
    case .english:
      return Locale(identifier: "en_US")
    case .simplifiedChinese:
      return Locale(identifier: "zh_CN")
    }
  }
}

/// Native strings for the Live Activity. These strings intentionally use the
/// language supplied by Flutter, not the extension's process locale: a person
/// can choose English in an otherwise Chinese device, or the reverse.
enum LiveActivityText {
  static let brandName = "OpenGlucose"

  static func liveGlucose(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Live glucose"
    case .simplifiedChinese:
      return "实时葡萄糖"
    }
  }

  static func sensorWarmingUp(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Sensor warming up"
    case .simplifiedChinese:
      return "传感器预热中"
    }
  }

  static func waitingForSensor(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Waiting for sensor"
    case .simplifiedChinese:
      return "正在等待传感器"
    }
  }

  static func waitingForGlucoseUpdate(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Waiting for glucose update"
    case .simplifiedChinese:
      return "正在等待葡萄糖更新"
    }
  }

  static func connecting(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Connecting"
    case .simplifiedChinese:
      return "正在连接"
    }
  }

  static func error(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Error"
    case .simplifiedChinese:
      return "出错"
    }
  }

  static func stale(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Stale"
    case .simplifiedChinese:
      return "数据已过时"
    }
  }

  static func openAppToViewGlucose(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Open the app to view your glucose"
    case .simplifiedChinese:
      return "打开应用查看你的葡萄糖读数"
    }
  }

  static func updated(_ time: String, for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Updated \(time)"
    case .simplifiedChinese:
      return "更新于 \(time)"
    }
  }

  static func glucoseUnavailable(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Glucose unavailable"
    case .simplifiedChinese:
      return "暂无葡萄糖读数"
    }
  }

  static func staleGlucoseUnavailable(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "Glucose unavailable, reading stale"
    case .simplifiedChinese:
      return "暂无葡萄糖读数，数据已过时"
    }
  }

  static func glucoseValue(
    _ value: String,
    unit: String,
    for language: LiveActivityLanguage
  ) -> String {
    switch language {
    case .english:
      return "Glucose \(value) \(spokenUnit(unit, for: language))"
    case .simplifiedChinese:
      return "葡萄糖读数 \(value) \(spokenUnit(unit, for: language))"
    }
  }

  static func warmupRemaining(
    _ minutes: Int,
    for language: LiveActivityLanguage
  ) -> String {
    switch language {
    case .english:
      return "Sensor warmup, \(minutes) minutes remaining"
    case .simplifiedChinese:
      return "传感器预热中，还剩 \(minutes) 分钟"
    }
  }

  static func readingAt(_ time: String, for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "reading at \(time)"
    case .simplifiedChinese:
      return "读数时间 \(time)"
    }
  }

  static func minuteUnit(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "min"
    case .simplifiedChinese:
      return "分钟"
    }
  }

  static func compactMinuteSuffix(for language: LiveActivityLanguage) -> String {
    switch language {
    case .english:
      return "m"
    case .simplifiedChinese:
      return "分"
    }
  }

  static func spokenUnit(_ unit: String, for language: LiveActivityLanguage) -> String {
    switch (language, unit) {
    case (.english, "mg/dL"):
      return "milligrams per deciliter"
    case (.english, "mmol/L"):
      return "millimoles per liter"
    case (.simplifiedChinese, "mg/dL"):
      return "毫克每分升"
    case (.simplifiedChinese, "mmol/L"):
      return "毫摩尔每升"
    default:
      return unit
    }
  }

  /// A semantic fallback for raw protocol stage codes. `stageLabel` is
  /// display text and may be translated, so it must never decide state.
  static func stageLabel(
    stageCode: String,
    isWarmup: Bool,
    for language: LiveActivityLanguage
  ) -> String {
    if isWarmup {
      return sensorWarmingUp(for: language)
    }
    switch stageCode {
    case "live":
      return liveGlucose(for: language)
    case "error":
      return error(for: language)
    case "progress":
      return connecting(for: language)
    default:
      return waitingForSensor(for: language)
    }
  }

  static func fallbackDetail(
    stageCode: String,
    isWarmup: Bool,
    lastReadingText: String,
    for language: LiveActivityLanguage
  ) -> String {
    if isWarmup {
      return sensorWarmingUp(for: language)
    }
    if lastReadingText != "--", !lastReadingText.isEmpty {
      return updated(lastReadingText, for: language)
    }
    switch stageCode {
    case "error":
      return error(for: language)
    case "progress":
      return connecting(for: language)
    case "live":
      return waitingForGlucoseUpdate(for: language)
    default:
      return waitingForSensor(for: language)
    }
  }
}

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct GlucoseLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var stageCode: String
    var stageLabel: String
    var languageCode: String
    var isWarmup: Bool
    var valueText: String
    var unitText: String
    var lastReadingText: String
    var lifeText: String
    var detailText: String
    var trendSymbol: String
    var deltaText: String
    var isStale: Bool
    var recordedAt: Date?

    private enum CodingKeys: String, CodingKey {
      case stageCode
      case stageLabel
      case languageCode
      case isWarmup
      case valueText
      case unitText
      case lastReadingText
      case lifeText
      case detailText
      case trendSymbol
      case deltaText
      case isStale
      case recordedAt
    }

    init(
      stageCode: String,
      stageLabel: String,
      languageCode: String = LiveActivityLanguage.english.rawValue,
      isWarmup: Bool = false,
      valueText: String,
      unitText: String,
      lastReadingText: String,
      lifeText: String,
      detailText: String,
      trendSymbol: String,
      deltaText: String,
      isStale: Bool,
      recordedAt: Date?
    ) {
      self.stageCode = stageCode
      self.stageLabel = stageLabel
      self.languageCode = LiveActivityLanguage(payloadLanguageCode: languageCode).rawValue
      self.isWarmup = isWarmup
      self.valueText = valueText
      self.unitText = unitText
      self.lastReadingText = lastReadingText
      self.lifeText = lifeText
      self.detailText = detailText
      self.trendSymbol = trendSymbol
      self.deltaText = deltaText
      self.isStale = isStale
      self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      stageCode = try values.decodeIfPresent(String.self, forKey: .stageCode) ?? "pending"
      stageLabel = try values.decodeIfPresent(String.self, forKey: .stageLabel) ?? ""
      let payloadLanguageCode = try values.decodeIfPresent(String.self, forKey: .languageCode)
      languageCode = LiveActivityLanguage(payloadLanguageCode: payloadLanguageCode).rawValue
      isWarmup = try values.decodeIfPresent(Bool.self, forKey: .isWarmup) ?? false
      valueText = try values.decodeIfPresent(String.self, forKey: .valueText) ?? "--"
      unitText = try values.decodeIfPresent(String.self, forKey: .unitText) ?? ""
      lastReadingText = try values.decodeIfPresent(String.self, forKey: .lastReadingText) ?? "--"
      lifeText = try values.decodeIfPresent(String.self, forKey: .lifeText) ?? ""
      detailText = try values.decodeIfPresent(String.self, forKey: .detailText) ?? ""
      trendSymbol = try values.decodeIfPresent(String.self, forKey: .trendSymbol) ?? ""
      deltaText = try values.decodeIfPresent(String.self, forKey: .deltaText) ?? ""
      isStale = try values.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
      recordedAt = try values.decodeIfPresent(Date.self, forKey: .recordedAt)
    }
  }

  // Retained for ActivityKit schema compatibility. This display-only value is
  // always the OpenGlucose brand, never the connected sensor identity.
  var sensorName: String
}
#endif
