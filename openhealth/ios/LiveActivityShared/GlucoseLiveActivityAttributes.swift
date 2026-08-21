import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct GlucoseLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var stageCode: String
    var stageLabel: String
    var valueText: String
    var unitText: String
    var lastReadingText: String
    var lifeText: String
    var detailText: String
    var trendSymbol: String
    var deltaText: String
    var isStale: Bool
    var recordedAt: Date?
  }

  // Retained for ActivityKit schema compatibility. This display-only value is
  // always the OpenGlucose brand, never the connected sensor identity.
  var sensorName: String
}
#endif
