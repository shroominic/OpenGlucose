import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyStorageChannel: PrivacyStorageChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinish = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    AidexBackgroundMonitor.shared.applicationDidFinishLaunching()
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
