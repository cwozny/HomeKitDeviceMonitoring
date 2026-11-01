import Foundation
import Testing
@testable import HomeSensors

@Suite("Battery levels")
struct BatteryTests
{
  @Test("Severity follows the 20% low and 10% critical thresholds", arguments: [
    (5, Severity.critical),
    (10, Severity.critical),
    (11, Severity.warning),
    (20, Severity.warning),
    (21, Severity.normal),
    (100, Severity.normal),
  ])
  func severity(level: Int, expected: Severity)
  {
    #expect(Battery(level: level).severity == expected)
  }

  @Test("A low-battery flag is a warning; a battery with no information is normal")
  func lowBatteryFlag()
  {
    #expect(Battery(isLowFlagged: true).severity == .warning)
    #expect(Battery(level: 80, isLowFlagged: true).severity == .warning)
    #expect(Battery(isLowFlagged: false).severity == .normal)
    #expect(Battery().severity == .normal)
  }

  @Test("Sorts lowest first, then unknown levels, then devices without a battery")
  func sortOrder()
  {
    let names = sampleDevices.sorted(using: DeviceSection.batteryOrder).map(\.name)
    #expect(names == ["Flagged low", "Low", "Full", "Unknown level", "No battery"])
  }

  @Test("The summary lists low batteries lowest first and finds the lowest known level")
  func summary()
  {
    let summary = Summary(devices: sampleDevices)
    #expect(summary.deviceCount == 5)
    #expect(summary.batteryCount == 4)
    #expect(summary.lowBattery.map(\.name) == ["Flagged low", "Low"])
    #expect(summary.lowest?.name == "Low")
  }

  private var sampleDevices: [DeviceSnapshot]
  {
    [
      makeDevice("No battery"),
      makeDevice("Full", battery: Battery(level: 90)),
      makeDevice("Unknown level", battery: Battery()),
      makeDevice("Flagged low", battery: Battery(isLowFlagged: true)),
      makeDevice("Low", battery: Battery(level: 15)),
    ]
  }
}
