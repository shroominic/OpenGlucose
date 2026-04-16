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

  var sensorName: String
}
#endif
