import Foundation

typealias NativeBackupExclusionVerifier = (URL) throws -> Void
typealias NativeLegacyPreferencesSynchronizer = () -> Bool

struct NativeBackgroundSensorTarget: Equatable {
  let sensorName: String?
  let serial: String?
}

enum NativeRestrictedStateStoreError: LocalizedError {
  case invalidFile
  case unsupportedVersion(Int)
  case backupExclusionFailed
  case legacyPurgeFailed
  case notInitialized
  case rollbackFailed

  var errorDescription: String? {
    switch self {
    case .invalidFile:
      return "The restricted native state file is invalid."
    case let .unsupportedVersion(version):
      return "Restricted native state schema version \(version) is unsupported."
    case .backupExclusionFailed:
      return "Restricted native state could not be excluded from backup."
    case .legacyPurgeFailed:
      return "Legacy restricted preferences could not be purged."
    case .notInitialized:
      return "Restricted native state is not initialized."
    case .rollbackFailed:
      return "Restricted native state rollback failed."
    }
  }
}

/// Stores the small amount of state needed by background Bluetooth and Live
/// Activities in a dedicated, backup-excluded Application Support directory.
/// Mutations become visible only after an atomic file transaction succeeds.
final class NativeRestrictedStateStore {
  static let shared = NativeRestrictedStateStore()

  static let legacySensorNameKey = "com.aidex.cgm.background.sensorName"
  static let legacySensorSerialKey = "com.aidex.cgm.background.sensorSerial"
  static let legacyLiveActivityPayloadKey =
    "com.aidex.cgm.live_activity.basePayload"

  private static let schemaVersion = 1
  private static let targetKey = "backgroundSensor"
  private static let payloadKey = "liveActivityPayload"
  private static let fileName = "restricted-native-state.json"

  private let fileManager: FileManager
  private let storageDirectoryOverride: URL?
  private let defaults: UserDefaults
  private let backupExclusionVerifier: NativeBackupExclusionVerifier
  private let legacyPreferencesSynchronizer: NativeLegacyPreferencesSynchronizer
  private let lock = NSLock()

  private var state: [String: Any] = [
    "schemaVersion": NativeRestrictedStateStore.schemaVersion,
  ]
  private var initialized = false

  init(
    fileManager: FileManager = .default,
    storageDirectoryURL: URL? = nil,
    defaults: UserDefaults = .standard,
    backupExclusionVerifier: NativeBackupExclusionVerifier? = nil,
    legacyPreferencesSynchronizer: NativeLegacyPreferencesSynchronizer? = nil
  ) {
    self.fileManager = fileManager
    storageDirectoryOverride = storageDirectoryURL
    self.defaults = defaults
    self.backupExclusionVerifier =
      backupExclusionVerifier ?? Self.markExcludedFromBackupAndVerify
    self.legacyPreferencesSynchronizer =
      legacyPreferencesSynchronizer ?? { defaults.synchronize() }
  }

  /// Purges the raw legacy payload before reading the replacement file. The
  /// sensor target is removed after migration commits; it is also purged if
  /// migration fails, accepting a recoverable rescan over backup exposure.
  func initializeAndPurgeLegacyDefaults() throws {
    try withLock {
      do {
        let legacyTarget = try readLegacyTargetAndPurgePayload()
        if initialized {
          if state[Self.targetKey] == nil, let legacyTarget {
            var candidate = state
            candidate[Self.targetKey] = encodedTarget(legacyTarget)
            try persist(candidate)
            state = candidate
          }
          try purgeLegacyTarget()
          return
        }

        let fileURL = try storageFileURL()
        try prepareStorageDirectory(fileURL.deletingLastPathComponent())
        try restoreInterruptedCommit(fileURL)

        var candidate: [String: Any]
        var needsWrite = false
        if fileManager.fileExists(atPath: fileURL.path) {
          try excludeFromBackupAndVerify(fileURL)
          candidate = try loadState(fileURL)
          discardTransactionArtifacts(fileURL)
        } else {
          discardIfPresent(URL(fileURLWithPath: fileURL.path + ".next"))
          candidate = ["schemaVersion": Self.schemaVersion]
          needsWrite = true
        }

        if candidate[Self.targetKey] == nil, let legacyTarget {
          candidate[Self.targetKey] = encodedTarget(legacyTarget)
          needsWrite = true
        }
        if needsWrite {
          try persist(candidate)
        }
        try purgeLegacyTarget()
        state = candidate
        initialized = true
      } catch {
        // Fail closed if the excluded store cannot be established. Losing a
        // target requires a rescan; leaving health/device identity in defaults
        // would make it eligible for backup.
        purgeAllLegacyDefaultsBestEffort()
        throw error
      }
    }
  }

  func backgroundTarget() throws -> NativeBackgroundSensorTarget? {
    try withLock {
      try requireInitialized()
      guard let encoded = state[Self.targetKey] as? [String: Any] else {
        return nil
      }
      let sensorName = normalized(encoded["sensorName"] as? String)
      let serial = normalized(encoded["serial"] as? String)?.uppercased()
      if sensorName == nil, serial == nil {
        return nil
      }
      return NativeBackgroundSensorTarget(
        sensorName: sensorName,
        serial: serial
      )
    }
  }

  func saveBackgroundTarget(sensorName: String?, serial: String?) throws {
    try withLock {
      try requireInitialized()
      let target = NativeBackgroundSensorTarget(
        sensorName: normalized(sensorName),
        serial: normalized(serial)?.uppercased()
      )
      var candidate = state
      if target.sensorName == nil, target.serial == nil {
        candidate.removeValue(forKey: Self.targetKey)
      } else {
        candidate[Self.targetKey] = encodedTarget(target)
      }
      try persist(candidate)
      state = candidate
    }
  }

  func clearBackgroundTarget() throws {
    try withLock {
      try requireInitialized()
      guard state[Self.targetKey] != nil else {
        return
      }
      var candidate = state
      candidate.removeValue(forKey: Self.targetKey)
      try persist(candidate)
      state = candidate
    }
  }

  func liveActivityPayload() throws -> [String: Any]? {
    try withLock {
      try requireInitialized()
      guard let payload = state[Self.payloadKey] as? [String: Any] else {
        return nil
      }
      return try normalizedJSONObject(payload)
    }
  }

  func saveLiveActivityPayload(_ payload: [String: Any]) throws {
    try withLock {
      try requireInitialized()
      var candidate = state
      candidate[Self.payloadKey] = try normalizedJSONObject(payload)
      try persist(candidate)
      state = candidate
    }
  }

  func clearLiveActivityPayload() throws {
    try withLock {
      try requireInitialized()
      guard state[Self.payloadKey] != nil else {
        return
      }
      var candidate = state
      candidate.removeValue(forKey: Self.payloadKey)
      try persist(candidate)
      state = candidate
    }
  }

  func storageFileURL() throws -> URL {
    let directory: URL
    if let storageDirectoryOverride {
      directory = storageDirectoryOverride
    } else {
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      directory = applicationSupport
        .appendingPathComponent("OpenGlucose", isDirectory: true)
        .appendingPathComponent("RestrictedNativeState", isDirectory: true)
    }
    return directory.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  private func readLegacyTargetAndPurgePayload() throws
    -> NativeBackgroundSensorTarget?
  {
    let legacyTarget = NativeBackgroundSensorTarget(
      sensorName: normalized(defaults.string(forKey: Self.legacySensorNameKey)),
      serial: normalized(defaults.string(forKey: Self.legacySensorSerialKey))?
        .uppercased()
    )
    defaults.removeObject(forKey: Self.legacyLiveActivityPayloadKey)
    try synchronizeLegacyPreferences()
    guard defaults.object(forKey: Self.legacyLiveActivityPayloadKey) == nil else {
      throw NativeRestrictedStateStoreError.legacyPurgeFailed
    }
    if legacyTarget.sensorName == nil, legacyTarget.serial == nil {
      return nil
    }
    return legacyTarget
  }

  private func purgeLegacyTarget() throws {
    let keys = [Self.legacySensorNameKey, Self.legacySensorSerialKey]
    for key in keys {
      defaults.removeObject(forKey: key)
    }
    try synchronizeLegacyPreferences()
    guard keys.allSatisfy({ defaults.object(forKey: $0) == nil }) else {
      throw NativeRestrictedStateStoreError.legacyPurgeFailed
    }
  }

  private func purgeAllLegacyDefaultsBestEffort() {
    for key in [
      Self.legacySensorNameKey,
      Self.legacySensorSerialKey,
      Self.legacyLiveActivityPayloadKey,
    ] {
      defaults.removeObject(forKey: key)
    }
    _ = legacyPreferencesSynchronizer()
  }

  private func synchronizeLegacyPreferences() throws {
    guard legacyPreferencesSynchronizer() else {
      throw NativeRestrictedStateStoreError.legacyPurgeFailed
    }
  }

  private func loadState(_ fileURL: URL) throws -> [String: Any] {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    guard
      let decoded = try? JSONSerialization.jsonObject(with: data),
      let dictionary = decoded as? [String: Any],
      let version = dictionary["schemaVersion"] as? Int
    else {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    guard version == Self.schemaVersion else {
      throw NativeRestrictedStateStoreError.unsupportedVersion(version)
    }
    if let target = dictionary[Self.targetKey], !(target is [String: Any]) {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    if let payload = dictionary[Self.payloadKey], !(payload is [String: Any]) {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    guard JSONSerialization.isValidJSONObject(dictionary) else {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    return dictionary
  }

  private func persist(_ candidate: [String: Any]) throws {
    guard JSONSerialization.isValidJSONObject(candidate) else {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    let fileURL = try storageFileURL()
    let directoryURL = fileURL.deletingLastPathComponent()
    try prepareStorageDirectory(directoryURL)

    let nextURL = URL(fileURLWithPath: fileURL.path + ".next")
    let previousURL = URL(fileURLWithPath: fileURL.path + ".previous")
    try removeIfPresent(nextURL)
    try removeIfPresent(previousURL)

    let data = try JSONSerialization.data(
      withJSONObject: candidate,
      options: [.sortedKeys]
    )
    do {
      try data.write(
        to: nextURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
      try excludeFromBackupAndVerify(nextURL)
    } catch {
      do {
        try removeIfPresent(nextURL)
      } catch {
        throw NativeRestrictedStateStoreError.rollbackFailed
      }
      throw error
    }

    var movedPrevious = false
    var installedNext = false
    do {
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.moveItem(at: fileURL, to: previousURL)
        movedPrevious = true
      }
      try fileManager.moveItem(at: nextURL, to: fileURL)
      installedNext = true
      try excludeFromBackupAndVerify(fileURL)
    } catch {
      let commitError = error
      do {
        if installedNext {
          try removeIfPresent(fileURL)
        }
        if movedPrevious, fileManager.fileExists(atPath: previousURL.path) {
          try fileManager.moveItem(at: previousURL, to: fileURL)
        }
        try removeIfPresent(nextURL)
      } catch {
        throw NativeRestrictedStateStoreError.rollbackFailed
      }
      throw commitError
    }
    discardIfPresent(previousURL)
  }

  private func prepareStorageDirectory(_ directoryURL: URL) throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try excludeFromBackupAndVerify(directoryURL)
  }

  private func excludeFromBackupAndVerify(_ sourceURL: URL) throws {
    try backupExclusionVerifier(sourceURL)
  }

  private static func markExcludedFromBackupAndVerify(
    _ sourceURL: URL
  ) throws {
    var url = sourceURL
    do {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
      let excluded = try url.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      ).isExcludedFromBackup
      guard excluded == true else {
        throw NativeRestrictedStateStoreError.backupExclusionFailed
      }
    } catch let error as NativeRestrictedStateStoreError {
      throw error
    } catch {
      throw NativeRestrictedStateStoreError.backupExclusionFailed
    }
  }

  private func restoreInterruptedCommit(_ fileURL: URL) throws {
    guard !fileManager.fileExists(atPath: fileURL.path) else {
      return
    }
    let previousURL = URL(fileURLWithPath: fileURL.path + ".previous")
    if fileManager.fileExists(atPath: previousURL.path) {
      try fileManager.moveItem(at: previousURL, to: fileURL)
    }
  }

  private func discardTransactionArtifacts(_ fileURL: URL) {
    discardIfPresent(URL(fileURLWithPath: fileURL.path + ".next"))
    discardIfPresent(URL(fileURLWithPath: fileURL.path + ".previous"))
  }

  private func removeIfPresent(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  private func discardIfPresent(_ url: URL) {
    try? removeIfPresent(url)
  }

  private func requireInitialized() throws {
    guard initialized else {
      throw NativeRestrictedStateStoreError.notInitialized
    }
  }

  private func normalized(_ value: String?) -> String? {
    let normalizedValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedValue?.isEmpty == false ? normalizedValue : nil
  }

  private func encodedTarget(
    _ target: NativeBackgroundSensorTarget
  ) -> [String: String] {
    var encoded: [String: String] = [:]
    if let sensorName = target.sensorName {
      encoded["sensorName"] = sensorName
    }
    if let serial = target.serial {
      encoded["serial"] = serial
    }
    return encoded
  }

  private func normalizedJSONObject(
    _ dictionary: [String: Any]
  ) throws -> [String: Any] {
    guard JSONSerialization.isValidJSONObject(dictionary) else {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    let data = try JSONSerialization.data(withJSONObject: dictionary)
    guard
      let normalized = try JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      throw NativeRestrictedStateStoreError.invalidFile
    }
    return normalized
  }

  private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }
}
