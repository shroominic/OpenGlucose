import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyStorageChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let restrictedStateReady: Bool
    do {
      try NativeRestrictedStateStore.shared.initializeAndPurgeLegacyDefaults()
      restrictedStateReady = true
    } catch {
      // The legacy raw payload is purged before replacement state is loaded;
      // target keys are also purged on failure. If exclusion cannot be
      // verified, background health features stay off until the user rescans.
      restrictedStateReady = false
    }
    let didFinish = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    GlucoseLiveActivityController.shared.enforceLaunchPrivacy()
    if restrictedStateReady {
      AidexBackgroundMonitor.shared.applicationDidFinishLaunching()
    }
    return didFinish
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    GlucoseLiveActivityController.shared.configure(
      with: messenger
    )
    configurePrivacyStorageChannel(with: messenger)
  }

  private func configurePrivacyStorageChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.openglucose.app/privacy_storage",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        !path.isEmpty
      else {
        result(
          FlutterError(
            code: "bad_args",
            message: "Expected a non-empty file path.",
            details: nil
          )
        )
        return
      }

      var url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        result(
          FlutterError(
            code: "missing_file",
            message: "Cannot exclude a missing file from backup.",
            details: nil
          )
        )
        return
      }
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let confirmed = try url.resourceValues(
          forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true
        result(confirmed)
      } catch {
        result(
          FlutterError(
            code: "backup_exclusion_failed",
            message: "Could not exclude restricted health state from backup.",
            details: nil
          )
        )
      }
    }
    privacyStorageChannel = channel
  }
}
