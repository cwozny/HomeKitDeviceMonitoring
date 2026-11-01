#if DEBUG
import Foundation

/// Fixed example accessories for SwiftUI previews and `-demo` launches.
enum SampleData
{
  static let devices: [DeviceSnapshot] = [
    make("Garage climate", room: "Garage", model: "TIMMERFLOTTE temp/humidity sensor", symbol: "thermometer.medium", battery: 86, readings: [(.temperature, 18.6), (.humidity, 54)]),
    make("Garage motion", room: "Garage", model: "MYGGSPRAY motion sensor", symbol: "figure.walk.motion", battery: 64, readings: [(.motion, 1), (.light, 212)]),
    make("Front door", room: "Entry", model: "MYGGBETT door/window sensor", symbol: "door.left.hand.closed", battery: 17, readings: [(.contact, 1)]),
    make("Under sink", room: "Kitchen", model: "KLIPPBOK water leak sensor", symbol: "drop.triangle", battery: 92, readings: [(.leak, 0)]),
    make("Kitchen air", room: "Kitchen", model: "ALPSTUGA air quality monitor", symbol: "aqi.medium", battery: nil, readings: [(.temperature, 21.4), (.humidity, 41), (.airQuality, 2), (.carbonDioxide, 712), (.pm25, 6)]),
    make("Bedroom climate", room: "Bedroom", model: "TIMMERFLOTTE temp/humidity sensor", symbol: "thermometer.medium", battery: 8, readings: [(.temperature, 19.9), (.humidity, 47)]),
    make("Hallway motion", room: "Hallway", model: "MYGGSPRAY motion sensor", symbol: "figure.walk.motion", battery: 51, readings: [(.motion, 0), (.light, 35)], reachable: false),
    make("Living room remote", room: "Living Room", model: "BILRESA remote", symbol: "button.programmable", battery: 73, readings: []),
    make("Laundry leak", room: "Laundry", model: "KLIPPBOK water leak sensor", symbol: "drop.triangle", battery: 39, readings: [(.leak, 1)]),
  ]

  private static func make(
    _ name: String,
    room: String,
    model: String,
    symbol: String,
    battery: Int?,
    readings: [(Reading.Kind, Double)],
    reachable: Bool = true
  ) -> DeviceSnapshot
  {
    var list: [Reading] = []
    for (kind, value) in readings
    {
      list.append(Reading(kind: kind, value: value))
    }
    var power: Battery?
    if let battery
    {
      power = Battery(level: battery)
    }
    return DeviceSnapshot(
      id: UUID(),
      name: name,
      home: "Home",
      room: room,
      manufacturer: "IKEA of Sweden",
      model: model,
      firmware: "1.0",
      symbol: symbol,
      isReachable: reachable,
      battery: power,
      readings: list
    )
  }
}
#endif
