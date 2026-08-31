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
  func testExportShareErrorsIncludeStableStageCodes() {
    let cases: [(ExportShareError, String, String, String)] = [
      (
        .channelUnavailable,
        "export_share_channel_unavailable",
        "channel",
        "unavailable"
      ),
      (.busy, "export_share_state_busy", "state", "busy"),
      (
        .invalidArguments,
        "export_share_input_invalid_arguments",
        "input",
        "invalid_arguments"
      ),
      (
        .invalidFile,
        "export_share_file_invalid_file",
        "file",
        "invalid_file"
      ),
      (
        .invalidLocation,
        "export_share_file_invalid_location",
        "file",
        "invalid_location"
      ),
      (
        .unavailablePresenter,
        "export_share_presenter_unavailable",
        "presenter",
        "unavailable"
      ),
      (
        .presentationRefused,
        "export_share_presentation_refused",
        "presentation",
        "refused"
      ),
      (
        .presentationInterrupted,
        "export_share_presentation_interrupted",
        "presentation",
        "interrupted"
      ),
      (
        .activityFailed,
        "export_share_activity_failed",
        "activity",
        "failed"
      ),
    ]

    for (failure, code, stage, reason) in cases {
      let flutterError = failure.flutterError
      XCTAssertEqual(flutterError.code, code)
      let details = flutterError.details as? [String: String]
      XCTAssertEqual(details?["stage"], stage)
      XCTAssertEqual(details?["reason"], reason)
    }
  }

  func testWindowSelectionUsesOnlyVisibleForegroundActiveKeyWindow() {
    let backgroundWindow = attachedWindow()
    let inactiveWindow = attachedWindow()
    let nonKeyWindow = attachedWindow()
    let hiddenWindow = attachedWindow()
    let expectedWindow = attachedWindow()
    let candidates = [
      ExportShareWindowCandidate(
        window: backgroundWindow,
        activationState: .background,
        isKeyWindow: true,
        isHidden: false
      ),
      ExportShareWindowCandidate(
        window: inactiveWindow,
        activationState: .foregroundInactive,
        isKeyWindow: true,
        isHidden: false
      ),
      ExportShareWindowCandidate(
        window: nonKeyWindow,
        activationState: .foregroundActive,
        isKeyWindow: false,
        isHidden: false
      ),
      ExportShareWindowCandidate(
        window: hiddenWindow,
        activationState: .foregroundActive,
        isKeyWindow: true,
        isHidden: true
      ),
      ExportShareWindowCandidate(
        window: expectedWindow,
        activationState: .foregroundActive,
        isKeyWindow: true,
        isHidden: false
      ),
    ]

    XCTAssertTrue(
      ExportShareChannel.foregroundActiveKeyWindow(candidates: candidates) ===
        expectedWindow
    )
  }

  func testWindowSelectionDoesNotFallBackToInactiveOrNonKeyWindow() {
    let inactiveWindow = attachedWindow()
    let nonKeyWindow = attachedWindow()

    XCTAssertNil(
      ExportShareChannel.foregroundActiveKeyWindow(candidates: [
        ExportShareWindowCandidate(
          window: inactiveWindow,
          activationState: .foregroundInactive,
          isKeyWindow: true,
          isHidden: false
        ),
        ExportShareWindowCandidate(
          window: nonKeyWindow,
          activationState: .foregroundActive,
          isKeyWindow: false,
          isHidden: false
        ),
      ])
    )
  }

  func testPresenterMustHaveAViewAttachedToTheSelectedWindow() throws {
    let window = try currentTestWindow()
    let presenter = try XCTUnwrap(window.rootViewController)
    let detachedPresenter = UIViewController()
    detachedPresenter.loadViewIfNeeded()

    XCTAssertFalse(
      ExportShareChannel.isPresenterAttached(detachedPresenter, to: window)
    )
    XCTAssertTrue(
      ExportShareChannel.isPresenterAttached(presenter, to: window)
    )
    XCTAssertNotNil(
      ExportShareChannel.activePresenter(candidates: [
        ExportShareWindowCandidate(
          window: window,
          activationState: .foregroundActive,
          isKeyWindow: true,
          isHidden: false
        ),
      ])
    )
  }

  func testRejectedPresentationResolvesAndAllowsImmediateRetry() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    var results: [Any?] = []

    for _ in 0..<2 {
      try session.present(
        activityController(),
        from: presenter,
        result: { results.append($0) },
        performPresentation: { _, _, _ in false }
      )
      XCTAssertFalse(session.isBusy)
    }

    XCTAssertEqual(results.count, 2)
    for result in results {
      let error = result as? FlutterError
      XCTAssertEqual(error?.code, "export_share_presentation_refused")
      let details = error?.details as? [String: String]
      XCTAssertEqual(details?["stage"], "presentation")
      XCTAssertEqual(details?["reason"], "refused")
    }
  }

  func testLostTransitionSignalStillRecoversOnNextRequest() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    var firstResult: Any?
    var secondResult: Any?

    try session.present(
      activityController(),
      from: presenter,
      result: { firstResult = $0 },
      performPresentation: { _, _, _ in true }
    )
    XCTAssertTrue(session.isBusy)

    try session.present(
      activityController(),
      from: presenter,
      result: { secondResult = $0 },
      performPresentation: { _, _, _ in false }
    )

    XCTAssertEqual(
      (firstResult as? FlutterError)?.code,
      "export_share_presentation_refused"
    )
    XCTAssertEqual(
      (secondResult as? FlutterError)?.code,
      "export_share_presentation_refused"
    )
    XCTAssertFalse(session.isBusy)
  }

  func testCompletedButInvisiblePresentationFailsImmediately() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    var receivedResult: Any?

    try session.present(
      activityController(),
      from: presenter,
      result: { receivedResult = $0 },
      performPresentation: { _, _, completion in
        completion(false)
        return true
      }
    )

    XCTAssertEqual(
      (receivedResult as? FlutterError)?.code,
      "export_share_presentation_refused"
    )
    XCTAssertFalse(session.isBusy)
  }

  func testBackgroundRecoversAcceptedButInvisiblePresentation() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    var receivedResult: Any?

    try session.present(
      activityController(),
      from: presenter,
      result: { receivedResult = $0 },
      performPresentation: { _, _, _ in true }
    )
    XCTAssertTrue(session.isBusy)

    session.applicationDidEnterBackground()

    XCTAssertEqual(
      (receivedResult as? FlutterError)?.code,
      "export_share_presentation_interrupted"
    )
    XCTAssertFalse(session.isBusy)
  }

  func testLatePresentationCallbackCannotResolveResultTwice() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    let activity = activityController()
    let completion = expectation(description: "activity result")
    var presentationCompletion: ((Bool) -> Void)?
    var results: [Any?] = []

    try session.present(
      activity,
      from: presenter,
      result: {
        results.append($0)
        completion.fulfill()
      },
      performPresentation: { _, _, callback in
        presentationCompletion = callback
        return true
      }
    )
    presentationCompletion?(true)
    activity.completionWithItemsHandler?(nil, false, nil, nil)
    wait(for: [completion], timeout: 1)
    presentationCompletion?(false)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first as? String, "dismissed")
    XCTAssertFalse(session.isBusy)
  }

  func testAcceptedPresentationStaysBusyUntilNormalCompletion() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    let firstActivity = activityController()
    let completion = expectation(description: "activity result")
    var firstResult: Any?

    try session.present(
      firstActivity,
      from: presenter,
      result: {
        firstResult = $0
        completion.fulfill()
      },
      performPresentation: { _, _, completion in
        completion(true)
        return true
      }
    )
    XCTAssertTrue(session.isBusy)

    XCTAssertThrowsError(
      try session.present(
        activityController(),
        from: presenter,
        result: { _ in },
        performPresentation: { _, _, completion in
          completion(true)
          return true
        }
      )
    ) { error in
      XCTAssertEqual(
        (error as? ExportShareError)?.flutterError.code,
        "export_share_state_busy"
      )
    }

    firstActivity.completionWithItemsHandler?(nil, true, nil, nil)
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(firstResult as? String, "completed")
    XCTAssertFalse(session.isBusy)
    try session.present(
      activityController(),
      from: presenter,
      result: { _ in },
      performPresentation: { _, _, _ in false }
    )
    XCTAssertFalse(session.isBusy)
  }

  func testActivityErrorUsesActivityStageAndClearsPendingState() throws {
    let session = ExportSharePresentationSession()
    let presenter = UIViewController()
    let activity = activityController()
    let completion = expectation(description: "activity error")
    var receivedResult: Any?

    try session.present(
      activity,
      from: presenter,
      result: {
        receivedResult = $0
        completion.fulfill()
      },
      performPresentation: { _, _, completion in
        completion(true)
        return true
      }
    )
    activity.completionWithItemsHandler?(
      nil,
      false,
      nil,
      NSError(domain: "ExportShareTests", code: 1)
    )
    wait(for: [completion], timeout: 1)

    let error = receivedResult as? FlutterError
    XCTAssertEqual(error?.code, "export_share_activity_failed")
    let details = error?.details as? [String: String]
    XCTAssertEqual(details?["stage"], "activity")
    XCTAssertEqual(details?["reason"], "failed")
    XCTAssertFalse(session.isBusy)
  }

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

  private func attachedWindow() -> UIWindow {
    UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
  }

  private func currentTestWindow() throws -> UIWindow {
    try XCTUnwrap(
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)
    )
  }

  private func activityController() -> UIActivityViewController {
    UIActivityViewController(
      activityItems: ["Synthetic export"],
      applicationActivities: nil
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
