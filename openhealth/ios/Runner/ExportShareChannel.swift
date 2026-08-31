import Flutter
import UIKit

enum ExportShareStage: String {
  case channel
  case state
  case input
  case file
  case presenter
  case presentation
  case activity
}

enum ExportShareError: LocalizedError {
  case channelUnavailable
  case busy
  case invalidArguments
  case invalidFile
  case invalidLocation
  case unavailablePresenter
  case presentationRefused
  case presentationInterrupted
  case activityFailed
  case unexpected

  var stage: ExportShareStage {
    switch self {
    case .channelUnavailable, .unexpected:
      return .channel
    case .busy:
      return .state
    case .invalidArguments:
      return .input
    case .invalidFile, .invalidLocation:
      return .file
    case .unavailablePresenter:
      return .presenter
    case .presentationRefused, .presentationInterrupted:
      return .presentation
    case .activityFailed:
      return .activity
    }
  }

  var reason: String {
    switch self {
    case .channelUnavailable:
      return "unavailable"
    case .busy:
      return "busy"
    case .invalidArguments:
      return "invalid_arguments"
    case .invalidFile:
      return "invalid_file"
    case .invalidLocation:
      return "invalid_location"
    case .unavailablePresenter:
      return "unavailable"
    case .presentationRefused:
      return "refused"
    case .presentationInterrupted:
      return "interrupted"
    case .activityFailed:
      return "failed"
    case .unexpected:
      return "unexpected"
    }
  }

  var flutterError: FlutterError {
    FlutterError(
      code: "export_share_\(stage.rawValue)_\(reason)",
      message: errorDescription,
      details: [
        "stage": stage.rawValue,
        "reason": reason,
      ]
    )
  }

  var errorDescription: String? {
    switch self {
    case .channelUnavailable:
      return "The export share channel is unavailable."
    case .busy:
      return "An export share sheet is already open."
    case .invalidArguments:
      return "Expected one prepared export file."
    case .invalidFile:
      return "The prepared export file is unavailable."
    case .invalidLocation:
      return "The prepared export file must be in the export cache."
    case .unavailablePresenter:
      return "The export share sheet has no active presentation window."
    case .presentationRefused:
      return "The export share sheet could not be presented."
    case .presentationInterrupted:
      return "The export share presentation was interrupted."
    case .activityFailed:
      return "The export share activity failed."
    case .unexpected:
      return "The export share request failed unexpectedly."
    }
  }
}

struct ExportShareWindowCandidate {
  let window: UIWindow
  let activationState: UIScene.ActivationState
  let isKeyWindow: Bool
  let isHidden: Bool
}

/// Owns one in-flight activity controller and always resolves its Flutter
/// result before accepting another request.
final class ExportSharePresentationSession:
  NSObject,
  UIAdaptivePresentationControllerDelegate
{
  typealias PerformPresentation = (
    UIViewController,
    UIActivityViewController,
    @escaping (Bool) -> Void
  ) -> Bool

  private var pendingActivity: UIActivityViewController?
  private var pendingResult: FlutterResult?
  private var presentationIsVisible = false
  private var backgroundObserver: NSObjectProtocol?

  override init() {
    super.init()
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.applicationDidEnterBackground()
    }
  }

  deinit {
    if let backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
    }
  }

  var isBusy: Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    return pendingActivity != nil || pendingResult != nil
  }

  func present(
    _ activity: UIActivityViewController,
    from presenter: UIViewController,
    result: @escaping FlutterResult,
    performPresentation: PerformPresentation
  ) throws {
    dispatchPrecondition(condition: .onQueue(.main))
    try prepareForNewRequest()

    pendingActivity = activity
    pendingResult = result
    presentationIsVisible = false
    activity.presentationController?.delegate = self
    activity.completionWithItemsHandler = {
      [weak self, weak activity] _, completed, _, error in
      DispatchQueue.main.async {
        guard let self, self.pendingActivity === activity else {
          return
        }
        if error != nil {
          self.finish(
            error: ExportShareError.activityFailed.flutterError
          )
        } else {
          self.finish(value: completed ? "completed" : "dismissed")
        }
      }
    }

    let accepted = performPresentation(presenter, activity) {
      [weak self, weak activity] isVisible in
      guard let self else {
        return
      }
      let complete = {
        self.presentationDidComplete(activity, isVisible: isVisible)
      }
      if Thread.isMainThread {
        complete()
      } else {
        DispatchQueue.main.async(execute: complete)
      }
    }
    guard pendingActivity === activity else {
      return
    }
    guard accepted else {
      finish(error: ExportShareError.presentationRefused.flutterError)
      return
    }
  }

  func prepareForNewRequest() throws {
    dispatchPrecondition(condition: .onQueue(.main))
    recoverStrandedPresentationIfNeeded()
    guard !isBusy else {
      throw ExportShareError.busy
    }
  }

  func applicationDidEnterBackground() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard
      !presentationIsVisible,
      let activity = pendingActivity,
      activity.viewIfLoaded?.window == nil
    else {
      return
    }
    activity.dismiss(animated: false)
    finish(error: ExportShareError.presentationInterrupted.flutterError)
  }

  private func presentationDidComplete(
    _ activity: UIActivityViewController?,
    isVisible: Bool
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let activity, pendingActivity === activity else {
      return
    }
    guard isVisible else {
      activity.dismiss(animated: false)
      finish(error: ExportShareError.presentationRefused.flutterError)
      return
    }
    presentationIsVisible = true
  }

  private func recoverStrandedPresentationIfNeeded() {
    guard
      !presentationIsVisible,
      let activity = pendingActivity,
      !activity.isBeingPresented,
      activity.viewIfLoaded?.window == nil
    else {
      return
    }
    activity.dismiss(animated: false)
    finish(error: ExportShareError.presentationRefused.flutterError)
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

  private func finish(value: String? = nil, error: FlutterError? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    let result = pendingResult
    pendingActivity?.completionWithItemsHandler = nil
    pendingActivity = nil
    pendingResult = nil
    presentationIsVisible = false
    if let error {
      result?(error)
    } else {
      result?(value)
    }
  }
}

/// Owns the iOS activity-sheet path for restricted local exports.
///
/// `share_plus` currently configures `popoverPresentationController` on
/// iPhone as well as iPad. On iOS 26 this can strand the activity controller
/// and block later share sheets. This bridge passes the file URL directly to
/// UIKit and configures a popover only when iPad requires one. It accepts only
/// a regular file in an app-cache child named `openglucose-export-*`.
final class ExportShareChannel: NSObject {
  private static let exportDirectoryPrefix = "openglucose-export-"

  private let channel: FlutterMethodChannel
  private let presentationSession = ExportSharePresentationSession()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.openglucose.app/export_share",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(ExportShareError.channelUnavailable.flutterError)
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
      try presentationSession.prepareForNewRequest()
      let arguments = try Self.arguments(call.arguments)
      let fileURL = try Self.validatedExportFile(arguments["filePath"])
      guard let presenter = Self.currentActivePresenter() else {
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
      try presentationSession.present(
        activity,
        from: presenter,
        result: result,
        performPresentation: Self.presentActivity
      )
    } catch let error as ExportShareError {
      result(error.flutterError)
    } catch {
      result(ExportShareError.unexpected.flutterError)
    }
  }

  static func presentActivity(
    presenter: UIViewController,
    activity: UIActivityViewController,
    completion: @escaping (Bool) -> Void
  ) -> Bool {
    presenter.present(activity, animated: true)
    let accepted = activity.presentingViewController != nil ||
      presenter.presentedViewController === activity
    guard accepted else {
      return false
    }
    if activity.viewIfLoaded?.window != nil {
      completion(true)
      return true
    }
    guard
      let coordinator = activity.transitionCoordinator ??
        presenter.transitionCoordinator
    else {
      DispatchQueue.main.async {
        completion(activity.viewIfLoaded?.window != nil)
      }
      return true
    }
    let registered = coordinator.animate(
      alongsideTransition: nil
    ) { context in
      completion(
        !context.isCancelled && activity.viewIfLoaded?.window != nil
      )
    }
    if !registered {
      DispatchQueue.main.async {
        completion(activity.viewIfLoaded?.window != nil)
      }
    }
    return true
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

  static func validatedExportFile(
    _ value: Any?,
    cachesDirectory: URL? = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first
  ) throws -> URL {
    guard let filePath = nonEmptyString(value) else {
      throw ExportShareError.invalidArguments
    }
    guard let cachesDirectory else {
      throw ExportShareError.invalidLocation
    }
    let originalFileURL = URL(fileURLWithPath: filePath).standardizedFileURL
    let originalValues = try? originalFileURL.resourceValues(
      forKeys: [.isSymbolicLinkKey]
    )
    guard originalValues?.isSymbolicLink != true else {
      throw ExportShareError.invalidFile
    }
    let fileURL = originalFileURL
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let resolvedCachesDirectory = cachesDirectory
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let exportDirectory = fileURL.deletingLastPathComponent()
    guard
      exportDirectory.deletingLastPathComponent() == resolvedCachesDirectory,
      exportDirectory.lastPathComponent.hasPrefix(exportDirectoryPrefix)
    else {
      throw ExportShareError.invalidLocation
    }
    let resourceValues = try? fileURL.resourceValues(
      forKeys: [.isRegularFileKey]
    )
    guard
      resourceValues?.isRegularFile == true,
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

  private static func currentActivePresenter() -> UIViewController? {
    let candidates = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { scene in
        scene.windows.map { window in
          ExportShareWindowCandidate(
            window: window,
            activationState: scene.activationState,
            isKeyWindow: window.isKeyWindow,
            isHidden: window.isHidden
          )
        }
      }
    return activePresenter(candidates: candidates)
  }

  static func activePresenter(
    candidates: [ExportShareWindowCandidate]
  ) -> UIViewController? {
    guard
      let window = foregroundActiveKeyWindow(candidates: candidates),
      let root = window.rootViewController
    else {
      return nil
    }
    let presenter = topViewController(root)
    guard isPresenterAttached(presenter, to: window) else {
      return nil
    }
    return presenter
  }

  static func foregroundActiveKeyWindow(
    candidates: [ExportShareWindowCandidate]
  ) -> UIWindow? {
    candidates.first(where: {
      $0.activationState == .foregroundActive &&
        $0.isKeyWindow &&
        !$0.isHidden
    })?.window
  }

  static func isPresenterAttached(
    _ presenter: UIViewController,
    to window: UIWindow
  ) -> Bool {
    presenter.isViewLoaded &&
      presenter.viewIfLoaded?.window === window &&
      !presenter.isBeingDismissed
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
