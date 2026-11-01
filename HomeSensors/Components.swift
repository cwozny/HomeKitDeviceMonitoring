import SwiftUI

struct StatTile: View
{
  var label: String
  var value: String
  var detail: String
  var status: Severity?

  var body: some View
  {
    VStack(alignment: .leading, spacing: 4)
    {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 6)
      {
        if let status
        {
          Image(systemName: status.symbol)
            .font(.title3)
            .foregroundStyle(status.color)
        }
        Text(value)
          .font(.title.weight(.semibold))
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
  }
}

struct DeviceRow: View
{
  var device: DeviceSnapshot
  var showRoom: Bool

  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View
  {
    Group
    {
      if sizeClass == .compact
      {
        compactLayout
      }
      else
      {
        wideLayout
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }

  private var wideLayout: some View
  {
    HStack(spacing: 16)
    {
      identity
        .frame(maxWidth: .infinity, alignment: .leading)
      readings
        .frame(minWidth: 200, maxWidth: 300, alignment: .leading)
      BatteryMeter(battery: device.battery)
        .frame(width: 150)
        .opacity(staleOpacity)
    }
  }

  private var compactLayout: some View
  {
    VStack(alignment: .leading, spacing: 8)
    {
      HStack(alignment: .top, spacing: 12)
      {
        identity
        Spacer(minLength: 0)
        BatteryMeter(battery: device.battery)
          .frame(width: 120)
          .opacity(staleOpacity)
      }
      readings
        .padding(.leading, 34)
    }
  }

  /// An accessory that isn't responding shows its last known values, dimmed.
  private var staleOpacity: Double
  {
    device.isReachable ? 1 : 0.5
  }

  private var identity: some View
  {
    HStack(spacing: 10)
    {
      Image(systemName: device.symbol)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2)
      {
        Text(device.name)
          .fontWeight(.medium)
          .lineLimit(1)
        if !subtitle.isEmpty
        {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if !device.isReachable
        {
          HStack(spacing: 4)
          {
            Image(systemName: Severity.serious.symbol)
              .foregroundStyle(Severity.serious.color)
            Text("Not responding")
              .foregroundStyle(.secondary)
          }
          .font(.caption)
        }
      }
    }
    .help(details)
  }

  @ViewBuilder
  private var readings: some View
  {
    let visible = device.readings.filter(\.isVisible)
    if visible.isEmpty
    {
      Text("No sensor readings")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    else
    {
      FlowLayout(spacing: 14, lineSpacing: 6)
      {
        ForEach(visible)
        {
          reading in
          ReadingChip(reading: reading)
        }
      }
      .opacity(staleOpacity)
    }
  }

  private var subtitle: String
  {
    var parts: [String] = []
    if showRoom
    {
      parts.append(device.room)
    }
    if let model = device.model, !model.isEmpty
    {
      parts.append(model)
    }
    return parts.joined(separator: " · ")
  }

  private var details: String
  {
    var parts: [String] = []
    if let manufacturer = device.manufacturer, !manufacturer.isEmpty
    {
      parts.append(manufacturer)
    }
    if let model = device.model, !model.isEmpty
    {
      parts.append(model)
    }
    if let firmware = device.firmware, !firmware.isEmpty
    {
      parts.append("Firmware \(firmware)")
    }
    return parts.joined(separator: " · ")
  }
}

struct ReadingChip: View
{
  var reading: Reading

  var body: some View
  {
    HStack(spacing: 4)
    {
      Image(systemName: reading.symbol)
        .foregroundStyle(iconStyle)
      Text(reading.text)
        .fontWeight(reading.alert != nil || reading.isActive ? .semibold : .regular)
        .foregroundStyle(reading.isQuiet ? .secondary : .primary)
    }
    .font(.callout)
    .help(reading.name)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(reading.name): \(reading.text)")
  }

  private var iconStyle: AnyShapeStyle
  {
    if let alert = reading.alert
    {
      return AnyShapeStyle(alert.color)
    }
    return AnyShapeStyle(.secondary)
  }
}

struct BatteryMeter: View
{
  var battery: Battery?

  var body: some View
  {
    HStack(spacing: 8)
    {
      if let battery
      {
        if let fraction = battery.fraction
        {
          MeterBar(fraction: fraction, tint: battery.severity.color)
        }
        else
        {
          Spacer(minLength: 0)
        }
        statusIcon(for: battery)
          .frame(width: 16, height: 16)
        Text(battery.text)
          .monospacedDigit()
          .frame(width: 40, alignment: .trailing)
      }
      else
      {
        Spacer(minLength: 0)
        Text("No battery")
          .foregroundStyle(.tertiary)
      }
    }
    .font(.callout)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(battery?.accessibilityDescription ?? "No battery")
  }

  @ViewBuilder
  private func statusIcon(for battery: Battery) -> some View
  {
    if battery.severity > .normal
    {
      Image(systemName: battery.severity.symbol)
        .foregroundStyle(battery.severity.color)
    }
    else if battery.charging == .charging
    {
      Image(systemName: "bolt.fill")
        .foregroundStyle(.secondary)
    }
    else
    {
      Color.clear
    }
  }
}

/// A thin meter: the fill carries severity, the track is a lighter step of the same hue.
struct MeterBar: View
{
  var fraction: Double
  var tint: Color

  var body: some View
  {
    GeometryReader
    {
      proxy in
      ZStack(alignment: .leading)
      {
        Capsule()
          .fill(tint.opacity(0.22))
        if fraction > 0
        {
          Capsule()
            .fill(tint)
            .frame(width: max(proxy.size.height, proxy.size.width * fraction))
        }
      }
    }
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}

/// Lays children out left to right and wraps onto new lines as needed.
struct FlowLayout: Layout
{
  var spacing: CGFloat = 12
  var lineSpacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize
  {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
  {
    let origins = arrange(subviews, width: bounds.width).origins
    for (index, origin) in origins.enumerated()
    {
      subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize)
  {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var maxX: CGFloat = 0
    for subview in subviews
    {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width
      {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      maxX = max(maxX, x + size.width)
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return (origins, CGSize(width: maxX, height: y + lineHeight))
  }
}
