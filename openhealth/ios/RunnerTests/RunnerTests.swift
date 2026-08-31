import Foundation
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

final class ExportSharePresentationPolicyTests: XCTestCase {
  func testIPhoneDoesNotUsePopoverPresentation() {
    XCTAssertFalse(
      ExportShareChannel.shouldConfigurePopover(interfaceIdiom: .phone)
    )
  }

  func testIPadUsesRequiredPopoverPresentation() {
    XCTAssertTrue(
      ExportShareChannel.shouldConfigurePopover(interfaceIdiom: .pad)
    )
  }

  func testExportShareAcceptsProductionCachePayload() throws {
    let cachesDirectory = try XCTUnwrap(
      FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    )
    let exportDirectory = cachesDirectory.appendingPathComponent(
      "openglucose-export-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: exportDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: exportDirectory) }

    let exportFile = exportDirectory.appendingPathComponent("export.csv")
    try Data("test export".utf8).write(to: exportFile)

    XCTAssertEqual(
      try ExportShareChannel.validatedExportFile(exportFile.path),
      exportFile.standardizedFileURL.resolvingSymlinksInPath()
    )
  }

  func testExportShareAcceptsOnlyScopedReadableCacheFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "openglucose-export-share-policy-\(UUID().uuidString)",
      isDirectory: true
    )
    let cachesDirectory = root.appendingPathComponent(
      "Library/Caches",
      isDirectory: true
    )
    let allowedDirectory = cachesDirectory.appendingPathComponent(
      "openglucose-export-allowed",
      isDirectory: true
    )
    let wrongPrefixDirectory = cachesDirectory.appendingPathComponent(
      "unscoped-export",
      isDirectory: true
    )
    let outsideDirectory = root.appendingPathComponent(
      "outside",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: allowedDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: outsideDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: wrongPrefixDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let allowedFile = allowedDirectory.appendingPathComponent("export.csv")
    let outsideFile = outsideDirectory.appendingPathComponent("export.csv")
    let wrongPrefixFile = wrongPrefixDirectory.appendingPathComponent(
      "export.csv"
    )
    try Data("test export".utf8).write(to: allowedFile)
    try Data("test export".utf8).write(to: outsideFile)
    try Data("test export".utf8).write(to: wrongPrefixFile)

    XCTAssertEqual(
      try ExportShareChannel.validatedExportFile(
        allowedFile.path,
        cachesDirectory: cachesDirectory
      ),
      allowedFile
    )
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        outsideFile.path,
        cachesDirectory: cachesDirectory
      )
    )
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        wrongPrefixFile.path,
        cachesDirectory: cachesDirectory
      )
    )
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        allowedDirectory.appendingPathComponent("missing.csv").path,
        cachesDirectory: cachesDirectory
      )
    )
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        allowedDirectory.path,
        cachesDirectory: cachesDirectory
      )
    )

    let nestedDirectory = allowedDirectory.appendingPathComponent(
      "nested",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: nestedDirectory,
      withIntermediateDirectories: true
    )
    let nestedFile = nestedDirectory.appendingPathComponent("export.csv")
    try Data("test export".utf8).write(to: nestedFile)
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        nestedFile.path,
        cachesDirectory: cachesDirectory
      )
    )

    let traversalPath = "\(allowedDirectory.path)/../unscoped-export/export.csv"
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        traversalPath,
        cachesDirectory: cachesDirectory
      )
    )

    let symbolicLink = allowedDirectory.appendingPathComponent("linked.csv")
    try FileManager.default.createSymbolicLink(
      at: symbolicLink,
      withDestinationURL: outsideFile
    )
    XCTAssertThrowsError(
      try ExportShareChannel.validatedExportFile(
        symbolicLink.path,
        cachesDirectory: cachesDirectory
      )
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
      "stageLabel": "预热中",
      "languageCode": "zh",
      "isWarmup": true,
      "valueText": "57",
      "unitText": "分钟",
      "lastReadingText": "14:55",
      "lifeText": "15 days left",
      "detailText": "Warming up",
      "trendSymbol": "up",
      "deltaText": "+12",
      "isStale": true,
    ])

    XCTAssertEqual(redacted["sensorName"] as? String, "OpenGlucose")
    XCTAssertEqual(redacted["stageCode"] as? String, "progress")
    XCTAssertEqual(redacted["stageLabel"] as? String, "传感器预热中")
    XCTAssertEqual(redacted["languageCode"] as? String, "zh")
    XCTAssertEqual(redacted["isWarmup"] as? Bool, true)
    XCTAssertEqual(redacted["valueText"] as? String, "57")
    XCTAssertEqual(redacted["unitText"] as? String, "min")
    XCTAssertEqual(redacted["lastReadingText"] as? String, "--")
    XCTAssertEqual(redacted["lifeText"] as? String, "")
    XCTAssertEqual(redacted["trendSymbol"] as? String, "")
    XCTAssertEqual(redacted["deltaText"] as? String, "")
    XCTAssertEqual(redacted["isStale"] as? Bool, false)
  }

  func testWarmupRequiresTheSemanticFlagAndValidatedMinutes() throws {
    for payload in [
      [
        "stageCode": "progress",
        "stageLabel": "预热中",
        "valueText": "123",
        "unitText": "分钟",
        "isWarmup": false,
      ],
      [
        "stageCode": "progress",
        "stageLabel": "Warmup",
        "valueText": "181",
        "isWarmup": true,
      ],
      [
        "stageCode": "progress",
        "stageLabel": "WARMUP",
        "valueText": "glucose: 123",
        "isWarmup": true,
      ],
    ] {
      let redacted = LiveActivityLockScreenRedaction.redact(payload)

      XCTAssertEqual(redacted["valueText"] as? String, "--")
      XCTAssertEqual(redacted["unitText"] as? String, "")
    }
  }

  func testRedactionUsesPayloadLanguageForGenericAndWarmupCopy() throws {
    let generic = LiveActivityLockScreenRedaction.redact([
      "stageCode": "progress",
      "stageLabel": "Connecting",
      "languageCode": "zh",
      "isWarmup": false,
      "valueText": "112",
      "unitText": "mg/dL",
    ])
    XCTAssertEqual(generic["stageLabel"] as? String, "正在连接")
    XCTAssertEqual(generic["detailText"] as? String, "打开应用查看你的葡萄糖读数")
    XCTAssertEqual(generic["valueText"] as? String, "--")

    let warmup = LiveActivityLockScreenRedaction.redact([
      "stageCode": "progress",
      "stageLabel": "not a state value",
      "languageCode": "zh",
      "isWarmup": true,
      "valueText": "42",
      "unitText": "anything",
    ])
    XCTAssertEqual(warmup["stageLabel"] as? String, "传感器预热中")
    XCTAssertEqual(warmup["detailText"] as? String, "传感器预热中")
    XCTAssertEqual(warmup["valueText"] as? String, "42")
  }

  func testLiveActivityTextUsesOnlySupportedPayloadLanguages() throws {
    XCTAssertEqual(LiveActivityLanguage(payloadLanguageCode: "zh"), .simplifiedChinese)
    XCTAssertEqual(LiveActivityLanguage(payloadLanguageCode: "ZH"), .simplifiedChinese)
    XCTAssertEqual(LiveActivityLanguage(payloadLanguageCode: "zh-Hant"), .english)
    XCTAssertEqual(LiveActivityLanguage(payloadLanguageCode: "fr"), .english)
    XCTAssertEqual(
      LiveActivityText.updated("14:55", for: .simplifiedChinese),
      "更新于 14:55"
    )
    XCTAssertEqual(
      LiveActivityText.warmupRemaining(42, for: .simplifiedChinese),
      "传感器预热中，还剩 42 分钟"
    )
  }

  func testLegacyLiveActivityStateDecodesWithSafeLanguageAndWarmupDefaults() throws {
    guard #available(iOS 16.1, *) else {
      throw XCTSkip("Live Activities require iOS 16.1 or later.")
    }
    let legacyPayload = """
    {
      "stageCode": "progress",
      "stageLabel": "WARMUP",
      "valueText": "57",
      "unitText": "min",
      "lastReadingText": "--",
      "lifeText": "",
      "detailText": "Sensor warming up",
      "trendSymbol": "",
      "deltaText": "",
      "isStale": false
    }
    """

    let state = try JSONDecoder().decode(
      GlucoseLiveActivityAttributes.ContentState.self,
      from: Data(legacyPayload.utf8)
    )

    XCTAssertEqual(state.languageCode, "en")
    XCTAssertFalse(state.isWarmup)
  }
}
