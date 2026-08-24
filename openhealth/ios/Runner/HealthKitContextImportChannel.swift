import Flutter
import Foundation
import HealthKit

/// Native, bounded Apple Health context reader.
///
/// This channel intentionally supports only sleep, workouts, and heart rate.
/// It never writes to HealthKit, does not start a background observer, and
/// does not log values, UUIDs, source identifiers, or anchors.
final class HealthKitContextImportChannel {
  private enum ContextType: String, CaseIterable {
    case sleep
    case workout
    case heartRate

    var sampleType: HKSampleType {
      switch self {
      case .sleep:
        return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
      case .workout:
        return HKObjectType.workoutType()
      case .heartRate:
        return HKObjectType.quantityType(forIdentifier: .heartRate)!
      }
    }

    var sampleKind: String {
      switch self {
      case .sleep:
        return "sleep"
      case .workout:
        return "activity"
      case .heartRate:
        return "heartRate"
      }
    }
  }

  private enum AnchorDecodeResult {
    case noAnchor
    case anchor(HKQueryAnchor)
    case invalid
  }

  private static let channelName = "com.openglucose.app/health_context_import"
  private static let schemaVersion = 1
  private static let maximumWindowMilliseconds: Int64 = 31 * 24 * 60 * 60 * 1000
  private static let maximumRecordsPerType = 1000

  private let channel: FlutterMethodChannel
  private let healthStore = HKHealthStore()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability":
      result([
        "schemaVersion": Self.schemaVersion,
        "status": HKHealthStore.isHealthDataAvailable() ? "available" : "unavailable",
      ])
    case "requestAuthorization":
      requestAuthorization(arguments: call.arguments, result: result)
    case "sync":
      sync(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestAuthorization(
    arguments: Any?,
    result: @escaping FlutterResult
  ) {
    guard
      HKHealthStore.isHealthDataAvailable(),
      let requestedTypes = Self.requestedTypes(arguments),
      Set(requestedTypes) == Set(ContextType.allCases)
    else {
      result(Self.statusResponse("unavailable"))
      return
    }
    let readTypes = Set(requestedTypes.map { $0.sampleType as HKObjectType })
    healthStore.requestAuthorization(
      toShare: Set<HKSampleType>(),
      read: readTypes
    ) { success, _ in
      DispatchQueue.main.async {
        // Apple does not reveal read authorization. `requested` deliberately
        // means only that iOS completed this request without an API failure.
        result(Self.statusResponse(success ? "requested" : "failed"))
      }
    }
  }

  private func sync(arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(Self.syncResponse(status: "unavailable", results: []))
      return
    }
    guard let request = Self.syncRequest(arguments) else {
      result(Self.syncResponse(status: "failed", results: []))
      return
    }

    let lock = NSLock()
    var typeResults = [[String: Any]]()
    let group = DispatchGroup()
    for type in ContextType.allCases {
      group.enter()
      runAnchoredQuery(
        type: type,
        start: request.start,
        end: request.end,
        encodedAnchor: request.anchors[type.rawValue]
      ) { typeResult in
        lock.lock()
        typeResults.append(typeResult)
        lock.unlock()
        group.leave()
      }
    }
    group.notify(queue: .main) {
      let orderedResults = typeResults.sorted {
        ($0["type"] as? String ?? "") < ($1["type"] as? String ?? "")
      }
      let status = Self.aggregateStatus(orderedResults)
      result(Self.syncResponse(status: status, results: orderedResults))
    }
  }

  private func runAnchoredQuery(
    type: ContextType,
    start: Date,
    end: Date,
    encodedAnchor: String?,
    completion: @escaping ([String: Any]) -> Void
  ) {
    let decodedAnchor = Self.decodeAnchor(encodedAnchor)
    if case .invalid = decodedAnchor {
      completion([
        "type": type.rawValue,
        "status": "anchorInvalid",
        "samples": [],
        "deletedIds": [],
        "nextAnchor": NSNull(),
        "mayHaveMore": false,
      ])
      return
    }
    let anchor: HKQueryAnchor?
    switch decodedAnchor {
    case .noAnchor:
      anchor = nil
    case let .anchor(value):
      anchor = value
    case .invalid:
      preconditionFailure("Invalid anchors return before query construction.")
    }
    let predicate = HKQuery.predicateForSamples(
      withStart: start,
      end: end,
      options: [.strictStartDate, .strictEndDate]
    )
    let query = HKAnchoredObjectQuery(
      type: type.sampleType,
      predicate: predicate,
      anchor: anchor,
      limit: Self.maximumRecordsPerType
    ) { [weak self] _, samples, deletedObjects, nextAnchor, error in
      guard let self, error == nil, let nextAnchor else {
        completion(Self.failedTypeResponse(type))
        return
      }
      guard let encodedNextAnchor = Self.encodeAnchor(nextAnchor) else {
        completion(Self.failedTypeResponse(type))
        return
      }
      let sourceSamples = samples ?? []
      var encodedSamples = [[String: Any]]()
      encodedSamples.reserveCapacity(sourceSamples.count)
      for sample in sourceSamples {
        guard let encodedSample = self.samplePayload(
          sample,
          type: type,
          start: start,
          end: end
        ) else {
          completion(Self.failedTypeResponse(type))
          return
        }
        encodedSamples.append(encodedSample)
      }
      let deletedIds = (deletedObjects ?? []).map { $0.uuid.uuidString }
      guard Set(deletedIds).count == deletedIds.count else {
        completion(Self.failedTypeResponse(type))
        return
      }
      let totalObjects = encodedSamples.count + deletedIds.count
      completion([
        "type": type.rawValue,
        "status": totalObjects == 0 ? "noAccessibleData" : "ok",
        "samples": encodedSamples,
        "deletedIds": deletedIds,
        "nextAnchor": encodedNextAnchor,
        // HealthKit does not expose a definitive "has more" bit for this
        // legacy query. A full page is reported conservatively instead.
        "mayHaveMore": totalObjects >= Self.maximumRecordsPerType,
      ])
    }
    healthStore.execute(query)
  }

  private func samplePayload(
    _ sample: HKSample,
    type: ContextType,
    start: Date,
    end: Date
  ) -> [String: Any]? {
    guard
      sample.startDate >= start,
      sample.endDate <= end
    else {
      return nil
    }
    var payload = provenancePayload(for: sample)
    switch type {
    case .sleep:
      guard let category = sample as? HKCategorySample else {
        return nil
      }
      payload["startMs"] = Self.milliseconds(sample.startDate)
      payload["endMs"] = Self.milliseconds(sample.endDate)
      payload["sleepStage"] = Self.sleepStage(category.value)
    case .workout:
      guard sample is HKWorkout else {
        return nil
      }
      payload["startMs"] = Self.milliseconds(sample.startDate)
      payload["endMs"] = Self.milliseconds(sample.endDate)
      // Keep the first import narrow. Workout activity-type normalization and
      // overlap policy remain a later, separate decision.
      payload["workoutLabel"] = "workout"
    case .heartRate:
      guard let quantity = sample as? HKQuantitySample else {
        return nil
      }
      let bpm = quantity.quantity.doubleValue(
        for: HKUnit.count().unitDivided(by: HKUnit.minute())
      )
      guard bpm.isFinite, bpm > 0 else {
        return nil
      }
      payload["timestampMs"] = Self.milliseconds(sample.startDate)
      payload["bpm"] = bpm
    }
    return payload
  }

  private func provenancePayload(for sample: HKSample) -> [String: Any] {
    let source = sample.sourceRevision.source
    let userEntered = (sample.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?
      .boolValue == true
    return [
      "id": sample.uuid.uuidString,
      "sourceApplicationId": Self.nonBlank(source.bundleIdentifier) ?? NSNull(),
      "sourceName": Self.nonBlank(source.name) ?? NSNull(),
      "sourceDevice": Self.nonBlank(sample.device?.name) ?? NSNull(),
      "sourceDeviceModel": Self.nonBlank(sample.device?.model) ?? NSNull(),
      "recordingMethod": userEntered ? "manual" : "automatic",
      "sourceRevision": Self.nonBlank(sample.sourceRevision.version) ?? NSNull(),
    ]
  }

  private static func requestedTypes(_ arguments: Any?) -> [ContextType]? {
    guard
      let dictionary = arguments as? [String: Any],
      dictionary["schemaVersion"] as? Int == schemaVersion,
      let strings = dictionary["types"] as? [String],
      strings.count == ContextType.allCases.count
    else {
      return nil
    }
    let types = strings.compactMap(ContextType.init(rawValue:))
    guard types.count == strings.count, Set(types).count == types.count else {
      return nil
    }
    return types
  }

  private static func syncRequest(_ arguments: Any?) -> (
    start: Date,
    end: Date,
    anchors: [String: String]
  )? {
    guard
      let dictionary = arguments as? [String: Any],
      dictionary["schemaVersion"] as? Int == schemaVersion,
      let requestedTypes = requestedTypes(arguments),
      Set(requestedTypes) == Set(ContextType.allCases),
      let startMilliseconds = integer(dictionary["startMs"]),
      let endMilliseconds = integer(dictionary["endMs"]),
      isValidWindow(startMilliseconds: startMilliseconds, endMilliseconds: endMilliseconds),
      let anchorValues = dictionary["anchors"] as? [String: String]
    else {
      return nil
    }
    let allowedKeys = Set(ContextType.allCases.map(\.rawValue))
    guard Set(anchorValues.keys).isSubset(of: allowedKeys) else {
      return nil
    }
    for anchor in anchorValues.values {
      guard isValidEncodedAnchor(anchor) else {
        return nil
      }
    }
    return (
      Date(timeIntervalSince1970: Double(startMilliseconds) / 1000),
      Date(timeIntervalSince1970: Double(endMilliseconds) / 1000),
      anchorValues
    )
  }

  static func isValidWindow(startMilliseconds: Int64, endMilliseconds: Int64) -> Bool {
    guard startMilliseconds >= 0, endMilliseconds > startMilliseconds else {
      return false
    }
    let interval = endMilliseconds - startMilliseconds
    return interval <= maximumWindowMilliseconds
  }

  static func sleepStage(_ rawValue: Int) -> String {
    switch rawValue {
    case 0:
      return "inBed"
    case 2:
      return "awake"
    case 3:
      return "light"
    case 4:
      return "deep"
    case 5:
      return "rem"
    default:
      return "asleep"
    }
  }

  private static func aggregateStatus(_ results: [[String: Any]]) -> String {
    if results.count != ContextType.allCases.count {
      return "failed"
    }
    let statuses = results.compactMap { $0["status"] as? String }
    guard statuses.count == ContextType.allCases.count else {
      return "failed"
    }
    if statuses.contains("failed") || statuses.contains("anchorInvalid") {
      return "partial"
    }
    let itemCount = results.reduce(0) { total, result in
      let samples = (result["samples"] as? [Any])?.count ?? 0
      let deleted = (result["deletedIds"] as? [Any])?.count ?? 0
      return total + samples + deleted
    }
    return itemCount == 0 ? "noAccessibleData" : "ok"
  }

  private static func failedTypeResponse(_ type: ContextType) -> [String: Any] {
    [
      "type": type.rawValue,
      "status": "failed",
      "samples": [],
      "deletedIds": [],
      "nextAnchor": NSNull(),
      "mayHaveMore": false,
    ]
  }

  private static func statusResponse(_ status: String) -> [String: Any] {
    ["schemaVersion": schemaVersion, "status": status]
  }

  private static func syncResponse(
    status: String,
    results: [[String: Any]]
  ) -> [String: Any] {
    [
      "schemaVersion": schemaVersion,
      "status": status,
      "results": results,
    ]
  }

  private static func decodeAnchor(_ value: String?) -> AnchorDecodeResult {
    guard let value else {
      return .noAnchor
    }
    guard
      isValidEncodedAnchor(value),
      let data = Data(base64Encoded: value),
      let anchor = try? NSKeyedUnarchiver.unarchivedObject(
        ofClass: HKQueryAnchor.self,
        from: data
      )
    else {
      return .invalid
    }
    return .anchor(anchor)
  }

  private static func encodeAnchor(_ anchor: HKQueryAnchor) -> String? {
    guard let data = try? NSKeyedArchiver.archivedData(
      withRootObject: anchor,
      requiringSecureCoding: true
    ) else {
      return nil
    }
    return data.base64EncodedString()
  }

  private static func isValidEncodedAnchor(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !normalized.isEmpty && normalized.count <= 32_768
  }

  private static func integer(_ value: Any?) -> Int64? {
    if let value = value as? Int {
      return Int64(value)
    }
    if let value = value as? Int64 {
      return value
    }
    if let number = value as? NSNumber,
       CFGetTypeID(number) != CFBooleanGetTypeID() {
      let doubleValue = number.doubleValue
      guard doubleValue.isFinite, floor(doubleValue) == doubleValue else {
        return nil
      }
      return number.int64Value
    }
    return nil
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private static func nonBlank(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}
