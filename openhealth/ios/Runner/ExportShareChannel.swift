import Flutter
import UIKit

private enum ExportShareError: LocalizedError {
  case busy
  case invalidArguments
  case invalidFile
  case invalidLocation
  case unavailablePresenter
  case presentationFailed

  var errorDescription: String? {
    switch self {
    case .busy:
      return "An export share sheet is already open."
    case .invalidArguments:
      return "Expected one prepared export file."
    case .invalidFile:
      return "The prepared export file is unavailable."
    case .invalidLocation:
      return "The prepared export file must be in temporary storage."
    case .unavailablePresenter:
      return "The export share sheet has no active presentation window."
    case .presentationFailed:
      return "The export share sheet could not be presented."
    }
  }
}

/// Owns the iOS activity-sheet path for restricted local exports.
///
/// `share_plus` currently configures `popoverPresentationController` on
/// iPhone as well as iPad. On iOS 26 this can strand the activity controller
/// and block later share sheets. This bridge passes the file URL directly to
/// UIKit and configures a popover only when iPad requires one.
final class ExportShareChannel: NSObject, UIAdaptivePresentationControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pendingActivity: UIActivityViewController?
  private var pendingResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.openglucose.app/export_share",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "export_share_failed",
            message: ExportShareError.unavailablePresenter.localizedDescription,
            details: nil
          )
        )
        return
      }
      DispatchQueue.main.async {
        self.handle(call, result: result)
      }
    }
  }

  private func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard call.method == "shareFile" else {
      result(FlutterMethodNotImplemented)
      return
    }

    do {
      guard pendingActivity == nil, pendingResult == nil else {
        throw ExportShareError.busy
      }
      let arguments = try Self.arguments(call.arguments)
      let fileURL = try Self.validatedTemporaryFile(arguments["filePath"])
      guard let presenter = Self.activePresenter() else {
        throw ExportShareError.unavailablePresenter
      }

      let activity = UIActivityViewController(
        activityItems: [fileURL],
        applicationActivities: nil
      )
      if let subject = Self.nonEmptyString(arguments["subject"]) {
        activity.setValue(subject, forKey: "subject")
      }
      Self.configurePopoverIfRequired(
        activity,
        presenter: presenter,
        arguments: arguments,
        interfaceIdiom: UIDevice.current.userInterfaceIdiom
      )
      activity.presentationController?.delegate = self

      pendingActivity = activity
      pendingResult = result
      activity.completionWithItemsHandler = {
        [weak self, weak activity] _, completed, _, error in
        DispatchQueue.main.async {
          guard let self, self.pendingActivity === activity else {
            return
          }
          if let error {
            self.finish(
              error: FlutterError(
                code: "export_share_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            self.finish(value: completed ? "completed" : "dismissed")
          }
        }
      }

      presenter.present(activity, animated: true) { [weak self, weak activity] in
        guard
          let self,
          self.pendingActivity === activity,
          activity?.presentingViewController == nil
        else {
          return
        }
        self.finish(
          error: FlutterError(
            code: "export_share_failed",
            message: ExportShareError.presentationFailed.localizedDescription,
            details: nil
          )
        )
      }
    } catch {
      result(
        FlutterError(
          code: "export_share_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func finish(value: String? = nil, error: FlutterError? = nil) {
    let result = pendingResult
    pendingActivity?.completionWithItemsHandler = nil
    pendingActivity = nil
    pendingResult = nil
    if let error {
      result?(error)
    } else {
      result?(value)
    }
  }

  func presentationControllerDidDismiss(
    _ presentationController: UIPresentationController
  ) {
    guard
      pendingActivity?.presentationController === presentationController
    else {
      return
    }
    finish(value: "dismissed")
  }

  private static func arguments(_ value: Any?) throws -> [String: Any] {
    guard let arguments = value as? [String: Any] else {
      throw ExportShareError.invalidArguments
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

  static func validatedTemporaryFile(
    _ value: Any?,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    guard let filePath = nonEmptyString(value) else {
      throw ExportShareError.invalidArguments
    }
    let fileURL = URL(fileURLWithPath: filePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let temporaryDirectory = temporaryDirectory
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard fileURL.path.hasPrefix(temporaryDirectory.path + "/") else {
      throw ExportShareError.invalidLocation
    }
    var isDirectory = ObjCBool(false)
    guard
      FileManager.default.fileExists(
        atPath: fileURL.path,
        isDirectory: &isDirectory
      ),
      !isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: fileURL.path)
    else {
      throw ExportShareError.invalidFile
    }
    return fileURL
  }

  static func shouldConfigurePopover(
    interfaceIdiom: UIUserInterfaceIdiom
  ) -> Bool {
    interfaceIdiom == .pad
  }

  private static func configurePopoverIfRequired(
    _ activity: UIActivityViewController,
    presenter: UIViewController,
    arguments: [String: Any],
    interfaceIdiom: UIUserInterfaceIdiom
  ) {
    guard
      shouldConfigurePopover(interfaceIdiom: interfaceIdiom),
      let popover = activity.popoverPresentationController
    else {
      return
    }
    popover.sourceView = presenter.view
    let origin = sourceRect(arguments)
    var convertedOrigin = origin
    if !origin.isEmpty, presenter.view.window != nil {
      convertedOrigin = presenter.view.convert(origin, from: nil)
    }
    if convertedOrigin.isEmpty {
      let bounds = presenter.view.bounds
      convertedOrigin = CGRect(
        x: bounds.midX - 1,
        y: bounds.midY - 1,
        width: 2,
        height: 2
      )
    }
    popover.sourceRect = convertedOrigin
  }

  private static func sourceRect(_ arguments: [String: Any]) -> CGRect {
    guard
      let x = arguments["originX"] as? NSNumber,
      let y = arguments["originY"] as? NSNumber,
      let width = arguments["originWidth"] as? NSNumber,
      let height = arguments["originHeight"] as? NSNumber
    else {
      return .zero
    }
    return CGRect(
      x: x.doubleValue,
      y: y.doubleValue,
      width: width.doubleValue,
      height: height.doubleValue
    )
  }

  private static func activePresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .sorted { lhs, rhs in
        Self.scenePriority(lhs.activationState) >
          Self.scenePriority(rhs.activationState)
      }
    for scene in scenes {
      let window = scene.windows.first(where: \.isKeyWindow)
        ?? scene.windows.first(where: { !$0.isHidden })
      if let root = window?.rootViewController {
        return topViewController(root)
      }
    }
    return nil
  }

  private static func scenePriority(
    _ activationState: UIScene.ActivationState
  ) -> Int {
    switch activationState {
    case .foregroundActive:
      return 3
    case .foregroundInactive:
      return 2
    case .background:
      return 1
    case .unattached:
      return 0
    @unknown default:
      return 0
    }
  }

  private static func topViewController(
    _ controller: UIViewController
  ) -> UIViewController {
    if
      let presented = controller.presentedViewController,
      !presented.isBeingDismissed
    {
      return topViewController(presented)
    }
    if
      let navigation = controller as? UINavigationController,
      let visible = navigation.visibleViewController
    {
      return topViewController(visible)
    }
    if
      let tab = controller as? UITabBarController,
      let selected = tab.selectedViewController
    {
      return topViewController(selected)
    }
    if
      let split = controller as? UISplitViewController,
      let last = split.viewControllers.last
    {
      return topViewController(last)
    }
    return controller
  }
}
