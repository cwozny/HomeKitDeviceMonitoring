import Foundation

/// How urgent a state is. Drives the fixed status palette.
enum Severity: Int, Comparable
{
  case normal
  case warning
  case serious
  case critical

  static func < (lhs: Severity, rhs: Severity) -> Bool
  {
    lhs.rawValue < rhs.rawValue
  }
}

struct Battery: Hashable
{
  enum Charging: Int
  {
    case notCharging = 0
    case charging = 1
    case notChargeable = 2
  }

  static let lowThreshold = 20
  static let criticalThreshold = 10

  /// Percent remaining, 0–100. Nil until the accessory reports a level.
  var level: Int?
  /// The accessory's own low-battery flag. Nil until the accessory reports it.
  var isLowFlagged: Bool?
  var charging: Charging?

  var severity: Severity
  {
    if let level, level <= Self.criticalThreshold
    {
      return .critical
    }
    if isLowFlagged == true
    {
      return .warning
    }
    if let level, level <= Self.lowThreshold
    {
      return .warning
    }
    return .normal
  }

  var fraction: Double?
  {
    guard let level else
    {
      return nil
    }
    return Double(min(max(level, 0), 100)) / 100
  }
}

struct Reading: Identifiable, Hashable
{
  /// Readings within a row appear in declaration order.
  enum Kind: Int, Comparable
  {
    case temperature
    case humidity
    case motion
    case occupancy
    case contact
    case leak
    case smoke
    case carbonMonoxideDetected
    case carbonDioxideDetected
    case airQuality
    case carbonDioxide
    case carbonMonoxide
    case pm25
    case pm10
    case voc
    case light
    case fault
    case tampered

    static func < (lhs: Kind, rhs: Kind) -> Bool
    {
      lhs.rawValue < rhs.rawValue
    }

    /// Fault and tamper flags alone don't make an accessory a sensor.
    var isMeasurement: Bool
    {
      self != .fault && self != .tampered
    }
  }

  var id = UUID()
  var kind: Kind
  /// Raw HomeKit value; nil until the accessory has reported one.
  var value: Double?
}

struct DeviceSnapshot: Identifiable, Hashable
{
  var id: UUID
  var name: String
  var home: String
  var room: String
  var manufacturer: String?
  var model: String?
  var firmware: String?
  var symbol: String
  var isReachable: Bool
  var battery: Battery?
  var readings: [Reading]

  var hasLowBattery: Bool
  {
    (battery?.severity ?? .normal) > .normal
  }

  var hasBatteryLevel: Bool
  {
    battery?.level != nil
  }

  /// Lowest battery first, flagged-but-unknown levels before known ones, no battery last.
  var batterySortKey: Int
  {
    guard let battery else
    {
      return Int.max
    }
    if let level = battery.level
    {
      return level
    }
    return battery.isLowFlagged == true ? -1 : 101
  }
}

struct Summary
{
  var deviceCount = 0
  var batteryCount = 0
  /// Batteries that have reported a level.
  var levelCount = 0
  /// Sorted lowest battery first.
  var lowBattery: [DeviceSnapshot] = []
  var notResponding: [DeviceSnapshot] = []
  var lowest: DeviceSnapshot?

  init(devices: [DeviceSnapshot])
  {
    deviceCount = devices.count
    for device in devices.sorted(using: DeviceSection.batteryOrder)
    {
      if device.battery != nil
      {
        batteryCount += 1
      }
      if device.hasBatteryLevel
      {
        levelCount += 1
      }
      if device.hasLowBattery
      {
        lowBattery.append(device)
      }
      if !device.isReachable
      {
        notResponding.append(device)
      }
      if lowest == nil && device.hasBatteryLevel
      {
        lowest = device
      }
    }
  }
}

enum Grouping: String, CaseIterable, Identifiable
{
  case room = "Room"
  case battery = "Battery level"

  var id: Self
  {
    self
  }
}

struct DeviceSection: Identifiable
{
  var id: String
  var title: String
  var devices: [DeviceSnapshot]

  static let nameOrder = KeyPathComparator(\DeviceSnapshot.name, comparator: .localizedStandard)
  static let batteryOrder = [KeyPathComparator(\DeviceSnapshot.batterySortKey), nameOrder]

  static func make(from devices: [DeviceSnapshot], grouping: Grouping, showHome: Bool) -> [DeviceSection]
  {
    switch grouping
    {
    case .battery:
      return [DeviceSection(id: "all", title: "All devices, lowest battery first", devices: devices.sorted(using: batteryOrder))]
    case .room:
      var groups: [String: [DeviceSnapshot]] = [:]
      for device in devices
      {
        groups[device.home + "\u{1F}" + device.room, default: []].append(device)
      }
      var sections: [DeviceSection] = []
      for (key, members) in groups
      {
        let first = members[0]
        let title = showHome ? "\(first.home) · \(first.room)" : first.room
        sections.append(DeviceSection(id: key, title: title, devices: members.sorted(using: nameOrder)))
      }
      return sections.sorted(using: KeyPathComparator(\DeviceSection.title, comparator: .localizedStandard))
    }
  }
}
