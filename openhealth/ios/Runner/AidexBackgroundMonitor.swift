import CoreBluetooth
import Foundation
import UIKit

final class AidexBackgroundMonitor: NSObject {
  static let shared = AidexBackgroundMonitor()

  private enum DefaultsKey {
    static let sensorName = "com.aidex.cgm.background.sensorName"
    static let sensorSerial = "com.aidex.cgm.background.sensorSerial"
  }

  private let aidexService = CBUUID(string: "181F")
  private let stateRestoreIdentifier = "com.aidex.cgm.background-monitor"
  private let defaults = UserDefaults.standard
  private let bluetoothQueue = DispatchQueue(
    label: "com.aidex.cgm.background-monitor"
  )

  private var centralManager: CBCentralManager?
  private var isScanning = false
  private var targetSensorName: String?
  private var targetSerial: String?
  private var lastCounter: Int?
  private var lastPayloadHex = ""
  private var lastObservedAt: Date?
  private var isAppActive = true

  private override init() {
    super.init()
    loadStoredTarget()
  }

  func applicationDidFinishLaunching() {
    isAppActive = UIApplication.shared.applicationState == .active
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    refreshScanState()
  }

  func configureTarget(sensorName: String, serial: String?) {
    let normalizedName = sensorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSerial = serial?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()

    targetSensorName = normalizedName.isEmpty ? nil : normalizedName
    targetSerial = normalizedSerial?.isEmpty == true ? nil : normalizedSerial
    lastCounter = nil
    lastPayloadHex = ""
    lastObservedAt = nil

    defaults.set(targetSensorName, forKey: DefaultsKey.sensorName)
    defaults.set(targetSerial, forKey: DefaultsKey.sensorSerial)

    refreshScanState()
  }

  func clearTarget() {
    targetSensorName = nil
    targetSerial = nil
    lastCounter = nil
    lastPayloadHex = ""
    lastObservedAt = nil
    defaults.removeObject(forKey: DefaultsKey.sensorName)
    defaults.removeObject(forKey: DefaultsKey.sensorSerial)
    stopScan()
  }

  private func ensureCentralManager() {
    guard centralManager == nil else {
      return
    }
    centralManager = CBCentralManager(
      delegate: self,
      queue: bluetoothQueue,
      options: [
        CBCentralManagerOptionRestoreIdentifierKey: stateRestoreIdentifier,
        CBCentralManagerOptionShowPowerAlertKey: false,
      ]
    )
  }

  private func loadStoredTarget() {
    targetSensorName = defaults.string(forKey: DefaultsKey.sensorName)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    targetSerial = defaults.string(forKey: DefaultsKey.sensorSerial)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
  }

  private var hasTarget: Bool {
    guard let targetSensorName, !targetSensorName.isEmpty else {
      return targetSerial?.isEmpty == false
    }
    return true
  }

  private func refreshScanState() {
    guard hasTarget, shouldMonitorInCurrentAppState else {
      stopScan()
      return
    }
    ensureCentralManager()
    guard let centralManager, centralManager.state == .poweredOn else {
      return
    }
    startScanIfNeeded()
  }

  private var shouldMonitorInCurrentAppState: Bool {
    !isAppActive
  }

  @objc
  private func applicationDidBecomeActive() {
    isAppActive = true
    refreshScanState()
  }

  @objc
  private func applicationDidEnterBackground() {
    isAppActive = false
    refreshScanState()
  }

  private func startScanIfNeeded() {
    guard !isScanning, let centralManager, centralManager.state == .poweredOn else {
      return
    }
    centralManager.scanForPeripherals(
      withServices: [aidexService],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
    isScanning = true
  }

  private func stopScan() {
    guard isScanning, let centralManager else {
      return
    }
    centralManager.stopScan()
    isScanning = false
  }

  private func matchesTarget(name: String?) -> Bool {
    let candidate = name?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased() ?? ""
    if candidate.isEmpty {
      return false
    }
    if let targetSerial, !targetSerial.isEmpty, candidate.contains(targetSerial) {
      return true
    }
    if let targetSensorName,
       !targetSensorName.isEmpty,
       candidate == targetSensorName.uppercased()
    {
      return true
    }
    return false
  }

  private func handleAdvertisement(
    localName: String?,
    manufacturerData: Data
  ) {
    guard let sample = AidexAdvertisementSample(manufacturerData: manufacturerData) else {
      return
    }
    guard let glucoseMgdl = sample.displayValueMgdl else {
      return
    }

    let now = Date()
    if sample.counter == lastCounter,
       sample.payloadHex == lastPayloadHex,
       let lastObservedAt,
       now.timeIntervalSince(lastObservedAt) < 45
    {
      return
    }

    lastCounter = sample.counter
    lastPayloadHex = sample.payloadHex
    lastObservedAt = now

    let sensorName = localName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedSensorName: String
    if let sensorName, !sensorName.isEmpty {
      resolvedSensorName = sensorName
    } else {
      resolvedSensorName = targetSensorName ?? "AiDEX"
    }
    GlucoseLiveActivityController.shared.upsertBackgroundGlucose(
      sensorName: resolvedSensorName,
      valueMgdl: glucoseMgdl,
      observedAt: now
    )
  }
}

extension AidexBackgroundMonitor: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    refreshScanState()
  }

  func centralManager(
    _ central: CBCentralManager,
    willRestoreState dict: [String: Any]
  ) {
    loadStoredTarget()
    isScanning = central.isScanning
    refreshScanState()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let localName = (
      advertisementData[CBAdvertisementDataLocalNameKey] as? String ??
      peripheral.name
    )
    guard matchesTarget(name: localName) else {
      return
    }
    guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
      return
    }
    handleAdvertisement(
      localName: localName,
      manufacturerData: manufacturerData
    )
  }
}

private struct AidexAdvertisementSample {
  let counter: Int
  let payloadHex: String
  let displayValueMgdl: Int?

  init?(manufacturerData: Data) {
    guard manufacturerData.count >= 15 else {
      return nil
    }
    let bytes = Array(manufacturerData)
    counter = AidexAdvertisementSample.littleEndian16(bytes, offset: 2)
    payloadHex = bytes.map { String(format: "%02x", $0) }.joined()

    let triplet = [
      AidexAdvertisementSample.bigEndian16(bytes, offset: 6),
      AidexAdvertisementSample.bigEndian16(bytes, offset: 9),
      AidexAdvertisementSample.bigEndian16(bytes, offset: 12),
    ]
    let qualifiers = [bytes[8], bytes[11], bytes[14]]
    displayValueMgdl = AidexAdvertisementSample.selectDisplayValue(
      triplet: triplet,
      qualifiers: qualifiers
    )
  }

  private static func selectDisplayValue(
    triplet: [Int],
    qualifiers: [UInt8]
  ) -> Int? {
    let count = min(triplet.count, qualifiers.count)
    for index in 0..<count {
      let decoded = decodeSfloat(triplet[index])
      guard decoded.isFinite else {
        continue
      }
      let qualifier = qualifiers[index]
      let isUsableQualifier = qualifier == 0x88 || qualifier == 0x84 || qualifier == 0x80
      if isUsableQualifier, decoded >= 30, decoded <= 400 {
        return Int(decoded.rounded())
      }
    }
    return nil
  }

  private static func decodeSfloat(_ raw: Int) -> Double {
    var exponent = (raw >> 12) & 0x0F
    if exponent >= 8 {
      exponent -= 16
    }
    var mantissa = raw & 0x0FFF
    if mantissa >= 0x0800 {
      mantissa -= 0x1000
    }
    if mantissa == 0x07FF {
      return .nan
    }
    return Double(mantissa) * pow(10.0, Double(exponent))
  }

  private static func littleEndian16(_ bytes: [UInt8], offset: Int) -> Int {
    Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
  }

  private static func bigEndian16(_ bytes: [UInt8], offset: Int) -> Int {
    (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
  }
}
