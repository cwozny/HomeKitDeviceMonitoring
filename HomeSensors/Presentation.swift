import SwiftUI

extension Color
{
  init(hex: UInt32)
  {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

extension Severity
{
  /// Fixed status palette. Reserved for status and always paired with an icon and a label.
  var color: Color
  {
    switch self
    {
    case .normal:
      Color.accentColor
    case .warning:
      Color(hex: 0xFAB219)
    case .serious:
      Color(hex: 0xEC835A)
    case .critical:
      Color(hex: 0xD03B3B)
    }
  }

  var symbol: String
  {
    switch self
    {
    case .normal:
      "checkmark.circle.fill"
    case .warning:
      "exclamationmark.triangle.fill"
    case .serious:
      "exclamationmark.circle.fill"
    case .critical:
      "exclamationmark.octagon.fill"
    }
  }
}

/// One summary tile. Shared by the app and the web page so both say the same thing.
struct SummaryTile
{
  var label: String
  var value: String
  var detail: String
  var status: Severity?
}

extension Summary
{
  var tiles: [SummaryTile]
  {
    var lowestStatus: Severity?
    if let severity = lowest?.battery?.severity, severity > .normal
    {
      lowestStatus = severity
    }
    var lowDetail = Self.names(lowBattery)
    if lowBattery.isEmpty
    {
      // Only a reported level shows that a battery is above the threshold.
      lowDetail = levelCount == batteryCount ? "All above \(Battery.lowThreshold)%" : "None reported low"
    }
    return [
      SummaryTile(label: "Devices", value: deviceCount.formatted(), detail: "\(batteryCount) on battery"),
      SummaryTile(
        label: "Low battery",
        value: lowBattery.count.formatted(),
        detail: lowDetail,
        // The list puts low flags without a level first, so the worst status can come later.
        status: lowBattery.compactMap(\.battery?.severity).max()
      ),
      SummaryTile(
        label: "Not responding",
        value: notResponding.count.formatted(),
        detail: notResponding.isEmpty ? "All responding" : Self.names(notResponding),
        status: notResponding.isEmpty ? nil : .serious
      ),
      SummaryTile(
        label: "Lowest battery",
        value: lowest?.battery?.text ?? "—",
        detail: lowest?.name ?? "No battery levels yet",
        status: lowestStatus
      ),
    ]
  }

  private static func names(_ devices: [DeviceSnapshot]) -> String
  {
    devices.map(\.name).joined(separator: ", ")
  }
}

extension Battery
{
  var text: String
  {
    if let level
    {
      return "\(level)%"
    }
    if let isLowFlagged
    {
      return isLowFlagged ? "Low" : "OK"
    }
    return "—"
  }

  var accessibilityDescription: String
  {
    var parts: [String] = []
    if let level
    {
      parts.append("Battery \(level) percent")
      switch severity
      {
      case .critical:
        parts.append("critical")
      case .warning, .serious:
        parts.append("low")
      case .normal:
        break
      }
    }
    else if let isLowFlagged
    {
      parts.append(isLowFlagged ? "Battery low" : "Battery OK")
    }
    else
    {
      parts.append("Battery level unknown")
    }
    if charging == .charging
    {
      parts.append("charging")
    }
    return parts.joined(separator: ", ")
  }
}

extension Reading
{
  var name: String
  {
    switch kind
    {
    case .temperature:
      "Temperature"
    case .humidity:
      "Humidity"
    case .motion:
      "Motion"
    case .occupancy:
      "Occupancy"
    case .contact:
      "Contact"
    case .leak:
      "Water leak"
    case .smoke:
      "Smoke"
    case .carbonMonoxideDetected, .carbonMonoxide:
      "Carbon monoxide"
    case .carbonDioxideDetected, .carbonDioxide:
      "Carbon dioxide"
    case .airQuality:
      "Air quality"
    case .pm25:
      "PM2.5"
    case .pm10:
      "PM10"
    case .voc:
      "Volatile organic compounds"
    case .light:
      "Light level"
    case .fault:
      "Fault"
    case .tampered:
      "Tamper"
    }
  }

  private var isOn: Bool
  {
    (value ?? 0) != 0
  }

  private var isBinary: Bool
  {
    switch kind
    {
    case .motion, .occupancy, .contact, .leak, .smoke, .carbonMonoxideDetected, .carbonDioxideDetected, .fault, .tampered:
      true
    default:
      false
    }
  }

  /// A binary state at rest (no motion, closed, dry). Shown in secondary ink.
  var isQuiet: Bool
  {
    isBinary && value != nil && !isOn
  }

  /// A binary state that is set (motion, open, occupied). Shown in bold.
  var isActive: Bool
  {
    isBinary && isOn
  }

  /// Fault and tamper flags appear only when set.
  var isVisible: Bool
  {
    switch kind
    {
    case .fault, .tampered:
      isOn
    default:
      true
    }
  }

  var alert: Severity?
  {
    guard let value else
    {
      return nil
    }
    switch kind
    {
    case .leak, .smoke, .carbonMonoxideDetected:
      return value != 0 ? .critical : nil
    case .fault:
      return value != 0 ? .serious : nil
    case .carbonDioxideDetected, .tampered:
      return value != 0 ? .warning : nil
    case .airQuality:
      if value >= 5
      {
        return .serious
      }
      return value >= 4 ? .warning : nil
    default:
      return nil
    }
  }

  var symbol: String
  {
    switch kind
    {
    case .temperature:
      "thermometer.medium"
    case .humidity:
      "humidity"
    case .motion:
      "figure.walk.motion"
    case .occupancy:
      "person.fill"
    case .contact:
      isOn ? "door.left.hand.open" : "door.left.hand.closed"
    case .leak:
      "drop.triangle"
    case .smoke:
      "smoke"
    case .carbonMonoxideDetected, .carbonMonoxide:
      "carbon.monoxide.cloud"
    case .carbonDioxideDetected, .carbonDioxide:
      "carbon.dioxide.cloud"
    case .airQuality:
      "aqi.medium"
    case .pm25, .pm10, .voc:
      "aqi.low"
    case .light:
      "sun.max"
    case .fault:
      "wrench.and.screwdriver"
    case .tampered:
      "hand.raised"
    }
  }

  var text: String
  {
    guard let value else
    {
      return "—"
    }
    let whole = value.formatted(.number.precision(.fractionLength(0)))
    switch kind
    {
    case .temperature:
      let style = Measurement<UnitTemperature>.FormatStyle(
        width: .abbreviated,
        usage: .weather,
        numberFormatStyle: .number.precision(.fractionLength(1))
      )
      return Measurement(value: value, unit: UnitTemperature.celsius).formatted(style)
    case .humidity:
      return "\(whole)%"
    case .motion:
      return isOn ? "Motion" : "No motion"
    case .occupancy:
      return isOn ? "Occupied" : "Unoccupied"
    case .contact:
      return isOn ? "Open" : "Closed"
    case .leak:
      return isOn ? "Leak detected" : "Dry"
    case .smoke:
      return isOn ? "Smoke detected" : "No smoke"
    case .carbonMonoxideDetected:
      return isOn ? "CO detected" : "No CO"
    case .carbonDioxideDetected:
      return isOn ? "CO₂ high" : "CO₂ normal"
    case .airQuality:
      switch Int(value)
      {
      case 1:
        return "Excellent air"
      case 2:
        return "Good air"
      case 3:
        return "Fair air"
      case 4:
        return "Inferior air"
      case 5:
        return "Poor air"
      default:
        return "Air unknown"
      }
    case .carbonDioxide:
      return "CO₂ \(whole) ppm"
    case .carbonMonoxide:
      return "CO \(whole) ppm"
    case .pm25:
      return "PM2.5 \(whole) µg/m³"
    case .pm10:
      return "PM10 \(whole) µg/m³"
    case .voc:
      return "VOC \(whole) µg/m³"
    case .light:
      return "\(whole) lx"
    case .fault:
      return "Fault"
    case .tampered:
      return "Tampered"
    }
  }
}
