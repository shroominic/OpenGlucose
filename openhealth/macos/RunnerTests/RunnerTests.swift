import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  func testRunnerIdentifiesItselfAsPreview() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.openglucose.app.macos.preview")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "OpenGlucose Preview")
  }

  func testRunnerDeclaresBluetoothPurpose() {
    let purpose = Bundle.main.object(
      forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription"
    ) as? String

    XCTAssertNotNil(purpose)
    XCTAssertFalse(purpose?.isEmpty ?? true)
  }

}
