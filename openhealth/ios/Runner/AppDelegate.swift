import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyStorageChannel: PrivacyStorageChannel?

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
    privacyStorageChannel = PrivacyStorageChannel(messenger: messenger)
  }
}
