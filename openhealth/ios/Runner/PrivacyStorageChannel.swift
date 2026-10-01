import Flutter
import Foundation

private enum PrivacyStorageError: LocalizedError {
  case invalidArguments
  case invalidLocation
  case invalidArtifact
  case fileCreationFailed
  case backupExclusionFailed
  case fileProtectionFailed

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Expected non-empty privacy-storage paths."
    case .invalidLocation:
      return "Restricted storage must be inside Application Support."
    case .invalidArtifact:
      return "A restricted storage artifact is not a regular file."
    case .fileCreationFailed:
      return "A protected database artifact could not be created."
    case .backupExclusionFailed:
      return "Restricted storage could not be excluded from backup."
    case .fileProtectionFailed:
      return "Complete iOS file protection could not be verified."
    }
  }
}

/// Owns the native half of the fail-closed privacy gate used by restricted
/// Flutter storage. Keeping the channel alive for the engine lifetime avoids
/// relying on a handler retained only by an autoreleased channel object.
final class PrivacyStorageChannel {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.openglucose.app/privacy_storage",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "excludeFromBackup":
          let arguments = try Self.arguments(call.arguments)
          guard let path = Self.nonEmptyString(arguments["path"]) else {
            throw PrivacyStorageError.invalidArguments
          }
          try ProtectedHealthDatabaseStorage.excludeFromBackupAndVerify(
            URL(fileURLWithPath: path)
          )
          result(true)
        case "prepareProtectedDatabase":
          let arguments = try Self.arguments(call.arguments)
          guard
            let directoryPath = Self.nonEmptyString(
              arguments["directoryPath"]
            ),
            let databasePath = Self.nonEmptyString(arguments["databasePath"])
          else {
            throw PrivacyStorageError.invalidArguments
          }
          try ProtectedHealthDatabaseStorage.prepare(
            directoryPath: directoryPath,
            databasePath: databasePath
          )
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(
            code: "privacy_storage_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private static func arguments(_ value: Any?) throws -> [String: Any] {
    guard let arguments = value as? [String: Any] else {
      throw PrivacyStorageError.invalidArguments
    }
    return arguments
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

/// Establishes a dedicated database directory with startup-accessible iOS
/// data-at-rest protection.
///
/// Protection is `completeUntilFirstUserAuthentication`, matching the native
/// restricted-state store. `FileProtectionType.complete` is intentionally
/// avoided: it is unavailable before first unlock after reboot and can fail
/// Flutter startup with `PathAccessException` when BLE/background launch races
/// the first unlock. Intermediate directories (notably the shared
/// `OpenGlucose` parent) are created without a protection attribute so sibling
/// stores such as restricted health state are not locked out.
///
/// The directory and every SQLite artifact are protected and excluded before
/// sqflite opens the database. Empty sidecars are valid SQLite inputs and let
/// us set attributes before SQLite can put health data in WAL/SHM/journal files.
enum ProtectedHealthDatabaseStorage {
  private static let fileManager = FileManager.default
  private static let sidecarSuffixes = ["", "-wal", "-shm", "-journal"]
  private static let startupAccessibleProtection =
    FileProtectionType.completeUntilFirstUserAuthentication

  static func prepare(directoryPath: String, databasePath: String) throws {
    let locations = try validatedLocations(
      directoryPath: directoryPath,
      databasePath: databasePath
    )
    try prepareDirectory(locations.directory)
    for suffix in sidecarSuffixes {
      let artifact = URL(fileURLWithPath: locations.database.path + suffix)
      try prepareRegularFile(artifact)
    }
  }

  static func excludeFromBackupAndVerify(_ sourceURL: URL) throws {
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw PrivacyStorageError.invalidArtifact
    }
    // Repair any previously applied complete-protection class that would make
    // restricted paths unreadable at the next cold start before first unlock.
    try applyAndVerifyStartupAccessibleProtection(sourceURL)
    var url = sourceURL
    do {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
      let excluded = try url.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      ).isExcludedFromBackup
      guard excluded == true else {
        throw PrivacyStorageError.backupExclusionFailed
      }
    } catch let error as PrivacyStorageError {
      throw error
    } catch {
      throw PrivacyStorageError.backupExclusionFailed
    }
  }

  private static func validatedLocations(
    directoryPath: String,
    databasePath: String
  ) throws -> (directory: URL, database: URL) {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).standardizedFileURL.resolvingSymlinksInPath()
    let directory = URL(
      fileURLWithPath: directoryPath,
      isDirectory: true
    ).standardizedFileURL.resolvingSymlinksInPath()
    let database = URL(
      fileURLWithPath: databasePath,
      isDirectory: false
    ).standardizedFileURL.resolvingSymlinksInPath()

    guard
      isDescendant(directory, of: applicationSupport),
      database.deletingLastPathComponent() == directory,
      !database.lastPathComponent.isEmpty
    else {
      throw PrivacyStorageError.invalidLocation
    }
    return (directory, database)
  }

  private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
    candidate.path.hasPrefix(parent.path + "/")
  }

  private static func prepareDirectory(_ directory: URL) throws {
    let parent = directory.deletingLastPathComponent()
    // Create shared ancestors without a protection attribute. FileManager
    // applies createDirectory attributes to intermediate directories too, so
    // putting complete/until-first-auth on this call would poison OpenGlucose
    // for sibling restricted-state paths.
    if parent.path != directory.path {
      try fileManager.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: nil
      )
      try applyAndVerifyStartupAccessibleProtection(parent)
    }
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [
        .protectionKey: startupAccessibleProtection,
      ]
    )
    let attributes = try fileManager.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw PrivacyStorageError.invalidArtifact
    }
    try applyAndVerifyStartupAccessibleProtection(directory)
    try excludeFromBackupAndVerify(directory)
  }

  private static func prepareRegularFile(_ file: URL) throws {
    if fileManager.fileExists(atPath: file.path) {
      let attributes = try fileManager.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw PrivacyStorageError.invalidArtifact
      }
    } else {
      let created = fileManager.createFile(
        atPath: file.path,
        contents: Data(),
        attributes: [.protectionKey: startupAccessibleProtection]
      )
      guard created else {
        throw PrivacyStorageError.fileCreationFailed
      }
    }
    try applyAndVerifyStartupAccessibleProtection(file)
    try excludeFromBackupAndVerify(file)
  }

  private static func applyAndVerifyStartupAccessibleProtection(
    _ url: URL
  ) throws {
    do {
      try fileManager.setAttributes(
        [.protectionKey: startupAccessibleProtection],
        ofItemAtPath: url.path
      )
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard
        let protection = attributes[.protectionKey] as? FileProtectionType,
        protection == startupAccessibleProtection
      else {
        throw PrivacyStorageError.fileProtectionFailed
      }
    } catch let error as PrivacyStorageError {
      throw error
    } catch {
      throw PrivacyStorageError.fileProtectionFailed
    }
  }
}
