import Foundation
import HealthKit
@testable import Runner
import XCTest

final class RunnerTests: XCTestCase {
  private var directoryURL: URL!
  private var defaults: UserDefaults!
  private var defaultsSuite: String!

  override func setUpWithError() throws {
    defaultsSuite = "com.openglucose.tests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("openglucose-native-state-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: defaultsSuite)
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testHealthContextImportAcceptsOnlyBoundedPositiveWindows() {
    let day: Int64 = 24 * 60 * 60 * 1000

    XCTAssertTrue(
      HealthKitContextImportChannel.isValidWindow(
        startMilliseconds: day,
        endMilliseconds: day + 30 * day
      )
    )
    XCTAssertFalse(
      HealthKitContextImportChannel.isValidWindow(
        startMilliseconds: day,
        endMilliseconds: day + 32 * day
      )
    )
    XCTAssertFalse(
      HealthKitContextImportChannel.isValidWindow(
        startMilliseconds: day,
        endMilliseconds: day
      )
    )
  }

  func testHealthContextImportNormalizesSleepStagesWithoutPayloadText() {
    XCTAssertEqual(HealthKitContextImportChannel.sleepStage(0), "inBed")
    XCTAssertEqual(HealthKitContextImportChannel.sleepStage(2), "awake")
    XCTAssertEqual(HealthKitContextImportChannel.sleepStage(3), "light")
    XCTAssertEqual(HealthKitContextImportChannel.sleepStage(4), "deep")
    XCTAssertEqual(HealthKitContextImportChannel.sleepStage(5), "rem")
    XCTAssertEqual(HealthKitContextImportChannel.sleepStage(1), "asleep")
  }

  func testHealthContextImportMapsAbsentUserEnteredMetadataToUnknown() {
    XCTAssertEqual(
      HealthKitContextImportChannel.recordingMethod(wasUserEntered: nil),
      "unknown"
    )
    XCTAssertEqual(
      HealthKitContextImportChannel.recordingMethod(wasUserEntered: NSNumber(value: true)),
      "manual"
    )
    XCTAssertEqual(
      HealthKitContextImportChannel.recordingMethod(wasUserEntered: NSNumber(value: false)),
      "automatic"
    )
  }

  func testHealthContextImportMapsNativeErrorsToSafePublicStates() {
    XCTAssertEqual(
      HealthKitContextImportChannel.queryErrorStatus(
        domain: HKErrorDomain,
        code: HKError.Code.errorNoData.rawValue
      ),
      "noAccessibleData"
    )
    XCTAssertEqual(
      HealthKitContextImportChannel.queryErrorStatus(
        domain: HKErrorDomain,
        code: HKError.Code.errorHealthDataUnavailable.rawValue
      ),
      "unavailable"
    )
    XCTAssertEqual(
      HealthKitContextImportChannel.queryErrorStatus(
        domain: HKErrorDomain,
        code: HKError.Code.errorDatabaseInaccessible.rawValue
      ),
      "locked"
    )
    XCTAssertEqual(
      HealthKitContextImportChannel.queryErrorStatus(
        domain: "untrusted.error.domain",
        code: 1
      ),
      "retry"
    )
  }

  func testLegacyDefaultsArePurgedAndOnlyTargetIsMigrated() throws {
    defaults.set(
      "AiDEX sensor",
      forKey: NativeRestrictedStateStore.legacySensorNameKey
    )
    defaults.set(
      " serial-123 ",
      forKey: NativeRestrictedStateStore.legacySensorSerialKey
    )
    defaults.set(
      ["sensorName": "AiDEX sensor", "valueText": "147"],
      forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
    )
    let store = makeStore()

    try store.initializeAndPurgeLegacyDefaults()

    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacySensorNameKey
      )
    )
    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacySensorSerialKey
      )
    )
    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
      )
    )
    XCTAssertEqual(
      try store.backgroundTarget(),
      NativeBackgroundSensorTarget(
        sensorName: "AiDEX sensor",
        serial: "SERIAL-123"
      )
    )
    XCTAssertNil(try store.liveActivityPayload())

    let fileURL = try store.storageFileURL()
    let source = try String(contentsOf: fileURL, encoding: .utf8)
    XCTAssertFalse(source.contains("147"))
    XCTAssertEqual(
      try fileURL.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      ).isExcludedFromBackup,
      true
    )
    XCTAssertEqual(
      try directoryURL.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      ).isExcludedFromBackup,
      true
    )
  }

  func testLegacyPayloadIsPurgedBeforeAStoredFileIsLoaded() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let fileURL = directoryURL.appendingPathComponent(
      "restricted-native-state.json"
    )
    try Data("not-json".utf8).write(to: fileURL)
    defaults.set(
      ["valueText": "221"],
      forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
    )
    defaults.set(
      "sensor-that-must-be-rescanned",
      forKey: NativeRestrictedStateStore.legacySensorNameKey
    )
    defaults.set(
      "serial-that-must-be-rescanned",
      forKey: NativeRestrictedStateStore.legacySensorSerialKey
    )
    let store = makeStore()

    XCTAssertThrowsError(try store.initializeAndPurgeLegacyDefaults())

    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
      )
    )
    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacySensorNameKey
      )
    )
    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacySensorSerialKey
      )
    )
    XCTAssertEqual(
      try String(contentsOf: fileURL, encoding: .utf8),
      "not-json"
    )
  }

  func testNativeMutationsStayInVersionedBackupExcludedFile() throws {
    let store = makeStore()
    try store.initializeAndPurgeLegacyDefaults()

    try store.saveBackgroundTarget(sensorName: "Sensor", serial: "abc")
    try store.saveLiveActivityPayload([
      "sensorName": "OpenGlucose",
      "valueText": "--",
      "detailText": "Open the app to view your glucose",
      "isStale": false,
    ])

    XCTAssertEqual(
      try store.backgroundTarget(),
      NativeBackgroundSensorTarget(sensorName: "Sensor", serial: "ABC")
    )
    XCTAssertEqual(
      try store.liveActivityPayload()?["valueText"] as? String,
      "--"
    )
    let fileURL = try store.storageFileURL()
    let data = try Data(contentsOf: fileURL)
    let envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
    XCTAssertEqual(
      try fileURL.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      ).isExcludedFromBackup,
      true
    )
  }

  func testFailedMigrationPurgesDefaultsAndLeavesNoUnexcludedState() throws {
    defaults.set(
      "sensor-that-must-be-rescanned",
      forKey: NativeRestrictedStateStore.legacySensorNameKey
    )
    defaults.set(
      ["valueText": "199"],
      forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
    )
    let store = NativeRestrictedStateStore(
      storageDirectoryURL: directoryURL,
      defaults: defaults,
      backupExclusionVerifier: { url in
        if url.lastPathComponent == "restricted-native-state.json" {
          throw NativeRestrictedStateStoreError.backupExclusionFailed
        }
      }
    )

    XCTAssertThrowsError(try store.initializeAndPurgeLegacyDefaults())

    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacySensorNameKey
      )
    )
    XCTAssertNil(
      defaults.object(
        forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try store.storageFileURL().path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: try store.storageFileURL().path + ".next"
      )
    )
  }

  func testFailedLegacySynchronizationBlocksInitialization() throws {
    defaults.set(
      "sensor-that-must-be-rescanned",
      forKey: NativeRestrictedStateStore.legacySensorNameKey
    )
    defaults.set(
      ["valueText": "188"],
      forKey: NativeRestrictedStateStore.legacyLiveActivityPayloadKey
    )
    var synchronizationAttempts = 0
    let store = NativeRestrictedStateStore(
      storageDirectoryURL: directoryURL,
      defaults: defaults,
      legacyPreferencesSynchronizer: {
        synchronizationAttempts += 1
        return false
      }
    )

    XCTAssertThrowsError(try store.initializeAndPurgeLegacyDefaults()) { error in
      guard case NativeRestrictedStateStoreError.legacyPurgeFailed = error else {
        return XCTFail("Expected legacyPurgeFailed, received \(type(of: error))")
      }
    }
    XCTAssertGreaterThanOrEqual(synchronizationAttempts, 2)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try store.storageFileURL().path)
    )
  }

  private func makeStore() -> NativeRestrictedStateStore {
    NativeRestrictedStateStore(
      storageDirectoryURL: directoryURL,
      defaults: defaults
    )
  }
}

final class LiveActivityLockScreenRedactionTests: XCTestCase {
  func testLiveGlucoseRequiresExplicitSensitiveContentConsent() throws {
    let payload: [String: Any] = [
      "sensorName": "Private sensor name",
      "stageCode": "live",
      "stageLabel": "LIVE",
      "valueText": "112",
      "unitText": "mg/dL",
      "lastReadingText": "14:55",
      "detailText": "Updated 14:55",
      "trendSymbol": "up",
      "deltaText": "+4",
      "isStale": false,
    ]

    let redacted = LiveActivityLockScreenRedaction.apply(
      to: payload,
      sensitiveContentEnabled: false
    )
    XCTAssertEqual(redacted["sensorName"] as? String, "OpenGlucose")
    XCTAssertEqual(redacted["valueText"] as? String, "--")
    XCTAssertEqual(redacted["unitText"] as? String, "")
    XCTAssertEqual(redacted["lastReadingText"] as? String, "--")
    XCTAssertEqual(redacted["trendSymbol"] as? String, "")
    XCTAssertEqual(redacted["deltaText"] as? String, "")

    let consented = LiveActivityLockScreenRedaction.apply(
      to: payload,
      sensitiveContentEnabled: true
    )
    XCTAssertEqual(consented["sensorName"] as? String, "OpenGlucose")
    XCTAssertEqual(consented["valueText"] as? String, "112")
    XCTAssertEqual(consented["unitText"] as? String, "mg/dL")
    XCTAssertEqual(consented["lastReadingText"] as? String, "14:55")
    XCTAssertEqual(consented["trendSymbol"] as? String, "up")
    XCTAssertEqual(consented["deltaText"] as? String, "+4")
  }

  func testWarmupCountdownSurvivesDefaultRedaction() throws {
    let redacted = LiveActivityLockScreenRedaction.redact([
      "sensorName": "Private sensor name",
      "stageCode": "progress",
      "stageLabel": "WARMUP",
      "valueText": "57",
      "unitText": "min",
      "lastReadingText": "14:55",
      "lifeText": "15 days left",
      "detailText": "Warming up",
      "trendSymbol": "up",
      "deltaText": "+12",
      "isStale": true,
    ])

    XCTAssertEqual(redacted["sensorName"] as? String, "OpenGlucose")
    XCTAssertEqual(redacted["stageCode"] as? String, "progress")
    XCTAssertEqual(redacted["stageLabel"] as? String, "WARMUP")
    XCTAssertEqual(redacted["valueText"] as? String, "57")
    XCTAssertEqual(redacted["unitText"] as? String, "min")
    XCTAssertEqual(redacted["lastReadingText"] as? String, "--")
    XCTAssertEqual(redacted["lifeText"] as? String, "")
    XCTAssertEqual(redacted["trendSymbol"] as? String, "")
    XCTAssertEqual(redacted["deltaText"] as? String, "")
    XCTAssertEqual(redacted["isStale"] as? Bool, false)
  }

  func testMalformedWarmupPayloadFailsClosed() throws {
    for payload in [
      [
        "stageCode": "live",
        "stageLabel": "WARMUP",
        "valueText": "123",
        "unitText": "min",
      ],
      [
        "stageCode": "progress",
        "stageLabel": "WARMUP",
        "valueText": "123",
        "unitText": "mg/dL",
      ],
      [
        "stageCode": "progress",
        "stageLabel": "WARMUP",
        "valueText": "glucose: 123",
        "unitText": "min",
      ],
    ] {
      let redacted = LiveActivityLockScreenRedaction.redact(payload)

      XCTAssertEqual(redacted["valueText"] as? String, "--")
      XCTAssertEqual(redacted["unitText"] as? String, "")
    }
  }
}
