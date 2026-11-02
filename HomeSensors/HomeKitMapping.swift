import HomeKit

/// Translates HomeKit accessories into dashboard snapshots.
enum HomeKitMapping
{
  private static let batteryTypes: Set<String> = [
    HMCharacteristicTypeBatteryLevel,
    HMCharacteristicTypeStatusLowBattery,
    HMCharacteristicTypeChargingState,
  ]

  /// The characteristics the dashboard reads and subscribes to.
  static func trackedCharacteristics(of accessory: HMAccessory) -> [HMCharacteristic]
  {
    var result: [HMCharacteristic] = []
    for service in accessory.services
    {
      for characteristic in service.characteristics
      {
        let type = characteristic.characteristicType
        if batteryTypes.contains(type) || Reading.Kind(characteristicType: type) != nil
        {
          result.append(characteristic)
        }
      }
    }
    return result
  }
}

extension Reading.Kind
{
  init?(characteristicType type: String)
  {
    switch type
    {
    case HMCharacteristicTypeCurrentTemperature:
      self = .temperature
    case HMCharacteristicTypeCurrentRelativeHumidity:
      self = .humidity
    case HMCharacteristicTypeMotionDetected:
      self = .motion
    case HMCharacteristicTypeOccupancyDetected:
      self = .occupancy
    case HMCharacteristicTypeContactState:
      self = .contact
    case HMCharacteristicTypeLeakDetected:
      self = .leak
    case HMCharacteristicTypeSmokeDetected:
      self = .smoke
    case HMCharacteristicTypeCarbonMonoxideDetected:
      self = .carbonMonoxideDetected
    case HMCharacteristicTypeCarbonDioxideDetected:
      self = .carbonDioxideDetected
    case HMCharacteristicTypeAirQuality:
      self = .airQuality
    case HMCharacteristicTypeCarbonDioxideLevel:
      self = .carbonDioxide
    case HMCharacteristicTypeCarbonMonoxideLevel:
      self = .carbonMonoxide
    case HMCharacteristicTypePM2_5Density:
      self = .pm25
    case HMCharacteristicTypePM10Density:
      self = .pm10
    case HMCharacteristicTypeVolatileOrganicCompoundDensity:
      self = .voc
    case HMCharacteristicTypeCurrentLightLevel:
      self = .light
    case HMCharacteristicTypeStatusFault:
      self = .fault
    case HMCharacteristicTypeStatusTampered:
      self = .tampered
    default:
      return nil
    }
  }
}

extension DeviceSnapshot
{
  /// Nil when the accessory has neither a battery nor a sensor reading.
  init?(accessory: HMAccessory, home: HMHome)
  {
    var hasBattery = false
    var level: Int?
    var isLow: Bool?
    var charging: Battery.Charging?
    var readings: [Reading] = []

    for characteristic in HomeKitMapping.trackedCharacteristics(of: accessory)
    {
      let type = characteristic.characteristicType
      let number = (characteristic.value as? NSNumber)?.doubleValue
      switch type
      {
      case HMCharacteristicTypeBatteryLevel:
        hasBattery = true
        if let number
        {
          level = Int(number.rounded())
        }
      case HMCharacteristicTypeStatusLowBattery:
        hasBattery = true
        if let number
        {
          isLow = isLow == true || number == 1
        }
      case HMCharacteristicTypeChargingState:
        if let number
        {
          charging = Battery.Charging(rawValue: Int(number))
        }
      default:
        if let kind = Reading.Kind(characteristicType: type)
        {
          readings.append(Reading(kind: kind, value: number))
        }
      }
    }

    let kinds = Set(readings.map(\.kind))
    guard hasBattery || kinds.contains(where: \.isMeasurement) else
    {
      return nil
    }

    self.init(
      id: accessory.uniqueIdentifier,
      name: accessory.name,
      room: (accessory.room ?? home.roomForEntireHome()).name,
      model: accessory.model,
      isReachable: accessory.isReachable,
      battery: hasBattery ? Battery(level: level, isLowFlagged: isLow, charging: charging) : nil,
      readings: readings.sorted(using: KeyPathComparator(\Reading.kind))
    )
  }
}
